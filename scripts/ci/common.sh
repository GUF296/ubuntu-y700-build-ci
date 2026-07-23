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

ci_sanitized_kernel_env() {
  ci_sanitized_git_env \
    env \
    -u MAKEFLAGS \
    -u MFLAGS \
    -u MAKEOVERRIDES \
    -u MAKELEVEL \
    -u MAKE_RESTARTS \
    -u ARCH \
    -u CROSS_COMPILE \
    -u KBUILD_OUTPUT \
    -u KBUILD_EXTMOD \
    -u KBUILD_SRC \
    -u KBUILD_BUILD_SALT \
    -u KBUILD_ABS_SRCTREE \
    -u KBUILD_ABS_OBJTREE \
    -u KBUILD_EXTRA_SYMBOLS \
    -u KBUILD_MODPOST_WARN \
    -u KBUILD_MODPOST_NOFINAL \
    -u KBUILD_SIGN_PIN \
    -u KBUILD_SIGN_KEY \
    -u KBUILD_CFLAGS \
    -u KBUILD_AFLAGS \
    -u KBUILD_CPPFLAGS \
    -u KBUILD_RUSTFLAGS \
    -u KCFLAGS \
    -u KAFLAGS \
    -u KCPPFLAGS \
    -u KRUSTFLAGS \
    -u CFLAGS \
    -u CXXFLAGS \
    -u CPPFLAGS \
    -u ASFLAGS \
    -u LDFLAGS \
    -u CFLAGS_KERNEL \
    -u CFLAGS_MODULE \
    -u AFLAGS_KERNEL \
    -u AFLAGS_MODULE \
    -u LDFLAGS_vmlinux \
    -u LDFLAGS_MODULE \
    -u HOSTCFLAGS \
    -u HOSTCXXFLAGS \
    -u HOSTLDFLAGS \
    -u USERCFLAGS \
    -u USERLDFLAGS \
    -u KCONFIG_CONFIG \
      -u KCONFIG_DEFCONFIG_LIST \
      -u KCONFIG_ALLCONFIG \
      -u KCONFIG_OVERWRITECONFIG \
    -u KCONFIG_WARN_UNKNOWN_SYMBOLS \
    -u KCONFIG_WERROR \
    -u KCONFIG_NOSILENTUPDATE \
    -u INSTALL_MOD_PATH \
    -u INSTALL_MOD_DIR \
    -u INSTALL_MOD_STRIP \
    -u INSTALL_PATH \
    -u INSTALL_DTBS_PATH \
    -u INSTALL_HDR_PATH \
    -u DEPMOD \
    -u MODLIB \
    -u M \
    -u O \
    -u SUBDIRS \
    -u V \
    -u W \
    -u C \
    -u CF \
    -u CHECK \
    -u CHECKFLAGS \
    -u CLIPPY \
    -u CONFIG_SHELL \
    -u CC \
      -u HOSTCC \
      -u LD \
      -u HOSTLD \
      -u AR \
      -u NM \
      -u OBJCOPY \
      -u OBJDUMP \
      -u STRIP \
    -u LLVM \
    -u LLVM_IAS \
    -u LLVM_AR \
    -u LLVM_NM \
    -u LLVM_OBJCOPY \
    -u LLVM_OBJDUMP \
    -u LLVM_STRIP \
    -u RUSTC \
    -u RUSTFLAGS \
    -u RUSTC_WRAPPER \
    -u RUSTDOC \
    -u RUSTDOCFLAGS \
    -u HOSTRUSTC \
    -u HOSTRUSTFLAGS \
    -u RUST_BINDGEN \
    -u RUST_LIB_SRC \
    -u CARGO \
    -u BINDGEN \
    -u BINDGEN_EXTRA_CLANG_ARGS \
    -u PAHOLE \
    "$@"
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
  local root=$1 target failed=0
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if ! umount -- "$target"; then
      printf 'error: failed to unmount %s\n' "$target" >&2
      failed=1
    fi
  done < <(ci_mount_targets_below "$root")
  [ "$failed" -eq 0 ] || return 1
  [ -z "$(ci_mount_targets_below "$root")" ] || {
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
  local candidate=$1 parent=$2 prefix=$3 resolved resolved_parent
  [ -e "$candidate" ] || return 0
  resolved=$(realpath -e -- "$candidate")
  resolved_parent=$(realpath -e -- "$parent")
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
  [ -z "$(ci_mount_targets_below "$resolved")" ] || {
    printf 'error: refusing to delete a tree containing active mounts: %s\n' "$resolved" >&2
    return 1
  }
  rm -rf -- "$resolved"
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
