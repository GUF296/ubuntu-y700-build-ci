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

ci_abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
  esac
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
  local dtb=$1 fdtget_bin=$2 path child child_path children reg compatible label
  local contract_record contract_tail expected_reg expected_label
  local right_path= left_path= right_parent left_parent
  local node_count=0 queue_index=0
  local -a queue=(/)

  [ -f "$dtb" ] && [ ! -L "$dtb" ] && [ -s "$dtb" ] ||
    ci_die 'TB321FU DTB contract input must be a nonempty regular file'
  [ -x "$fdtget_bin" ] && [ -f "$fdtget_bin" ] ||
    ci_die 'fdtget contract tool must be an executable regular file'

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

ci_validate_https_apt_uri() {
  local value=$1

  [[ ${#value} -le 512 && $value =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~:/@%+,-]*)?$ ]] ||
    ci_die 'APT URI must be a safe HTTPS URL'
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
  local raw=${1-} line token
  local -a line_tokens=()
  while IFS= read -r line || [ -n "$line" ]; do
    line_tokens=()
    read -r -a line_tokens <<< "$line"
    for token in "${line_tokens[@]}"; do
      [[ ${#token} -le 128 && $token =~ ^[A-Za-z0-9][A-Za-z0-9+.:_@=-]*$ ]] ||
        ci_die "invalid package token: $token"
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
  local value=$1
  [[ ${#value} -ge 13 && ${#value} -le 512 && $value != *:* && $value != *[[:space:]]* && $value != \!* && $value != \** ]] ||
    ci_die "DEFAULT_USER_PASSWORD_HASH is not a usable crypt(3) hash"
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
  local value=$1 line key_type key_blob remainder
  local found=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "$line" ] || continue
    case $line in \#*) continue ;; esac
    key_type=
    key_blob=
    remainder=
    read -r key_type key_blob remainder <<< "$line"
    case $key_type in
      ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa) ;;
      *) ci_die "unsupported or option-prefixed authorized key type: $key_type" ;;
    esac
    [[ ${#key_blob} -ge 16 && $key_blob =~ ^[A-Za-z0-9+/]+={0,3}$ ]] ||
      ci_die "invalid authorized key body for type $key_type"
    found=1
  done <<< "$value"
  [ "$found" -eq 1 ] || ci_die "DEFAULT_USER_AUTHORIZED_KEYS contains no public key"
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
  local root=$1 relative link target resolved_target
  [ -d "$root" ] || ci_die "rootfs overlay is not a directory: $root"
  root=$(realpath -e -- "$root")
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
  done < <(find "$root" -type l -print0)
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

ci_download() {
  local src=$1
  local dst=$2
  local verifier=${3:-}
  local tmp="${dst}.part.$$"
  rm -f -- "$tmp"
  case "$src" in
    https://*)
      [ -n "$verifier" ] || ci_die "remote download requires an explicit SHA-256 or OpenPGP fingerprint: $src"
      ci_require_cmd curl
      if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 -o "$tmp" "$src"; then
        rm -f -- "$tmp"
        ci_die "download failed: $src"
      fi
      ;;
    http://*)
      ci_die "refusing insecure HTTP download: $src"
      ;;
    '')
      ci_die "empty download source for $dst"
      ;;
    *)
      [ -f "$src" ] || ci_die "local download source is not a regular file: $src"
      cp -- "$src" "$tmp"
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
