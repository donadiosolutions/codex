#!/usr/bin/env bash
set -euo pipefail

base_image='registry.fedoraproject.org/fedora@sha256:7011f51bd8089d345be42d41f0aa3190d258823528852a5e7ec976fe2fd20f53'
base_tag=codex-fedora44-base:7011f51bd8089d345be42d41f0aa3190d258823528852a5e7ec976fe2fd20f53

if [[ "${1:-}" == --prepare-image ]]; then
  # Reuse signed RPM provisioning, letting DNF resolve Fedora package versions.
  provisioner=/workflow/.github/scripts/fedora-build-benchmark.sh
  grep -Eq '^alsa-lib-devel-[0-9]' "$provisioner"
  grep -Eq '^which-[0-9]' "$provisioner"
  prepared_script="$(mktemp)"
  trap 'unlink "$prepared_script"' EXIT
  # Expand the Rust version lookup in the provisioner after DNF installs Rust.
  # shellcheck disable=SC2016
  sed -E '/^alsa-lib-devel-[0-9]/,/^which-[0-9]/s/-[0-9].*[.](x86_64|noarch)$/\.\1/; s/= 1[.]98[.]1$/= "$(rpm -q --qf "%{VERSION}" rust)"/' \
    "$provisioner" > "$prepared_script"
  bash "$prepared_script" --prepare-image
  exit 0
fi

if [[ "${1:-}" == --build ]]; then
  workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
  source_dir="$workspace/source"
  results="${RUNNER_TEMP:?RUNNER_TEMP is required}"
  source_commit="${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
  source_repository="${SOURCE_REPOSITORY:?SOURCE_REPOSITORY is required}"
  [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'SOURCE_COMMIT must be a full lowercase Git SHA' >&2; exit 1; }
  [[ -d "$source_dir/.git" || -f "$source_dir/.git" ]] || { echo "Missing selected source checkout: $source_dir" >&2; exit 1; }
  actual_commit="$(git -c safe.directory=/src -C /src rev-parse HEAD)"
  [[ "$actual_commit" == "$source_commit" ]] || { echo "Selected source commit $actual_commit does not match SOURCE_COMMIT $source_commit" >&2; exit 1; }
  export STABLE_GIT_COMMIT="$actual_commit"

  export CARGO_HOME=/cache/cargo
  export CARGO_TARGET_DIR=/bench/target
  export CARGO_INCREMENTAL=0
  export CARGO_BUILD_JOBS=16
  export RUSTC=/usr/bin/rustc
  export RUSTC_BOOTSTRAP=1
  export RUSTC_WRAPPER=/usr/bin/sccache
  export SCCACHE_DIR=/cache/sccache
  export SCCACHE_CACHE_SIZE=20G
  export SCCACHE_SERVER_PORT=4227
  export SCCACHE_IDLE_TIMEOUT=14400
  export CARGO_PROFILE_RELEASE_DEBUG=full
  export CARGO_PROFILE_RELEASE_STRIP=none
  export CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO=off
  build_dir=/src
  source_code_sha="$actual_commit"
  export RUSTFLAGS='-Z min-recursion-limit=256 -C target-cpu=skylake-avx512 -C debuginfo=full -C strip=none -C split-debuginfo=off -C dwarf-version=5 -C force-frame-pointers=yes'
  export LC_ALL=C
  trap 'status=$?; trap - EXIT; sccache --show-stats --stats-format json > /bench/sccache-stats.json 2>/bench/sccache-stats-error.txt || true; sccache --stop-server > /bench/sccache-shutdown.txt 2>&1 || true; exit "$status"' EXIT

  rust_version="$(rpm -q --qf '%{VERSION}' rust)"
  for package in cargo rust-src rust-std-static; do
    test "$(rpm -q --qf '%{VERSION}' "$package")" = "$rust_version"
  done
  cp /opt/fedora-benchmark/*.txt /bench/
  mkdir -p /bench/raw "$CARGO_HOME" "$SCCACHE_DIR"
  v8_version="$(python3 - <<'PY'
import tomllib
from pathlib import Path

lock = tomllib.loads(Path('/src/codex-rs/Cargo.lock').read_text())
versions = sorted({p['version'] for p in lock['package'] if p['name'] == 'v8'})
if len(versions) != 1:
    raise SystemExit(f'expected one locked v8 crate version, found {versions!r}')
print(versions[0])
PY
)"
  target=x86_64-unknown-linux-gnu
  profile=ptrcomp_sandbox_release
  binding_dir="/cache/rusty_v8/$v8_version"
  mkdir -p "$binding_dir"
  archive="librusty_v8_${profile}_${target}.a.gz"
  binding="src_binding_${profile}_${target}.rs"
  manifest="rusty_v8_${profile}_${target}.sha256"
  base="https://github.com/openai/codex/releases/download/rusty-v8-v${v8_version}"
  for artifact in "$manifest" "$archive" "$binding"; do
    if [[ ! -s "$binding_dir/$artifact" ]]; then
      curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 \
        "$base/$artifact" -o "$binding_dir/$artifact.part"
      mv "$binding_dir/$artifact.part" "$binding_dir/$artifact"
    fi
  done
  trusted="/src/third_party/v8/rusty_v8_${v8_version//./_}_release_manifests.sha256"
  expected_manifest="$(awk -v name="$manifest" '$2 == name { print $1 }' "$trusted")"
  [[ "$expected_manifest" =~ ^[0-9a-f]{64}$ ]] || { echo "Missing trusted hash for $manifest" >&2; exit 1; }
  printf '%s  %s\n' "$expected_manifest" "$binding_dir/$manifest" | sha256sum --check -
  test "$(wc -l < "$binding_dir/$manifest")" -eq 2
  (cd "$binding_dir" && tr -d '\r' < "$manifest" | sha256sum --check -)
  export RUSTY_V8_ARCHIVE="$binding_dir/$archive"
  export RUSTY_V8_SRC_BINDING_PATH="$binding_dir/$binding"
  expected_archive="$(awk -v name="$archive" '$2 == name { print $1 }' "$binding_dir/$manifest")"
  expected_binding="$(awk -v name="$binding" '$2 == name { print $1 }' "$binding_dir/$manifest")"
  [[ "$expected_archive" =~ ^[0-9a-f]{64}$ && "$expected_binding" =~ ^[0-9a-f]{64}$ ]] || { echo 'Rusty V8 manifest does not contain both expected artifacts' >&2; exit 1; }
  printf '%s  %s\n' "$expected_archive" "$RUSTY_V8_ARCHIVE" "$expected_binding" "$RUSTY_V8_SRC_BINDING_PATH" | sha256sum --check -

  original_lock=/src/codex-rs/Cargo.lock
  metadata=/bench/workspace-metadata.json
  /usr/bin/cargo metadata --manifest-path /src/codex-rs/Cargo.toml \
    --locked --no-deps --format-version 1 > "$metadata"
  original_lock_sha="$(sha256sum "$original_lock" | cut -d' ' -f1)"
  cp "$original_lock" /bench/Cargo.lock.original
  lock_repair=$(python3 - "$metadata" "$original_lock" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

metadata = json.loads(Path(sys.argv[1]).read_text())
lock = tomllib.loads(Path(sys.argv[2]).read_text())
members = set(metadata["workspace_members"])
versions = {p["name"]: p["version"] for p in metadata["packages"] if p["id"] in members}
local = [p for p in lock["package"] if "source" not in p]
old = {p["name"]: p["version"] for p in local}
if len(versions) != len(members) or len(old) != len(local) or set(versions) != set(old):
    raise SystemExit("ambiguous or incomplete workspace/local lock package set")
print(sum(old[name] != version for name, version in versions.items()))
PY
)
  if [[ "$lock_repair" -gt 0 ]]; then
    build_dir=/bench/source
    [[ ! -e "$build_dir" ]] || { echo "Repair source destination already exists: $build_dir" >&2; exit 1; }
    mkdir -p "$build_dir"
    cp -a /src/. "$build_dir/"
    cmp -s "$original_lock" "$build_dir/codex-rs/Cargo.lock" || {
      echo 'Source-copy lockfile differs from the selected source lockfile' >&2
      exit 1
    }
    timeout --kill-after=30s 10m /usr/bin/cargo update --workspace \
      --manifest-path "$build_dir/codex-rs/Cargo.toml"
    python3 - "$metadata" /bench/Cargo.lock.original "$build_dir/codex-rs/Cargo.lock" <<'PY'
import copy
import json
import sys
import tomllib
from collections import Counter
from pathlib import Path

metadata = json.loads(Path(sys.argv[1]).read_text())
before = tomllib.loads(Path(sys.argv[2]).read_text())
after = tomllib.loads(Path(sys.argv[3]).read_text())
members = set(metadata["workspace_members"])
versions = {p["name"]: p["version"] for p in metadata["packages"] if p["id"] in members}
expected = copy.deepcopy(before)
local = [p for p in before["package"] if "source" not in p]
old = {p["name"]: p["version"] for p in local}
if len(versions) != len(members) or len(old) != len(local) or set(versions) != set(old):
    raise SystemExit("ambiguous or incomplete workspace/local lock package set")
changed = 0
for package in expected["package"]:
    if "source" in package:
        continue
    changed += package["version"] != versions[package["name"]]
    package["version"] = versions[package["name"]]
    for index, dependency in enumerate(package.get("dependencies", [])):
        parts = dependency.split(" ", 2)
        if len(parts) == 2 and parts[0] in old and parts[1] == old[parts[0]]:
            parts[1] = versions[parts[0]]
            package["dependencies"][index] = " ".join(parts)
key = lambda package: json.dumps(package, sort_keys=True)
other_before = {k: v for k, v in before.items() if k != "package"}
other_after = {k: v for k, v in after.items() if k != "package"}
if not changed or other_before != other_after or Counter(map(key, expected["package"])) != Counter(map(key, after["package"])):
    raise SystemExit("Cargo changed lock data beyond workspace package versions/references")
print(f"External records unchanged; normalized {changed} local workspace package versions")
PY
    repaired_lock_sha="$(sha256sum "$build_dir/codex-rs/Cargo.lock" | cut -d' ' -f1)"
    source_code_sha="$(git -c safe.directory="$build_dir" -C "$build_dir" rev-parse HEAD)"
    [[ "$source_code_sha" == "$actual_commit" ]] || { echo 'Repair copy source commit changed' >&2; exit 1; }
    git -c safe.directory="$build_dir" -C "$build_dir" diff --quiet "$actual_commit" -- . ':(exclude)codex-rs/Cargo.lock' || {
      echo 'Workspace lock repair changed source files outside Cargo.lock' >&2
      exit 1
    }
    cd "$build_dir/codex-rs"
  else
    repaired_lock_sha="$original_lock_sha"
    cd /src/codex-rs
  fi
  printf 'Source code unchanged SHA: %s\nOriginal workspace lock SHA-256: %s\nNormalized workspace lock SHA-256: %s\nWorkspace package versions repaired: %s\nBuild source directory: %s\n' \
    "$source_code_sha" "$original_lock_sha" "$repaired_lock_sha" "$lock_repair" "$build_dir" \
    > /bench/workspace-lock-repair.txt
  /usr/bin/cargo fetch --locked --target "$target"
  /usr/bin/cargo fetch --locked --manifest-path /usr/lib/rustlib/src/rust/library/Cargo.toml
  export CARGO_NET_OFFLINE=true
  /usr/bin/sccache --zero-stats
  /usr/bin/sccache --show-stats --stats-format json > /bench/sccache-before-build.json
  /usr/bin/cargo build -Zbuild-std=std,panic_abort --locked --release \
    --target "$target" --jobs 16 -p codex-cli --bin codex \
    -p codex-code-mode-host --bin codex-code-mode-host

  for binary in codex codex-code-mode-host; do
    path="$CARGO_TARGET_DIR/$target/release/$binary"
    [[ -x "$path" ]] || { echo "Missing built executable: $path" >&2; exit 1; }
    headers="$(readelf -hW "$path")"
    grep -Fq 'Class:                             ELF64' <<< "$headers"
    grep -Eq 'Machine:.*Advanced Micro Devices X86-64' <<< "$headers"
    program_headers="$(readelf -lW "$path")"
    grep -Fq '/lib64/ld-linux-x86-64.so.2' <<< "$program_headers"
    dynamic="$(readelf -dW "$path")"
    grep -Fq 'Shared library: [libc.so.6]' <<< "$dynamic"
    if grep -Eqi 'musl|ld-musl' <<< "$dynamic$program_headers"; then
      echo "$binary contains a musl interpreter or dependency" >&2
      exit 1
    fi
    sections="$(readelf -SW "$path")"
    for section in .debug_info .debug_abbrev .debug_line .symtab; do
      grep -Fq "$section" <<< "$sections" || { echo "$binary lacks $section" >&2; exit 1; }
    done
    timeout --kill-after=30s 5m readelf --debug-dump=info --dwarf-depth=1 "$path" > "/bench/$binary.dwarf-headers.txt"
    grep -Eq 'Version: +5([[:space:]]|$)' "/bench/$binary.dwarf-headers.txt" || {
      echo "$binary has no Rust compilation unit with DWARF version 5" >&2
      exit 1
    }
    install -m 0755 "$path" "/bench/raw/$binary"
    {
      printf 'Binary: %s\n' "$binary"
      stat --format='Size: %s bytes' "$path"
      sha256sum "$path"
      grep -E 'Class:|Machine:' <<< "$headers"
      grep -F 'Requesting program interpreter:' <<< "$program_headers"
      grep -F 'Shared library: [libc.so.6]' <<< "$dynamic"
      printf 'DWARF 5: confirmed in at least one compilation unit\n'
    } > "/bench/$binary.build-details.txt"
  done

  cat > /bench/build-details.txt <<EOF
Source repository: $source_repository
Source commit: $actual_commit
Source code unchanged SHA: $source_code_sha
Original workspace lock SHA-256: $original_lock_sha
Normalized workspace lock SHA-256: $repaired_lock_sha
Workspace package versions repaired: $lock_repair
Target: x86_64-unknown-linux-gnu
Rust: $(/usr/bin/rustc --version)
Cargo: $(/usr/bin/cargo --version)
Fedora packages: matching Rust, Cargo and standard library $rust_version from signed Fedora 44 RPMs; DNF-resolved package versions
Build: cargo build -Zbuild-std=std,panic_abort --locked --release --target x86_64-unknown-linux-gnu --jobs 16 -p codex-cli --bin codex -p codex-code-mode-host --bin codex-code-mode-host
RUSTFLAGS: $RUSTFLAGS
Release profile: optimized release; DEBUG=full, STRIP=none, SPLIT_DEBUGINFO=off
CPU requirement: x86-64 Skylake AVX-512 or newer with compatible AVX-512 support
Rusty V8: prebuilt ptrcomp_sandbox_release archive and binding, verified against selected-source release manifest
glibc: $(rpm -q glibc)
EOF
  exit 0
fi

[[ "${1:-}" != --* ]] || { echo "Unknown mode: $1" >&2; exit 2; }
workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
source_commit="${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
source_repository="${SOURCE_REPOSITORY:?SOURCE_REPOSITORY is required}"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'SOURCE_COMMIT must be a full lowercase Git SHA' >&2; exit 1; }
[[ -d "$workspace/source/.git" || -f "$workspace/source/.git" ]] || { echo "Missing selected source checkout: $workspace/source" >&2; exit 1; }
cache=/mnt/codex-build-cache
mountpoint -q "$cache" || { echo "Sticky disk is not mounted at $cache" >&2; exit 1; }
results="${RUNNER_TEMP:?RUNNER_TEMP is required}/fedora-benchmark"
container=codex-fedora44-benchmark
mkdir -p "$cache/images" "$cache/dnf" "$cache/rpms" "$cache/cargo" \
  "$cache/sccache" "$cache/rusty_v8" "$results"
[[ ! -e "$results/target" && ! -e "$results/raw" && ! -e "$results/dist" ]] || {
  echo "Results directory already contains build output: $results" >&2
  exit 1
}
mkdir "$results/raw" "$results/dist"

helper="$workspace/.github/scripts/fedora-release-build.sh"
provisioner="$workspace/.github/scripts/fedora-build-benchmark.sh"
[[ -x "$helper" && -f "$provisioner" ]] || { echo 'Missing trusted build helper or image provisioner' >&2; exit 1; }
prepared_key="$(cat "$provisioner" "$helper" | sha256sum | cut -c1-24)"
prepared_image="codex-fedora44-benchmark:$prepared_key"
prepared_tar="$cache/images/prepared-$prepared_key.tar"
prepared_sum="$prepared_tar.sha256"
base_tar="$cache/images/fedora44.tar"
base_sum="$base_tar.sha256"
created=false
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [[ "$created" == true ]]; then
    if ! docker stop --time 30 "$container" > "$results/container-stop.txt" 2>&1; then
      docker kill "$container" >> "$results/container-stop.txt" 2>&1 || true
      status=1
    fi
    docker inspect "$container" --format '{{json .State}}' > "$results/container-final-state.json" || status=1
    docker rm "$container" > /dev/null || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

load_image() {
  [[ -s "$2" ]] || { echo "Missing image checksum: $2" >&2; exit 1; }
  (cd "$(dirname "$1")" && sha256sum --check "$(basename "$2")")
  timeout --kill-after=30s 30m docker load --input "$1"
}
save_image() {
  timeout --kill-after=30s 30m docker save --output "$2.part" "$1"
  mv "$2.part" "$2"
  (cd "$(dirname "$2")" && sha256sum "$(basename "$2")" > "$(basename "$2").sha256")
}
start_container() {
  docker run --detach --name "$container" --cpus=16 --pids-limit=2048 \
    --mount "type=bind,src=$workspace/source,dst=/src,readonly" \
    --mount "type=bind,src=$workspace,dst=/workflow,readonly" \
    --mount "type=bind,src=$cache,dst=/cache" \
    --mount "type=bind,src=$results,dst=/bench" \
    --env "SOURCE_COMMIT=$source_commit" --env "SOURCE_REPOSITORY=$source_repository" \
    --env GITHUB_WORKSPACE=/workflow --env RUNNER_TEMP=/bench \
    --workdir /src/codex-rs "$1" sleep 12600
  created=true
}

if [[ -s "$prepared_tar" ]]; then
  load_image "$prepared_tar" "$prepared_sum"
else
  if [[ -s "$base_tar" ]]; then
    load_image "$base_tar" "$base_sum"
  else
    timeout --kill-after=30s 30m docker pull --platform linux/amd64 "$base_image"
    docker tag "$base_image" "$base_tag"
    save_image "$base_tag" "$base_tar"
    base_sum="$base_tar.sha256"
  fi
  start_container "$base_tag"
  timeout --kill-after=30s 30m docker exec "$container" \
    bash /workflow/.github/scripts/fedora-release-build.sh --prepare-image
  docker commit "$container" "$prepared_image" > "$results/prepared-image-id.txt"
  save_image "$prepared_image" "$prepared_tar"
  docker stop --time 30 "$container" > "$results/provision-container-stop.txt"
  docker rm "$container" > /dev/null
  created=false
fi

start_container "$prepared_image"
docker inspect "$container" --format '{{json .HostConfig}}' > "$results/container-host-config.json"
docker image inspect "$prepared_image" > "$results/prepared-image.json"
printf '%s\n' "$base_image" > "$results/base-image.txt"
lscpu > "$results/runner-cpu.txt"
timeout --kill-after=30s 200m docker exec "$container" \
  bash /workflow/.github/scripts/fedora-release-build.sh --build

for binary in codex codex-code-mode-host; do
  raw="$results/raw/$binary"
  [[ -s "$raw" ]] || { echo "Container did not produce $raw" >&2; exit 1; }
done
command -v zstd >/dev/null || { echo 'Runner-provided zstd is required' >&2; exit 1; }
zstd --version > "$results/zstd-version.txt"
zstd_flags=(-9 -T16 --long=26 -B64M '--zstd=ovlog=8,hlog=22,clog=22,mml=4,lmml=32')
for binary in codex codex-code-mode-host; do
  input="$results/raw/$binary"
  output="$results/dist/$binary-x86_64-unknown-linux-gnu.zst"
  timeout --kill-after=30s 30m zstd "${zstd_flags[@]}" -f "$input" -o "$output"
  timeout --kill-after=30s 30m zstd -t "$output"
  raw_sha="$(sha256sum "$input" | cut -d' ' -f1)"
  compressed_sha="$(timeout --kill-after=30s 30m zstd -dc "$output" | sha256sum | cut -d' ' -f1)"
  [[ "$raw_sha" == "$compressed_sha" ]] || { echo "Decompressed checksum mismatch for $binary" >&2; exit 1; }
done
(cd "$results/dist" && sha256sum codex-x86_64-unknown-linux-gnu.zst \
  codex-code-mode-host-x86_64-unknown-linux-gnu.zst > SHA256SUMS)
[[ "$(find "$results/dist" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 3 ]] || {
  echo 'dist/ must contain exactly the two compressed binaries and SHA256SUMS' >&2
  exit 1
}
(cd "$results/dist" && sha256sum --check SHA256SUMS)
cat > "$results/release-notes.md" <<EOF
Fedora 44 GNU/Linux x86_64 release build

Source repository: $source_repository
Source commit: $source_commit
Target: x86_64-unknown-linux-gnu
Compiler: $(awk -F': ' '/^Rust:/{print $2}' "$results/build-details.txt")
CPU requirement: x86-64 Skylake AVX-512 or newer with compatible AVX-512 support
Debug information: full Rust DWARF5, unstripped symbols, split debuginfo disabled
Native V8: verified prebuilt ptrcomp_sandbox_release archive and binding
Compressor: $(cat "$results/zstd-version.txt")
Compression flags: ${zstd_flags[*]}
Artifacts: codex-x86_64-unknown-linux-gnu.zst and codex-code-mode-host-x86_64-unknown-linux-gnu.zst
Checksums: SHA256SUMS contains the SHA-256 digests of both compressed artifacts
EOF
{
  printf '\nBuild environment:\n\n~~~text\n'
  cat "$results/build-details.txt"
  printf '~~~\n'
} >> "$results/release-notes.md"
printf 'Prepared artifacts in %s\nRelease notes: %s/release-notes.md\n' "$results/dist" "$results"
