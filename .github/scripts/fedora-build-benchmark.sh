#!/usr/bin/env bash
set -euo pipefail

# The workflow supplies a fresh disk key for cold, then the same key for hot.
phase="${BENCHMARK_PHASE:-cold}"
[[ "$phase" == cold || "$phase" == hot ]]
base_image='registry.fedoraproject.org/fedora@sha256:7011f51bd8089d345be42d41f0aa3190d258823528852a5e7ec976fe2fd20f53'
base_tag=codex-fedora44-base:7011f51bd8089d345be42d41f0aa3190d258823528852a5e7ec976fe2fd20f53

if [[ "${1:-}" == --prepare-image ]]; then
  mkdir -p /opt/fedora-benchmark /cache/rpms
  cat > /opt/fedora-benchmark/packages.requested.txt <<'PACKAGES'
alsa-lib-devel-1.2.16.1-1.fc44.x86_64
binutils-2.46.1-1.fc44.x86_64
cargo-1.98.1-1.fc44.x86_64
clang-22.1.8-4.fc44.x86_64
cmake-4.3.0-1.fc44.x86_64
curl-8.18.0-10.fc44.x86_64
findutils-4.10.0-7.fc44.x86_64
gcc-16.2.1-2.fc44.x86_64
gcc-c++-16.2.1-2.fc44.x86_64
git-2.55.0-1.fc44.x86_64
gzip-1.14-2.fc44.x86_64
libcap-devel-2.78-1.fc44.x86_64
make-4.4.1-12.fc44.x86_64
openssl-devel-3.5.9-1.fc44.x86_64
perl-5.42.3-525.fc44.x86_64
pkgconf-pkg-config-2.5.1-1.fc44.x86_64
procps-ng-4.0.6-1.fc44.x86_64
python3-3.14.7-1.fc44.x86_64
rust-1.98.1-1.fc44.x86_64
rust-src-1.98.1-1.fc44.noarch
rust-std-static-1.98.1-1.fc44.x86_64
sccache-0.17.0-3.fc44.x86_64
tar-1.35-9.fc44.x86_64
time-1.9-28.fc44.x86_64
which-2.25-1.fc44.x86_64
PACKAGES
  mapfile -t packages < /opt/fedora-benchmark/packages.requested.txt
  # Retain missing dependencies; installed base-image providers stay in the image.
  dnf --setopt=cachedir=/cache/dnf --setopt=keepcache=1 download \
    --resolve --destdir=/cache/rpms "${packages[@]}"
  rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-primary
  rpm -K /cache/rpms/*.rpm > /opt/fedora-benchmark/packages.signatures.txt
  rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' /cache/rpms/*.rpm \
    | sort > /opt/fedora-benchmark/packages.resolved.txt
  dnf install -y --disablerepo='*' --setopt=gpgcheck=1 \
    --setopt=localpkg_gpgcheck=1 /cache/rpms/*.rpm
  rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    | sort > /opt/fedora-benchmark/packages.installed.txt
  for package in rust cargo rust-src; do
    test "$(rpm -q --qf '%{VERSION}' "$package")" = 1.98.1
  done
  exit 0
fi

if [[ "${1:-}" == --build ]]; then
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
  # Final ThinLTO can outlast the default daemon idle timeout and erase stats.
  export SCCACHE_IDLE_TIMEOUT=14400
  export RUSTFLAGS='-Z min-recursion-limit=256 -C target-cpu=skylake-avx512 -C debuginfo=full -C strip=none -C split-debuginfo=off -C dwarf-version=5 -C force-frame-pointers=yes'
  STABLE_GIT_COMMIT="$(git -c safe.directory=/src -C /src rev-parse HEAD)"
  export STABLE_GIT_COMMIT
  export LC_ALL=C
  if [[ "$phase" == hot ]]; then export CARGO_NET_OFFLINE=true; fi
  trap 'sccache --stop-server > /bench/sccache-shutdown.txt 2>&1 || true' EXIT
  cp /opt/fedora-benchmark/*.txt /bench/
  for package in rust cargo rust-src; do
    test "$(rpm -q --qf '%{VERSION}' "$package")" = 1.98.1
  done

  target=x86_64-unknown-linux-gnu
  version="$(python3 /src/.github/scripts/rusty_v8_bazel.py resolved-v8-crate-version)"
  profile=ptrcomp_sandbox_release
  binding_dir="/cache/rusty_v8/$version"
  mkdir -p "$binding_dir" "$SCCACHE_DIR" /bench/probe
  archive="librusty_v8_${profile}_${target}.a.gz"
  binding="src_binding_${profile}_${target}.rs"
  manifest="rusty_v8_${profile}_${target}.sha256"
  base="https://github.com/openai/codex/releases/download/rusty-v8-v${version}"
  for artifact in "$manifest" "$archive" "$binding"; do
    if [[ ! -s "$binding_dir/$artifact" ]]; then
      [[ "$phase" == cold ]] || { echo "Hot cache missing $artifact" >&2; exit 1; }
      curl --fail --location --retry 2 --max-time 300 "$base/$artifact" \
        -o "$binding_dir/$artifact.part"
      mv "$binding_dir/$artifact.part" "$binding_dir/$artifact"
    fi
  done
  trusted="/src/third_party/v8/rusty_v8_${version//./_}_release_manifests.sha256"
  expected="$(awk -v name="$manifest" '$2 == name { print $1 }' "$trusted")"
  test -n "$expected"
  printf '%s  %s\n' "$expected" "$binding_dir/$manifest" | sha256sum --check -
  test "$(wc -l < "$binding_dir/$manifest")" -eq 2
  (cd "$binding_dir" && tr -d '\r' < "$manifest" | sha256sum --check -)
  cp "$binding_dir/$manifest" /bench/
  export RUSTY_V8_ARCHIVE="$binding_dir/$archive"
  export RUSTY_V8_SRC_BINDING_PATH="$binding_dir/$binding"

  cd /src/codex-rs
  fetch_options=(--locked)
  if [[ "$phase" == hot ]]; then fetch_options+=(--offline); fi
  /usr/bin/cargo fetch "${fetch_options[@]}" --target "$target"
  /usr/bin/cargo fetch "${fetch_options[@]}" \
    --manifest-path /usr/lib/rustlib/src/rust/library/Cargo.toml
  # sccache hashes CARGO_* variables: both measured builds must match exactly.
  # Cold hydration may download, but compilation needs only the hydrated inputs.
  export CARGO_NET_OFFLINE=true
  printf 'pub fn flags_probe() -> u64 { 42 }\n' > /bench/probe/probe.rs
  read -r -a flags <<< "$RUSTFLAGS"
  sccache /usr/bin/rustc "${flags[@]}" --crate-name flags_probe --crate-type rlib \
    --emit link --out-dir /bench/probe /bench/probe/probe.rs
  sccache --show-stats --stats-format json > /bench/cache-probe.json
  if [[ "$phase" == hot ]]; then
    python3 -c 'import json; s = json.load(open("/bench/cache-probe.json")); assert s["stats"]["cache_hits"]["counts"].get("Rust", 0) > 0, "Hot compiler cache probe missed"'
    echo 'Persistent Rust cache probe hit; starting measured hot build.'
  fi
  cat /proc/self/cgroup > /bench/container-cgroup.txt
  ps -eo pid,ppid,args > /bench/processes-before.txt
  status=0
  python3 /src/.github/scripts/measure-fedora-build.py || status=$?
  if [[ -d "$CARGO_TARGET_DIR/cargo-timings" ]]; then
    cp -r "$CARGO_TARGET_DIR/cargo-timings" /bench/cargo-timings
  fi
  for binary in codex codex-code-mode-host; do
    path="$CARGO_TARGET_DIR/$target/release/$binary"
    if [[ -x "$path" ]]; then
      {
        stat --format='Size: %s bytes' "$path"
        sha256sum "$path"
        readelf -l "$path"
        readelf -d "$path"
        readelf -SW "$path"
        ldd "$path"
      } > "/bench/$binary.elf.txt"
    elif [[ "$status" == 0 ]]; then
      echo "Missing binary $path" >&2
      status=1
    fi
  done
  cat /sys/fs/cgroup/memory.events > /bench/memory-events.txt
  exit "$status"
fi

cache=/mnt/codex-build-cache
mountpoint -q "$cache" || { echo "Sticky disk is not mounted at $cache" >&2; exit 1; }
if [[ "$phase" == cold ]]; then
  for input in images dnf rpms cargo sccache rusty_v8; do
    if [[ -d "$cache/$input" && -n "$(find "$cache/$input" -mindepth 1 -print -quit)" ]]; then
      echo 'Cold benchmark requires a fresh sticky disk key' >&2
      exit 1
    fi
  done
fi
results="${RUNNER_TEMP:?}/fedora-benchmark"
workspace="${GITHUB_WORKSPACE:?}"
container=codex-fedora44-benchmark
mkdir -p "$cache/images" "$cache/dnf" "$cache/rpms" "$cache/cargo" \
  "$cache/sccache" "$cache/rusty_v8" "$results"
# A fresh local target is necessary even when the disk is hot.
test ! -e "$results/target"
prepared_key="$(sha256sum "$workspace/.github/scripts/fedora-build-benchmark.sh" | cut -c1-24)"
prepared_image="codex-fedora44-benchmark:$prepared_key"
prepared_tar="$cache/images/prepared-$prepared_key.tar"
base_tar="$cache/images/fedora44.tar"
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
  (cd "$cache/images" && sha256sum --check "$(basename "$1").sha256")
  timeout --kill-after=30s 30m docker load --input "$1"
}
save_image() {
  timeout --kill-after=30s 30m docker save --output "$2.part" "$1"
  mv "$2.part" "$2"
  (cd "$cache/images" && sha256sum "$(basename "$2")" > "$(basename "$2").sha256")
}
start_container() {
  docker run --detach --name "$container" --cpus=16 --pids-limit=2048 \
    --mount "type=bind,src=$workspace,dst=/src,readonly" \
    --mount "type=bind,src=$cache,dst=/cache" \
    --mount "type=bind,src=$results,dst=/bench" \
    --env "BENCHMARK_PHASE=$phase" --workdir /src/codex-rs "$1" sleep 12600
  created=true
}
if [[ -s "$prepared_tar" ]]; then
  load_image "$prepared_tar"
else
  [[ "$phase" == cold ]] || { echo 'Hot cache missing prepared Fedora image' >&2; exit 1; }
  if [[ -s "$base_tar" ]]; then
    load_image "$base_tar"
  else
    timeout --kill-after=30s 30m docker pull --platform linux/amd64 "$base_image"
    docker tag "$base_image" "$base_tag"
    save_image "$base_tag" "$base_tar"
  fi
  start_container "$base_tag"
  timeout --kill-after=30s 30m docker exec "$container" \
    bash /src/.github/scripts/fedora-build-benchmark.sh --prepare-image
  docker commit "$container" "$prepared_image" > "$results/prepared-image-id.txt"
  save_image "$prepared_image" "$prepared_tar"
  docker stop --time 30 "$container"
  docker rm "$container"
  created=false
fi
start_container "$prepared_image"
docker inspect "$container" --format '{{json .HostConfig}}' > "$results/container-host-config.json"
docker image inspect "$prepared_image" > "$results/prepared-image.json"
printf '%s\n' "$base_image" > "$results/base-image.txt"
lscpu > "$results/runner-cpu.txt"
timeout --kill-after=30s 200m docker exec "$container" \
  bash /src/.github/scripts/fedora-build-benchmark.sh --build
