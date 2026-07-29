#!/bin/sh

PRODUCER_CANONICAL_PATH=/usr/sbin:/usr/bin:/sbin:/bin
PRODUCER_ENV_POLICY=isolated-allowlist-v1

# Use a fixed POSIX interpreter for the first instructions: noninteractive
# Bash would process an inherited BASH_ENV before any script code. Always
# re-enter through an empty environment when the file is executed as a script,
# including when a caller explicitly overrides the shebang with Bash. The
# clean Bash process sources this file, which is distinguishable from executing
# it because BASH_SOURCE no longer equals the fixed -c argv0.
if [ -z "${BASH_VERSION-}" ] || [ "${BASH_SOURCE-}" = "$0" ]; then
  clean_script=$(/usr/bin/realpath -e -- "$0") || {
    printf 'error: cannot resolve kernel bootstrap producer path\n' >&2
    exit 1
  }
  exec /usr/bin/env -i \
    PATH="$PRODUCER_CANONICAL_PATH" \
    HOME=/nonexistent \
    LANG=C \
    LC_ALL=C \
    TZ=UTC \
    KERNEL_SOURCE_DIR="${KERNEL_SOURCE_DIR-}" \
    KERNEL_GIT_DIR="${KERNEL_GIT_DIR-}" \
    KERNEL_BUILD_DIR="${KERNEL_BUILD_DIR-}" \
    EXPECTED_KERNEL_COMMIT="${EXPECTED_KERNEL_COMMIT-}" \
    EXPECTED_KERNEL_CONFIG_SHA256="${EXPECTED_KERNEL_CONFIG_SHA256-}" \
    EXPECTED_KERNEL_RELEASE="${EXPECTED_KERNEL_RELEASE-}" \
    KERNEL_PACKAGE_VERSION="${KERNEL_PACKAGE_VERSION-}" \
    BASE_DEVICE_DEB_ARCHIVE="${BASE_DEVICE_DEB_ARCHIVE-}" \
    BASE_DEVICE_DEB_ARCHIVE_SHA256="${BASE_DEVICE_DEB_ARCHIVE_SHA256-}" \
    OUTPUT_DIR="${OUTPUT_DIR-}" \
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH-}" \
    KERNEL_BUILD_JOBS="${KERNEL_BUILD_JOBS-}" \
    ARCH="${ARCH-}" \
    CROSS_COMPILE="${CROSS_COMPILE-}" \
    DTB_NAME="${DTB_NAME-}" \
    KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP-}" \
    KBUILD_BUILD_USER="${KBUILD_BUILD_USER-}" \
    KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST-}" \
    KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION-}" \
    KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY="${KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY-}" \
    GITHUB_REPOSITORY="${GITHUB_REPOSITORY-}" \
    KERNEL_RUSTC="${KERNEL_RUSTC-}" \
    HTTPS_PROXY="${HTTPS_PROXY-}" \
    HTTP_PROXY="${HTTP_PROXY-}" \
    NO_PROXY="${NO_PROXY-}" \
    https_proxy="${https_proxy-}" \
    http_proxy="${http_proxy-}" \
    no_proxy="${no_proxy-}" \
    /usr/bin/bash --noprofile --norc -c '
      producer_script=$1
      shift
      . "$producer_script" "$@"
    ' tb321fu-kernel-producer "$clean_script" "$@"
fi

set -euo pipefail
umask 022

readonly PRODUCER_CANONICAL_PATH
readonly PRODUCER_ENV_POLICY
readonly KBUILD_PATH_POLICY=private-locked-tool-directory-v1
readonly KBUILD_CONFIG_SHELL_POLICY=absolute-locked-sh-v1
readonly KBUILD_PATH_IDENTITY_POLICY=deterministic-input-key-v1
readonly KBUILD_KCFLAGS_POLICY=debug-prefix-map-source-and-build-v1
readonly KBUILD_HOSTFLAGS_POLICY=file-prefix-map-source-and-build-v1
readonly -a PRODUCER_INPUT_ENV=(
  KERNEL_SOURCE_DIR
  KERNEL_GIT_DIR
  KERNEL_BUILD_DIR
  EXPECTED_KERNEL_COMMIT
  EXPECTED_KERNEL_CONFIG_SHA256
  EXPECTED_KERNEL_RELEASE
  KERNEL_PACKAGE_VERSION
  BASE_DEVICE_DEB_ARCHIVE
  BASE_DEVICE_DEB_ARCHIVE_SHA256
  OUTPUT_DIR
  SOURCE_DATE_EPOCH
  KERNEL_BUILD_JOBS
  ARCH
  CROSS_COMPILE
  DTB_NAME
  KBUILD_BUILD_TIMESTAMP
  KBUILD_BUILD_USER
  KBUILD_BUILD_HOST
  KBUILD_BUILD_VERSION
  KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY
  GITHUB_REPOSITORY
  KERNEL_RUSTC
  HTTPS_PROXY
  HTTP_PROXY
  NO_PROXY
  https_proxy
  http_proxy
  no_proxy
)

[ "$PATH" = "$PRODUCER_CANONICAL_PATH" ] &&
  [ "${HOME:-}" = /nonexistent ] &&
  [ "${LANG:-}" = C ] &&
  [ "${LC_ALL:-}" = C ] &&
  [ "${TZ:-}" = UTC ] || {
    printf 'error: invalid kernel bootstrap producer environment policy\n' >&2
    exit 1
  }

while IFS= read -r exported_name; do
  case "$exported_name" in
    PATH|HOME|LANG|LC_ALL|TZ|PWD|OLDPWD|SHLVL|_) continue ;;
  esac
  exported_allowed=0
  for clean_name in "${PRODUCER_INPUT_ENV[@]}"; do
    if [ "$exported_name" = "$clean_name" ]; then
      exported_allowed=1
      break
    fi
  done
  [ "$exported_allowed" -eq 1 ] || {
    printf 'error: unexpected exported producer variable: %s\n' "$exported_name" >&2
    exit 1
  }
done < <(compgen -e | LC_ALL=C /usr/bin/sort)

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
  EXPECTED_KERNEL_RELEASE       exact kernelrelease from the authoritative refs
  KERNEL_PACKAGE_VERSION        Debian version; must equal EXPECTED_KERNEL_RELEASE
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
  the same clean, commit-bound build. The first canonical closure emits the full
  kernel SDK archive plus its deterministic tree manifest; allow several GiB of
  temporary build space. Minimal-SDK optimization is deferred until the matching
  external haptics module has built successfully from this exact archive.
EOF
}

mode=build
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --preflight) mode=preflight; shift ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

declare -A LOCKED_TOOL_PATH=()
declare -A LOCKED_TOOL_COMMAND_PATH=()
declare -A LOCKED_TOOL_COMMAND_NAME=()
declare -A LOCKED_TOOL_SHA256=()
declare -A LOCKED_TOOL_VERSION=()
declare -A LOCKED_TOOL_STATE=()
declare -A LOCKED_TOOL_COMMAND_STATE=()
BISON_DATA_DIR=
BISON_DATA_SHA256=
BISON_DATA_STATE=

resolve_tool_path() {
  local label=$1 command=$2 candidate command_directory command_path path

  if [[ $command = */* ]]; then
    candidate=$command
  else
    candidate=$(type -P -- "$command") || ci_die "required command not found: $command"
  fi
  command_directory=$(/usr/bin/realpath -e -- "$(/usr/bin/dirname -- "$candidate")") ||
    ci_die "cannot resolve tool directory: $command"
  command_path="$command_directory/$(/usr/bin/basename -- "$candidate")"
  path=$(/usr/bin/realpath -e -- "$command_path") ||
    ci_die "cannot resolve tool: $command"
  [ -f "$path" ] && [ -x "$path" ] ||
    ci_die "tool is not an executable regular file: $command"
  LOCKED_TOOL_COMMAND_PATH["$label"]=$command_path
  LOCKED_TOOL_COMMAND_NAME["$label"]=$(/usr/bin/basename -- "$command_path")
  LOCKED_TOOL_PATH["$label"]=$path
}

capture_tool_identity() {
  local label=$1 mode=${2:---version} path command_path output line digest state

  path=${LOCKED_TOOL_PATH[$label]:-}
  [ -n "$path" ] || ci_die "tool path was not locked: $label"
  command_path=${LOCKED_TOOL_COMMAND_PATH[$label]:-}
  [ -n "$command_path" ] || ci_die "tool invocation path was not locked: $label"
  digest=$(${LOCKED_TOOL_COMMAND_PATH[sha256sum]} -- "$path")
  read -r digest _ <<<"$digest"
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || ci_die "cannot hash locked tool: $label"
  case "$mode" in
    awk) output=$("$command_path" -W version 2>&1 || true) ;;
    *) output=$("$command_path" "$mode" 2>&1 || true) ;;
  esac
  line=
  while IFS= read -r state; do
    if [ -n "$state" ]; then
      line=$state
      break
    fi
  done <<<"$output"
  [ -n "$line" ] && [ "${#line}" -le 255 ] &&
    [[ $line != *$'\t'* && $line != *$'\r'* && $line != *$'\n'* ]] &&
    [[ $line =~ ^[[:print:]]+$ ]] ||
    ci_die "invalid locked tool version: $label"
  state=$(${LOCKED_TOOL_COMMAND_PATH[stat]} -Lc '%d:%i:%s:%Y' -- "$path") ||
    ci_die "cannot stat locked tool: $label"
  LOCKED_TOOL_SHA256["$label"]=$digest
  LOCKED_TOOL_VERSION["$label"]=$line
  LOCKED_TOOL_STATE["$label"]=$state
  LOCKED_TOOL_COMMAND_STATE["$label"]=$(${LOCKED_TOOL_COMMAND_PATH[stat]} -c '%d:%i:%s:%Y:%F' -- "${LOCKED_TOOL_COMMAND_PATH[$label]}") ||
    ci_die "cannot stat locked tool invocation path: $label"
}

canonical_data_tree_sha256() {
  local root=$1 output digest

  output=$("${LOCKED_TOOL_COMMAND_PATH[tar]}" \
    --sort=name \
    --format=gnu \
    --numeric-owner \
    --owner=0 \
    --group=0 \
    --mtime=@0 \
    -C "$root" \
    -cf - \
    . | "${LOCKED_TOOL_COMMAND_PATH[sha256sum]}") ||
    ci_die "cannot hash canonical data tree: $root"
  read -r digest _ <<<"$output"
  [[ $digest =~ ^[0-9a-f]{64}$ ]] ||
    ci_die "invalid canonical data-tree SHA-256: $root"
  printf '%s\n' "$digest"
}

capture_bison_data_identity() {
  local reported resolved bad_entry bad_mode entry_count total_size

  reported=$("${LOCKED_TOOL_COMMAND_PATH[bison]}" --print-datadir) ||
    ci_die 'cannot query the Bison data directory'
  [ -n "$reported" ] && [ "${#reported}" -le 512 ] &&
    [[ $reported = /* && $reported != *$'\t'* && $reported != *$'\r'* &&
       $reported != *$'\n'* && $reported != *\\* ]] ||
    ci_die 'Bison reported an unsafe data directory'
  resolved=$("${LOCKED_TOOL_COMMAND_PATH[realpath]}" -e -- "$reported") ||
    ci_die 'cannot resolve the Bison data directory'
  [ "$reported" = "$resolved" ] && [ -d "$resolved" ] && [ ! -L "$resolved" ] ||
    ci_die 'Bison data directory is not a canonical real directory'

  bad_entry=$("${LOCKED_TOOL_COMMAND_PATH[find]}" "$resolved" -xdev -mindepth 1 \
    ! -type d ! -type f -print -quit) ||
    ci_die 'cannot inspect Bison data-tree entry types'
  [ -z "$bad_entry" ] ||
    ci_die "Bison data tree contains an unsupported entry: $bad_entry"
  bad_mode=$("${LOCKED_TOOL_COMMAND_PATH[find]}" "$resolved" -xdev \
    \( -type d ! -perm 0755 -o -type f ! -perm 0644 \) -print -quit) ||
    ci_die 'cannot inspect Bison data-tree modes'
  [ -z "$bad_mode" ] ||
    ci_die "Bison data tree contains an unexpected mode: $bad_mode"
  entry_count=$("${LOCKED_TOOL_COMMAND_PATH[find]}" "$resolved" -xdev -printf '.\n' |
    "${LOCKED_TOOL_COMMAND_PATH[wc]}" -l) ||
    ci_die 'cannot count Bison data-tree entries'
  [ "$entry_count" -ge 2 ] && [ "$entry_count" -le 4096 ] ||
    ci_die 'Bison data tree has an unsafe entry count'
  total_size=$("${LOCKED_TOOL_COMMAND_PATH[find]}" "$resolved" -xdev -type f -printf '%s\n' |
    "${LOCKED_TOOL_COMMAND_PATH[awk]}" '{ total += $1 } END { print total + 0 }') ||
    ci_die 'cannot measure the Bison data tree'
  [ "$total_size" -gt 0 ] && [ "$total_size" -le 16777216 ] ||
    ci_die 'Bison data tree has an unsafe logical size'

  BISON_DATA_DIR=$resolved
  BISON_DATA_SHA256=$(canonical_data_tree_sha256 "$resolved")
  BISON_DATA_STATE=$("${LOCKED_TOOL_COMMAND_PATH[stat]}" -Lc '%d:%i:%s:%Y' -- "$resolved") ||
    ci_die 'cannot stat the Bison data directory'
}

verify_bison_data_identity() {
  local phase=$1 reported resolved state digest

  [ -n "$BISON_DATA_DIR" ] && [ -n "$BISON_DATA_SHA256" ] &&
    [ -n "$BISON_DATA_STATE" ] ||
    ci_die "Bison data identity was not captured $phase"
  reported=$("${LOCKED_TOOL_COMMAND_PATH[bison]}" --print-datadir) ||
    ci_die "cannot query the Bison data directory $phase"
  [ "$reported" = "$BISON_DATA_DIR" ] ||
    ci_die "Bison data directory changed $phase"
  resolved=$("${LOCKED_TOOL_COMMAND_PATH[realpath]}" -e -- "$reported") ||
    ci_die "Bison data directory disappeared $phase"
  [ "$resolved" = "$BISON_DATA_DIR" ] && [ -d "$resolved" ] && [ ! -L "$resolved" ] ||
    ci_die "Bison data directory identity changed $phase"
  state=$("${LOCKED_TOOL_COMMAND_PATH[stat]}" -Lc '%d:%i:%s:%Y' -- "$resolved") ||
    ci_die "cannot stat the Bison data directory $phase"
  [ "$state" = "$BISON_DATA_STATE" ] ||
    ci_die "Bison data directory state changed $phase"
  digest=$(canonical_data_tree_sha256 "$resolved")
  [ "$digest" = "$BISON_DATA_SHA256" ] ||
    ci_die "Bison data tree bytes changed $phase"
}

mark_tool_unused() {
  local label=$1

  LOCKED_TOOL_PATH["$label"]=unused
  LOCKED_TOOL_COMMAND_PATH["$label"]=unused
  LOCKED_TOOL_COMMAND_NAME["$label"]=unused
  LOCKED_TOOL_SHA256["$label"]=unused
  LOCKED_TOOL_VERSION["$label"]=unused
  LOCKED_TOOL_STATE["$label"]=unused
  LOCKED_TOOL_COMMAND_STATE["$label"]=unused
}

verify_locked_tools() {
  local phase=$1 label path state digest resolved command_state

  for label in "${!LOCKED_TOOL_SHA256[@]}"; do
    [ "${LOCKED_TOOL_SHA256[$label]}" != unused ] || continue
    path=${LOCKED_TOOL_PATH[$label]}
    resolved=$(${LOCKED_TOOL_COMMAND_PATH[realpath]} -e -- "${LOCKED_TOOL_COMMAND_PATH[$label]}") ||
      ci_die "locked tool invocation path disappeared $phase: $label"
    [ "$resolved" = "$path" ] ||
      ci_die "locked tool invocation target changed $phase: $label"
    command_state=$(${LOCKED_TOOL_COMMAND_PATH[stat]} -c '%d:%i:%s:%Y:%F' -- "${LOCKED_TOOL_COMMAND_PATH[$label]}") ||
      ci_die "cannot stat locked tool invocation path $phase: $label"
    [ "$command_state" = "${LOCKED_TOOL_COMMAND_STATE[$label]}" ] ||
      ci_die "locked tool invocation path changed $phase: $label"
    [ -f "$path" ] && [ -x "$path" ] ||
      ci_die "locked tool disappeared $phase: $label"
    state=$(${LOCKED_TOOL_COMMAND_PATH[stat]} -Lc '%d:%i:%s:%Y' -- "$path") ||
      ci_die "cannot stat locked tool $phase: $label"
    [ "$state" = "${LOCKED_TOOL_STATE[$label]}" ] ||
      ci_die "locked tool identity changed $phase: $label"
    digest=$(${LOCKED_TOOL_COMMAND_PATH[sha256sum]} -- "$path")
    read -r digest _ <<<"$digest"
    [ "$digest" = "${LOCKED_TOOL_SHA256[$label]}" ] ||
      ci_die "locked tool bytes changed $phase: $label"
  done
  verify_bison_data_identity "$phase"
}

for tool_spec in \
  bash:bash git:git make:make sha256sum:sha256sum find:find sort:sort \
  xargs:xargs rsync:rsync cp:cp dpkg:dpkg dpkg-deb:dpkg-deb \
  depmod:depmod modinfo:modinfo tar:tar gzip:gzip xz:xz touch:touch \
  realpath:realpath nproc:nproc date:date install:install awk:awk \
  stat:stat grep:grep sed:sed readlink:readlink wc:wc tr:tr cut:cut \
  findmnt:findmnt curl:curl \
  python3:python3 fdtget:fdtget flock:flock mv:mv chmod:chmod mkdir:mkdir \
  mktemp:mktemp rm:rm cat:cat dirname:dirname basename:basename env:env \
  host-gcc:gcc host-gxx:g++ host-as:as host-ld:ld host-ar:ar \
  flex:flex bison:bison m4:m4 perl:perl \
  pkg-config:pkg-config true:true sh:sh bc:bc getconf:getconf \
  sha1sum:sha1sum ln:ln uname:uname cmp:cmp head:head expr:expr uniq:uniq; do
  resolve_tool_path "${tool_spec%%:*}" "${tool_spec#*:}"
done

for tool_label in \
  bash git make sha256sum find sort xargs rsync cp dpkg dpkg-deb depmod \
  modinfo tar gzip xz touch realpath nproc date install stat grep sed \
  readlink wc tr cut findmnt curl python3 fdtget flock mv chmod mkdir mktemp rm cat dirname \
  basename env host-gcc host-gxx host-as host-ld host-ar flex bison m4 \
  perl pkg-config true sh bc getconf \
  sha1sum ln uname cmp head expr uniq; do
  capture_tool_identity "$tool_label"
done
capture_tool_identity awk awk

readonly BASH_BIN=${LOCKED_TOOL_COMMAND_PATH[bash]}
readonly GIT_BIN=${LOCKED_TOOL_COMMAND_PATH[git]}
readonly MAKE_BIN=${LOCKED_TOOL_COMMAND_PATH[make]}
readonly SHA256SUM_BIN=${LOCKED_TOOL_COMMAND_PATH[sha256sum]}
readonly FIND_BIN=${LOCKED_TOOL_COMMAND_PATH[find]}
readonly SORT_BIN=${LOCKED_TOOL_COMMAND_PATH[sort]}
readonly XARGS_BIN=${LOCKED_TOOL_COMMAND_PATH[xargs]}
readonly RSYNC_BIN=${LOCKED_TOOL_COMMAND_PATH[rsync]}
readonly CP_BIN=${LOCKED_TOOL_COMMAND_PATH[cp]}
readonly DPKG_BIN=${LOCKED_TOOL_COMMAND_PATH[dpkg]}
readonly DPKG_DEB_BIN=${LOCKED_TOOL_COMMAND_PATH[dpkg-deb]}
readonly DEPMOD_BIN=${LOCKED_TOOL_COMMAND_PATH[depmod]}
readonly MODINFO_BIN=${LOCKED_TOOL_COMMAND_PATH[modinfo]}
readonly TAR_BIN=${LOCKED_TOOL_COMMAND_PATH[tar]}
readonly GZIP_BIN=${LOCKED_TOOL_COMMAND_PATH[gzip]}
readonly XZ_BIN=${LOCKED_TOOL_COMMAND_PATH[xz]}
readonly FDTGET_BIN=${LOCKED_TOOL_COMMAND_PATH[fdtget]}
readonly FLOCK_BIN=${LOCKED_TOOL_COMMAND_PATH[flock]}
readonly MV_BIN=${LOCKED_TOOL_COMMAND_PATH[mv]}
readonly READLINK_BIN=${LOCKED_TOOL_COMMAND_PATH[readlink]}
readonly LN_BIN=${LOCKED_TOOL_COMMAND_PATH[ln]}
readonly SH_BIN=${LOCKED_TOOL_COMMAND_PATH[sh]}
readonly HOST_GCC_BIN=${LOCKED_TOOL_COMMAND_PATH[host-gcc]}
readonly HOST_GXX_BIN=${LOCKED_TOOL_COMMAND_PATH[host-gxx]}
readonly HOST_AS_BIN=${LOCKED_TOOL_COMMAND_PATH[host-as]}
readonly HOST_LD_BIN=${LOCKED_TOOL_COMMAND_PATH[host-ld]}
readonly HOST_AR_BIN=${LOCKED_TOOL_COMMAND_PATH[host-ar]}
readonly FLEX_BIN=${LOCKED_TOOL_COMMAND_PATH[flex]}
readonly BISON_BIN=${LOCKED_TOOL_COMMAND_PATH[bison]}
readonly M4_BIN=${LOCKED_TOOL_COMMAND_PATH[m4]}
[ "${LOCKED_TOOL_COMMAND_PATH[m4]}" = /usr/bin/m4 ] ||
  ci_die 'Bison/Flex require the canonical absolute /usr/bin/m4 invocation path'
readonly AWK_BIN=${LOCKED_TOOL_COMMAND_PATH[awk]}
readonly PERL_BIN=${LOCKED_TOOL_COMMAND_PATH[perl]}
readonly PYTHON3_BIN=${LOCKED_TOOL_COMMAND_PATH[python3]}
readonly PKG_CONFIG_BIN=${LOCKED_TOOL_COMMAND_PATH[pkg-config]}
readonly TRUE_BIN=${LOCKED_TOOL_COMMAND_PATH[true]}
capture_bison_data_identity
readonly BISON_DATA_DIR BISON_DATA_SHA256 BISON_DATA_STATE

# Common helpers call these names directly. Keep their existing interfaces but
# bind every invocation in this producer process to the path captured above.
sha256sum() { "$SHA256SUM_BIN" "$@"; }
find() { "${LOCKED_TOOL_COMMAND_PATH[find]}" "$@"; }
sort() { "$SORT_BIN" "$@"; }
xargs() { "$XARGS_BIN" "$@"; }
rsync() { "$RSYNC_BIN" "$@"; }
cp() { "$CP_BIN" "$@"; }
dpkg() { "$DPKG_BIN" "$@"; }
touch() { "${LOCKED_TOOL_COMMAND_PATH[touch]}" "$@"; }
realpath() { "${LOCKED_TOOL_COMMAND_PATH[realpath]}" "$@"; }
nproc() { "${LOCKED_TOOL_COMMAND_PATH[nproc]}" "$@"; }
date() { "${LOCKED_TOOL_COMMAND_PATH[date]}" "$@"; }
install() { "${LOCKED_TOOL_COMMAND_PATH[install]}" "$@"; }
awk() { "$AWK_BIN" "$@"; }
stat() { "${LOCKED_TOOL_COMMAND_PATH[stat]}" "$@"; }
grep() { "${LOCKED_TOOL_COMMAND_PATH[grep]}" "$@"; }
sed() { "${LOCKED_TOOL_COMMAND_PATH[sed]}" "$@"; }
readlink() { "${LOCKED_TOOL_COMMAND_PATH[readlink]}" "$@"; }
wc() { "${LOCKED_TOOL_COMMAND_PATH[wc]}" "$@"; }
tr() { "${LOCKED_TOOL_COMMAND_PATH[tr]}" "$@"; }
cut() { "${LOCKED_TOOL_COMMAND_PATH[cut]}" "$@"; }
findmnt() { "${LOCKED_TOOL_COMMAND_PATH[findmnt]}" "$@"; }
curl() { "${LOCKED_TOOL_COMMAND_PATH[curl]}" "$@"; }
python3() { "$PYTHON3_BIN" "$@"; }
mv() { "$MV_BIN" "$@"; }
chmod() { "${LOCKED_TOOL_COMMAND_PATH[chmod]}" "$@"; }
mkdir() { "${LOCKED_TOOL_COMMAND_PATH[mkdir]}" "$@"; }
mktemp() { "${LOCKED_TOOL_COMMAND_PATH[mktemp]}" "$@"; }
rm() { "${LOCKED_TOOL_COMMAND_PATH[rm]}" "$@"; }
cat() { "${LOCKED_TOOL_COMMAND_PATH[cat]}" "$@"; }
dirname() { "${LOCKED_TOOL_COMMAND_PATH[dirname]}" "$@"; }
basename() { "${LOCKED_TOOL_COMMAND_PATH[basename]}" "$@"; }
env() { "${LOCKED_TOOL_COMMAND_PATH[env]}" "$@"; }

kernel_locked_path=
kernel_kcflags=
kernel_kaflags=
kernel_hostcflags=
kernel_hostcxxflags=
initialize_kernel_prefix_maps() {
  kernel_kcflags="-fdebug-prefix-map=$kernel_source=/usr/src/tb321fu-linux-source -fdebug-prefix-map=$kernel_build=/usr/src/tb321fu-linux-build"
  kernel_kaflags=$kernel_kcflags
  kernel_hostcflags="-ffile-prefix-map=$kernel_source=/usr/src/tb321fu-linux-source -ffile-prefix-map=$kernel_build=/usr/src/tb321fu-linux-build"
  kernel_hostcxxflags=$kernel_hostcflags
}

prepare_kernel_locked_path() {
  local destination=$1 label name link target
  local -A expected_names=()

  [ ! -e "$destination" ] && [ ! -L "$destination" ] ||
    ci_die 'private Kbuild tool path already exists'
  mkdir -m 0700 -- "$destination"
  for label in "${!LOCKED_TOOL_PATH[@]}"; do
    target=${LOCKED_TOOL_PATH[$label]}
    [ "$target" != unused ] || continue
    name=${LOCKED_TOOL_COMMAND_NAME[$label]}
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9+._-]{0,127}$ ]] ||
      ci_die "unsafe private Kbuild tool name: $label"
    link="$destination/$name"
    if [ -n "${expected_names[$name]:-}" ]; then
      [ "${expected_names[$name]}" = "$target" ] ||
        ci_die "private Kbuild tool name collision: $name"
      continue
    fi
    "$LN_BIN" -s -- "$target" "$link"
    expected_names["$name"]=$target
  done
  verify_kernel_locked_path "$destination"
}

verify_kernel_locked_path() {
  local destination=$1 label name link target resolved actual_count
  local expected_count=0
  local -A expected_names=()

  [ -d "$destination" ] && [ ! -L "$destination" ] &&
    [ "$(stat -c '%a' -- "$destination")" = 700 ] ||
    ci_die 'private Kbuild tool path is not a real mode-0700 directory'
  for label in "${!LOCKED_TOOL_PATH[@]}"; do
    target=${LOCKED_TOOL_PATH[$label]}
    [ "$target" != unused ] || continue
    name=${LOCKED_TOOL_COMMAND_NAME[$label]}
    if [ -n "${expected_names[$name]:-}" ]; then
      [ "${expected_names[$name]}" = "$target" ] ||
        ci_die "private Kbuild tool name collision: $name"
      continue
    fi
    expected_names["$name"]=$target
    expected_count=$((expected_count + 1))
    link="$destination/$name"
    [ -L "$link" ] || ci_die "private Kbuild tool link disappeared: $name"
    [ "$("$READLINK_BIN" -- "$link")" = "$target" ] ||
      ci_die "private Kbuild tool link target changed: $name"
    resolved=$(realpath -e -- "$link") ||
      ci_die "private Kbuild tool link became dangling: $name"
    [ "$resolved" = "$target" ] ||
      ci_die "private Kbuild tool link resolves to unexpected bytes: $name"
  done
  [ -z "$(find "$destination" -mindepth 1 -maxdepth 1 ! -type l -print -quit)" ] ||
    ci_die 'private Kbuild tool path contains a non-symlink entry'
  actual_count=$(find "$destination" -mindepth 1 -maxdepth 1 -type l | wc -l)
  [ "$actual_count" -eq "$expected_count" ] ||
    ci_die 'private Kbuild tool path contains an unexpected entry'
}

verify_kernel_release_identity() {
  local actual_release=$1

  [[ $actual_release =~ ^[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}$ ]] ||
    ci_die "unsafe kernel release: $actual_release"
  [ "$actual_release" = "$EXPECTED_KERNEL_RELEASE" ] ||
    ci_die "kernel release mismatch: expected $EXPECTED_KERNEL_RELEASE, got $actual_release"
}

: "${KERNEL_SOURCE_DIR:?set KERNEL_SOURCE_DIR}"
: "${KERNEL_GIT_DIR:?set KERNEL_GIT_DIR}"
: "${KERNEL_BUILD_DIR:?set KERNEL_BUILD_DIR}"
: "${EXPECTED_KERNEL_COMMIT:?set EXPECTED_KERNEL_COMMIT}"
: "${EXPECTED_KERNEL_CONFIG_SHA256:?set EXPECTED_KERNEL_CONFIG_SHA256}"
: "${EXPECTED_KERNEL_RELEASE:?set EXPECTED_KERNEL_RELEASE}"
: "${KERNEL_PACKAGE_VERSION:?set KERNEL_PACKAGE_VERSION}"
: "${BASE_DEVICE_DEB_ARCHIVE:?set BASE_DEVICE_DEB_ARCHIVE}"
: "${BASE_DEVICE_DEB_ARCHIVE_SHA256:?set BASE_DEVICE_DEB_ARCHIVE_SHA256}"

if [ -n "${ARCH:-}" ] && [ "$ARCH" != arm64 ]; then
  ci_die 'ARCH must be arm64'
fi
ARCH=arm64
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-kernel-bootstrap}
KERNEL_BUILD_JOBS=${KERNEL_BUILD_JOBS:-$(nproc)}
KERNEL_RUSTC=${KERNEL_RUSTC:-}

[ -n "$OUTPUT_DIR" ] && [ "${#OUTPUT_DIR}" -le 4096 ] &&
  [[ $OUTPUT_DIR != *$'\t'* && $OUTPUT_DIR != *$'\r'* && $OUTPUT_DIR != *$'\n'* ]] &&
  [[ $OUTPUT_DIR != *//* && $OUTPUT_DIR != */ && $OUTPUT_DIR != ../* &&
     $OUTPUT_DIR != */../* && $OUTPUT_DIR != */.. && $OUTPUT_DIR != ./*/../* ]] ||
  ci_die 'unsafe OUTPUT_DIR'
early_output_name=${OUTPUT_DIR##*/}
[[ $early_output_name =~ ^tb321fu-kernel-bootstrap([A-Za-z0-9._-]{0,96})$ ]] ||
  ci_die "OUTPUT_DIR basename must be a bounded tb321fu-kernel-bootstrap name"

[[ $EXPECTED_KERNEL_COMMIT =~ ^[0-9a-f]{40}$ ]] || ci_die "EXPECTED_KERNEL_COMMIT must be 40 lowercase hex characters"
[[ $EXPECTED_KERNEL_CONFIG_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid EXPECTED_KERNEL_CONFIG_SHA256"
[[ $EXPECTED_KERNEL_RELEASE =~ ^[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}$ ]] || ci_die "unsafe EXPECTED_KERNEL_RELEASE"
[[ $BASE_DEVICE_DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid baseline archive SHA-256"
[[ $DTB_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\.dtb$ ]] || ci_die "unsafe DTB_NAME"
[[ $KERNEL_PACKAGE_VERSION =~ ^[0-9][0-9A-Za-z.+~_-]{0,63}$ ]] || ci_die "unsafe KERNEL_PACKAGE_VERSION"
[ "$KERNEL_PACKAGE_VERSION" = "$EXPECTED_KERNEL_RELEASE" ] ||
  ci_die 'KERNEL_PACKAGE_VERSION must equal EXPECTED_KERNEL_RELEASE'
case "$EXPECTED_KERNEL_RELEASE" in
  *-g"${EXPECTED_KERNEL_COMMIT:0:12}"*) ;;
  *) ci_die "EXPECTED_KERNEL_RELEASE does not bind EXPECTED_KERNEL_COMMIT" ;;
esac
[[ $KERNEL_BUILD_JOBS =~ ^[1-9][0-9]{0,3}$ ]] || ci_die "invalid KERNEL_BUILD_JOBS"
[[ $CROSS_COMPILE =~ ^/?[A-Za-z0-9][A-Za-z0-9._+/-]{0,254}-$ && $CROSS_COMPILE != *..* && $CROSS_COMPILE != *//* ]] ||
  ci_die "unsafe CROSS_COMPILE"
if [[ $CROSS_COMPILE = */* && $CROSS_COMPILE != /* ]]; then
  ci_die 'CROSS_COMPILE containing a slash must be absolute'
fi
if [[ $CROSS_COMPILE = /* ]]; then
  cross_directory=$(${LOCKED_TOOL_COMMAND_PATH[realpath]} -e -- "$(${LOCKED_TOOL_COMMAND_PATH[dirname]} -- "$CROSS_COMPILE")") ||
    ci_die 'cannot resolve CROSS_COMPILE directory'
  cross_basename=$(${LOCKED_TOOL_COMMAND_PATH[basename]} -- "$CROSS_COMPILE")
else
  cross_gcc_candidate=$(type -P -- "${CROSS_COMPILE}gcc") ||
    ci_die "required command not found: ${CROSS_COMPILE}gcc"
  cross_directory=$(${LOCKED_TOOL_COMMAND_PATH[realpath]} -e -- "$(${LOCKED_TOOL_COMMAND_PATH[dirname]} -- "$cross_gcc_candidate")") ||
    ci_die 'cannot resolve CROSS_COMPILE directory'
  cross_basename=$CROSS_COMPILE
fi
[[ $cross_basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}-$ ]] ||
  ci_die 'unsafe CROSS_COMPILE basename'
CROSS_COMPILE="$cross_directory/$cross_basename"
[ "${#CROSS_COMPILE}" -le 257 ] &&
  [[ $CROSS_COMPILE =~ ^/[A-Za-z0-9][A-Za-z0-9._+/-]{0,254}-$ &&
     $CROSS_COMPILE != *..* && $CROSS_COMPILE != *//* ]] ||
  ci_die 'canonical CROSS_COMPILE is not representable by the evidence schema'

for cross_tool in gcc as ld ar nm objcopy objdump readelf strip; do
  resolve_tool_path "$cross_tool" "${CROSS_COMPILE}${cross_tool}"
  capture_tool_identity "$cross_tool"
done

"$DPKG_BIN" --validate-version "$KERNEL_PACKAGE_VERSION" >/dev/null ||
  ci_die "invalid KERNEL_PACKAGE_VERSION"

for proxy_name in HTTPS_PROXY HTTP_PROXY https_proxy http_proxy; do
  proxy_value=${!proxy_name}
  if [ -n "$proxy_value" ]; then
    [ "${#proxy_value}" -le 2048 ] &&
      [[ $proxy_value =~ ^https?://[A-Za-z0-9._~:/@%+,-]+$ ]] ||
      ci_die "invalid transport proxy variable: $proxy_name"
  fi
done
for proxy_name in NO_PROXY no_proxy; do
  proxy_value=${!proxy_name}
  if [ -n "$proxy_value" ]; then
    [ "${#proxy_value}" -le 2048 ] &&
      [[ $proxy_value =~ ^[A-Za-z0-9.*_~:,-]*$ ]] ||
      ci_die "invalid transport proxy variable: $proxy_name"
  fi
done

kernel_source=$(realpath -e -- "$KERNEL_SOURCE_DIR")
kernel_git=$(realpath -e -- "$KERNEL_GIT_DIR")
kernel_build_input=$(realpath -e -- "$KERNEL_BUILD_DIR")
[ -d "$kernel_source" ] || ci_die "kernel source is not a directory"
[ -d "$kernel_git/objects" ] || ci_die "KERNEL_GIT_DIR is not a Git object database"
[ -d "$kernel_build_input" ] || ci_die "kernel build is not a directory"
[ -s "$kernel_build_input/.config" ] || ci_die "kernel build has no prepared .config"
configured_rustc_version=$("$AWK_BIN" -F= '
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
resolve_tool_path rustc "$KERNEL_RUSTC"
capture_tool_identity rustc
kernel_rustc=${LOCKED_TOOL_COMMAND_PATH[rustc]}
if [ "$configured_rustc_version" = 0 ]; then
  LOCKED_TOOL_VERSION[rustc]=disabled
fi
if "${LOCKED_TOOL_COMMAND_PATH[grep]}" -Fxq 'CONFIG_DEBUG_INFO_BTF=y' "$kernel_build_input/.config"; then
  resolve_tool_path pahole pahole
  capture_tool_identity pahole
else
  mark_tool_unused pahole
fi
kernel_build=$kernel_build_input

git_cmd=(ci_sanitized_git_env "$GIT_BIN" --no-replace-objects --git-dir="$kernel_git" --work-tree="$kernel_source")
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
  local status
  local -a locked_make_environment=(
    PATH="$kernel_locked_path"
    GIT_DIR="$kernel_git"
    GIT_WORK_TREE="$kernel_source"
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"
    ARCH="$ARCH"
    CROSS_COMPILE="$CROSS_COMPILE"
    KBUILD_BUILD_TIMESTAMP="$KBUILD_BUILD_TIMESTAMP"
    KBUILD_BUILD_USER="$KBUILD_BUILD_USER"
    KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST"
    KBUILD_BUILD_VERSION="$KBUILD_BUILD_VERSION"
    KCONFIG_NOTIMESTAMP=1
    HOSTCC="$HOST_GCC_BIN"
    HOSTCXX="$HOST_GXX_BIN"
    HOSTAS="$HOST_AS_BIN"
    HOSTLD="$HOST_LD_BIN"
    HOSTAR="$HOST_AR_BIN"
    LEX="$FLEX_BIN"
    YACC="$BISON_BIN"
    M4="$M4_BIN"
    BISON_PKGDATADIR="$BISON_DATA_DIR"
    AWK="$AWK_BIN"
    PERL="$PERL_BIN"
    PYTHON3="$PYTHON3_BIN"
    PKG_CONFIG="$PKG_CONFIG_BIN"
    CONFIG_SHELL="$SH_BIN"
    SHELL="$SH_BIN"
    KCFLAGS="$kernel_kcflags"
    KAFLAGS="$kernel_kaflags"
    HOSTCFLAGS="$kernel_hostcflags"
    HOSTCXXFLAGS="$kernel_hostcxxflags"
  )
  local -a locked_optional_make_arguments=()
  if [ "${LOCKED_TOOL_PATH[pahole]}" != unused ]; then
    locked_make_environment+=(PAHOLE="${LOCKED_TOOL_COMMAND_PATH[pahole]}")
    locked_optional_make_arguments+=(PAHOLE="${LOCKED_TOOL_COMMAND_PATH[pahole]}")
  fi
  verify_locked_tools 'before Kbuild invocation'
  verify_kernel_locked_path "$kernel_locked_path"
  # Kconfig stores the first compiler-version line. Invoke the canonical
  # locked command symlink so a versioned symlink target cannot rewrite the
  # approved config while both command and target identities remain checked.
  if ci_sanitized_kernel_env \
      "${locked_make_environment[@]}" \
      "$MAKE_BIN" -C "$kernel_source" \
      O="$kernel_build" \
      ARCH="$ARCH" \
      CROSS_COMPILE="$CROSS_COMPILE" \
      SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
      KBUILD_BUILD_TIMESTAMP="$KBUILD_BUILD_TIMESTAMP" \
      KBUILD_BUILD_USER="$KBUILD_BUILD_USER" \
      KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST" \
      KBUILD_BUILD_VERSION="$KBUILD_BUILD_VERSION" \
      KCONFIG_NOTIMESTAMP=1 \
      RUSTC="$kernel_rustc" \
      CC="${LOCKED_TOOL_COMMAND_PATH[gcc]}" \
      AS="${LOCKED_TOOL_COMMAND_PATH[as]}" \
      LD="${LOCKED_TOOL_COMMAND_PATH[ld]}" \
      AR="${LOCKED_TOOL_COMMAND_PATH[ar]}" \
      NM="${LOCKED_TOOL_COMMAND_PATH[nm]}" \
      OBJCOPY="${LOCKED_TOOL_COMMAND_PATH[objcopy]}" \
      OBJDUMP="${LOCKED_TOOL_COMMAND_PATH[objdump]}" \
      READELF="${LOCKED_TOOL_COMMAND_PATH[readelf]}" \
      STRIP="${LOCKED_TOOL_COMMAND_PATH[strip]}" \
      HOSTCC="$HOST_GCC_BIN" \
      HOSTCXX="$HOST_GXX_BIN" \
      HOSTAS="$HOST_AS_BIN" \
      HOSTLD="$HOST_LD_BIN" \
      HOSTAR="$HOST_AR_BIN" \
      LEX="$FLEX_BIN" \
      YACC="$BISON_BIN" \
      M4="$M4_BIN" \
      BISON_PKGDATADIR="$BISON_DATA_DIR" \
      AWK="$AWK_BIN" \
      PERL="$PERL_BIN" \
      PYTHON3="$PYTHON3_BIN" \
      PKG_CONFIG="$PKG_CONFIG_BIN" \
      CONFIG_SHELL="$SH_BIN" \
      SHELL="$SH_BIN" \
      KCFLAGS="$kernel_kcflags" \
      KAFLAGS="$kernel_kaflags" \
      HOSTCFLAGS="$kernel_hostcflags" \
      HOSTCXXFLAGS="$kernel_hostcxxflags" \
      "${locked_optional_make_arguments[@]}" \
      "$@"; then
    status=0
  else
    status=$?
  fi
  verify_kernel_locked_path "$kernel_locked_path"
  verify_locked_tools 'after Kbuild invocation'
  return "$status"
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

assert_no_private_paths_in_compiled_objects() {
  local search_root=$1 patterns=$2 report=$3
  local first_private_path_leak scan_status

  if grep -aFrl -f "$patterns" --include='*.o' --include='*.ko' \
      "$search_root" > "$report"; then
    first_private_path_leak=$(sed -n '1p' "$report")
    ci_die "compiled kernel object retains a private build/source path: $first_private_path_leak"
  else
    scan_status=$?
    [ "$scan_status" -eq 1 ] ||
      ci_die 'cannot scan compiled kernel objects for private path leakage'
  fi
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

kernel_rustc_version() {
  printf '%s\n' "${LOCKED_TOOL_VERSION[rustc]}"
}

write_locked_toolchain_record() {
  local label=$1

  ci_require_tsv_scalar "tool version for $label" "${LOCKED_TOOL_VERSION[$label]}" 255
  printf '%s-sha256\t%s\n' "$label" "${LOCKED_TOOL_SHA256[$label]}"
  printf '%s-version\t%s\n' "$label" "${LOCKED_TOOL_VERSION[$label]}"
}

write_kernel_toolchain_manifest() {
  local destination=$1

  {
    printf 'schema\ttb321fu.kernel-toolchain/v2\n'
    printf 'cross-compile\t%s\n' "$CROSS_COMPILE"
    printf 'bison-data-directory\t%s\n' "$BISON_DATA_DIR"
    printf 'bison-data-sha256\t%s\n' "$BISON_DATA_SHA256"
    for tool_label in \
      gcc as ld ar nm objcopy objdump readelf strip rustc host-gcc host-gxx \
      host-as host-ld host-ar \
      flex bison m4 awk perl python3 pkg-config pahole git make depmod modinfo \
      tar gzip xz dpkg-deb fdtget bash sh bc getconf sha1sum ln uname \
      sha256sum find sort xargs rsync cp dpkg touch realpath nproc date \
      install stat grep sed readlink wc tr cut findmnt curl flock mv chmod \
      mkdir mktemp rm cat dirname basename env true cmp head expr uniq; do
      write_locked_toolchain_record "$tool_label"
    done
  } > "$destination"
}

write_kbuild_flags_manifest() {
  local destination=$1

  {
    printf 'schema\ttb321fu.kbuild-flags/v2\n'
    printf 'environment-policy\t%s\n' "$PRODUCER_ENV_POLICY"
    printf 'path\t%s\n' "$KBUILD_PATH_POLICY"
    printf 'config-shell\t%s\n' "$KBUILD_CONFIG_SHELL_POLICY"
    printf 'build-path-policy\t%s\n' "$KBUILD_PATH_IDENTITY_POLICY"
    printf 'lc-all\tC\n'
    printf 'lang\tC\n'
    printf 'tz\tUTC\n'
    printf 'arch\t%s\n' "$ARCH"
    printf 'cross-compile\t%s\n' "$CROSS_COMPILE"
    printf 'kconfig-notimestamp\t1\n'
    printf 'dtb-contract\ttb321fu-aw86937-dual-v1\n'
    printf 'depmod-config\tempty-private-v1\n'
    printf 'kcflags\t%s\n' "$KBUILD_KCFLAGS_POLICY"
    printf 'kaflags\t%s\n' "$KBUILD_KCFLAGS_POLICY"
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
    printf 'hostcflags\t%s\n' "$KBUILD_HOSTFLAGS_POLICY"
    printf 'hostcxxflags\t%s\n' "$KBUILD_HOSTFLAGS_POLICY"
    printf 'hostldflags\tunset\n'
    printf 'usercflags\tunset\n'
    printf 'userldflags\tunset\n'
    printf 'localversion\tunset\n'
    printf 'dtc\tunset\n'
    printf 'dtc-flags\tunset\n'
    printf 'objcopyflags\tunset\n'
    printf 'host-extracflags\tunset\n'
    printf 'host-extracxxflags\tunset\n'
    printf 'host-extrarustflags\tunset\n'
    printf 'hostldlibs\tunset\n'
    printf 'procmacroldflags\tunset\n'
    printf 'kbuild-extra-warn\tunset\n'
    printf 'kbuild-clippy\tunset\n'
    printf 'kbuild-checksrc\tunset\n'
    printf 'kbuild-extmod-output\tunset\n'
    printf 'kbuild-nocmddep\tunset\n'
    printf 'kbuild-nsdeps\tunset\n'
    printf 'kbuild-preserve\tunset\n'
    printf 'kbuild-symtypes\tunset\n'
    printf 'kbuild-gendwarfksyms-stable\tunset\n'
    printf 'kbuild-kconfig\tunset\n'
    printf 'kconfig-autoconfig\tunset\n'
    printf 'kconfig-autoheader\tunset\n'
    printf 'config-prefix\tunset\n'
    printf 'kconfig-defconfig-list\tunset\n'
    printf 'kconfig-allconfig\tunset\n'
    printf 'kconfig-overwriteconfig\tunset\n'
    printf 'kconfig-warn-unknown-symbols\tunset\n'
    printf 'kconfig-werror\tunset\n'
    printf 'kconfig-nosilentupdate\tunset\n'
    printf 'makefiles\tunset\n'
    printf 'gnumakeflags\tunset\n'
    printf 'makeflags\tunset\n'
    printf 'mflags\tunset\n'
    printf 'makeoverrides\tunset\n'
    printf 'cpath\tunset\n'
    printf 'gcc-exec-prefix\tunset\n'
    printf 'compiler-path\tunset\n'
    printf 'library-path\tunset\n'
    printf 'pkg-config-path\tunset\n'
    printf 'tar-options\tunset\n'
    printf 'gzip-env\tunset\n'
    printf 'xz-opt\tunset\n'
    printf 'xz-defaults\tunset\n'
    printf 'dpkg-deb-threads-max\t1\n'
    printf 'dpkg-deb-compressor-type\txz\n'
    printf 'dpkg-deb-compressor-level\t6\n'
    printf 'source-date-epoch\t%s\n' "$SOURCE_DATE_EPOCH"
    printf 'kbuild-build-timestamp\t%s\n' "$KBUILD_BUILD_TIMESTAMP"
    printf 'kbuild-build-user\t%s\n' "$KBUILD_BUILD_USER"
    printf 'kbuild-build-host\t%s\n' "$KBUILD_BUILD_HOST"
    printf 'kbuild-build-version\t%s\n' "$KBUILD_BUILD_VERSION"
  } > "$destination"
}

validate_sdk_relative_path() {
  local relative=$1 component
  local -a sdk_components=()

  [ -n "$relative" ] && [ "${#relative}" -le 4094 ] ||
    ci_die 'kernel SDK manifest contains an unsafe path'
  [[ $relative != /* && $relative != *//* && $relative != */ ]] ||
    ci_die 'kernel SDK manifest contains an unsafe path'
  [[ $relative != *\\* && $relative != *$'\t'* &&
     $relative != *$'\r'* && $relative != *$'\n'* ]] ||
    ci_die 'kernel SDK manifest contains an unsafe path'
  [ "$(LC_ALL=C printf '%s' "$relative" | tr -d '\040-\176' | wc -c)" -eq 0 ] ||
    ci_die 'kernel SDK manifest path must be printable ASCII'
  IFS=/ read -r -a sdk_components <<< "$relative"
  [[ ${sdk_components[0]} != *:* ]] ||
    ci_die 'kernel SDK manifest contains an unsafe path'
  for component in "${sdk_components[@]}"; do
    [ -n "$component" ] && [ "$component" != . ] && [ "$component" != .. ] &&
      [ "${#component}" -le 255 ] ||
      ci_die 'kernel SDK manifest contains an unsafe path'
  done
}

write_kernel_sdk_manifest() {
  local root=$1 destination=$2 entry relative digest mode target special size
  local mode_value normalized_mode expected_mode
  local record_count=0 total_regular_bytes=0

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
        target=
        IFS= read -r -d '' target < <("$READLINK_BIN" -z -- "$entry") ||
          ci_die 'cannot read a NUL-terminated kernel SDK symlink target'
        [ -n "$target" ] && [ "${#target}" -le 4096 ] &&
          [[ $target != *$'\t'* && $target != *$'\r'* && $target != *$'\n'* ]] &&
          [ "$(LC_ALL=C printf '%s' "$target" | tr -d '\040-\176' | wc -c)" -eq 0 ] ||
          ci_die 'kernel SDK symlink target must be bounded printable ASCII'
        [[ $target != /* && $target != *\\* && ${target%%/*} != *:* ]] ||
          ci_die 'kernel SDK symlink target has an unsafe lexical form'
        [ "$mode" = 777 ] ||
          ci_die 'kernel SDK symlink mode differs from the consumer contract'
        digest=$(printf '%s' "$target" | sha256sum | awk '{print $1}')
        printf 'symlink\t%s\t%s\t./%s\n' "$digest" "$mode" "$relative"
      else
        mode_value=$((8#$mode))
        normalized_mode=$(( (mode_value & 0755) | 0600 ))
        if (( (mode_value & 0100) == 0 )); then
          normalized_mode=$((normalized_mode & ~0111))
        fi
        printf -v expected_mode '%o' "$normalized_mode"
        [ "$mode" = "$expected_mode" ] ||
          ci_die 'kernel SDK regular-file mode would be changed by safe extraction'
        size=$(stat -c '%s' "$entry")
        [ "$size" -le 8589934592 ] ||
          ci_die 'kernel SDK contains a regular file larger than 8 GiB'
        total_regular_bytes=$((total_regular_bytes + size))
        [ "$total_regular_bytes" -le 34359738368 ] ||
          ci_die 'kernel SDK regular-file total exceeds 32 GiB'
        digest=$(sha256sum "$entry" | awk '{print $1}')
        printf 'file\t%s\t%s\t./%s\n' "$digest" "$mode" "$relative"
      fi
      record_count=$((record_count + 1))
      [ "$record_count" -le 200000 ] || ci_die 'kernel SDK manifest has too many records'
    done < <(find "$root" -xdev \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
  } > "$destination"
  [ "$record_count" -gt 0 ] || ci_die 'kernel SDK manifest is empty'
  [ "$(stat -c '%s' "$destination")" -le 16777216 ] ||
    ci_die 'kernel SDK manifest exceeds the 16 MiB consumer limit'
}

write_kernel_sdk_archive() {
  local root=$1 destination=$2 file_list member_list size_file entry relative resolved size
  local archive_entry_count=0 source_regular_bytes=0 archive_bytes

  [ -d "$root" ] || ci_die 'kernel SDK root is not a directory'
  while IFS= read -r -d '' entry; do
    [ "$entry" = "$root/source" ] && continue
    resolved=$(realpath -e -- "$entry") ||
      ci_die "kernel SDK root contains a dangling symlink: $entry"
    case "$resolved" in
      "$root"|"$root"/*) ;;
      *) ci_die "kernel SDK root contains an external symlink: $entry" ;;
    esac
  done < <("$FIND_BIN" "$root" -xdev -type l -print0)

  file_list="$work/kernel-sdk-files.list"
  member_list="$work/kernel-sdk-members.list"
  size_file="$work/kernel-sdk-uncompressed-size"
  (
    cd "$root"
    : > "$file_list"
    while IFS= read -r -d '' entry; do
      relative=${entry#./}
      validate_sdk_relative_path "$relative"
      printf '%s\0' "$entry" >> "$file_list"
      if [ -f "$entry" ] && [ ! -L "$entry" ]; then
        size=$(stat -c '%s' -- "$entry")
        source_regular_bytes=$((source_regular_bytes + size))
        [ "$source_regular_bytes" -le 34359738368 ] ||
          ci_die 'kernel SDK archive regular-file total exceeds 32 GiB'
      fi
      archive_entry_count=$((archive_entry_count + 1))
      [ "$archive_entry_count" -le 200000 ] ||
        ci_die 'kernel SDK archive contains too many source entries'
    done < <(
      "$FIND_BIN" . -xdev -mindepth 1 ! -path ./source ! -path './source/*' -print0 |
        LC_ALL=C "$SORT_BIN" -z
    )
    [ "$archive_entry_count" -gt 0 ] || ci_die 'kernel SDK archive source list is empty'
    printf '%s\n' "$source_regular_bytes" > "$size_file"
    "$TAR_BIN" --format=gnu --hard-dereference --null --no-recursion --sort=name \
      --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
      --files-from="$file_list" -cf - | "$GZIP_BIN" -6 -n > "$destination"
  )
  [ -s "$destination" ] || ci_die 'kernel SDK archive is empty'
  source_regular_bytes=$(cat "$size_file")
  [[ $source_regular_bytes =~ ^[0-9]+$ ]] ||
    ci_die 'kernel SDK archive logical size record is invalid'
  archive_bytes=$(stat -c '%s' -- "$destination")
  [ "$source_regular_bytes" -le $((archive_bytes * 1000)) ] ||
    ci_die 'kernel SDK archive compression ratio exceeds the consumer limit'
  "$TAR_BIN" -tzf "$destination" > "$member_list" ||
    ci_die 'cannot list kernel SDK archive'
  [ "$(wc -c < "$member_list")" -le 67108864 ] ||
    ci_die 'kernel SDK archive member listing exceeds size limit'
  [ "$(wc -l < "$member_list")" -le 200000 ] ||
    ci_die 'kernel SDK archive contains too many members'
  if grep -Fx './source' "$member_list" >/dev/null; then
    ci_die 'kernel SDK archive must not retain the transient source symlink'
  fi
}

readonly CANONICAL_KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY=GUF296/ubuntu-y700-build-ci
producer_repository=
producer_commit=
producer_tree=
producer_tree_sha256=
producer_safe_extract_sha256=
producer_bundle_verifier_sha256=
producer_root_path=
verify_bootstrap_producer_state() {
  local producer_root actual status relative current_sha committed_sha index_record index_mode expected_mode index_flags
  local -a producer_git=()

  producer_safe_extract_sha256=
  producer_bundle_verifier_sha256=

  if [ -n "${KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY:-}" ]; then
    producer_repository=$KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY
  else
    producer_repository=${GITHUB_REPOSITORY:-}
  fi
  [ "$producer_repository" = "$CANONICAL_KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY" ] ||
    ci_die 'kernel bootstrap producer repository must be GUF296/ubuntu-y700-build-ci'

  producer_root=$(ci_sanitized_git_env "$GIT_BIN" -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel) ||
    ci_die 'kernel bootstrap packager must run from a Git worktree'
  producer_root=$(${LOCKED_TOOL_COMMAND_PATH[realpath]} -e -- "$producer_root")
  producer_root_path=$producer_root
  producer_git=(ci_sanitized_git_env "$GIT_BIN" --no-replace-objects -C "$producer_root")
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
  index_flags=$("${producer_git[@]}" ls-files -v) ||
    ci_die 'cannot inspect kernel bootstrap producer index flags'
  if grep -Eq '^[a-zS] ' <<<"$index_flags"; then
    ci_die 'kernel bootstrap producer has unsafe assume-unchanged/skip-worktree index flags'
  fi
  for entry in \
    "$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")" \
    "$SCRIPT_DIR/common.sh" \
    "$SCRIPT_DIR/safe-extract-archive.py" \
    "$SCRIPT_DIR/verify-kernel-bundle.py"; do
    relative=$(realpath --relative-to="$producer_root" -- "$entry")
    case "$relative" in
      ''|/*|../*|*/../*|*/..|*\\*) ci_die 'kernel bootstrap producer script escaped its Git worktree' ;;
    esac
    "${producer_git[@]}" ls-files --error-unmatch -- "$relative" >/dev/null ||
      ci_die "kernel bootstrap producer script is not tracked: $relative"
    index_record=$("${producer_git[@]}" ls-files --stage -- "$relative") ||
      ci_die "cannot read kernel bootstrap producer index mode: $relative"
    read -r index_mode _ <<<"$index_record"
    case "$relative" in
      scripts/ci/package-kernel-bootstrap.sh) expected_mode=100755 ;;
      scripts/ci/common.sh) expected_mode=100755 ;;
      scripts/ci/safe-extract-archive.py) expected_mode=100644 ;;
      scripts/ci/verify-kernel-bundle.py) expected_mode=100644 ;;
      *) ci_die "unexpected kernel bootstrap producer source: $relative" ;;
    esac
    [ "$index_mode" = "$expected_mode" ] ||
      ci_die "kernel bootstrap producer index mode mismatch: $relative"
    current_sha=$(sha256sum "$entry" | awk '{print $1}')
    committed_sha=$("${producer_git[@]}" show "$actual:$relative" | sha256sum | awk '{print $1}') ||
      ci_die "cannot read committed kernel bootstrap producer script: $relative"
    [ "$current_sha" = "$committed_sha" ] ||
      ci_die "kernel bootstrap producer script differs from its committed bytes: $relative"
    if [ "$relative" = scripts/ci/safe-extract-archive.py ]; then
      producer_safe_extract_sha256=$committed_sha
    elif [ "$relative" = scripts/ci/verify-kernel-bundle.py ]; then
      producer_bundle_verifier_sha256=$committed_sha
    fi
  done
  [[ $producer_safe_extract_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    ci_die 'kernel bootstrap safe extractor identity is unavailable'
  [[ $producer_bundle_verifier_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    ci_die 'kernel bootstrap metadata verifier identity is unavailable'
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
  verify_locked_tools 'during preflight'
  printf 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS commit=%s config=%s rustc=%s producer-repository=%s producer-commit=%s producer-tree=%s producer-tree-sha256=%s\n' \
    "$actual_commit" "$expected_config_sha" "$(kernel_rustc_version)" \
    "$producer_repository" "$producer_commit" "$producer_tree" "$producer_tree_sha256"
  exit 0
fi

bootstrap_producer_repository=$producer_repository
bootstrap_producer_commit=$producer_commit
bootstrap_producer_tree=$producer_tree
bootstrap_producer_tree_sha256=$producer_tree_sha256

validate_kernel_bootstrap_output_location() {
  local path=$1 parent=$2 probe relative ignore_record ignore_source

  case "$path" in
    "$kernel_source"|"$kernel_source"/*|"$kernel_git"|"$kernel_git"/*|\
    "$kernel_build_input"|"$kernel_build_input"/*)
      ci_die 'OUTPUT_DIR must not overlap authoritative kernel inputs'
      ;;
  esac
  [ -n "$producer_root_path" ] || ci_die 'kernel bootstrap producer root is unavailable'
  case "$path" in
    "$producer_root_path")
      ci_die 'OUTPUT_DIR must not replace the producer worktree'
      ;;
    "$producer_root_path"/*)
      for probe in "$path" "$path.lock" "$parent/.tb321fu-kernel-bootstrap.probe"; do
        relative=$(realpath -m --relative-to="$producer_root_path" -- "$probe") ||
          ci_die 'cannot normalize producer-local OUTPUT_DIR probe'
        case "$relative" in
          ''|.|/*|../*|*/../*|*/..|*\\*)
            ci_die 'producer-local OUTPUT_DIR probe escaped its worktree'
            ;;
        esac
        ignore_record=$(ci_sanitized_git_env "$GIT_BIN" -C "$producer_root_path" \
          check-ignore -v -- "$relative") ||
          ci_die 'producer-local OUTPUT_DIR, lock and temporary paths must be Git-ignored'
        ignore_source=${ignore_record%%:*}
        case "$ignore_source" in
          .gitignore|*/.gitignore) ;;
          *) ci_die 'producer-local OUTPUT_DIR must be ignored by a tracked .gitignore' ;;
        esac
        ci_sanitized_git_env "$GIT_BIN" -C "$producer_root_path" \
          ls-files --error-unmatch -- "$ignore_source" >/dev/null ||
          ci_die 'producer-local OUTPUT_DIR ignore policy is not tracked'
      done
      ;;
  esac
}

validate_compiler_prefix_map_path() {
  local label=$1 path=$2

  [ -n "$path" ] && [ "${#path}" -le 4096 ] &&
    [[ $path =~ ^/[A-Za-z0-9_./+-]+$ ]] ||
    ci_die "$label cannot be represented safely in deterministic compiler flags"
}

output_parent_requested=$(dirname -- "$OUTPUT_DIR")
output_name=$(basename -- "$OUTPUT_DIR")
[ "$output_name" = "$early_output_name" ] || ci_die 'OUTPUT_DIR basename changed during validation'
output_parent_candidate=$(realpath -m -- "$output_parent_requested") ||
  ci_die 'cannot normalize OUTPUT_DIR parent'
output_path_candidate="$output_parent_candidate/$output_name"
[ "${#output_path_candidate}" -le 4096 ] || ci_die 'resolved OUTPUT_DIR exceeds size limit'
validate_kernel_bootstrap_output_location "$output_path_candidate" "$output_parent_candidate"
build_identity_key="$actual_commit-$expected_config_sha"
kernel_build_candidate="$output_parent_candidate/.tb321fu-kernel-build-$build_identity_key"
kernel_locked_path_candidate="$output_parent_candidate/.tb321fu-kernel-tools-$build_identity_key"
validate_kernel_bootstrap_output_location "$kernel_build_candidate" "$output_parent_candidate"
validate_kernel_bootstrap_output_location "$kernel_locked_path_candidate" "$output_parent_candidate"
mkdir -p -- "$output_parent_requested"
output_parent=$(realpath -e -- "$output_parent_requested")
[ "$output_parent" = "$output_parent_candidate" ] ||
  ci_die 'OUTPUT_DIR parent changed while it was created'
output_path="$output_parent/$output_name"
[ "$output_path" = "$output_path_candidate" ] || ci_die 'OUTPUT_DIR changed during validation'
validate_kernel_bootstrap_output_location "$output_path" "$output_parent"
kernel_build="$output_parent/.tb321fu-kernel-build-$build_identity_key"
kernel_locked_path="$output_parent/.tb321fu-kernel-tools-$build_identity_key"
[ "$kernel_build" = "$kernel_build_candidate" ] &&
  [ "$kernel_locked_path" = "$kernel_locked_path_candidate" ] ||
  ci_die 'deterministic private Kbuild paths changed during validation'
validate_compiler_prefix_map_path 'kernel source path' "$kernel_source"
validate_compiler_prefix_map_path 'private kernel build path' "$kernel_build"
[ ! -e "$output_path" ] && [ ! -L "$output_path" ] ||
  ci_die 'kernel bootstrap target already exists'

output_lock_path="$output_path.lock"
if [ -e "$output_lock_path" ] || [ -L "$output_lock_path" ]; then
  [ -f "$output_lock_path" ] && [ ! -L "$output_lock_path" ] ||
    ci_die 'kernel bootstrap target lock must be a regular file'
fi
saved_umask=$(umask)
umask 077
exec {output_lock_fd}>>"$output_lock_path"
umask "$saved_umask"
"$FLOCK_BIN" -n "$output_lock_fd" ||
  ci_die 'kernel bootstrap target is already locked'
[ ! -e "$output_path" ] && [ ! -L "$output_path" ] ||
  ci_die 'kernel bootstrap target appeared while acquiring its lock'

kernel_build_lock_path="$kernel_build.lock"
if [ -e "$kernel_build_lock_path" ] || [ -L "$kernel_build_lock_path" ]; then
  [ -f "$kernel_build_lock_path" ] && [ ! -L "$kernel_build_lock_path" ] ||
    ci_die 'deterministic private Kbuild lock must be a regular file'
fi
saved_umask=$(umask)
umask 077
exec {kernel_build_lock_fd}>>"$kernel_build_lock_path"
umask "$saved_umask"
"$FLOCK_BIN" -n "$kernel_build_lock_fd" ||
  ci_die 'the deterministic private Kbuild path is already locked'
[ ! -e "$kernel_build" ] && [ ! -L "$kernel_build" ] &&
  [ ! -e "$kernel_locked_path" ] && [ ! -L "$kernel_locked_path" ] ||
  ci_die 'a deterministic private Kbuild path already exists'

work=$(${LOCKED_TOOL_COMMAND_PATH[mktemp]} -d "$output_parent/.tb321fu-kernel-bootstrap.XXXXXX")
kernel_build_input_state=
cleanup() {
  local status=$?

  if [ -n "$kernel_build_input_state" ] && [ -f "$kernel_build_input_state" ]; then
    if ! (cd "$kernel_build_input" && sha256sum --strict --check "$kernel_build_input_state" >/dev/null); then
      printf 'error: kernel build input changed while bootstrap packaging ran\n' >&2
      status=1
    fi
  fi
  if [ -e "$work" ] || [ -L "$work" ]; then
    if ! ci_safe_rmtree "$work" "$output_parent" .tb321fu-kernel-bootstrap; then
      status=1
    fi
  fi
  if [ -e "$kernel_build" ] || [ -L "$kernel_build" ]; then
    if ! ci_safe_rmtree "$kernel_build" "$output_parent" .tb321fu-kernel-build-; then
      status=1
    fi
  fi
  if [ -e "$kernel_locked_path" ] || [ -L "$kernel_locked_path" ]; then
    if ! ci_safe_rmtree "$kernel_locked_path" "$output_parent" .tb321fu-kernel-tools-; then
      status=1
    fi
  fi
  return "$status"
}
trap cleanup EXIT

runtime_safe_extract="$work/safe-extract-archive.py"
install -m 0644 "$SCRIPT_DIR/safe-extract-archive.py" "$runtime_safe_extract"
[ "$(sha256sum "$runtime_safe_extract" | awk '{print $1}')" = "$producer_safe_extract_sha256" ] ||
  ci_die 'private safe extractor differs from committed producer bytes'
runtime_bundle_verifier="$work/verify-kernel-bundle.py"
install -m 0644 "$SCRIPT_DIR/verify-kernel-bundle.py" "$runtime_bundle_verifier"
[ "$(sha256sum "$runtime_bundle_verifier" | awk '{print $1}')" = "$producer_bundle_verifier_sha256" ] ||
  ci_die 'private metadata verifier differs from committed producer bytes'
verify_kernel_bootstrap_metadata_snapshot() {
  local root=$1

  [ "$(sha256sum "$runtime_bundle_verifier" | awk '{print $1}')" = "$producer_bundle_verifier_sha256" ] ||
    ci_die 'private metadata verifier changed before stage verification'
  "$PYTHON3_BIN" -I "$runtime_bundle_verifier" \
    "$root/KERNEL-BUNDLE.tsv" \
    --kbuild-flags "$root/KBUILD-FLAGS.tsv" \
    --toolchain "$root/KERNEL-TOOLCHAIN.tsv" \
    --sdk-manifest "$root/KERNEL-SDK-MANIFEST.tsv" >/dev/null ||
    ci_die 'generated kernel bootstrap metadata failed canonical parser verification'
}
kernel_build_input_state="$work/kernel-build-input-state.sha256"
write_kernel_build_input_state "$kernel_build_input_state"

approved_config="$work/approved-kernel.config"
install -m 0644 "$kernel_build_input/.config" "$approved_config"
mkdir -m 0700 -- "$kernel_build"
prepare_kernel_locked_path "$kernel_locked_path"
initialize_kernel_prefix_maps
# Build from a fresh private O= directory. Reject ref-derived ABI drift before
# acquiring or extracting the baseline archive.
install -m 0644 "$approved_config" "$kernel_build/.config"
kernel_make olddefconfig
private_config_sha=$(sha256sum "$kernel_build/.config" | awk '{print $1}')
[ "$private_config_sha" = "$expected_config_sha" ] ||
  ci_die 'private olddefconfig changed the approved kernel config'
verify_kernel_source_state "after clean configuration restore"

kernel_release=$(kernel_make -s kernelrelease)
verify_kernel_release_identity "$kernel_release"

baseline_archive="$work/baseline-device-debs.tar.gz"
baseline_dir="$work/baseline"
mkdir -p "$baseline_dir"
ci_download "$BASE_DEVICE_DEB_ARCHIVE" "$baseline_archive" "$BASE_DEVICE_DEB_ARCHIVE_SHA256"
"$PYTHON3_BIN" -I "$runtime_safe_extract" "$baseline_archive" "$baseline_dir" ||
  ci_die "safe archive extraction failed: $baseline_archive"

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

kernel_make -j"$KERNEL_BUILD_JOBS" Image modules "qcom/$DTB_NAME"
[ "$(sha256sum "$kernel_build/.config" | awk '{print $1}')" = "$expected_config_sha" ] ||
  ci_die 'kernel build changed the approved kernel config'
[ "$(cat "$kernel_build/include/config/kernel.release")" = "$kernel_release" ] || ci_die "built kernel.release does not match source commit"
grep -Fxq "#define UTS_RELEASE \"$kernel_release\"" "$kernel_build/include/generated/utsrelease.h" || ci_die "UTS_RELEASE does not match built kernel release"

[ -s "$kernel_build/arch/arm64/kernel/entry.o" ] ||
  ci_die 'kernel build did not produce the required ARM64 assembly object'
private_path_patterns="$work/private-build-paths.patterns"
private_path_leaks="$work/private-build-path-leaks.list"
printf '%s\n' "$kernel_build" "$kernel_source" "$work" > "$private_path_patterns"
assert_no_private_paths_in_compiled_objects \
  "$kernel_build" "$private_path_patterns" "$private_path_leaks"

image="$kernel_build/arch/arm64/boot/Image"
dtb="$kernel_build/arch/arm64/boot/dts/qcom/$DTB_NAME"
[ -s "$image" ] || ci_die "missing kernel Image"
[ -s "$dtb" ] || ci_die "missing $DTB_NAME"
ci_verify_tb321fu_haptics_dtb "$dtb" "$FDTGET_BIN"

modules_root="$work/modules-root"
kernel_make INSTALL_MOD_PATH="$modules_root" DEPMOD="$TRUE_BIN" modules_install
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
depmod_config="$work/depmod.conf"
install -m 0644 /dev/null "$depmod_config"
"$DEPMOD_BIN" -C "$depmod_config" -b "$modules_root" "$kernel_release"

module_count=0
while IFS= read -r -d '' module; do
  vermagic=$("$MODINFO_BIN" -F vermagic "$module")
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
package_special=$(find "$package_root" ! -type d ! -type f -print -quit)
[ -z "$package_special" ] ||
  ci_die "kernel modules package contains an unsupported non-regular member: $package_special"
find "$package_root" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"

stage="$work/stage"
artifacts="$work/kernel-artifacts"
device="$work/device-debs"
mkdir -p "$stage" "$artifacts" "$device"
modules_deb="$device/y700-daily-kernel-modules_${KERNEL_PACKAGE_VERSION}_arm64.deb"
"$DPKG_DEB_BIN" --root-owner-group --threads-max=1 -Zxz -z6 \
  -b "$package_root" "$modules_deb" >/dev/null

modules_manifest="$work/MODULES.sha256"
(
  cd "$package_root"
  find ./usr/lib/modules -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --
) > "$modules_manifest"
modules_manifest_file_count=$(wc -l < "$modules_manifest")
[[ $modules_manifest_file_count =~ ^[1-9][0-9]{0,8}$ ]] ||
  ci_die 'kernel modules manifest is empty or has an unsafe record count'
[ "$modules_manifest_file_count" -le 400000 ] ||
  ci_die 'kernel modules manifest has too many records'
[ "$(stat -c '%s' "$modules_manifest")" -le 16777216 ] ||
  ci_die 'kernel modules manifest exceeds the 16 MiB consumer limit'
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
compiler_version=${LOCKED_TOOL_VERSION[gcc]}
compiler_sha=${LOCKED_TOOL_SHA256[gcc]}
rustc_version=$(kernel_rustc_version)
rustc_sha=${LOCKED_TOOL_SHA256[rustc]}
make_version=${LOCKED_TOOL_VERSION[make]}
make_sha=${LOCKED_TOOL_SHA256[make]}
dpkg_deb_version=${LOCKED_TOOL_VERSION[dpkg-deb]}
dpkg_deb_sha=${LOCKED_TOOL_SHA256[dpkg-deb]}
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
"$TAR_BIN" --format=gnu --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
  --owner=0 --group=0 --numeric-owner -C "$artifacts" -cf - . |
  "$GZIP_BIN" -6 -n > "$kernel_archive"
"$TAR_BIN" --format=gnu --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
  --owner=0 --group=0 --numeric-owner -C "$device" -cf - . |
  "$GZIP_BIN" -6 -n > "$device_archive"
chmod 0644 "$kernel_archive" "$device_archive"
cp -a "$artifacts/SOURCE-LOCK.tsv" "$stage/KERNEL-SOURCE-LOCK.tsv"
cp -a "$bundle_file" "$stage/KERNEL-BUNDLE.tsv"
cp -a "$artifacts/MODULES.sha256" "$stage/MODULES.sha256"
cp -a "$sdk_manifest" "$stage/KERNEL-SDK-MANIFEST.tsv"
cp -a "$toolchain_manifest" "$stage/KERNEL-TOOLCHAIN.tsv"
cp -a "$kbuild_flags_manifest" "$stage/KBUILD-FLAGS.tsv"
(
  cd "$stage"
  "$SHA256SUM_BIN" -- "$(basename -- "$kernel_archive")" "$(basename -- "$device_archive")" \
    "$(basename -- "$sdk_archive")" KERNEL-SOURCE-LOCK.tsv KERNEL-BUNDLE.tsv \
    MODULES.sha256 KERNEL-SDK-MANIFEST.tsv KERNEL-TOOLCHAIN.tsv KBUILD-FLAGS.tsv > SHA256SUMS.txt
)

kernel_archive_name=$(basename -- "$kernel_archive")
device_archive_name=$(basename -- "$device_archive")
sdk_archive_name=$(basename -- "$sdk_archive")
verify_kernel_source_state 'before bootstrap promotion'
verify_kernel_build_input_state "$kernel_build_input_state"
verify_bootstrap_producer_state
[ "$producer_repository" = "$bootstrap_producer_repository" ] &&
  [ "$producer_commit" = "$bootstrap_producer_commit" ] &&
  [ "$producer_tree" = "$bootstrap_producer_tree" ] &&
  [ "$producer_tree_sha256" = "$bootstrap_producer_tree_sha256" ] ||
  ci_die 'kernel bootstrap producer identity changed before promotion'
verify_locked_tools 'before bootstrap promotion'
ci_verify_kernel_bootstrap_stage \
  "$stage" "$kernel_archive_name" "$device_archive_name" "$sdk_archive_name" \
  "$SHA256SUM_BIN" "${LOCKED_TOOL_COMMAND_PATH[stat]}"
verify_kernel_bootstrap_metadata_snapshot "$stage"
verify_locked_tools 'after final stage verification'
[ ! -e "$output_path" ] && [ ! -L "$output_path" ] ||
  ci_die 'kernel bootstrap target appeared before promotion'
"$MV_BIN" --no-clobber -T -- "$stage" "$output_path"
[ ! -e "$stage" ] && [ -d "$output_path" ] && [ ! -L "$output_path" ] ||
  ci_die 'kernel bootstrap no-clobber promotion failed'
ci_verify_kernel_bootstrap_stage \
  "$output_path" "$kernel_archive_name" "$device_archive_name" "$sdk_archive_name" \
  "$SHA256SUM_BIN" "${LOCKED_TOOL_COMMAND_PATH[stat]}"
verify_kernel_bootstrap_metadata_snapshot "$output_path"
verify_locked_tools 'after bootstrap promotion'
trap - EXIT
cleanup
exec {output_lock_fd}>&-
printf 'KERNEL_BOOTSTRAP=PASS release=%s commit=%s bundle=%s modules=%d output=%s\n' \
  "$kernel_release" "$actual_commit" "$kernel_bundle_id" "$module_count" "$output_path"
