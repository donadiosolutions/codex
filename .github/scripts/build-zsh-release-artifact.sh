#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <archive-path>" >&2
  exit 1
fi

archive_path="$1"
workspace="${GITHUB_WORKSPACE:?missing GITHUB_WORKSPACE}"
zsh_commit="${ZSH_COMMIT:?missing ZSH_COMMIT}"
zsh_patch="${ZSH_PATCH:?missing ZSH_PATCH}"
temp_root="${RUNNER_TEMP:-/tmp}"
work_root="$(mktemp -d "${temp_root%/}/codex-zsh-release.XXXXXX")"
trap 'rm -r -- "$work_root"' EXIT

if [[ -n "${ZSH_BUILD_JOBS:-}" ]]; then
  if [[ ! "$ZSH_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ZSH_BUILD_JOBS must be a positive integer" >&2
    exit 1
  fi
  build_jobs="$ZSH_BUILD_JOBS"
else
  if command -v nproc >/dev/null 2>&1; then
    build_jobs="$(nproc)"
  else
    build_jobs="$(getconf _NPROCESSORS_ONLN)"
  fi
fi

if [[ "$archive_path" = /* ]]; then
  output_archive="$archive_path"
else
  output_archive="${workspace%/}/$archive_path"
fi

source_root="${work_root}/zsh"
package_root="${work_root}/codex-zsh"
wrapper_path="${work_root}/exec-wrapper"
stdout_path="${work_root}/stdout.txt"
wrapper_log_path="${work_root}/wrapper.log"

mkdir -p "$source_root"
git -C "$source_root" init
git -C "$source_root" remote add origin https://git.code.sf.net/p/zsh/code
git -C "$source_root" fetch --depth=1 origin "$zsh_commit"
git -C "$source_root" checkout --detach FETCH_HEAD
fetched_commit="$(git -C "$source_root" rev-parse HEAD)"
if [[ "$fetched_commit" != "$zsh_commit" ]]; then
  echo "fetched zsh commit $fetched_commit does not match requested $zsh_commit" >&2
  exit 1
fi
cd "$source_root"
git apply "${workspace%/}/${zsh_patch}"
./Util/preconfig
./configure

make -j"${build_jobs}"

cat > "$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${CODEX_WRAPPER_LOG:?missing CODEX_WRAPPER_LOG}"
printf '%s\n' "$@" > "$CODEX_WRAPPER_LOG"
file="$1"
shift
if [[ "$#" -eq 0 ]]; then
  exec "$file"
fi
arg0="$1"
shift
exec -a "$arg0" "$file" "$@"
EOF
chmod +x "$wrapper_path"

CODEX_WRAPPER_LOG="$wrapper_log_path" \
EXEC_WRAPPER="$wrapper_path" \
"${source_root}/Src/zsh" -fc '/bin/echo smoke-zsh' > "$stdout_path"

grep -Fx "smoke-zsh" "$stdout_path"
grep -Fx "/bin/echo" "$wrapper_log_path"

mkdir -p "$package_root/bin" "$(dirname "$output_archive")"
cp "${source_root}/Src/zsh" "$package_root/bin/zsh"
chmod +x "$package_root/bin/zsh"

(cd "$work_root" && tar -czf "$output_archive" codex-zsh)
