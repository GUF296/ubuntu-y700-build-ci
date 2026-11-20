#!/usr/bin/env bash
set -euo pipefail

ci_log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

ci_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ci_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || ci_die "required command not found: $1"
}

ci_bool() {
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

ci_validate_bool() {
  local value=${1-} label=${2:-boolean}

  case "$value" in
    0|1|yes|no|true|false|on|off) ;;
    *) ci_die "$label must be one of 0, 1, yes, no, true, false, on or off" ;;
  esac
}

ci_abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
  esac
}

ci_validate_no_symlink_ancestors() {
  local path=${1:?path is required} label=${2:-path} current
  current=$(ci_abs_path "$path")
  while :; do
    [ ! -L "$current" ] || ci_die "$label contains a symlink component: $current"
    [ "$current" = / ] && break
    current=${current%/*}
    [ -n "$current" ] || current=/
  done
}

# Return a monotonic timestamp in milliseconds. /proc/uptime is backed by
# CLOCK_MONOTONIC on Linux and avoids wall-clock adjustments changing a
# download deadline. Keep a Bash-only fallback for non-Linux fixture runs.
ci_monotonic_millis() {
  local uptime whole fraction
  if [ -r /proc/uptime ]; then
    read -r uptime _ < /proc/uptime || return 1
    whole=${uptime%%.*}
    fraction=${uptime#*.}
    [ "$fraction" = "$uptime" ] && fraction=0
    fraction=${fraction}000
    fraction=${fraction:0:3}
    [[ "$whole" =~ ^[0-9]+$ && "$fraction" =~ ^[0-9]{3}$ ]] || return 1
    printf '%d\n' "$((10#$whole * 1000 + 10#$fraction))"
    return 0
  fi
  # Bash 5 exposes EPOCHREALTIME with microsecond resolution. It is not
  # monotonic, but is preferable to integer SECONDS outside Linux fixtures.
  if [[ ${EPOCHREALTIME:-} =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    fraction=${BASH_REMATCH[2]}000
    fraction=${fraction:0:3}
    printf '%d\n' "$((10#${BASH_REMATCH[1]} * 1000 + 10#$fraction))"
    return 0
  fi
  return 1
}

# Run Git without caller-provided repository, object, index, replacement, or
# configuration state. Callers may append their own explicit GIT_DIR/worktree.
ci_sanitized_git_env() {
  env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_COMMON_DIR \
    -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_REPLACE_REF_BASE \
    -u GIT_NAMESPACE \
    -u GIT_SHALLOW_FILE \
    -u GIT_GRAFT_FILE \
    -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_COUNT \
    -u GIT_CONFIG_SYSTEM \
    -u GIT_CONFIG_GLOBAL \
    -u GIT_EXEC_PATH \
    -u GIT_TEMPLATE_DIR \
    -u GIT_CEILING_DIRECTORIES \
    -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
    -u GIT_IMPLICIT_WORK_TREE \
    -u GIT_PREFIX \
    -u GIT_INTERNAL_SUPER_PREFIX \
    -u GIT_QUARANTINE_PATH \
    -u GIT_SSH \
    -u GIT_SSH_COMMAND \
    -u GIT_SSH_VARIANT \
    -u GIT_PROXY_COMMAND \
    -u GIT_ASKPASS \
    -u GIT_ALLOW_PROTOCOL \
    -u GIT_PROTOCOL_FROM_USER \
    -u GIT_NO_REPLACE_OBJECTS \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=core.fsmonitor \
    GIT_CONFIG_VALUE_0=false \
    GIT_CONFIG_KEY_1=core.untrackedCache \
    GIT_CONFIG_VALUE_1=false \
    GIT_CONFIG_KEY_2=core.excludesFile \
    GIT_CONFIG_VALUE_2=/dev/null \
    "$@"
}

readonly CI_CANONICAL_BUILD_PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Kbuild accepts open-ended and target-specific variable names, so a denylist
# cannot make an inherited environment deterministic. Start from an empty
# environment and add only the fixed process policy plus arguments selected by
# the caller. Git's repository/configuration escape hatches are likewise
# replaced by the explicit state below.
ci_sanitized_kernel_env() {
  env -i \
    PATH="$CI_CANONICAL_BUILD_PATH" \
    HOME=/nonexistent \
    LANG=C \
    LC_ALL=C \
    TZ=UTC \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=core.fsmonitor \
    GIT_CONFIG_VALUE_0=false \
    GIT_CONFIG_KEY_1=core.untrackedCache \
    GIT_CONFIG_VALUE_1=false \
    GIT_CONFIG_KEY_2=core.excludesFile \
    GIT_CONFIG_VALUE_2=/dev/null \
    "$@"
}

ci_verify_tb321fu_haptics_dtb() {
  local dtb=$1 fdtget_bin=$2 path child child_path children reg compatible label status
  local contract_record contract_tail expected_reg expected_label
  local right_path= left_path= right_parent left_parent
  local root_compatible wrapper_compatible wrapper_reg parent_compatible parent_reg
  local wrapper_path=/soc@0/geniqup@ac0000
  local expected_parent=/soc@0/geniqup@ac0000/i2c@a9c000
  local node_count=0 queue_index=0
  local -a queue=(/)
  local -a availability_paths=(/ /soc@0 "$wrapper_path" "$expected_parent")

  [ -f "$dtb" ] && [ ! -L "$dtb" ] && [ -s "$dtb" ] ||
    ci_die 'TB321FU DTB contract input must be a nonempty regular file'
  [ -x "$fdtget_bin" ] && [ -f "$fdtget_bin" ] ||
    ci_die 'fdtget contract tool must be an executable regular file'

  root_compatible=$("$fdtget_bin" -t s "$dtb" / compatible) ||
    ci_die 'compiled DTB root lacks compatible'
  [ "$root_compatible" = 'lenovo,tb321fu qcom,sm8650' ] ||
    ci_die 'compiled DTB root compatible mismatch'

  while [ "$queue_index" -lt "${#queue[@]}" ]; do
    path=${queue[$queue_index]}
    queue_index=$((queue_index + 1))
    children=$("$fdtget_bin" -l "$dtb" "$path") ||
      ci_die "cannot enumerate compiled DTB node: $path"
    [ "${#children}" -le 1048576 ] ||
      ci_die 'compiled DTB node listing exceeds size limit'
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      [[ $child =~ ^[A-Za-z0-9,._+@#-]{1,255}$ ]] ||
        ci_die 'compiled DTB contains an unsafe node name'
      if [ "$path" = / ]; then
        child_path="/$child"
      else
        child_path="$path/$child"
      fi
      queue+=("$child_path")
      node_count=$((node_count + 1))
      [ "$node_count" -le 20000 ] ||
        ci_die 'compiled DTB contains too many nodes'
      case "$child" in
        haptics-right@5a)
          [ -z "$right_path" ] ||
            ci_die 'compiled DTB contains duplicate haptics-right@5a nodes'
          right_path=$child_path
          ;;
        haptics-left@5b)
          [ -z "$left_path" ] ||
            ci_die 'compiled DTB contains duplicate haptics-left@5b nodes'
          left_path=$child_path
          ;;
      esac
    done <<<"$children"
  done

  [ -n "$right_path" ] && [ -n "$left_path" ] ||
    ci_die 'compiled DTB lacks the two TB321FU AW86937 nodes'
  right_parent=${right_path%/*}
  left_parent=${left_path%/*}
  [ "$right_parent" = "$left_parent" ] ||
    ci_die 'compiled DTB AW86937 nodes do not share one I2C parent'
  [ "$right_path" = "$expected_parent/haptics-right@5a" ] &&
    [ "$left_path" = "$expected_parent/haptics-left@5b" ] ||
    ci_die 'compiled DTB AW86937 nodes are not on the canonical TB321FU I2C bus'

  wrapper_compatible=$("$fdtget_bin" -t s "$dtb" "$wrapper_path" compatible) ||
    ci_die 'compiled DTB canonical GENI wrapper lacks compatible'
  [ "$wrapper_compatible" = qcom,geni-se-qup ] ||
    ci_die 'compiled DTB canonical GENI wrapper compatible mismatch'
  wrapper_reg=$("$fdtget_bin" -t x "$dtb" "$wrapper_path" reg) ||
    ci_die 'compiled DTB canonical GENI wrapper lacks reg'
  [ "$wrapper_reg" = '0 ac0000 0 2000' ] ||
    ci_die 'compiled DTB canonical GENI wrapper reg mismatch'

  parent_compatible=$("$fdtget_bin" -t s "$dtb" "$right_parent" compatible) ||
    ci_die 'compiled DTB canonical I2C controller lacks compatible'
  [ "$parent_compatible" = qcom,geni-i2c ] ||
    ci_die 'compiled DTB canonical I2C controller compatible mismatch'
  parent_reg=$("$fdtget_bin" -t x "$dtb" "$right_parent" reg) ||
    ci_die 'compiled DTB canonical I2C controller lacks reg'
  [ "$parent_reg" = '0 a9c000 0 4000' ] ||
    ci_die 'compiled DTB canonical I2C controller reg mismatch'

  for path in "${availability_paths[@]}"; do
    status=$("$fdtget_bin" -d okay -t s "$dtb" "$path" status) ||
      ci_die "cannot read compiled DTB effective status: $path"
    [ "$status" = okay ] ||
      ci_die "compiled DTB ancestor status is not okay: $path"
  done

  for contract_record in \
    "$right_path:5a:aw86937-haptics-right" \
    "$left_path:5b:aw86937-haptics-left"; do
    path=${contract_record%%:*}
    contract_tail=${contract_record#*:}
    expected_reg=${contract_tail%%:*}
    expected_label=${contract_tail#*:}
    reg=$("$fdtget_bin" -t x "$dtb" "$path" reg) ||
      ci_die "compiled DTB AW86937 node lacks reg: $path"
    case "$reg" in
      "$expected_reg"|0x"$expected_reg"|000000"$expected_reg") ;;
      *) ci_die "compiled DTB AW86937 reg mismatch: $path" ;;
    esac
    compatible=$("$fdtget_bin" -t s "$dtb" "$path" compatible) ||
      ci_die "compiled DTB AW86937 node lacks compatible: $path"
    [ "$compatible" = 'lenovo,tb321fu-aw86937 awinic,aw86937' ] ||
      ci_die "compiled DTB AW86937 compatible mismatch: $path"
    label=$("$fdtget_bin" -t s "$dtb" "$path" label) ||
      ci_die "compiled DTB AW86937 node lacks label: $path"
    [ "$label" = "$expected_label" ] ||
      ci_die "compiled DTB AW86937 label mismatch: $path"
    status=$("$fdtget_bin" -d okay -t s "$dtb" "$path" status) ||
      ci_die "cannot read compiled DTB AW86937 node status: $path"
    [ "$status" = okay ] ||
      ci_die "compiled DTB AW86937 node status is not okay: $path"
  done
}

ci_verify_kernel_bootstrap_stage() {
  local stage=$1 kernel_archive_name=$2 device_archive_name=$3
  local sdk_archive_name=$4 sha256sum_bin=$5 stat_bin=$6 entry name mode
  local index line checksum_name
  local -a checksum_names=(
    "$kernel_archive_name"
    "$device_archive_name"
    "$sdk_archive_name"
    KERNEL-SOURCE-LOCK.tsv
    KERNEL-BUNDLE.tsv
    MODULES.sha256
    KERNEL-SDK-MANIFEST.tsv
    KERNEL-TOOLCHAIN.tsv
    KBUILD-FLAGS.tsv
  )
  local -a root_names=("${checksum_names[@]}" SHA256SUMS.txt)
  local -a checksum_lines=()
  local -A expected=()

  [ -d "$stage" ] && [ ! -L "$stage" ] ||
    ci_die 'kernel bootstrap stage must be a directory'
  for name in "${root_names[@]}"; do
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]{0,255}$ ]] ||
      ci_die 'kernel bootstrap expected member has an unsafe name'
    [ -z "${expected[$name]+x}" ] ||
      ci_die 'kernel bootstrap expected member set contains a duplicate'
    expected["$name"]=1
  done

  shopt -s nullglob dotglob
  local -a entries=("$stage"/*)
  shopt -u nullglob dotglob
  [ "${#entries[@]}" -eq 10 ] ||
    ci_die 'kernel bootstrap stage must contain exactly ten root files'
  for entry in "${entries[@]}"; do
    name=${entry##*/}
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]{0,255}$ ]] ||
      ci_die 'kernel bootstrap stage contains an unsafe member name'
    [ "${expected[$name]+x}" = x ] ||
      ci_die "kernel bootstrap stage contains an unexpected member: $name"
    [ -f "$entry" ] && [ ! -L "$entry" ] ||
      ci_die "kernel bootstrap stage member must be a regular file: $name"
    mode=$("$stat_bin" -c '%a' -- "$entry") ||
      ci_die "cannot stat kernel bootstrap stage member: $name"
    [ "$mode" = 644 ] ||
      ci_die "kernel bootstrap stage member mode must be 0644: $name"
  done

  [ "$("$stat_bin" -c '%s' -- "$stage/SHA256SUMS.txt")" -le 4096 ] ||
    ci_die 'kernel bootstrap checksum manifest exceeds size limit'
  mapfile -t checksum_lines < "$stage/SHA256SUMS.txt"
  [ "${#checksum_lines[@]}" -eq 9 ] ||
    ci_die 'kernel bootstrap checksum manifest must contain exactly nine records'
  for index in "${!checksum_names[@]}"; do
    line=${checksum_lines[$index]}
    [[ $line =~ ^[0-9a-f]{64}\ \ [A-Za-z0-9][A-Za-z0-9._+~-]{0,255}$ ]] ||
      ci_die 'kernel bootstrap checksum manifest contains a malformed record'
    checksum_name=${line:66}
    [ "$checksum_name" = "${checksum_names[$index]}" ] ||
      ci_die 'kernel bootstrap checksum manifest has an unexpected record order'
  done
  (cd "$stage" && "$sha256sum_bin" --strict --check SHA256SUMS.txt >/dev/null) ||
    ci_die 'kernel bootstrap checksum verification failed'
}

ci_validate_output_prefix() {
  local value=$1
  [[ ${#value} -le 64 && $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    ci_die "invalid OUTPUT_PREFIX (1-64 characters; letters, digits, dot, underscore and hyphen only): $value"
}

ci_validate_output_dir() {
  local value=$1 component
  local -a components=()
  [[ -n "$value" && ${#value} -le 256 && "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
    ci_die "invalid OUTPUT_DIR: $value"
  [[ "$value" != /* ]] || ci_die "OUTPUT_DIR must be relative to the repository: $value"
  IFS=/ read -r -a components <<< "$value"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. &&
       "$component" =~ ^[A-Za-z0-9._-]+$ ]] ||
      ci_die "invalid OUTPUT_DIR component: $component"
  done
}

ci_validate_sha256() {
  local label=$1 value=$2
  [[ "$value" =~ ^[A-Fa-f0-9]{64}$ ]] ||
    ci_die "$label must be a 64-character SHA-256 digest"
}

ci_validate_https_url() {
  local label=$1 value=$2 authority host path
  [[ -n "$value" && ${#value} -le 2048 && "$value" != *$'\n'* && "$value" != *$'\r'* &&
     "$value" != *'"'* && "$value" != *"'"* && "$value" != *';'* &&
     "$value" != *'?'* && "$value" != *'#'* && "$value" != *'\\'* ]] ||
    ci_die "$label must be a simple HTTPS URL"
  [[ "$value" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~:/@%+,-]*)?$ ]] ||
    ci_die "$label must be a simple HTTPS URL"
  authority=${value#https://}
  authority=${authority%%/*}
  ci_validate_dns_authority "$label" "$authority"
  host=${authority%%:*}
  path=${value#https://$authority}
  [[ "$path" != *//* ]] || ci_die "$label has an invalid path"
}

ci_validate_image_size() {
  local label=$1 value=$2 min_mib=$3 max_mib=$4 number suffix mib
  [[ "$value" =~ ^([1-9][0-9]{0,6})([MGT])$ ]] ||
    ci_die "$label must be an integer size with M, G or T suffix: $value"
  number=${BASH_REMATCH[1]}
  suffix=${BASH_REMATCH[2]}
  case "$suffix" in
    M) mib=$number ;;
    G) (( number <= 131072 )) || ci_die "$label is too large: $value"; mib=$((number * 1024)) ;;
    T) (( number <= 128 )) || ci_die "$label is too large: $value"; mib=$((number * 1024 * 1024)) ;;
  esac
  (( mib >= min_mib && mib <= max_mib )) ||
    ci_die "$label is outside ${min_mib}MiB..${max_mib}MiB: $value"
}

ci_validate_download_source() {
  local label=$1 source=$2 digest=${3:-}
  case "$source" in
    https://*)
      ci_validate_https_url "$label" "$source"
      [ -n "$digest" ] || ci_die "$label requires an explicit SHA-256 digest"
      ci_validate_sha256 "${label}_SHA256" "$digest"
      ;;
    http://*) ci_die "$label must use HTTPS" ;;
    '')
      [ -z "$digest" ] || ci_die "${label}_SHA256 is set without $label"
      ;;
    *)
      [[ "$source" != *$'\n'* && "$source" != *$'\r'* ]] ||
        ci_die "$label local path contains control characters"
      [ -f "$source" ] && [ ! -L "$source" ] ||
        ci_die "$label local source is not a regular non-symlink file: $source"
      [ -z "$digest" ] || ci_validate_sha256 "${label}_SHA256" "$digest"
      ;;
  esac
}

ci_validate_single_line() {
  local value=${1-} label=${2:-value}

  case $value in
    *$'\n'*|*$'\r'*)
      ci_die "$label must not contain a line break"
      ;;
  esac
  # Bash variables cannot contain NUL bytes; any NUL supplied through an
  # environment boundary is rejected by the boundary parser before this
  # function is called.
}

ci_validate_text_block_size() {
  local value=${1-} label=${2:-value} max_bytes=$3 max_lines=$4 max_line_bytes=$5
  local line line_count=0
  local LC_ALL=C

  (( ${#value} <= max_bytes )) ||
    ci_die "$label exceeds $max_bytes bytes"
  while IFS= read -r line || [ -n "$line" ]; do
    line_count=$((line_count + 1))
    (( line_count <= max_lines )) ||
      ci_die "$label exceeds $max_lines lines"
    (( ${#line} <= max_line_bytes )) ||
      ci_die "$label contains a line longer than $max_line_bytes bytes"
  done <<< "$value"
}

ci_validate_rootfs_image_size() {
  local value=${1-} number suffix multiplier bytes

  ci_validate_single_line "$value" ROOTFS_IMAGE_SIZE
  [[ $value =~ ^([0-9]{1,14})([KMGT]?)$ ]] ||
    ci_die 'ROOTFS_IMAGE_SIZE must be a positive integer with an optional K/M/G/T suffix'
  number=${BASH_REMATCH[1]}
  number=$((10#$number))
  suffix=${BASH_REMATCH[2]}
  (( number > 0 )) ||
    ci_die 'ROOTFS_IMAGE_SIZE must be a positive integer with an optional K/M/G/T suffix'
  case $suffix in
    '') multiplier=1 ;;
    K) multiplier=1024 ;;
    M) multiplier=$((1024 ** 2)) ;;
    G) multiplier=$((1024 ** 3)) ;;
    T) multiplier=$((1024 ** 4)) ;;
  esac
  # Keep sparse-image requests within a bounded, representable range.  The
  # lower bound prevents a configuration that can never hold a desktop rootfs;
  # the upper bound avoids accidental multi-terabyte allocations on a runner.
  if (( number > 64 * 1024 ** 4 / multiplier )); then
    ci_die 'ROOTFS_IMAGE_SIZE must not exceed 64T'
  fi
  bytes=$((number * multiplier))
  (( bytes >= 1024 ** 3 && bytes <= 64 * 1024 ** 4 )) ||
    ci_die 'ROOTFS_IMAGE_SIZE must be between 1G and 64T'
}

ci_validate_rootfs_label() {
  local value=${1-}

  ci_validate_single_line "$value" ROOTFS_LABEL
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,15}$ ]] ||
    ci_die 'ROOTFS_LABEL must be 1-16 ASCII letters, digits, dot, underscore or hyphen characters'
}

ci_validate_hostname() {
  local value=${1-}

  ci_validate_single_line "$value" HOSTNAME_NAME
  [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ||
    ci_die 'HOSTNAME_NAME must be a single RFC 1123 hostname label of 1-63 characters'
}

ci_validate_account_name() {
  local value=${1-}

  [[ ${#value} -le 32 && $value =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]] ||
    ci_die 'DEFAULT_USER_NAME must be a safe Linux account name'
  case "$value" in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|systemd-*|messagebus|_apt)
      ci_die "DEFAULT_USER_NAME is reserved: $value"
      ;;
  esac
}

ci_validate_root_password_mode() {
  local value=${1-}

  case "$value" in
    locked|set|empty) ;;
    *) ci_die 'ROOT_PASSWORD_MODE must be locked, set or empty' ;;
  esac
}

ci_validate_user_sudo_mode() {
  local value=${1-}

  case "$value" in
    password|nopasswd|none) ;;
    *) ci_die 'USER_SUDO_MODE must be password, nopasswd or none' ;;
  esac
}

ci_validate_sddm_session() {
  local value=${1-}

  ci_validate_single_line "$value" SDDM_AUTOLOGIN_SESSION
  [[ -n "$value" && ${#value} -le 128 &&
     "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
    ci_die 'SDDM_AUTOLOGIN_SESSION must be a safe desktop session name'
}

ci_validate_distro_name() {
  local value=${1-}

  ci_validate_single_line "$value" DISTRO
  [[ "$value" =~ ^[a-z][a-z0-9+.-]{0,31}$ ]] ||
    ci_die 'DISTRO must be a lowercase Debian/Ubuntu suite name'
}

ci_validate_arch_name() {
  local value=${1-}

  ci_validate_single_line "$value" ARCH
  [[ "$value" =~ ^[a-z0-9][a-z0-9+._-]{0,15}$ ]] ||
    ci_die 'ARCH must be a safe Debian architecture name'
}

ci_validate_debootstrap_variant() {
  local value=${1-}

  [ -z "$value" ] && return 0
  ci_validate_single_line "$value" DEBOOTSTRAP_VARIANT
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]{0,31}$ ]] ||
    ci_die 'DEBOOTSTRAP_VARIANT contains unsupported characters'
}

ci_validate_partlabel() {
  local value=${1-} label=${2:-PARTLABEL}

  ci_validate_single_line "$value" "$label"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,35}$ ]] ||
    ci_die "$label must be 1-36 ASCII letters, digits, dot, underscore or hyphen characters"
}

ci_validate_uuid() {
  local value=${1-} label=${2:-UUID}

  [ -z "$value" ] && return 0
  ci_validate_single_line "$value" "$label"
  [[ "$value" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ||
     "$value" = random || "$value" = time ]] ||
    ci_die "$label must be a canonical UUID, random or time"
}

ci_validate_compression() {
  local value=${1-} label=${2:-COMPRESS}

  case "$value" in
    none|zstd|xz|7z) ;;
    *) ci_die "$label must be none, zstd, xz or 7z" ;;
  esac
}

ci_validate_volume_size() {
  local value=${1-} label=${2:-CHUNK_SIZE} number suffix multiplier bytes

  [ -z "$value" ] && return 0
  ci_validate_single_line "$value" "$label"
  [[ "$value" =~ ^([1-9][0-9]{0,8})([kKmMgG]?)$ ]] ||
    ci_die "$label must be a positive 7z volume size"
  number=$((10#${BASH_REMATCH[1]}))
  suffix=${BASH_REMATCH[2]}
  case "$suffix" in
    '') multiplier=1 ;;
    k|K) multiplier=1024 ;;
    m|M) multiplier=$((1024 ** 2)) ;;
    g|G) multiplier=$((1024 ** 3)) ;;
  esac
  bytes=$((number * multiplier))
  (( bytes >= 1024 ** 2 && bytes <= 64 * 1024 ** 3 )) ||
    ci_die "$label must be between 1 MiB and 64 GiB"
}

ci_validate_local_path_value() {
  local value=${1-} label=${2:-path}

  [ -z "$value" ] && return 0
  [[ ${#value} -le 4096 && "$value" != *$'\n'* && "$value" != *$'\r'* &&
     "$value" != *$'\t'* ]] ||
    ci_die "$label contains unsupported control characters"
}

ci_validate_dns_authority() {
  local label=$1 authority=$2 host port

  if [[ "$authority" == *:* ]]; then
    host=${authority%:*}
    port=${authority##*:}
    [[ "$host" != *:* && "$port" =~ ^[0-9]{1,5}$ ]] ||
      ci_die "$label has an invalid host or port"
    port=$((10#$port))
    (( port <= 65535 )) || ci_die "$label port is outside 0..65535"
  else
    host=$authority
  fi
  [[ ${#host} -le 253 &&
     "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] ||
    ci_die "$label has an invalid DNS host"
}

ci_validate_apt_proxy() {
  local value=${1-} authority port

  [ -z "$value" ] && return 0
  [[ ${#value} -le 512 &&
     $value =~ ^https?://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]{0,253}[A-Za-z0-9])(:[0-9]{1,5})?$ ]] ||
    ci_die 'APT proxy must be an HTTP(S) URI with a host and optional port; credentials, paths and configuration syntax are forbidden'
  authority=${value#http://}
  authority=${authority#https://}
  if [[ "$authority" == \[*\]* ]]; then
    # Keep the existing IPv6 proxy support, while requiring a bounded decimal
    # port when one is present.  The bracketed address is otherwise passed to
    # curl for full IPv6 parsing.
    if [[ "$authority" == *']:'* ]]; then
      port=${authority##*:}
      [[ "$port" =~ ^[0-9]{1,5}$ ]] || ci_die 'APT proxy has an invalid port'
      port=$((10#$port))
      (( port <= 65535 )) || ci_die 'APT proxy port is outside 0..65535'
    fi
  else
    ci_validate_dns_authority 'APT proxy' "$authority"
  fi
}

ci_validate_locale_name() {
  local value=${1-}

  [[ ${#value} -le 64 &&
     $value =~ ^[A-Za-z0-9][A-Za-z0-9_.@+-]*$ ]] ||
    ci_die 'locale name contains unsupported characters'
}

ci_validate_locales() {
  local value=${1-} line locale charset extra record_count=0

  ci_validate_text_block_size "$value" LOCALES 16384 256 256

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "${line//[[:space:]]/}" ] || continue
    locale= charset= extra=
    read -r locale charset extra <<< "$line"
    [[ -n "$locale" && -n "$charset" && -z "$extra" ]] ||
      ci_die 'each LOCALES record must contain exactly a locale name and charset'
    ci_validate_locale_name "$locale"
    [[ ${#charset} -le 64 &&
       $charset =~ ^[A-Za-z0-9][A-Za-z0-9_.@+-]*$ ]] ||
      ci_die 'locale charset contains unsupported characters'
    record_count=$((record_count + 1))
    (( record_count <= 128 )) ||
      ci_die 'LOCALES must not contain more than 128 locale records'
  done <<< "$value"
  (( record_count > 0 )) ||
    ci_die 'LOCALES must contain at least one locale record'
}

ci_validate_lang_name_in_locales() {
  local lang=${1-} locales=${2-} line locale charset extra found=0

  ci_validate_locale_name "$lang"
  case "$lang" in
    C|POSIX|C.UTF-8)
      return 0
      ;;
  esac
  ci_validate_locales "$locales"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "${line//[[:space:]]/}" ] || continue
    locale= charset= extra=
    read -r locale charset extra <<< "$line"
    [ "$locale" = "$lang" ] && found=1
  done <<< "$locales"
  (( found == 1 )) ||
    ci_die 'LANG_NAME must identify a locale listed in LOCALES'
}

ci_validate_timezone() {
  local value=${1-} component
  local -a components=()

  # An empty override keeps the builder's documented default.  Non-empty
  # values must be relative IANA zoneinfo components; in particular, no
  # parent component may escape /usr/share/zoneinfo inside the chroot.
  [ -z "$value" ] && return 0
  ci_validate_single_line "$value" TZ_REGION
  [[ ${#value} -le 128 && "$value" != /* && "$value" != */ &&
     "$value" != *//* ]] ||
    ci_die 'TZ_REGION must be a relative IANA timezone name'
  IFS=/ read -r -a components <<< "$value"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. &&
       "$component" =~ ^[A-Za-z0-9]([A-Za-z0-9._+-]*[A-Za-z0-9])?$ ]] ||
      ci_die 'TZ_REGION contains an unsafe timezone component'
  done
}

ci_validate_https_apt_uri() {
  local value=$1 authority

  [[ ${#value} -le 512 && $value =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~:/@%+,-]*)?$ ]] ||
    ci_die 'APT URI must be a safe HTTPS URL'
  authority=${value#https://}
  authority=${authority%%/*}
  ci_validate_dns_authority 'APT URI' "$authority"
}

ci_validate_https_apt_source_options() {
  local option=$1 value

  case "$option" in
    arch=*)
      value=${option#arch=}
      [ "$value" = arm64 ] ||
        ci_die 'unsupported APT source architecture option'
      ;;
    signed-by=*)
      value=${option#signed-by=}
      [[ $value =~ ^/(etc/apt/keyrings|usr/share/keyrings)/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(asc|gpg)$ ]] ||
        ci_die 'unsafe APT signed-by option'
      ;;
    trusted=*|allow-insecure=*|allow-downgrade-to-insecure=*|check-valid-until=*)
      ci_die 'APT source option bypasses repository authentication'
      ;;
    *)
      ci_die 'unsupported APT source option'
      ;;
  esac
}

ci_validate_https_apt_sources_list() {
  local value=$1 line uri suite index option closed
  local -a fields=() options=()
  local entries=0

  ci_validate_text_block_size "$value" APT_SOURCES_LIST 65536 256 4096

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line%%#*}
    [ -n "${line//[[:space:]]/}" ] || continue
    read -r -a fields <<< "$line"
    case "${fields[0]:-}" in
      deb|deb-src)
        index=1
        if [[ "${fields[1]:-}" = \[* ]]; then
          options=()
          closed=0
          while [ "$index" -lt "${#fields[@]}" ]; do
            option=${fields[index]}
            option=${option#[}
            option=${option%]}
            [ -n "$option" ] || ci_die 'empty APT source option block'
            options+=("$option")
            if [[ "${fields[index]}" = *] ]]; then
              closed=1
              index=$((index + 1))
              break
            fi
            index=$((index + 1))
          done
          [ "$closed" -eq 1 ] ||
            ci_die 'unterminated APT source option block'
          for option in "${options[@]}"; do
            ci_validate_https_apt_source_options "$option"
          done
        fi
        uri=${fields[index]:-}
        ci_validate_https_apt_uri "$uri"
        suite=${fields[index + 1]:-}
        [[ $suite =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
          ci_die 'unsafe APT source suite'
        [ "${#fields[@]}" -ge $((index + 3)) ] ||
          ci_die 'APT source entry has no component'
        for ((index += 2; index < ${#fields[@]}; index++)); do
          [[ ${fields[index]} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
            ci_die 'unsafe APT source component'
        done
        entries=$((entries + 1))
        (( entries <= 128 )) ||
          ci_die 'APT_SOURCES_LIST must not contain more than 128 repository entries'
        ;;
      *) ci_die 'unsupported APT sources.list entry' ;;
    esac
  done <<< "$value"
  [ "$entries" -gt 0 ] || ci_die "APT_SOURCES_LIST contains no repository entries"
}

# APT configuration is expressive enough to redirect all of the paths whose
# contents are included in provenance, or to relax transport/authentication
# checks. The build only needs ordinary package policy and optional proxy
# settings, so reject those directives rather than trying to model APT's full
# nested configuration grammar. Matching a forbidden token in a comment is
# intentionally fail-closed: configuration is build input, not user prose.
ci_validate_apt_config_file() {
  local path=$1

  [ -f "$path" ] && [ ! -L "$path" ] ||
    ci_die 'APT configuration must be a regular file'
  [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$path" | wc -c)" -eq 0 ] ||
    ci_die 'APT configuration contains non-printable data'
  if LC_ALL=C grep -Eiq \
    '(^|[^[:alnum:]_])[[:space:]]*dir([^[:alnum:]_]|$)|(^|[^[:alnum:]_-])(allowinsecurerepositories|allowdowngradetoinsecurerepositories|allowweakrepositories|check-valid-until|allowunauthenticated|verify-peer|verify-host)([^[:alnum:]_-]|$)' \
    "$path"; then
    ci_die 'APT configuration contains a forbidden path or authentication override'
  fi
}

ci_normalize_package_list() {
  local raw=${1-} line token token_count=0
  local -a line_tokens=()
  ci_validate_text_block_size "$raw" PACKAGE_LIST 65536 2048 65536
  while IFS= read -r line || [ -n "$line" ]; do
    line_tokens=()
    read -r -a line_tokens <<< "$line"
    for token in "${line_tokens[@]}"; do
      [[ ${#token} -le 128 && $token =~ ^[A-Za-z0-9][A-Za-z0-9+.:_@=-]*$ ]] ||
        ci_die "invalid package token: $token"
      token_count=$((token_count + 1))
      (( token_count <= 1024 )) ||
        ci_die 'PACKAGE_LIST must not contain more than 1024 package tokens'
      printf '%s\n' "$token"
    done
  done <<< "$raw"
}

ci_resolve_path_for_comparison() {
  local path=$1 parent
  if [ -e "$path" ] || [ -L "$path" ]; then
    realpath -e -- "$path"
    return
  fi
  parent=$(realpath -e -- "$(dirname -- "$path")")
  printf '%s/%s\n' "$parent" "$(basename -- "$path")"
}

ci_require_distinct_paths() {
  local -a labels=() paths=() resolved=()
  local label path i j
  [ "$#" -ge 4 ] && [ $(( $# % 2 )) -eq 0 ] ||
    ci_die "ci_require_distinct_paths expects LABEL PATH pairs"
  while [ "$#" -gt 0 ]; do
    label=$1
    path=$2
    labels+=("$label")
    paths+=("$path")
    resolved+=("$(ci_resolve_path_for_comparison "$path")")
    shift 2
  done
  for ((i = 0; i < ${#paths[@]}; i++)); do
    for ((j = i + 1; j < ${#paths[@]}; j++)); do
      if [ "${resolved[i]}" = "${resolved[j]}" ] ||
         { [ -e "${paths[i]}" ] && [ -e "${paths[j]}" ] && [ "${paths[i]}" -ef "${paths[j]}" ]; }; then
        ci_die "${labels[i]} and ${labels[j]} must refer to distinct paths"
      fi
    done
  done
}

ci_validate_password_hash() {
  local value=${1-}

  # Validate the complete encoding before handing the value to chpasswd.  A
  # length-only check accepts arbitrary DES salts and strings that can never be
  # used by crypt(3), which can silently remove the only password access path.
  if [[ "$value" =~ ^[./0-9A-Za-z]{13}$ ]]; then
    :
  elif [[ "$value" =~ ^\$1\$[./0-9A-Za-z]{0,8}\$[./0-9A-Za-z]{22}$ ]]; then
    :
  elif [[ "$value" =~ ^\$2[abxy]\$(0[4-9]|[12][0-9]|3[01])\$[./0-9A-Za-z]{53}$ ]]; then
    :
  elif [[ "$value" =~ ^\$5\$(rounds=[1-9][0-9]{0,8}\$)?[./0-9A-Za-z]{0,16}\$[./0-9A-Za-z]{43}$ ]]; then
    :
  elif [[ "$value" =~ ^\$6\$(rounds=[1-9][0-9]{0,8}\$)?[./0-9A-Za-z]{0,16}\$[./0-9A-Za-z]{86}$ ]]; then
    :
  elif [[ "$value" =~ ^\$y\$[./0-9A-Za-z]+\$[./0-9A-Za-z]{0,16}\$[./0-9A-Za-z]{43}$ ]]; then
    :
  else
    ci_die 'DEFAULT_USER_PASSWORD_HASH is not a supported crypt(3) hash'
  fi

  # Ask the host libcrypt implementation to parse the selected format as a
  # final compatibility check.  The hash is supplied on stdin and no derived
  # value is printed; an unavailable/invalid implementation is fail-closed.
  if ! printf '%s\n' "$value" | python3 -I -B -c \
    'import crypt,sys; value=sys.stdin.read().rstrip("\n"); result=crypt.crypt("tb321fu-validation", value); raise SystemExit(0 if result and not result.startswith("*") else 1)' \
    >/dev/null 2>&1; then
    ci_die 'DEFAULT_USER_PASSWORD_HASH is not accepted by the host crypt(3) implementation'
  fi
}

ci_require_sudo_password_hash() {
  local sudo_mode=$1 password_hash=$2

  case "$sudo_mode" in
    password)
      [ -n "$password_hash" ] && [ "$password_hash" != '!' ] ||
        ci_die 'USER_SUDO_MODE=password requires a nonempty DEFAULT_USER_PASSWORD_HASH'
      ci_validate_password_hash "$password_hash"
      ;;
    nopasswd|none)
      ;;
    *)
      ci_die "unsupported USER_SUDO_MODE=$sudo_mode"
      ;;
  esac
}

ci_validate_authorized_keys() {
  local value=${1-}
  ci_validate_text_block_size "$value" DEFAULT_USER_AUTHORIZED_KEYS 65536 512 16384
  # Parse the SSH wire-format blob rather than only its printable base64
  # envelope.  The parser is intentionally read-only and receives secrets on
  # stdin, so diagnostics never echo key material into CI logs.
  if ! printf '%s\n' "$value" | python3 -I -B -c '
import base64, sys

SUPPORTED = {
    "ssh-ed25519", "sk-ssh-ed25519@openssh.com",
    "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    "sk-ecdsa-sha2-nistp256@openssh.com", "ssh-rsa",
}
CURVES = {
    "ecdsa-sha2-nistp256": ("nistp256", 65),
    "ecdsa-sha2-nistp384": ("nistp384", 97),
    "ecdsa-sha2-nistp521": ("nistp521", 133),
    "sk-ecdsa-sha2-nistp256@openssh.com": ("nistp256", 65),
}

def field(data, offset):
    if offset + 4 > len(data):
        raise ValueError
    length = int.from_bytes(data[offset:offset + 4], "big")
    start = offset + 4
    end = start + length
    if end > len(data):
        raise ValueError
    return data[start:end], end

def u32(data, offset):
    if offset + 4 > len(data):
        raise ValueError
    return int.from_bytes(data[offset:offset + 4], "big"), offset + 4

def mpint(data, offset):
    value, offset = field(data, offset)
    if not value or value[0] & 0x80:
        raise ValueError
    if len(value) > 1 and value[0] == 0 and not (value[1] & 0x80):
        raise ValueError
    if int.from_bytes(value, "big") == 0:
        raise ValueError
    return value, offset

def check_blob(key_type, encoded):
    try:
        raw = base64.b64decode(encoded.encode("ascii"), validate=True)
        if base64.b64encode(raw).decode("ascii") != encoded:
            raise ValueError
        algorithm, offset = field(raw, 0)
        if algorithm.decode("ascii") != key_type:
            raise ValueError
        if key_type == "ssh-ed25519":
            key, offset = field(raw, offset)
            if len(key) != 32:
                raise ValueError
        elif key_type == "sk-ssh-ed25519@openssh.com":
            key, offset = field(raw, offset)
            application, offset = field(raw, offset)
            if len(key) != 32 or not application:
                raise ValueError
        elif key_type in CURVES:
            curve, offset = field(raw, offset)
            expected_curve, point_length = CURVES[key_type]
            point, offset = field(raw, offset)
            if curve.decode("ascii") != expected_curve:
                raise ValueError
            if len(point) != point_length or point[:1] != b"\\x04":
                raise ValueError
            if key_type.startswith("sk-"):
                application, offset = field(raw, offset)
                if not application:
                    raise ValueError
        elif key_type == "ssh-rsa":
            exponent, offset = mpint(raw, offset)
            modulus, offset = mpint(raw, offset)
            exponent_value = int.from_bytes(exponent, "big")
            if exponent_value < 3 or not (exponent_value & 1) or len(modulus) < 128:
                raise ValueError
        if offset != len(raw):
            raise ValueError
    except (ValueError, UnicodeDecodeError, UnicodeEncodeError, base64.binascii.Error):
        raise ValueError

count = 0
for line in sys.stdin.read().splitlines():
    line = line.rstrip("\\r")
    if not line or line.startswith("#"):
        continue
    fields = line.split()
    if len(fields) < 2 or fields[0] not in SUPPORTED:
        raise SystemExit(1)
    check_blob(fields[0], fields[1])
    count += 1
    if count > 256:
        raise SystemExit(1)
if count == 0:
    raise SystemExit(1)
' >/dev/null 2>&1; then
    ci_die 'DEFAULT_USER_AUTHORIZED_KEYS contains no structurally valid OpenSSH public key'
  fi
}

ci_validate_resolv_conf_content() {
  local value=${1-}

  [ -z "$value" ] && return 0
  ci_validate_text_block_size "$value" RESOLV_CONF_CONTENT 16384 256 1024
}

ci_require_user_access_path() {
  local password_hash=$1 authorized_keys=$2 autologin=$3
  local access_paths=0
  if [ -n "$password_hash" ] && [ "$password_hash" != '!' ]; then
    ci_validate_password_hash "$password_hash"
    access_paths=$((access_paths + 1))
  fi
  if [ -n "$authorized_keys" ]; then
    ci_validate_authorized_keys "$authorized_keys"
    access_paths=$((access_paths + 1))
  fi
  if ci_bool "$autologin"; then
    access_paths=$((access_paths + 1))
  fi
  [ "$access_paths" -gt 0 ] ||
    ci_die "no user access path: set a password hash, authorized key, or explicitly enable SDDM autologin"
}

ci_source_date_epoch() {
  local epoch=${SOURCE_DATE_EPOCH:-0}
  [[ $epoch =~ ^[0-9]{1,10}$ ]] ||
    ci_die "SOURCE_DATE_EPOCH must be a decimal Unix timestamp: $epoch"
  printf '%s\n' "$epoch"
}

ci_reproducible_prefix_flags() {
  local source_prefix=$1
  local canonical_prefix=$2
  case "$source_prefix$canonical_prefix" in
    *[[:space:]\=]*) ci_die "prefix-map paths must not contain whitespace or equals signs" ;;
  esac
  printf '%s\n' \
    "-ffile-prefix-map=$source_prefix=$canonical_prefix" \
    "-fdebug-prefix-map=$source_prefix=$canonical_prefix" \
    "-fmacro-prefix-map=$source_prefix=$canonical_prefix"
}

ci_normalize_package_tree() {
  local root=$1
  local epoch
  [ -d "$root" ] || ci_die "package tree not found: $root"
  epoch=$(ci_source_date_epoch)
  export SOURCE_DATE_EPOCH=$epoch
  find "$root" -xdev -exec touch -h -d "@$epoch" {} +
}

ci_iso8601_timestamp() {
  local epoch
  epoch=$(ci_source_date_epoch)
  date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

ci_normalize_fat_tree() {
  local root=$1
  local epoch
  [ -d "$root" ] || ci_die "FAT payload tree not found: $root"
  epoch=$(ci_source_date_epoch)
  if [ "$epoch" -lt 315532800 ]; then
    epoch=315532800
  fi
  find "$root" -xdev -exec touch -h -d "@$epoch" {} +
}

ci_e2fsck_repair() {
  local target=$1 allow_repairs=${2:-1} rc
  if e2fsck -f -y -- "$target"; then
    rc=0
  else
    rc=$?
  fi
  case $rc in
    0) return 0 ;;
    1)
      [ "$allow_repairs" = 1 ] ||
        ci_die "e2fsck modified $target after build evidence was recorded"
      return 0
      ;;
    *) ci_die "e2fsck failed for $target with status $rc" ;;
  esac
}

ci_mount_targets_below() {
  local root=$1
  ci_require_cmd findmnt
  findmnt -rn --raw -o TARGET | awk -v root="$root" \
    '$0 == root || index($0, root "/") == 1 { print length($0) "\t" $0 }' |
    sort -rn | cut -f2-
}

ci_unmount_tree() {
  local root=$1 target targets remaining failed=0
  targets=$(ci_mount_targets_below "$root") || {
    printf 'error: failed to inspect mounts below %s\n' "$root" >&2
    return 1
  }
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if ! umount -- "$target"; then
      printf 'error: failed to unmount %s\n' "$target" >&2
      failed=1
    fi
  done <<<"$targets"
  [ "$failed" -eq 0 ] || return 1
  remaining=$(ci_mount_targets_below "$root") || {
    printf 'error: failed to re-inspect mounts below %s\n' "$root" >&2
    return 1
  }
  [ -z "$remaining" ] || {
    printf 'error: mounts remain below %s\n' "$root" >&2
    return 1
  }
}

ci_validate_rootfs_overlay_tree() {
  local root=$1 relative link target resolved_target special hardlinked privileged
  [ ! -L "$root" ] || ci_die "rootfs overlay root must not be a symlink: $root"
  [ -d "$root" ] || ci_die "rootfs overlay is not a directory: $root"
  root=$(realpath -e -- "$root") || ci_die "cannot resolve rootfs overlay: $root"
  [ ! -L "$root" ] || ci_die "rootfs overlay root resolved to a symlink: $root"
  special=$(find -P "$root" -xdev \
    \( -type b -o -type c -o -type p -o -type s \) -print -quit)
  [ -z "$special" ] || ci_die "rootfs overlay contains an unsupported special file: $special"
  hardlinked=$(find -P "$root" -xdev -type f -links +1 -print -quit)
  [ -z "$hardlinked" ] || ci_die "rootfs overlay contains a hard-linked regular file: $hardlinked"
  privileged=$(find -P "$root" -xdev \( -type f -o -type d \) -perm /6000 -print -quit)
  [ -z "$privileged" ] || ci_die "rootfs overlay contains a setuid/setgid member: $privileged"
  for relative in dev proc sys run; do
    if [ -e "$root/$relative" ] || [ -L "$root/$relative" ]; then
      ci_die "rootfs overlay must not contain runtime path: $relative"
    fi
  done
  while IFS= read -r -d '' link; do
    target=$(readlink -- "$link") || ci_die "cannot read rootfs overlay symlink: $link"
    case "$target" in
      /*) ci_die "rootfs overlay symlink must not use an absolute target: $link" ;;
    esac
    resolved_target=$(realpath -m -- "$(dirname -- "$link")/$target")
    case "$resolved_target" in
      "$root"|"$root"/*) ;;
      *) ci_die "rootfs overlay symlink escapes overlay root: $link" ;;
    esac
  done < <(find -P "$root" -type l -print0)
}

ci_safe_rmtree() {
  local candidate=$1 parent=$2 prefix=$3 resolved resolved_parent mounts
  local candidate_state final_state
  if [ ! -e "$candidate" ]; then
    [ ! -L "$candidate" ] || {
      printf 'error: refusing cleanup of a dangling symlink: %s\n' "$candidate" >&2
      return 1
    }
    return 0
  fi
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || {
    printf 'error: cleanup candidate must be a real directory: %s\n' "$candidate" >&2
    return 1
  }
  candidate_state=$(stat -c '%d:%i' -- "$candidate") || {
    printf 'error: cannot inspect cleanup candidate: %s\n' "$candidate" >&2
    return 1
  }
  resolved=$(realpath -e -- "$candidate") || {
    printf 'error: cannot canonicalize cleanup candidate: %s\n' "$candidate" >&2
    return 1
  }
  resolved_parent=$(realpath -e -- "$parent") || {
    printf 'error: cannot canonicalize cleanup parent: %s\n' "$parent" >&2
    return 1
  }
  [ "$(dirname -- "$resolved")" = "$resolved_parent" ] || {
    printf 'error: refusing cleanup outside expected parent: %s\n' "$resolved" >&2
    return 1
  }
  case $(basename -- "$resolved") in
    "$prefix"*) ;;
    *)
      printf 'error: refusing cleanup with unexpected basename: %s\n' "$resolved" >&2
      return 1
      ;;
  esac
  mounts=$(ci_mount_targets_below "$resolved") || {
    printf 'error: refusing cleanup because mount inspection failed: %s\n' "$resolved" >&2
    return 1
  }
  [ -z "$mounts" ] || {
    printf 'error: refusing to delete a tree containing active mounts: %s\n' "$resolved" >&2
    return 1
  }
  final_state=$(stat -c '%d:%i' -- "$candidate") || {
    printf 'error: cleanup candidate disappeared during validation: %s\n' "$candidate" >&2
    return 1
  }
  [ "$final_state" = "$candidate_state" ] && [ -d "$candidate" ] && [ ! -L "$candidate" ] || {
    printf 'error: cleanup candidate changed during validation: %s\n' "$candidate" >&2
    return 1
  }
  # Remove the validated directory entry, not its canonical target. If the leaf
  # is exchanged for a symlink after the final lstat, rm removes only that link.
  rm -rf -- "$candidate"
}

ci_verify_download() {
  local file=$1 verifier=$2 expected actual
  local -a primary_fingerprints=()
  case $verifier in
    sha256:*) expected=${verifier#sha256:} ;;
    [[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]*) expected=$verifier ;;
    openpgp-fpr:*)
      expected=${verifier#openpgp-fpr:}
      [[ $expected =~ ^[A-Fa-f0-9]{40}$ ]] || ci_die "invalid OpenPGP fingerprint: $expected"
      ci_require_cmd gpg
      mapfile -t primary_fingerprints < <(
        gpg --batch --quiet --show-keys --with-colons "$file" 2>/dev/null |
          awk -F: '
            $1 == "pub" { want_primary_fpr=1; next }
            $1 == "sub" { want_primary_fpr=0; next }
            $1 == "fpr" && want_primary_fpr { print toupper($10); want_primary_fpr=0 }
          '
      )
      [ "${#primary_fingerprints[@]}" -eq 1 ] ||
        ci_die "OpenPGP input must contain exactly one primary key: $file"
      [ "${primary_fingerprints[0]}" = "${expected^^}" ] ||
        ci_die "OpenPGP fingerprint mismatch for $file"
      return
      ;;
    *) ci_die "unsupported or missing download verifier for $file" ;;
  esac
  [[ $expected =~ ^[A-Fa-f0-9]{64}$ ]] || ci_die "invalid SHA-256 verifier: $expected"
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "${expected,,}" ] || ci_die "SHA-256 mismatch for $file: expected ${expected,,}, got $actual"
}

ci_download_matches_verifier() {
  local file=$1 verifier=$2

  # A pinned SHA commits to every expected byte. An OpenPGP fingerprint only
  # identifies the primary key and can also match a parseable truncated export.
  [[ $verifier != openpgp-fpr:* ]] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  (ci_verify_download "$file" "$verifier") >/dev/null 2>&1
}

ci_download() {
  local src=$1
  local dst=$2
  local verifier=${3:-}
  local tmp
  local attempt=1
  local max_attempts=${CI_DOWNLOAD_MAX_ATTEMPTS:-24}
  local deadline_seconds=${CI_DOWNLOAD_DEADLINE_SECONDS:-5400}
  local deadline_ms now_ms remaining_ms attempt_timeout
  local resume_reset=0
  local curl_rc

  [[ "$max_attempts" =~ ^[1-9][0-9]{0,2}$ ]] ||
    ci_die "CI_DOWNLOAD_MAX_ATTEMPTS must be 1..32"
  [[ "$deadline_seconds" =~ ^[1-9][0-9]{1,5}$ ]] ||
    ci_die "CI_DOWNLOAD_DEADLINE_SECONDS must be 10..86400"
  max_attempts=$((10#$max_attempts))
  deadline_seconds=$((10#$deadline_seconds))
  (( max_attempts <= 32 )) || ci_die "CI_DOWNLOAD_MAX_ATTEMPTS must be 1..32"
  (( deadline_seconds >= 10 && deadline_seconds <= 86400 )) ||
    ci_die "CI_DOWNLOAD_DEADLINE_SECONDS must be 10..86400"
  deadline_ms=$(ci_monotonic_millis) || ci_die 'cannot read a monotonic clock for download deadline'
  deadline_ms=$((deadline_ms + deadline_seconds * 1000))

  local dst_dir dst_name
  dst_dir=$(dirname -- "$dst")
  dst_name=$(basename -- "$dst")
  ci_validate_no_symlink_ancestors "$dst_dir" 'download destination directory'
  [ -d "$dst_dir" ] || ci_die "download destination directory is missing: $dst_dir"
  [ ! -L "$dst_dir" ] || ci_die "download destination directory is a symlink: $dst_dir"
  [ ! -L "$dst" ] || ci_die "download destination is a symlink: $dst"
  tmp=$(mktemp "$dst_dir/.${dst_name}.part.XXXXXX") ||
    ci_die "cannot create private download temporary file: $dst"
  case "$src" in
    https://*)
      [ -n "$verifier" ] || ci_die "remote download requires an explicit SHA-256 or OpenPGP fingerprint: $src"
      ci_require_cmd "${CI_CURL_BIN:-curl}"
      while :; do
        now_ms=$(ci_monotonic_millis) || {
          rm -f -- "$tmp"
          ci_die "cannot read a monotonic clock for download deadline: $src"
        }
        remaining_ms=$((deadline_ms - now_ms))
        [ "$remaining_ms" -gt 0 ] || {
          rm -f -- "$tmp"
          ci_die "download deadline exceeded: $src"
        }
        # curl accepts fractional seconds.  Use the exact remaining
        # millisecond budget (rather than rounding up), so an individual
        # transfer can never be granted more time than the outer deadline.
        if [ "$remaining_ms" -gt 3600000 ]; then
          attempt_timeout=3600.000
        else
          attempt_timeout=$(printf '%d.%03d' \
            "$((remaining_ms / 1000))" "$((remaining_ms % 1000))")
        fi
        if "${CI_CURL_BIN:-curl}" \
          --disable \
          --proto '=https' \
          --proto-redir '=https' \
          --tlsv1.2 \
          --http1.1 \
          --fail \
          --location \
          --connect-timeout 30 \
          --max-time "$attempt_timeout" \
          --speed-limit 1024 \
          --speed-time 300 \
          --continue-at - \
          --output "$tmp" \
          "$src"; then
          break
        else
          curl_rc=$?
        fi

        if [ -s "$tmp" ] && ci_download_matches_verifier "$tmp" "$verifier"; then
          ci_log "HTTPS download completed before curl exit $curl_rc: $src"
          break
        fi
        if [ "$curl_rc" -eq 33 ] && [ -s "$tmp" ] && [ "$resume_reset" -eq 0 ]; then
          rm -f -- "$tmp"
          resume_reset=1
          ci_log "server rejected HTTPS resume; retrying once from byte zero: $src"
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
          rm -f -- "$tmp"
          ci_die "download failed after $max_attempts attempts or deadline: $src"
        fi
        attempt=$((attempt + 1))
        ci_log "retrying HTTPS download ($attempt/$max_attempts) after curl exit $curl_rc: $src"
      done
      ;;
    http://*)
      ci_die "refusing insecure HTTP download: $src"
      ;;
    '')
      ci_die "empty download source for $dst"
      ;;
    *)
      [ -f "$src" ] && [ ! -L "$src" ] ||
        ci_die "local download source is not a regular file: $src"
      cp --reflink=auto -- "$src" "$tmp"
      ;;
  esac
  if [ -n "$verifier" ]; then
    if ! (ci_verify_download "$tmp" "$verifier"); then
      rm -f -- "$tmp"
      ci_die "download verification failed: $src"
    fi
  fi
  mv -f -- "$tmp" "$dst"
}

ci_extract_archive() {
  local archive=$1
  local dest=$2
  local helper
  helper=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/safe-extract-archive.py
  ci_require_cmd python3
  [ -f "$archive" ] || ci_die "archive not found: $archive"
  python3 "$helper" "$archive" "$dest" || ci_die "safe archive extraction failed: $archive"
}
