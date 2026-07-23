#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: package-kernel-bootstrap.sh

Required environment:
  KERNEL_SOURCE_DIR             authoritative kernel worktree
  KERNEL_GIT_DIR                authoritative Git object database
  KERNEL_BUILD_DIR              completed out-of-tree kernel build
  EXPECTED_KERNEL_COMMIT        exact 40-hex source commit
  EXPECTED_KERNEL_CONFIG_SHA256 exact approved post-olddefconfig .config digest
  KERNEL_PACKAGE_VERSION        Debian version for the modules package
  BASE_DEVICE_DEB_ARCHIVE       tested device archive to update
  BASE_DEVICE_DEB_ARCHIVE_SHA256

Optional environment:
  OUTPUT_DIR                    default: out/tb321fu-kernel-bootstrap
  SOURCE_DATE_EPOCH             default: kernel commit timestamp
  KERNEL_BUILD_JOBS             default: host CPU count
  ARCH                          default: arm64
  CROSS_COMPILE                 default: aarch64-linux-gnu-
  DTB_NAME                      default: sm8650-lenovo-tb321fu.dtb
  KBUILD_BUILD_TIMESTAMP        default: UTC kernel commit timestamp
  KBUILD_BUILD_USER             default: tb321fu-ci
  KBUILD_BUILD_HOST             default: tb321fu-builder
  KBUILD_BUILD_VERSION          default: 1
  KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY
                                explicit producer identity; otherwise use
                                GITHUB_REPOSITORY. It must be
                                GUF296/ubuntu-y700-build-ci.
  KERNEL_RUSTC                  required when the approved config enables Rust;
                                otherwise defaults to /bin/false so host Rust
                                installation state cannot rewrite Kconfig probes

Options:
  --preflight                   validate source/config/build and producer identity

The baseline rootfs-overlay DEB and compat overlay are copied byte-for-byte.
  Only the kernel-modules DEB is replaced. Image, DTB and modules must come from
  the same clean, commit-bound build. The output also records a deterministic
  kernel SDK tree manifest; it avoids copying a second, potentially multi-GB SDK.
EOF
}

mode=build
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --preflight) mode=preflight; shift ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

for command in git make sha256sum find sort xargs rsync cp dpkg dpkg-deb depmod modinfo tar gzip touch realpath nproc date install awk stat grep sed readlink wc tr; do
  ci_require_cmd "$command"
done

: "${KERNEL_SOURCE_DIR:?set KERNEL_SOURCE_DIR}"
: "${KERNEL_GIT_DIR:?set KERNEL_GIT_DIR}"
: "${KERNEL_BUILD_DIR:?set KERNEL_BUILD_DIR}"
: "${EXPECTED_KERNEL_COMMIT:?set EXPECTED_KERNEL_COMMIT}"
: "${EXPECTED_KERNEL_CONFIG_SHA256:?set EXPECTED_KERNEL_CONFIG_SHA256}"
: "${KERNEL_PACKAGE_VERSION:?set KERNEL_PACKAGE_VERSION}"
: "${BASE_DEVICE_DEB_ARCHIVE:?set BASE_DEVICE_DEB_ARCHIVE}"
: "${BASE_DEVICE_DEB_ARCHIVE_SHA256:?set BASE_DEVICE_DEB_ARCHIVE_SHA256}"

ARCH=${ARCH:-arm64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-kernel-bootstrap}
KERNEL_BUILD_JOBS=${KERNEL_BUILD_JOBS:-$(nproc)}
KERNEL_RUSTC=${KERNEL_RUSTC:-}

[[ $EXPECTED_KERNEL_COMMIT =~ ^[0-9a-f]{40}$ ]] || ci_die "EXPECTED_KERNEL_COMMIT must be 40 lowercase hex characters"
[[ $EXPECTED_KERNEL_CONFIG_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid EXPECTED_KERNEL_CONFIG_SHA256"
[[ $BASE_DEVICE_DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid baseline archive SHA-256"
[[ $DTB_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\.dtb$ ]] || ci_die "unsafe DTB_NAME"
[[ $KERNEL_PACKAGE_VERSION =~ ^[0-9][0-9A-Za-z.+~_-]{0,63}$ ]] || ci_die "unsafe KERNEL_PACKAGE_VERSION"
[[ $KERNEL_BUILD_JOBS =~ ^[1-9][0-9]{0,3}$ ]] || ci_die "invalid KERNEL_BUILD_JOBS"
[[ $CROSS_COMPILE =~ ^/?[A-Za-z0-9][A-Za-z0-9._+/-]{0,254}-$ && $CROSS_COMPILE != *..* && $CROSS_COMPILE != *//* ]] ||
  ci_die "unsafe CROSS_COMPILE"
dpkg --validate-version "$KERNEL_PACKAGE_VERSION" >/dev/null || ci_die "invalid KERNEL_PACKAGE_VERSION"
for command in gcc as ld ar nm objcopy strip; do
  ci_require_cmd "${CROSS_COMPILE}${command}"
done

kernel_source=$(realpath -e -- "$KERNEL_SOURCE_DIR")
kernel_git=$(realpath -e -- "$KERNEL_GIT_DIR")
kernel_build_input=$(realpath -e -- "$KERNEL_BUILD_DIR")
[ -d "$kernel_source" ] || ci_die "kernel source is not a directory"
[ -d "$kernel_git/objects" ] || ci_die "KERNEL_GIT_DIR is not a Git object database"
[ -d "$kernel_build_input" ] || ci_die "kernel build is not a directory"
[ -s "$kernel_build_input/.config" ] || ci_die "kernel build has no prepared .config"
configured_rustc_version=$(awk -F= '
  $1 == "CONFIG_RUSTC_VERSION" { print $2; count++ }
  END { exit count == 1 ? 0 : 1 }
' "$kernel_build_input/.config") ||
  ci_die 'kernel config must contain exactly one CONFIG_RUSTC_VERSION'
[[ $configured_rustc_version =~ ^[0-9]+$ ]] ||
  ci_die 'CONFIG_RUSTC_VERSION is not numeric'
if [ "$configured_rustc_version" = 0 ]; then
  # A Rust-disabled config must not acquire host Rust behavior merely because
  # an ambient KERNEL_RUSTC was supplied. /bin/false is recorded explicitly
  # as the inert sentinel in the toolchain evidence.
  KERNEL_RUSTC=/bin/false
elif [ -z "$KERNEL_RUSTC" ]; then
  ci_die 'set KERNEL_RUSTC to the compiler used by the approved Rust-enabled config'
fi
[[ $KERNEL_RUSTC = /* ]] || ci_die 'KERNEL_RUSTC must be an absolute path'
kernel_rustc=$(realpath -e -- "$KERNEL_RUSTC")
[ -f "$kernel_rustc" ] && [ -x "$kernel_rustc" ] ||
  ci_die 'KERNEL_RUSTC must resolve to an executable regular file'
kernel_build=$kernel_build_input

git_cmd=(ci_sanitized_git_env git --no-replace-objects --git-dir="$kernel_git" --work-tree="$kernel_source")
expected_config_sha=${EXPECTED_KERNEL_CONFIG_SHA256,,}

verify_kernel_source_state() {
  local phase=$1 actual status ignored index_flags config_sha

  actual=$("${git_cmd[@]}" rev-parse HEAD)
  [ "$actual" = "$EXPECTED_KERNEL_COMMIT" ] ||
    ci_die "kernel commit mismatch $phase: expected $EXPECTED_KERNEL_COMMIT, got $actual"
  status=$("${git_cmd[@]}" status --porcelain=v1 --untracked-files=all)
  [ -z "$status" ] || ci_die "kernel worktree must be clean $phase"
  ignored=$("${git_cmd[@]}" status --porcelain=v1 --ignored --untracked-files=all | awk '$1 == "!!"')
  [ -z "$ignored" ] || ci_die "kernel worktree contains ignored files $phase"
  index_flags=$("${git_cmd[@]}" ls-files -v)
  if grep -Eq '^[a-zS] ' <<<"$index_flags"; then
    ci_die "kernel worktree has unsafe assume-unchanged/skip-worktree index flags $phase"
  fi
  config_sha=$(sha256sum "$kernel_build/.config" | awk '{print $1}')
  [ "$config_sha" = "$expected_config_sha" ] ||
    ci_die "kernel config SHA-256 mismatch $phase: expected $expected_config_sha, got $config_sha"
}

kernel_make() {
  ci_sanitized_kernel_env \
    GIT_DIR="$kernel_git" \
    GIT_WORK_TREE="$kernel_source" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    KBUILD_BUILD_TIMESTAMP="$KBUILD_BUILD_TIMESTAMP" \
    KBUILD_BUILD_USER="$KBUILD_BUILD_USER" \
    KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST" \
    KBUILD_BUILD_VERSION="$KBUILD_BUILD_VERSION" \
    KCONFIG_NOTIMESTAMP=1 \
    make -C "$kernel_source" O="$kernel_build" RUSTC="$kernel_rustc" "$@"
}

write_kernel_build_input_state() {
  local destination=$1

  [ -s "$kernel_build_input/.config" ] ||
    ci_die 'kernel build input is missing the approved .config'
  (cd "$kernel_build_input" && sha256sum -- .config) > "$destination"
}

verify_kernel_build_input_state() {
  local state_file=$1

  (cd "$kernel_build_input" && sha256sum --strict --check "$state_file" >/dev/null) ||
    ci_die "kernel build input changed while bootstrap packaging ran"
}

ci_require_tsv_scalar() {
  local label=$1 value=$2 maximum=${3:-512}

  [ -n "$value" ] && [ "${#value}" -le "$maximum" ] ||
    ci_die "invalid $label"
  [[ $value != *$'\t'* && $value != *$'\r'* && $value != *$'\n'* ]] ||
    ci_die "invalid $label"
  [ "$(LC_ALL=C printf '%s' "$value" | tr -d '\040-\176' | wc -c)" -eq 0 ] ||
    ci_die "invalid $label"
}

tool_sha256() {
  local command=$1 path

  path=$(realpath -e -- "$(command -v "$command")")
  [ -f "$path" ] && [ -x "$path" ] ||
    ci_die "tool is not an executable regular file: $command"
  sha256sum "$path" | awk '{print $1}'
}

tool_version() {
  local command=$1 value

  value=$("$command" --version 2>/dev/null | sed -n '1p' || true)
  ci_require_tsv_scalar "tool version for $command" "$value" 255
  printf '%s\n' "$value"
}

write_toolchain_record() {
  local label=$1 command=$2 sha version

  sha=$(tool_sha256 "$command")
  version=$(tool_version "$command")
  printf '%s-sha256\t%s\n' "$label" "$sha"
  printf '%s-version\t%s\n' "$label" "$version"
}

kernel_rustc_version() {
  if [ "$configured_rustc_version" = 0 ]; then
    printf 'disabled\n'
  else
    tool_version "$kernel_rustc"
  fi
}

write_rustc_toolchain_record() {
  local sha version

  sha=$(tool_sha256 "$kernel_rustc")
  version=$(kernel_rustc_version)
  printf 'rustc-sha256\t%s\n' "$sha"
  printf 'rustc-version\t%s\n' "$version"
}

write_kernel_toolchain_manifest() {
  local destination=$1

  {
    printf 'schema\ttb321fu.kernel-toolchain/v1\n'
    printf 'cross-compile\t%s\n' "$CROSS_COMPILE"
    write_toolchain_record gcc "${CROSS_COMPILE}gcc"
    write_toolchain_record as "${CROSS_COMPILE}as"
    write_toolchain_record ld "${CROSS_COMPILE}ld"
    write_toolchain_record ar "${CROSS_COMPILE}ar"
    write_toolchain_record nm "${CROSS_COMPILE}nm"
    write_toolchain_record objcopy "${CROSS_COMPILE}objcopy"
    write_toolchain_record strip "${CROSS_COMPILE}strip"
    write_rustc_toolchain_record
    write_toolchain_record make make
    write_toolchain_record dpkg-deb dpkg-deb
  } > "$destination"
}

write_kbuild_flags_manifest() {
  local destination=$1

  {
    printf 'schema\ttb321fu.kbuild-flags/v1\n'
    printf 'arch\t%s\n' "$ARCH"
    printf 'cross-compile\t%s\n' "$CROSS_COMPILE"
    printf 'kconfig-notimestamp\t1\n'
    printf 'kcflags\tunset\n'
    printf 'kaflags\tunset\n'
    printf 'kcppflags\tunset\n'
    printf 'krustflags\tunset\n'
    printf 'kbuild-cflags\tunset\n'
    printf 'kbuild-aflags\tunset\n'
    printf 'kbuild-cppflags\tunset\n'
    printf 'kbuild-rustflags\tunset\n'
    printf 'cflags\tunset\n'
    printf 'cxxflags\tunset\n'
    printf 'cppflags\tunset\n'
    printf 'asflags\tunset\n'
    printf 'ldflags\tunset\n'
    printf 'cflags-kernel\tunset\n'
    printf 'cflags-module\tunset\n'
    printf 'aflags-kernel\tunset\n'
    printf 'aflags-module\tunset\n'
    printf 'ldflags-vmlinux\tunset\n'
    printf 'ldflags-module\tunset\n'
    printf 'hostcflags\tunset\n'
    printf 'hostcxxflags\tunset\n'
    printf 'hostldflags\tunset\n'
    printf 'usercflags\tunset\n'
    printf 'userldflags\tunset\n'
    printf 'makeflags\tunset\n'
    printf 'makeoverrides\tunset\n'
    printf 'source-date-epoch\t%s\n' "$SOURCE_DATE_EPOCH"
    printf 'kbuild-build-timestamp\t%s\n' "$KBUILD_BUILD_TIMESTAMP"
    printf 'kbuild-build-user\t%s\n' "$KBUILD_BUILD_USER"
    printf 'kbuild-build-host\t%s\n' "$KBUILD_BUILD_HOST"
    printf 'kbuild-build-version\t%s\n' "$KBUILD_BUILD_VERSION"
  } > "$destination"
}

validate_sdk_relative_path() {
  local relative=$1 component

  [ -n "$relative" ] && [ "${#relative}" -le 4094 ] ||
    ci_die 'kernel SDK manifest contains an unsafe path'
  [[ $relative != /* && $relative != *//* && $relative != */ ]] ||
    ci_die 'kernel SDK manifest contains an unsafe path'
  [[ $relative != *$'\t'* && $relative != *$'\r'* && $relative != *$'\n'* ]] ||
    ci_die 'kernel SDK manifest contains an unsafe path'
  IFS=/ read -r -a sdk_components <<< "$relative"
  for component in "${sdk_components[@]}"; do
    [ -n "$component" ] && [ "$component" != . ] && [ "$component" != .. ] &&
      [ "${#component}" -le 255 ] ||
      ci_die 'kernel SDK manifest contains an unsafe path'
  done
}

write_kernel_sdk_manifest() {
  local root=$1 destination=$2 entry relative digest mode target special
  local record_count=0

  [ -d "$root" ] || ci_die 'kernel SDK root is not a directory'
  special=$(find "$root" -xdev ! -type d ! -type f ! -type l -print -quit)
  [ -z "$special" ] || ci_die "kernel SDK root contains an unsupported special file: $special"
  for entry in \
    "$root/.config" \
    "$root/Module.symvers" \
    "$root/include/config/kernel.release" \
    "$root/include/generated/autoconf.h" \
    "$root/include/generated/utsrelease.h"; do
    [ -f "$entry" ] && [ ! -L "$entry" ] ||
      ci_die "kernel SDK root lacks required regular file: ${entry#"$root"/}"
  done
  if [ -e "$root/source" ] || [ -L "$root/source" ]; then
    [ -L "$root/source" ] || ci_die 'kernel SDK source path must be a symlink when present'
  fi

  {
    printf 'schema\ttb321fu.kernel-sdk-manifest/v1\n'
    while IFS= read -r -d '' entry; do
      relative=${entry#"$root"/}
      validate_sdk_relative_path "$relative"
      [ "$relative" = source ] && continue
      mode=$(stat -c '%a' "$entry")
      if [ -L "$entry" ]; then
        target=$(readlink -- "$entry")
        digest=$(printf '%s' "$target" | sha256sum | awk '{print $1}')
        printf 'symlink\t%s\t%s\t./%s\n' "$digest" "$mode" "$relative"
      else
        digest=$(sha256sum "$entry" | awk '{print $1}')
        printf 'file\t%s\t%s\t./%s\n' "$digest" "$mode" "$relative"
      fi
      record_count=$((record_count + 1))
      [ "$record_count" -le 500000 ] || ci_die 'kernel SDK manifest has too many records'
    done < <(find "$root" -xdev \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
  } > "$destination"
  [ "$record_count" -gt 0 ] || ci_die 'kernel SDK manifest is empty'
}

write_kernel_sdk_archive() {
  local root=$1 destination=$2 file_list entry resolved

  [ -d "$root" ] || ci_die 'kernel SDK root is not a directory'
  while IFS= read -r -d '' entry; do
    [ "$entry" = "$root/source" ] && continue
    resolved=$(realpath -e -- "$entry") ||
      ci_die "kernel SDK root contains a dangling symlink: $entry"
    case "$resolved" in
      "$root"|"$root"/*) ;;
      *) ci_die "kernel SDK root contains an external symlink: $entry" ;;
    esac
  done < <(find "$root" -xdev -type l -print0)

  file_list="$work/kernel-sdk-files.list"
  (
    cd "$root"
    find . -xdev -mindepth 1 ! -path ./source ! -path './source/*' -print0 |
      LC_ALL=C sort -z > "$file_list"
    tar --null --files-from="$file_list" --no-recursion --sort=name \
      --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -cf - | gzip -n > "$destination"
  )
  [ -s "$destination" ] || ci_die 'kernel SDK archive is empty'
  if tar -tzf "$destination" | grep -Fxq './source'; then
    ci_die 'kernel SDK archive must not retain the transient source symlink'
  fi
}

readonly CANONICAL_KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY=GUF296/ubuntu-y700-build-ci
producer_repository=
producer_commit=
producer_tree=
producer_tree_sha256=
verify_bootstrap_producer_state() {
  local producer_root actual status relative current_sha committed_sha
  local -a producer_git=()

  if [ "${KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY+x}" = x ]; then
    producer_repository=$KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY
  else
    producer_repository=${GITHUB_REPOSITORY:-}
  fi
  [ "$producer_repository" = "$CANONICAL_KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY" ] ||
    ci_die 'kernel bootstrap producer repository must be GUF296/ubuntu-y700-build-ci'

  producer_root=$(ci_sanitized_git_env git -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel) ||
    ci_die 'kernel bootstrap packager must run from a Git worktree'
  producer_root=$(realpath -e -- "$producer_root")
  producer_git=(ci_sanitized_git_env git --no-replace-objects -C "$producer_root")
  actual=$("${producer_git[@]}" rev-parse HEAD) ||
    ci_die 'cannot resolve kernel bootstrap producer commit'
  [[ $actual =~ ^[0-9a-f]{40}$ ]] || ci_die 'invalid kernel bootstrap producer commit'
  producer_tree=$("${producer_git[@]}" rev-parse "$actual^{tree}") ||
    ci_die 'cannot resolve kernel bootstrap producer tree'
  [[ $producer_tree =~ ^[0-9a-f]{40}$ ]] ||
    ci_die 'invalid kernel bootstrap producer tree'
  producer_tree_sha256=$("${producer_git[@]}" cat-file tree "$producer_tree" | sha256sum | awk '{print $1}') ||
    ci_die 'cannot hash kernel bootstrap producer tree'
  [[ $producer_tree_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    ci_die 'invalid kernel bootstrap producer tree SHA-256'
  status=$("${producer_git[@]}" status --porcelain=v1 --untracked-files=all)
  [ -z "$status" ] || ci_die 'kernel bootstrap producer worktree must be clean'
  for entry in "$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")" "$SCRIPT_DIR/common.sh"; do
    relative=$(realpath --relative-to="$producer_root" -- "$entry")
    case "$relative" in
      ''|/*|../*|*/../*|*/..|*\\*) ci_die 'kernel bootstrap producer script escaped its Git worktree' ;;
    esac
    "${producer_git[@]}" ls-files --error-unmatch -- "$relative" >/dev/null ||
      ci_die "kernel bootstrap producer script is not tracked: $relative"
    current_sha=$(sha256sum "$entry" | awk '{print $1}')
    committed_sha=$("${producer_git[@]}" show "$actual:$relative" | sha256sum | awk '{print $1}') ||
      ci_die "cannot read committed kernel bootstrap producer script: $relative"
    [ "$current_sha" = "$committed_sha" ] ||
      ci_die "kernel bootstrap producer script differs from its committed bytes: $relative"
  done
  producer_commit=$actual
}

actual_commit=$("${git_cmd[@]}" rev-parse HEAD)

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$("${git_cmd[@]}" show -s --format=%ct "$actual_commit")}
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]{1,12}$ ]] || ci_die "invalid SOURCE_DATE_EPOCH"
export SOURCE_DATE_EPOCH
KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-$(LC_ALL=C date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')}
KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-tb321fu-ci}
KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-tb321fu-builder}
KBUILD_BUILD_VERSION=${KBUILD_BUILD_VERSION:-1}
[[ $KBUILD_BUILD_TIMESTAMP =~ ^[0-9A-Za-z][0-9A-Za-z,:+._\ -]{0,95}$ ]] || ci_die "invalid KBUILD_BUILD_TIMESTAMP"
[[ $KBUILD_BUILD_USER =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || ci_die "invalid KBUILD_BUILD_USER"
[[ $KBUILD_BUILD_HOST =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || ci_die "invalid KBUILD_BUILD_HOST"
[[ $KBUILD_BUILD_VERSION =~ ^[1-9][0-9]{0,8}$ ]] || ci_die "invalid KBUILD_BUILD_VERSION"
export KBUILD_BUILD_TIMESTAMP KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_VERSION
export KCONFIG_NOTIMESTAMP=1

verify_kernel_source_state "before release packaging"
verify_bootstrap_producer_state
if [ "$mode" = preflight ]; then
  printf 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS commit=%s config=%s rustc=%s producer-repository=%s producer-commit=%s producer-tree=%s producer-tree-sha256=%s\n' \
    "$actual_commit" "$expected_config_sha" "$(kernel_rustc_version)" \
    "$producer_repository" "$producer_commit" "$producer_tree" "$producer_tree_sha256"
  exit 0
fi

bootstrap_producer_repository=$producer_repository
bootstrap_producer_commit=$producer_commit
bootstrap_producer_tree=$producer_tree
bootstrap_producer_tree_sha256=$producer_tree_sha256

output_parent=$(dirname -- "$OUTPUT_DIR")
output_name=$(basename -- "$OUTPUT_DIR")
case "$output_name" in
  tb321fu-kernel-bootstrap*) ;;
  *) ci_die "OUTPUT_DIR basename must start with tb321fu-kernel-bootstrap" ;;
esac
mkdir -p "$output_parent"
output_parent=$(realpath -e -- "$output_parent")
output_path="$output_parent/$output_name"
if [ -e "$output_path" ]; then
  ci_safe_rmtree "$output_path" "$output_parent" tb321fu-kernel-bootstrap
fi

work=$(mktemp -d "$output_parent/.tb321fu-kernel-bootstrap.XXXXXX")
kernel_build_input_state=
cleanup() {
  local status=$?

  if [ -n "$kernel_build_input_state" ] && [ -f "$kernel_build_input_state" ]; then
    if ! (cd "$kernel_build_input" && sha256sum --strict --check "$kernel_build_input_state" >/dev/null); then
      printf 'error: kernel build input changed while bootstrap packaging ran\n' >&2
      status=1
    fi
  fi
  if [ -d "$work" ]; then
    ci_safe_rmtree "$work" "$output_parent" .tb321fu-kernel-bootstrap
  fi
  return "$status"
}
trap cleanup EXIT

kernel_build_input_state="$work/kernel-build-input-state.sha256"
write_kernel_build_input_state "$kernel_build_input_state"

baseline_archive="$work/baseline-device-debs.tar.gz"
baseline_dir="$work/baseline"
mkdir -p "$baseline_dir"
ci_download "$BASE_DEVICE_DEB_ARCHIVE" "$baseline_archive" "$BASE_DEVICE_DEB_ARCHIVE_SHA256"
ci_extract_archive "$baseline_archive" "$baseline_dir"

mapfile -d '' baseline_modules < <(find "$baseline_dir" -maxdepth 1 -type f -name 'y700-daily-kernel-modules_*.deb' -print0)
mapfile -d '' baseline_rootfs < <(find "$baseline_dir" -maxdepth 1 -type f -name 'y700-daily-rootfs-overlay_*.deb' -print0)
mapfile -d '' baseline_compat < <(find "$baseline_dir" -maxdepth 1 -type f -name 'y700-compat1-extra-rootfs-overlay.tar.gz' -print0)
mapfile -d '' baseline_bundle_metadata < <(find "$baseline_dir" -maxdepth 1 -type f -name KERNEL-BUNDLE.tsv -print0)
mapfile -d '' baseline_source_metadata < <(find "$baseline_dir" -maxdepth 1 -type f -name SOURCE-LOCK.tsv -print0)
mapfile -d '' baseline_sdk_metadata < <(find "$baseline_dir" -maxdepth 1 -type f -name KERNEL-SDK-MANIFEST.tsv -print0)
mapfile -d '' baseline_toolchain_metadata < <(find "$baseline_dir" -maxdepth 1 -type f -name KERNEL-TOOLCHAIN.tsv -print0)
mapfile -d '' baseline_kbuild_flags_metadata < <(find "$baseline_dir" -maxdepth 1 -type f -name KBUILD-FLAGS.tsv -print0)
[ "${#baseline_modules[@]}" -eq 1 ] || ci_die "baseline archive must contain exactly one kernel modules DEB"
[ "${#baseline_rootfs[@]}" -eq 1 ] || ci_die "baseline archive must contain exactly one rootfs overlay DEB"
[ "${#baseline_compat[@]}" -eq 1 ] || ci_die "baseline archive must contain exactly one compat overlay"
baseline_count=$(find "$baseline_dir" -maxdepth 1 -type f | wc -l)
# Legacy archives contain only the three device payloads. Older bootstrap
# archives add the bundle/source lock pair; current ones add the SDK,
# toolchain, and Kbuild evidence that this invocation will replace. No other
# member is safe, so an iterative bootstrap remains an exact allowlist.
case "$baseline_count" in
  3)
    [ "${#baseline_bundle_metadata[@]}" -eq 0 ] &&
      [ "${#baseline_source_metadata[@]}" -eq 0 ] &&
      [ "${#baseline_sdk_metadata[@]}" -eq 0 ] &&
      [ "${#baseline_toolchain_metadata[@]}" -eq 0 ] &&
      [ "${#baseline_kbuild_flags_metadata[@]}" -eq 0 ] ||
      ci_die "three-member baseline archive contains unexpected metadata"
    ;;
  5)
    [ "${#baseline_bundle_metadata[@]}" -eq 1 ] &&
      [ "${#baseline_source_metadata[@]}" -eq 1 ] &&
      [ "${#baseline_sdk_metadata[@]}" -eq 0 ] &&
      [ "${#baseline_toolchain_metadata[@]}" -eq 0 ] &&
      [ "${#baseline_kbuild_flags_metadata[@]}" -eq 0 ] ||
      ci_die "five-member baseline archive must contain exactly the replaceable metadata files"
    ;;
  8)
    [ "${#baseline_bundle_metadata[@]}" -eq 1 ] &&
      [ "${#baseline_source_metadata[@]}" -eq 1 ] &&
      [ "${#baseline_sdk_metadata[@]}" -eq 1 ] &&
      [ "${#baseline_toolchain_metadata[@]}" -eq 1 ] &&
      [ "${#baseline_kbuild_flags_metadata[@]}" -eq 1 ] ||
      ci_die "eight-member baseline archive must contain the complete replaceable metadata set"
    ;;
  *) ci_die "baseline archive must contain exactly three payloads with an approved replaceable metadata set" ;;
esac
[ -z "$(find "$baseline_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] || ci_die "baseline archive contains a non-regular member"

rootfs_sha=$(sha256sum "${baseline_rootfs[0]}" | awk '{print $1}')
compat_sha=$(sha256sum "${baseline_compat[0]}" | awk '{print $1}')

approved_config="$work/approved-kernel.config"
install -m 0644 "$kernel_build_input/.config" "$approved_config"
kernel_build="$work/kernel-build"
mkdir -p "$kernel_build"
# Build from a fresh private O= directory. Reusing generated files through
# hardlinks would let Kbuild mutate the authoritative build input.
install -m 0644 "$approved_config" "$kernel_build/.config"
kernel_make olddefconfig
verify_kernel_source_state "after clean configuration restore"

kernel_release=$(kernel_make -s kernelrelease)
[[ $kernel_release =~ ^[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}$ ]] || ci_die "unsafe kernel release: $kernel_release"
case "$kernel_release" in
  *-g"${actual_commit:0:12}"*) ;;
  *) ci_die "kernel release does not bind the expected commit: $kernel_release" ;;
esac

kernel_make -j"$KERNEL_BUILD_JOBS" Image modules "qcom/$DTB_NAME"
[ "$(cat "$kernel_build/include/config/kernel.release")" = "$kernel_release" ] || ci_die "built kernel.release does not match source commit"
grep -Fxq "#define UTS_RELEASE \"$kernel_release\"" "$kernel_build/include/generated/utsrelease.h" || ci_die "UTS_RELEASE does not match built kernel release"

image="$kernel_build/arch/arm64/boot/Image"
dtb="$kernel_build/arch/arm64/boot/dts/qcom/$DTB_NAME"
[ -s "$image" ] || ci_die "missing kernel Image"
[ -s "$dtb" ] || ci_die "missing $DTB_NAME"

modules_root="$work/modules-root"
kernel_make INSTALL_MOD_PATH="$modules_root" DEPMOD=/bin/true modules_install
verify_kernel_source_state "after kernel build and modules_install"
verify_kernel_build_input_state "$kernel_build_input_state"
verify_bootstrap_producer_state
[ "$producer_repository" = "$bootstrap_producer_repository" ] ||
  ci_die 'kernel bootstrap producer repository changed while packaging ran'
[ "$producer_commit" = "$bootstrap_producer_commit" ] ||
  ci_die 'kernel bootstrap producer commit changed while packaging ran'
[ "$producer_tree" = "$bootstrap_producer_tree" ] ||
  ci_die 'kernel bootstrap producer tree changed while packaging ran'
[ "$producer_tree_sha256" = "$bootstrap_producer_tree_sha256" ] ||
  ci_die 'kernel bootstrap producer tree hash changed while packaging ran'
[ -d "$modules_root/lib/modules/$kernel_release" ] || ci_die "modules_install produced the wrong kernel release"
[ "$(find "$modules_root/lib/modules" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] || ci_die "modules_install produced multiple releases"
rm -f -- "$modules_root/lib/modules/$kernel_release/build" "$modules_root/lib/modules/$kernel_release/source"
depmod -b "$modules_root" "$kernel_release"

module_count=0
while IFS= read -r -d '' module; do
  vermagic=$(modinfo -F vermagic "$module")
  case "$vermagic" in
    "$kernel_release"|"$kernel_release "*) ;;
    *) ci_die "module vermagic mismatch: $module: $vermagic" ;;
  esac
  module_count=$((module_count + 1))
done < <(find "$modules_root/lib/modules/$kernel_release" -type f -name '*.ko*' -print0)
[ "$module_count" -gt 0 ] || ci_die "no installed kernel modules found"

package_root="$work/package-root"
mkdir -p "$package_root/DEBIAN" "$package_root/usr/lib"
rsync -aH --numeric-ids "$modules_root/lib/modules" "$package_root/usr/lib/"
cat > "$package_root/DEBIAN/control" <<EOF
Package: y700-daily-kernel-modules
Version: $KERNEL_PACKAGE_VERSION
Section: misc
Priority: optional
Architecture: arm64
Depends: kmod
Maintainer: TB321FU Linux build <noreply@localhost>
Description: Lenovo TB321FU kernel modules for $kernel_release.
EOF
cat > "$package_root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
current_release='$kernel_release'
if command -v depmod >/dev/null 2>&1; then
  depmod "\$current_release"
fi
exit 0
EOF
find "$package_root" -type d -exec chmod 0755 {} +
find "$package_root" -type f -exec chmod 0644 {} +
chmod 0755 "$package_root/DEBIAN/postinst"
[ -z "$(find "$package_root" -type d ! -perm 0755 -print -quit)" ] || ci_die "package contains a non-0755 directory"
[ -z "$(find "$package_root" -type f ! -path '*/DEBIAN/postinst' ! -perm 0644 -print -quit)" ] ||
  ci_die "package contains a regular file with an unexpected mode"
[ "$(stat -c '%a' "$package_root/DEBIAN/postinst")" = 755 ] || ci_die "postinst must be mode 0755"
find "$package_root" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"

stage="$work/stage"
artifacts="$work/kernel-artifacts"
device="$work/device-debs"
mkdir -p "$stage" "$artifacts" "$device"
modules_deb="$device/y700-daily-kernel-modules_${KERNEL_PACKAGE_VERSION}_arm64.deb"
dpkg-deb --root-owner-group -Zxz -b "$package_root" "$modules_deb" >/dev/null

modules_manifest="$work/MODULES.sha256"
(
  cd "$package_root"
  find ./usr/lib/modules -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --
) > "$modules_manifest"
modules_manifest_file_count=$(wc -l < "$modules_manifest")
[[ $modules_manifest_file_count =~ ^[1-9][0-9]{0,8}$ ]] ||
  ci_die 'kernel modules manifest is empty or has an unsafe record count'
modules_manifest_sha=$(sha256sum "$modules_manifest" | awk '{print $1}')

cp -a "${baseline_rootfs[0]}" "$device/"
cp -a "${baseline_compat[0]}" "$device/"
[ "$(sha256sum "$device/$(basename -- "${baseline_rootfs[0]}")" | awk '{print $1}')" = "$rootfs_sha" ] || ci_die "rootfs baseline changed"
[ "$(sha256sum "$device/$(basename -- "${baseline_compat[0]}")" | awk '{print $1}')" = "$compat_sha" ] || ci_die "compat baseline changed"

cp -a "$image" "$artifacts/Image"
cp -a "$dtb" "$artifacts/$DTB_NAME"
cp -a "$kernel_build/.config" "$artifacts/kernel.config"
sdk_manifest="$work/KERNEL-SDK-MANIFEST.tsv"
toolchain_manifest="$work/KERNEL-TOOLCHAIN.tsv"
kbuild_flags_manifest="$work/KBUILD-FLAGS.tsv"
write_kernel_sdk_manifest "$kernel_build" "$sdk_manifest"
write_kernel_toolchain_manifest "$toolchain_manifest"
write_kbuild_flags_manifest "$kbuild_flags_manifest"

kernel_archive="$stage/tb321fu-kernel-artifacts-${kernel_release}.tar.gz"
device_archive="$stage/tb321fu-device-debs-${kernel_release}.tar.gz"
sdk_archive="$stage/tb321fu-kernel-build-sdk-${kernel_release}.tar.gz"
write_kernel_sdk_archive "$kernel_build" "$sdk_archive"
chmod 0644 "$sdk_archive"

packager_sha=$(sha256sum "$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")" | awk '{print $1}')
common_sha=$(sha256sum "$SCRIPT_DIR/common.sh" | awk '{print $1}')
compiler_version=$(tool_version "${CROSS_COMPILE}gcc")
compiler_sha=$(tool_sha256 "${CROSS_COMPILE}gcc")
rustc_version=$(kernel_rustc_version)
rustc_sha=$(tool_sha256 "$kernel_rustc")
make_version=$(tool_version make)
make_sha=$(tool_sha256 make)
dpkg_deb_version=$(tool_version dpkg-deb)
dpkg_deb_sha=$(tool_sha256 dpkg-deb)
config_sha=$(sha256sum "$kernel_build/.config" | awk '{print $1}')
image_sha=$(sha256sum "$image" | awk '{print $1}')
dtb_sha=$(sha256sum "$dtb" | awk '{print $1}')
modules_deb_sha=$(sha256sum "$modules_deb" | awk '{print $1}')
sdk_archive_sha=$(sha256sum "$sdk_archive" | awk '{print $1}')
sdk_manifest_sha=$(sha256sum "$sdk_manifest" | awk '{print $1}')
toolchain_manifest_sha=$(sha256sum "$toolchain_manifest" | awk '{print $1}')
kbuild_flags_manifest_sha=$(sha256sum "$kbuild_flags_manifest" | awk '{print $1}')

bundle_identity="$work/KERNEL-BUNDLE.identity.tsv"
bundle_file="$work/KERNEL-BUNDLE.tsv"
{
  printf 'schema\ttb321fu.kernel-bundle/v2\n'
  printf 'kernel-source-commit\t%s\n' "$actual_commit"
  printf 'kernel-release\t%s\n' "$kernel_release"
  printf 'kernel-config-sha256\t%s\n' "$config_sha"
  printf 'kernel-image-sha256\t%s\n' "$image_sha"
  printf 'kernel-dtb-name\t%s\n' "$DTB_NAME"
  printf 'kernel-dtb-sha256\t%s\n' "$dtb_sha"
  printf 'kernel-modules-deb-sha256\t%s\n' "$modules_deb_sha"
  printf 'kernel-modules-manifest-sha256\t%s\n' "$modules_manifest_sha"
  printf 'kernel-sdk-archive-sha256\t%s\n' "$sdk_archive_sha"
  printf 'kernel-sdk-manifest-sha256\t%s\n' "$sdk_manifest_sha"
  printf 'kernel-toolchain-manifest-sha256\t%s\n' "$toolchain_manifest_sha"
  printf 'kbuild-flags-sha256\t%s\n' "$kbuild_flags_manifest_sha"
  printf 'rustc-sha256\t%s\n' "$rustc_sha"
  printf 'rustc\t%s\n' "$rustc_version"
  printf 'source-date-epoch\t%s\n' "$SOURCE_DATE_EPOCH"
  printf 'kbuild-build-timestamp\t%s\n' "$KBUILD_BUILD_TIMESTAMP"
  printf 'kbuild-build-user\t%s\n' "$KBUILD_BUILD_USER"
  printf 'kbuild-build-host\t%s\n' "$KBUILD_BUILD_HOST"
  printf 'kbuild-build-version\t%s\n' "$KBUILD_BUILD_VERSION"
} > "$bundle_identity"
kernel_bundle_id=$(sha256sum "$bundle_identity" | awk '{print $1}')
cp "$bundle_identity" "$bundle_file"
printf 'kernel-bundle-id\t%s\n' "$kernel_bundle_id" >> "$bundle_file"
install -m 0644 "$bundle_file" "$artifacts/KERNEL-BUNDLE.tsv"
install -m 0644 "$bundle_file" "$device/KERNEL-BUNDLE.tsv"
install -m 0644 "$modules_manifest" "$artifacts/MODULES.sha256"
install -m 0644 "$sdk_manifest" "$artifacts/KERNEL-SDK-MANIFEST.tsv"
install -m 0644 "$sdk_manifest" "$device/KERNEL-SDK-MANIFEST.tsv"
install -m 0644 "$toolchain_manifest" "$artifacts/KERNEL-TOOLCHAIN.tsv"
install -m 0644 "$toolchain_manifest" "$device/KERNEL-TOOLCHAIN.tsv"
install -m 0644 "$kbuild_flags_manifest" "$artifacts/KBUILD-FLAGS.tsv"
install -m 0644 "$kbuild_flags_manifest" "$device/KBUILD-FLAGS.tsv"
{
  printf 'schema\ttb321fu.kernel-bootstrap/v3\n'
  printf 'kernel_bundle_id\t%s\n' "$kernel_bundle_id"
  printf 'kernel_commit\t%s\n' "$actual_commit"
  printf 'kernel_release\t%s\n' "$kernel_release"
  printf 'source_date_epoch\t%s\n' "$SOURCE_DATE_EPOCH"
  printf 'config_sha256\t%s\n' "$config_sha"
  printf 'image_sha256\t%s\n' "$image_sha"
  printf 'dtb_name\t%s\n' "$DTB_NAME"
  printf 'dtb_sha256\t%s\n' "$dtb_sha"
  printf 'modules_deb_sha256\t%s\n' "$modules_deb_sha"
  printf 'modules_manifest_sha256\t%s\n' "$modules_manifest_sha"
  printf 'modules_manifest_file_count\t%s\n' "$modules_manifest_file_count"
  printf 'kernel_sdk_archive_sha256\t%s\n' "$sdk_archive_sha"
  printf 'kernel_sdk_manifest_sha256\t%s\n' "$sdk_manifest_sha"
  printf 'kernel_toolchain_manifest_sha256\t%s\n' "$toolchain_manifest_sha"
  printf 'kbuild_flags_sha256\t%s\n' "$kbuild_flags_manifest_sha"
  printf 'baseline_archive_sha256\t%s\n' "${BASE_DEVICE_DEB_ARCHIVE_SHA256,,}"
  printf 'baseline_rootfs_sha256\t%s\n' "$rootfs_sha"
  printf 'baseline_compat_sha256\t%s\n' "$compat_sha"
  printf 'producer_repository\t%s\n' "$bootstrap_producer_repository"
  printf 'producer_commit\t%s\n' "$bootstrap_producer_commit"
  printf 'producer_tree\t%s\n' "$bootstrap_producer_tree"
  printf 'producer_tree_sha256\t%s\n' "$bootstrap_producer_tree_sha256"
  printf 'producer_state\tclean\n'
  printf 'packager_sha256\t%s\n' "$packager_sha"
  printf 'common_sh_sha256\t%s\n' "$common_sha"
  printf 'compiler_sha256\t%s\n' "$compiler_sha"
  printf 'compiler\t%s\n' "$compiler_version"
  printf 'rustc_sha256\t%s\n' "$rustc_sha"
  printf 'rustc\t%s\n' "${rustc_version:-unavailable}"
  printf 'kbuild_build_timestamp\t%s\n' "$KBUILD_BUILD_TIMESTAMP"
  printf 'kbuild_build_user\t%s\n' "$KBUILD_BUILD_USER"
  printf 'kbuild_build_host\t%s\n' "$KBUILD_BUILD_HOST"
  printf 'kbuild_build_version\t%s\n' "$KBUILD_BUILD_VERSION"
  printf 'make_sha256\t%s\n' "$make_sha"
  printf 'make\t%s\n' "$make_version"
  printf 'dpkg_deb_sha256\t%s\n' "$dpkg_deb_sha"
  printf 'dpkg_deb\t%s\n' "$dpkg_deb_version"
  printf 'module_count\t%s\n' "$module_count"
} > "$artifacts/SOURCE-LOCK.tsv"
install -m 0644 "$artifacts/SOURCE-LOCK.tsv" "$device/SOURCE-LOCK.tsv"

find "$artifacts" "$device" -type f -exec chmod 0644 {} +
find "$artifacts" "$device" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
tar -C "$artifacts" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -cf - . | gzip -n > "$kernel_archive"
tar -C "$device" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -cf - . | gzip -n > "$device_archive"
chmod 0644 "$kernel_archive" "$device_archive"
cp -a "$artifacts/SOURCE-LOCK.tsv" "$stage/KERNEL-SOURCE-LOCK.tsv"
cp -a "$bundle_file" "$stage/KERNEL-BUNDLE.tsv"
cp -a "$artifacts/MODULES.sha256" "$stage/MODULES.sha256"
cp -a "$sdk_manifest" "$stage/KERNEL-SDK-MANIFEST.tsv"
cp -a "$toolchain_manifest" "$stage/KERNEL-TOOLCHAIN.tsv"
cp -a "$kbuild_flags_manifest" "$stage/KBUILD-FLAGS.tsv"
(
  cd "$stage"
  sha256sum -- "$(basename -- "$kernel_archive")" "$(basename -- "$device_archive")" \
    "$(basename -- "$sdk_archive")" KERNEL-SOURCE-LOCK.tsv KERNEL-BUNDLE.tsv \
    MODULES.sha256 KERNEL-SDK-MANIFEST.tsv KERNEL-TOOLCHAIN.tsv KBUILD-FLAGS.tsv > SHA256SUMS.txt
)

mv "$stage" "$output_path"
trap - EXIT
cleanup
printf 'KERNEL_BOOTSTRAP=PASS release=%s commit=%s bundle=%s modules=%d output=%s\n' \
  "$kernel_release" "$actual_commit" "$kernel_bundle_id" "$module_count" "$output_path"
