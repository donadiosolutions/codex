#!/usr/bin/env bash
# Runs only inside the existing Fedora release build container.
set -euo pipefail
mode="${1:?mode required}"
source_root="${2:?selected build source required}"
version="${RELEASE_VERSION:?RELEASE_VERSION required}"
export CODEX_REPO_ROOT="$source_root"
export PYTHONDONTWRITEBYTECODE=1
target=x86_64-unknown-linux-gnu
voice="$source_root/third_party/voice"

if [[ "$mode" == --build ]]; then
  mkdir /bench/voice-archives
  # The selected source supplies every native source version and trusted hash.
  python3 - "$voice/sources.json" <<'PY' > /bench/voice-downloads.txt
import json, sys
for source in json.load(open(sys.argv[1]))['sources']:
    print(source['url'], source['archive'], source['sha256'], sep='\t')
PY
  while IFS=$'\t' read -r url archive digest; do
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 \
      "$url" -o "/bench/voice-archives/$archive"
    printf '%s  %s\n' "$digest" "/bench/voice-archives/$archive" | sha256sum --check -
  done < /bench/voice-downloads.txt
  # Fedora GCC reports ../lib64; the private SDK requires the canonical lib/.
  # Adjust only this configure option in a temporary selected-source recipe.
  cp -a "$voice" /bench/voice-recipe
  python3 - <<'PYLIBFFI'
from pathlib import Path
path = Path('/bench/voice-recipe/build_native.py')
text = path.read_text()
needle = '"--disable-docs",\n                *configure_options,'
assert text.count(needle) == 1, 'unsupported selected-source libffi configure recipe'
path.write_text(text.replace(needle, '"--disable-docs",\n                "--disable-multi-os-directory",\n                *configure_options,', 1))
PYLIBFFI
  native_flags=()
  for flag in -O3 -march=skylake-avx512 -g -gdwarf-5 -fno-omit-frame-pointer; do
    native_flags+=("--c-flag=$flag" "--cxx-flag=$flag")
  done
  python3 /bench/voice-recipe/build_native.py --archives /bench/voice-archives \
    --output /bench/voice-native --target "$target" --jobs 16 \
    --cc /usr/bin/gcc --cxx /usr/bin/g++ --ar /usr/bin/ar --ranlib /usr/bin/ranlib \
    --cmake /usr/bin/cmake --make /usr/bin/make --pkg-config /usr/bin/pkg-config \
    --shell /usr/bin/bash "${native_flags[@]}" > /bench/voice-native.log 2>&1
  printf 'STABLE_GIT_COMMIT %s\n' "$SOURCE_COMMIT" > /bench/voice-status.txt
  PYTHONPATH="$voice" python3 - <<'PY'
from pathlib import Path
from prepare_built_runtime import prepare_built
prepare_built(Path('/bench/voice-native/prefix'), Path('/bench/voice-native/built.json'),
              Path('/bench/voice-status.txt'), 'x86_64-unknown-linux-gnu',
              Path('/bench/voice-prepared'), sdk_output=Path('/bench/voice-sdk'))
PY
  python3 "$voice/release_runtime.py" stage --target "$target" \
    --source /bench/voice-prepared --output /bench/voice-runtime
  python3 "$voice/release_runtime.py" seal --target "$target" --output /bench/voice-runtime

  # GStreamer and GLib are private inputs. Only ALSA uses Fedora pkg-config.
  cat > /bench/voice-pkg-config <<'PKG'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == alsa ]]; then
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
    exec /usr/bin/pkg-config "$@"
  fi
done
export PKG_CONFIG_LIBDIR=/bench/voice-sdk/lib/pkgconfig:/bench/voice-sdk/share/pkgconfig
export PKG_CONFIG_PATH=
exec /usr/bin/pkg-config --define-prefix "$@"
PKG
  chmod 0755 /bench/voice-pkg-config
  (
    export PKG_CONFIG=/bench/voice-pkg-config
    export PKG_CONFIG_PATH=
    export PKG_CONFIG_LIBDIR=/bench/voice-sdk/lib/pkgconfig
    for key in GLIB_2_0 GOBJECT_2_0 GIO_2_0 GSTREAMER_1_0 GSTREAMER_BASE_1_0 GSTREAMER_APP_1_0 GSTREAMER_AUDIO_1_0; do
      export "SYSTEM_DEPS_${key}_SEARCH_NATIVE=/bench/voice-sdk/lib"
      if [[ "$key" == GSTREAMER_* ]]; then export "SYSTEM_DEPS_${key}_LDFLAGS="; fi
    done
    # shellcheck disable=SC2016 # ELF loader expands $ORIGIN at runtime.
    /usr/bin/cargo rustc --manifest-path "$source_root/codex-rs/Cargo.toml" \
      -Zbuild-std=std,panic_abort --locked --release --target "$target" --jobs 16 \
      -p codex-voice-host --bin codex-voice-host -- -C 'link-arg=-Wl,-rpath,$ORIGIN/../lib'
  )
  # Source identity and patch come from upstream's existing zsh release recipe.
  zsh_commit="$(sed -n 's/^  ZSH_COMMIT: //p' /workflow/.github/workflows/rust-release-zsh.yml)"
  [[ "$zsh_commit" =~ ^[0-9a-f]{40}$ ]]
  zsh_workspace="$source_root"
  zsh_patch=codex-rs/shell-escalation/patches/zsh-exec-wrapper.patch
  if [[ ! -f "$zsh_workspace/$zsh_patch" ]]; then
    # Upstream removed the backend in cd85a26, but still ships the zsh payload.
    # Preserve the exact patch blob from e89e5136bdd11931bb143fcafa2e89cc8313e99b.
    zsh_workspace=/workflow
    zsh_patch=.github/scripts/zsh-exec-wrapper.patch
    printf '%s  %s\n' 696b7d923b8071554d00e811afb9a08fcad4baada796f7314d12ecd72d06152c \
      "$zsh_workspace/$zsh_patch" | sha256sum --check -
  fi
  # zsh defaults to linking with -s unless these variables are explicitly set.
  GITHUB_WORKSPACE="$zsh_workspace" RUNNER_TEMP=/bench ZSH_COMMIT="$zsh_commit" \
    ZSH_PATCH="$zsh_patch" ZSH_BUILD_JOBS=16 LDFLAGS='' EXELDFLAGS='' LIBLDFLAGS='' \
    bash /workflow/.github/scripts/build-zsh-release-artifact.sh /bench/zsh.tar.gz \
    > /bench/zsh-build.log 2>&1
  mkdir /bench/zsh
  tar -xzf /bench/zsh.tar.gz -C /bench/zsh
  exit 0
fi
[[ "$mode" == --package ]] || { echo "Unknown mode: $mode" >&2; exit 2; }
python3 "$source_root/scripts/build_codex_package.py" --target "$target" --variant codex \
  --package-version "$version" --cargo-profile release --strip none \
  --entrypoint-bin /bench/raw/codex --code-mode-host-bin /bench/raw/codex-code-mode-host \
  --bwrap-bin /bench/raw/bwrap --zsh-bin /bench/raw/zsh --package-dir /bench/package
# Use the selected source's runtime policy/resources with the corrected validator.
mkdir /bench/package-helpers
cp -a "$voice" /bench/package-helpers/voice
python3 - <<'PYVALIDATOR'
import ast
from pathlib import Path

def version_pattern(text):
    nodes = [node.args[0] for node in ast.walk(ast.parse(text))
             if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
             and node.func.attr == 'fullmatch' and len(node.args) >= 2
             and isinstance(node.args[1], ast.Name) and node.args[1].id == 'release_version']
    assert len(nodes) == 1 and isinstance(nodes[0], ast.Constant)
    return nodes[0]

path = Path('/bench/package-helpers/voice/assemble_package.py')
text = path.read_text()
node = version_pattern(text)
trusted = version_pattern(Path('/workflow/third_party/voice/assemble_package.py').read_text())
old = r'[0-9]+\.[0-9]+\.[0-9]+(?:-alpha(?:\.[0-9]+){0,2}|-beta(?:\.[0-9]+)?)?'
assert node.value in (old, trusted.value), 'unsupported selected-source voice version validator'
lines = text.splitlines(keepends=True)
start = sum(map(len, lines[:node.lineno - 1])) + node.col_offset
end = sum(map(len, lines[:node.end_lineno - 1])) + node.end_col_offset
path.write_text(text[:start] + repr(trusted.value) + text[end:])
PYVALIDATOR
mkdir /bench/vendor
python3 /bench/package-helpers/voice/assemble_package.py --package /bench/package \
  --helper /bench/raw/codex-voice-host --runtime /bench/voice-runtime --voice-target "$target" \
  --build-commit "$SOURCE_COMMIT" --release-version "$version" \
  --output /bench/vendor/x86_64-unknown-linux-musl
mkdir -p /bench/dist
python3 "$source_root/codex-cli/scripts/build_npm_package.py" --package codex-linux-x64 \
  --release-version "$version" --vendor-src /bench/vendor --staging-dir /bench/npm-stage \
  --pack-output "/bench/dist/codex-npm-linux-x64-${version}.tgz"
# Validate the actual packed bytes after relocation, including voice initialization.
mkdir /bench/relocated-npm
tar -xzf "/bench/dist/codex-npm-linux-x64-${version}.tgz" -C /bench/relocated-npm
python3 /workflow/.github/scripts/verify-fedora-npm.py \
  /bench/relocated-npm/package "$version" "$SOURCE_COMMIT" "$CODEX_BWRAP_SHA256"
