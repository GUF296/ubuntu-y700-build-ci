#!/usr/bin/env bash
set -euo pipefail

# Runs inside the target rootfs. It records parsed repository facts, package
# identities and index digests, never raw source config, comments, proxies, or
# package-index content.

usage() {
  printf '%s\n' "usage: $(basename "$0") PROVENANCE_DIR PHASE update|install|purge|autoremove|mark-auto [arguments...]" >&2
}

die() {
  printf 'error: APT transaction provenance: %s\n' "$1" >&2
  exit 1
}

[ "$#" -ge 3 ] || { usage; exit 2; }
provenance_dir=$1
phase=$2
operation=$3
shift 3

[[ $provenance_dir = /* && $provenance_dir != *$'\n'* && ${#provenance_dir} -le 512 ]] ||
  die 'unsafe provenance directory'
[[ $phase =~ ^[a-z][a-z0-9-]{0,63}$ ]] || die 'unsafe transaction phase'
case "$operation" in
  update|install|purge|autoremove|mark-auto) ;;
  *) die 'unsupported apt-get operation' ;;
esac

validate_apt_arguments() {
  local argument end_of_options=0

  if [ "$operation" = update ] && [ "$#" -ne 0 ]; then
    die 'apt-get update must not receive caller-supplied arguments'
  fi
  for argument in "$@"; do
    [ "$end_of_options" -eq 0 ] || continue
    case "$argument" in
      --)
        case "$operation" in
          install|purge) end_of_options=1 ;;
          *) die 'unexpected apt-get option terminator' ;;
        esac
        ;;
      -y|--yes|--assume-yes)
        ;;
      --no-install-recommends)
        [ "$operation" = install ] ||
          die 'unexpected apt-get install policy option'
        ;;
      --purge)
        [ "$operation" = autoremove ] ||
          die 'unexpected apt-get purge policy option'
        ;;
      -*)
        die 'caller-supplied apt-get option is forbidden'
        ;;
    esac
  done
}
validate_apt_arguments "$@"

validate_apt_mark_arguments() {
  local package

  [ "$operation" = mark-auto ] || return 0
  [ "$#" -gt 0 ] || die 'apt-mark auto requires at least one package'
  for package in "$@"; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.-]{0,127}(:[a-z0-9][a-z0-9+.-]{0,31})?$ ]] ||
      die 'unsafe apt-mark package name'
  done
}
validate_apt_mark_arguments "$@"

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]{1,10}$ ]] || die 'invalid SOURCE_DATE_EPOCH'
apt_root=${CI_APT_ROOT:-/}
if [ "$apt_root" != / ]; then
  [ -d "$apt_root" ] && [ ! -L "$apt_root" ] || die 'unsafe APT root directory'
  apt_root=$(realpath -e -- "${apt_root%/}")
fi
common_script=${CI_APT_COMMON_SH:-/root/ci-apt-common.sh}
[ -f "$common_script" ] && [ ! -L "$common_script" ] ||
  die 'missing trusted APT validation helper'
# shellcheck source=/dev/null
. "$common_script"
[ -z "${APT_CONFIG:-}" ] ||
  die 'APT_CONFIG environment override is forbidden'

readonly MAX_APT_TEXT_FILE_BYTES=1048576
readonly MAX_APT_KEYRING_FILE_BYTES=16777216
readonly MAX_APT_INDEX_FILE_BYTES=536870912
readonly MAX_APT_EVIDENCE_FILES=512
readonly MAX_APT_AUTO_PACKAGES=32768

validate_regular_file_size() {
  local path=$1 label=$2 maximum=$3 size

  [ -f "$path" ] && [ ! -L "$path" ] ||
    die "$label must be a regular file"
  size=$(stat -c '%s' -- "$path")
  [[ $size =~ ^[0-9]+$ ]] && [ "$size" -le "$maximum" ] ||
    die "$label is too large or has an invalid size"
}

ensure_directory() {
  local path=$1 current= component index
  local -a components=()

  [[ $path = /* ]] || die 'provenance path must be absolute'
  IFS=/ read -r -a components <<< "${path#/}"
  for ((index = 0; index < ${#components[@]}; index++)); do
    component=${components[index]}
    [ -n "$component" ] || continue
    current="${current}/${component}"
    [ ! -L "$current" ] || die 'provenance path must not contain a symlink'
    if [ ! -e "$current" ]; then
      if [ "$index" -eq $(( ${#components[@]} - 1 )) ]; then
        mkdir -m 0700 -- "$current"
      else
        mkdir -- "$current"
      fi
    fi
    [ -d "$current" ] && [ ! -L "$current" ] ||
      die 'provenance path is not a directory'
  done
}

validate_text_file() {
  local path=$1

  validate_regular_file_size "$path" 'APT source' "$MAX_APT_TEXT_FILE_BYTES"
  [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$path" | wc -c)" -eq 0 ] ||
    die 'APT source contains non-printable data'
}

source_file_has_active_entries() {
  local path=$1

  awk 'NF && $1 !~ /^#/ { found=1 } END { exit found ? 0 : 1 }' "$path"
}

emit_sanitized_source_file() {
  local path=$1 relative=$2 output=$3
  local contents= line index option closed uri suite components line_digest
  local -a fields=() component_fields=()

  validate_text_file "$path"
  source_file_has_active_entries "$path" || return 0
  contents=$(<"$path")
  ci_validate_https_apt_sources_list "$contents"

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line%%#*}
    [ -n "${line//[[:space:]]/}" ] || continue
    fields=()
    read -r -a fields <<< "$line"
    index=1
    if [[ ${fields[1]:-} = \[* ]]; then
      closed=0
      while [ "$index" -lt "${#fields[@]}" ]; do
        option=${fields[index]}
        if [[ $option = *] ]]; then
          closed=1
          index=$((index + 1))
          break
        fi
        index=$((index + 1))
      done
      [ "$closed" -eq 1 ] || die 'unterminated validated source option block'
    fi
    uri=${fields[index]}
    suite=${fields[index + 1]}
    component_fields=("${fields[@]:$((index + 2))}")
    components=$(IFS=,; printf '%s' "${component_fields[*]}")
    line_digest=$(printf '%s\0' "${fields[@]}" | sha256sum | awk '{print $1}')
    printf 'source\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$relative" "${fields[0]}" "$uri" "$suite" "$components" "$line_digest" >> "$output"
  done <<< "$contents"
}

collect_sources() {
  local output=$1 source_file sources_dir path basename count=0

  : > "$output"
  source_file="$apt_root/etc/apt/sources.list"
  [ ! -L "$source_file" ] || die 'sources.list must not be a symlink'
  emit_sanitized_source_file "$source_file" etc/apt/sources.list "$output"

  sources_dir="$apt_root/etc/apt/sources.list.d"
  if [ -e "$sources_dir" ] || [ -L "$sources_dir" ]; then
    [ -d "$sources_dir" ] && [ ! -L "$sources_dir" ] ||
      die 'sources.list.d must be a real directory'
    path=$(find -P "$sources_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)
    [ -z "$path" ] || die 'sources.list.d must not contain symlinks'
    while IFS= read -r -d '' path; do
      basename=$(basename -- "$path")
      case "$basename" in
        *.list)
          emit_sanitized_source_file \
            "$path" "etc/apt/sources.list.d/$basename" "$output"
          count=$((count + 1))
          [ "$count" -le "$MAX_APT_EVIDENCE_FILES" ] ||
            die 'too many APT source files'
          ;;
        *) die 'unsupported APT source file type' ;;
      esac
    done < <(find -P "$sources_dir" -mindepth 1 -maxdepth 1 -type f -print0 |
      LC_ALL=C sort -z)
  fi

  [ -s "$output" ] ||
    die 'no active APT source entries across sources.list and sources.list.d'
  LC_ALL=C sort -u -o "$output" "$output"
}

collect_indexes() {
  local output=$1 lists_dir="$apt_root/var/lib/apt/lists" path basename size digest count=0

  [ -d "$lists_dir" ] && [ ! -L "$lists_dir" ] ||
    die 'APT lists directory is missing or unsafe'
  [ -z "$(find -P "$lists_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
    die 'APT lists directory contains a symlink'
  : > "$output"
  while IFS= read -r -d '' path; do
    basename=$(basename -- "$path")
    [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
      die 'unsafe APT index filename'
    size=$(stat -c '%s' -- "$path")
    [[ $size =~ ^[0-9]+$ ]] && [ "$size" -le "$MAX_APT_INDEX_FILE_BYTES" ] ||
      die 'invalid or oversized APT index size'
    digest=$(sha256sum -- "$path" | awk '{print $1}')
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || die 'invalid APT index digest'
    printf 'index\t%s\t%s\t%s\n' "$basename" "$size" "$digest" >> "$output"
    count=$((count + 1))
    [ "$count" -le "$MAX_APT_EVIDENCE_FILES" ] || die 'too many APT index files'
  done < <(find -P "$lists_dir" -mindepth 1 -maxdepth 1 -type f ! -name lock -print0 |
    LC_ALL=C sort -z)
  [ "$count" -gt 0 ] || die 'no APT index files were recorded'
  LC_ALL=C sort -u -o "$output" "$output"
}

append_digest_fact() {
  local tag=$1 path=$2 relative=$3 output=$4 size digest maximum

  case "$tag" in
    keyring) maximum=$MAX_APT_KEYRING_FILE_BYTES ;;
    apt-config|preference) maximum=$MAX_APT_TEXT_FILE_BYTES ;;
    *) die 'unsupported APT evidence tag' ;;
  esac
  validate_regular_file_size "$path" "$tag evidence" "$maximum"
  size=$(stat -c '%s' -- "$path")
  [[ $size =~ ^[0-9]+$ ]] || die "invalid $tag evidence size"
  digest=$(sha256sum -- "$path" | awk '{print $1}')
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || die "invalid $tag evidence digest"
  printf '%s\t%s\t%s\t%s\n' "$tag" "$relative" "$size" "$digest" >> "$output"
}

collect_keyring_directory() {
  local directory=$1 relative_prefix=$2 output=$3 path basename count=0

  if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
    return 0
  fi
  [ -d "$directory" ] && [ ! -L "$directory" ] ||
    die 'APT keyring path is not a real directory'
  [ -z "$(find -P "$directory" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
    die 'APT keyring directory contains a symlink'
  while IFS= read -r -d '' path; do
    basename=$(basename -- "$path")
    case "$basename" in
      *.asc|*.gpg)
        [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.(asc|gpg)$ ]] ||
          die 'unsafe APT keyring filename'
        append_digest_fact keyring "$path" "$relative_prefix/$basename" "$output"
        count=$((count + 1))
        [ "$count" -le "$MAX_APT_EVIDENCE_FILES" ] ||
          die 'too many APT keyring files'
        ;;
    esac
  done < <(find -P "$directory" -mindepth 1 -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)
}

append_signed_by_keyrings_from_source() {
  local path=$1 output=$2 contents= line index option closed keyring target relative
  local -a fields=()

  validate_text_file "$path"
  source_file_has_active_entries "$path" || return 0
  contents=$(<"$path")
  ci_validate_https_apt_sources_list "$contents"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line%%#*}
    [ -n "${line//[[:space:]]/}" ] || continue
    fields=()
    read -r -a fields <<< "$line"
    [[ ${fields[1]:-} = \[* ]] || continue
    index=1
    closed=0
    while [ "$index" -lt "${#fields[@]}" ]; do
      option=${fields[index]}
      option=${option#[}
      option=${option%]}
      case "$option" in
        signed-by=*)
          keyring=${option#signed-by=}
          case "$keyring" in
            /etc/apt/keyrings/*|/usr/share/keyrings/*) ;;
            *) die 'validated APT source has an unsupported signed-by path' ;;
          esac
          target="$apt_root$keyring"
          [ -f "$target" ] && [ ! -L "$target" ] ||
            die 'active signed-by keyring is missing or unsafe'
          relative=${keyring#/}
          append_digest_fact keyring "$target" "$relative" "$output"
          ;;
      esac
      if [[ ${fields[index]} = *] ]]; then
        closed=1
        break
      fi
      index=$((index + 1))
    done
    [ "$closed" -eq 1 ] || die 'unterminated validated source option block'
  done <<< "$contents"
}

collect_signed_by_keyrings() {
  local output=$1 sources_file="$apt_root/etc/apt/sources.list"
  local sources_dir="$apt_root/etc/apt/sources.list.d" path basename

  [ -f "$sources_file" ] && [ ! -L "$sources_file" ] ||
    die 'sources.list must be a regular file for keyring evidence'
  append_signed_by_keyrings_from_source "$sources_file" "$output"
  if [ -e "$sources_dir" ] || [ -L "$sources_dir" ]; then
    [ -d "$sources_dir" ] && [ ! -L "$sources_dir" ] ||
      die 'sources.list.d must be a real directory for keyring evidence'
    [ -z "$(find -P "$sources_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
      die 'sources.list.d contains a symlink for keyring evidence'
    while IFS= read -r -d '' path; do
      basename=$(basename -- "$path")
      case "$basename" in
        *.list) append_signed_by_keyrings_from_source "$path" "$output" ;;
        *) die 'unsupported APT source file type for keyring evidence' ;;
      esac
    done < <(find -P "$sources_dir" -mindepth 1 -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)
  fi
}

collect_keyrings() {
  local output=$1 trusted_keyring="$apt_root/etc/apt/trusted.gpg"

  : > "$output"
  if [ -e "$trusted_keyring" ] || [ -L "$trusted_keyring" ]; then
    [ ! -L "$trusted_keyring" ] || die 'APT trusted.gpg must not be a symlink'
    append_digest_fact keyring "$trusted_keyring" etc/apt/trusted.gpg "$output"
  fi
  collect_keyring_directory \
    "$apt_root/etc/apt/trusted.gpg.d" etc/apt/trusted.gpg.d "$output"
  collect_keyring_directory \
    "$apt_root/etc/apt/keyrings" etc/apt/keyrings "$output"
  collect_keyring_directory \
    "$apt_root/usr/share/keyrings" usr/share/keyrings "$output"
  collect_signed_by_keyrings "$output"
  [ -s "$output" ] || die 'no trusted APT keyring files were recorded'
  LC_ALL=C sort -u -o "$output" "$output"
}

collect_apt_configs() {
  local output=$1 apt_conf="$apt_root/etc/apt/apt.conf"
  local apt_conf_dir="$apt_root/etc/apt/apt.conf.d" path basename count=0

  : > "$output"
  if [ -e "$apt_conf" ] || [ -L "$apt_conf" ]; then
    [ ! -L "$apt_conf" ] || die 'apt.conf must not be a symlink'
    validate_regular_file_size "$apt_conf" 'APT configuration' "$MAX_APT_TEXT_FILE_BYTES"
    ci_validate_apt_config_file "$apt_conf"
    append_digest_fact apt-config "$apt_conf" etc/apt/apt.conf "$output"
  fi
  if [ -e "$apt_conf_dir" ] || [ -L "$apt_conf_dir" ]; then
    [ -d "$apt_conf_dir" ] && [ ! -L "$apt_conf_dir" ] ||
      die 'apt.conf.d must be a real directory'
    [ -z "$(find -P "$apt_conf_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
      die 'apt.conf.d contains a symlink'
    while IFS= read -r -d '' path; do
      basename=$(basename -- "$path")
      [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
        die 'unsafe APT config filename'
      validate_regular_file_size "$path" 'APT configuration' "$MAX_APT_TEXT_FILE_BYTES"
      ci_validate_apt_config_file "$path"
      append_digest_fact apt-config "$path" "etc/apt/apt.conf.d/$basename" "$output"
      count=$((count + 1))
      [ "$count" -le "$MAX_APT_EVIDENCE_FILES" ] ||
        die 'too many APT configuration files'
    done < <(find -P "$apt_conf_dir" -mindepth 1 -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)
  fi
  [ -s "$output" ] || die 'no APT config files were recorded'
  LC_ALL=C sort -u -o "$output" "$output"
}

validate_apt_preference_file() {
  local path=$1

  validate_regular_file_size "$path" 'APT preference' "$MAX_APT_TEXT_FILE_BYTES"
  [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$path" | wc -c)" -eq 0 ] ||
    die 'APT preference contains non-printable data'
}

collect_preferences() {
  local output=$1 preference="$apt_root/etc/apt/preferences"
  local preference_dir="$apt_root/etc/apt/preferences.d" path basename count=0

  : > "$output"
  if [ -e "$preference" ] || [ -L "$preference" ]; then
    [ ! -L "$preference" ] || die 'APT preferences must not be a symlink'
    validate_apt_preference_file "$preference"
    append_digest_fact preference "$preference" etc/apt/preferences "$output"
  fi
  if [ -e "$preference_dir" ] || [ -L "$preference_dir" ]; then
    [ -d "$preference_dir" ] && [ ! -L "$preference_dir" ] ||
      die 'APT preferences.d must be a real directory'
    [ -z "$(find -P "$preference_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
      die 'APT preferences.d contains a symlink'
    while IFS= read -r -d '' path; do
      basename=$(basename -- "$path")
      [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
        die 'unsafe APT preference filename'
      validate_apt_preference_file "$path"
      append_digest_fact preference "$path" "etc/apt/preferences.d/$basename" "$output"
      count=$((count + 1))
      [ "$count" -le "$MAX_APT_EVIDENCE_FILES" ] ||
        die 'too many APT preference files'
    done < <(find -P "$preference_dir" -mindepth 1 -maxdepth 1 -type f -print0 |
      LC_ALL=C sort -z)
  fi
  LC_ALL=C sort -u -o "$output" "$output"
}

collect_auto_packages() {
  local output=$1 package count=0

  command -v apt-mark >/dev/null 2>&1 || die 'apt-mark is required for solver provenance'
  LC_ALL=C apt-mark showauto | LC_ALL=C sort -u > "$output"
  while IFS= read -r package || [ -n "$package" ]; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.-]{0,127}(:[a-z0-9][a-z0-9+.-]{0,31})?$ ]] ||
      die "unsafe apt-mark showauto package name: $package"
    count=$((count + 1))
    [ "$count" -le "$MAX_APT_AUTO_PACKAGES" ] ||
      die 'too many apt-mark showauto packages'
  done < "$output"
}

collect_extended_states() {
  local output=$1 state_file="$apt_root/var/lib/apt/extended_states" size digest

  : > "$output"
  if [ ! -e "$state_file" ] && [ ! -L "$state_file" ]; then
    digest=$(printf '' | sha256sum | awk '{print $1}')
    printf 'extended-state\tvar/lib/apt/extended_states\t0\t%s\n' "$digest" > "$output"
    return 0
  fi
  validate_regular_file_size "$state_file" 'APT extended_states' "$MAX_APT_KEYRING_FILE_BYTES"
  [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$state_file" | wc -c)" -eq 0 ] ||
    die 'APT extended_states contains non-printable data'
  size=$(stat -c '%s' -- "$state_file")
  digest=$(sha256sum -- "$state_file" | awk '{print $1}')
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || die 'invalid APT extended_states digest'
  printf 'extended-state\tvar/lib/apt/extended_states\t%s\t%s\n' "$size" "$digest" > "$output"
}

collect_packages() {
  local output=$1 package version architecture count=0

  LC_ALL=C dpkg-query -W \
    -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Architecture}\n' |
    LC_ALL=C awk -F '\t' '$1 == "ii " { print $2 "\t" $3 "\t" $4 }' |
    LC_ALL=C sort -u > "$output"
  [ -s "$output" ] || die 'installed package inventory is empty'
  while IFS=$'\t' read -r package version architecture; do
    [[ $package =~ ^[A-Za-z0-9][A-Za-z0-9+.:_-]{0,127}$ ]] ||
      die 'unsafe installed package name'
    [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]{0,255}$ ]] ||
      die 'unsafe installed package version'
    [[ $architecture =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
      die 'unsafe installed package architecture'
    count=$((count + 1))
    [ "$count" -le "$MAX_APT_AUTO_PACKAGES" ] ||
      die 'too many installed packages for APT provenance'
  done < "$output"
}

collect_local_debs() {
  local output=$1 item basename digest

  : > "$output"
  for item in "$@"; do
    case "$item" in
      *.deb)
        [ -f "$item" ] && [ ! -L "$item" ] ||
          die 'local APT package is not a regular file'
        basename=$(basename -- "$item")
        [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.deb$ ]] ||
          die 'unsafe local APT package filename'
        digest=$(sha256sum -- "$item" | awk '{print $1}')
        [[ $digest =~ ^[0-9a-f]{64}$ ]] || die 'invalid local APT package digest'
        printf 'local-deb\t%s\t%s\n' "$basename" "$digest" >> "$output"
        ;;
    esac
  done
  LC_ALL=C sort -u -o "$output" "$output"
}

expected_provenance_dir="$apt_root/var/lib/tb321fu-build-provenance/apt-transactions"
[ "$apt_root" != / ] || expected_provenance_dir=/var/lib/tb321fu-build-provenance/apt-transactions
[ "$provenance_dir" = "$expected_provenance_dir" ] ||
  die 'unexpected provenance directory'
ensure_directory "$provenance_dir"
transaction_dir="$provenance_dir/transactions"
state_dir="$provenance_dir/state"
ensure_directory "$transaction_dir"
ensure_directory "$state_dir"

# Calls are serialized by provisioning. The on-rootfs counter continues into
# the GPU phase and makes one output record correspond to one apt-get call.
counter_file="$state_dir/next"
next=1
if [ -e "$counter_file" ]; then
  [ -f "$counter_file" ] && [ ! -L "$counter_file" ] ||
    die 'unsafe transaction counter'
  read -r next < "$counter_file" || die 'empty transaction counter'
  [[ $next =~ ^[1-9][0-9]{0,3}$ ]] || die 'invalid transaction counter'
fi
[ "$next" -le 9999 ] || die 'too many APT transactions'
printf -v transaction_id '%04d' "$next"

temporary=$(mktemp -d "$transaction_dir/.${transaction_id}-${phase}-${operation}.XXXXXX")
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT INT TERM

pre_sources_file="$temporary/pre-sources.tsv"
pre_keyrings_file="$temporary/pre-keyrings.tsv"
pre_apt_configs_file="$temporary/pre-apt-configs.tsv"
pre_preferences_file="$temporary/pre-preferences.tsv"
pre_auto_packages_file="$temporary/pre-auto-packages.tsv"
pre_extended_states_file="$temporary/pre-extended-states.tsv"
post_sources_file="$temporary/post-sources.tsv"
indexes_file="$temporary/indexes.tsv"
post_keyrings_file="$temporary/post-keyrings.tsv"
post_apt_configs_file="$temporary/post-apt-configs.tsv"
post_preferences_file="$temporary/post-preferences.tsv"
post_auto_packages_file="$temporary/post-auto-packages.tsv"
post_extended_states_file="$temporary/post-extended-states.tsv"
packages_file="$temporary/packages.tsv"
local_debs_file="$temporary/local-debs.tsv"
mark_auto_inputs_file="$temporary/mark-auto-inputs.tsv"

# Authentication and repository selection must describe the exact state APT
# consumed. Package maintainer scripts can alter these files after resolution,
# so preserve both snapshots instead of mislabeling post-call state as input.
collect_sources "$pre_sources_file"
collect_keyrings "$pre_keyrings_file"
collect_apt_configs "$pre_apt_configs_file"
collect_preferences "$pre_preferences_file"
collect_auto_packages "$pre_auto_packages_file"
collect_extended_states "$pre_extended_states_file"

case "$operation" in
  mark-auto)
    printf '%s\n' "$@" | LC_ALL=C sort -u > "$mark_auto_inputs_file"
    apt-mark auto "$@"
    ;;
  *)
    : > "$mark_auto_inputs_file"
    env -u APT_CONFIG apt-get \
      -o Dir::Etc::sourcelist=sources.list \
      -o Dir::Etc::sourceparts=sources.list.d \
      -o Dir::Etc::trusted=trusted.gpg \
      -o Dir::Etc::trustedparts=trusted.gpg.d \
      -o APT::Get::AllowUnauthenticated=false \
      -o Acquire::AllowInsecureRepositories=false \
      -o Acquire::AllowDowngradeToInsecureRepositories=false \
      -o Acquire::AllowWeakRepositories=false \
      -o Acquire::Check-Valid-Until=true \
      -o Acquire::https::Verify-Peer=true \
      -o Acquire::https::Verify-Host=true \
      "$operation" "$@"
    ;;
esac

collect_sources "$post_sources_file"
collect_indexes "$indexes_file"
collect_keyrings "$post_keyrings_file"
collect_apt_configs "$post_apt_configs_file"
collect_preferences "$post_preferences_file"
collect_auto_packages "$post_auto_packages_file"
collect_extended_states "$post_extended_states_file"
collect_packages "$packages_file"
collect_local_debs "$local_debs_file" "$@"

record="$temporary/${transaction_id}-${phase}-${operation}.tsv"
{
  printf 'schema\ttb321fu.apt-transaction/v3\n'
  printf 'transaction\t%s\n' "$transaction_id"
  printf 'timestamp\t%s\n' "$SOURCE_DATE_EPOCH"
  printf 'phase\t%s\n' "$phase"
  printf 'operation\t%s\n' "$operation"
  printf 'request-sha256\t%s\n' "$(printf '%s\0' "$operation" "$@" | sha256sum | awk '{print $1}')"
  printf 'pre-sources-sha256\t%s\n' "$(sed 's/^/pre-/' "$pre_sources_file" | sha256sum | awk '{print $1}')"
  printf 'pre-keyrings-sha256\t%s\n' "$(sed 's/^/pre-/' "$pre_keyrings_file" | sha256sum | awk '{print $1}')"
  printf 'pre-apt-configs-sha256\t%s\n' "$(sed 's/^/pre-/' "$pre_apt_configs_file" | sha256sum | awk '{print $1}')"
  printf 'pre-preferences-sha256\t%s\n' "$(sed 's/^/pre-/' "$pre_preferences_file" | sha256sum | awk '{print $1}')"
  printf 'pre-auto-packages-sha256\t%s\n' "$(sed 's/^/pre-auto-package\t/' "$pre_auto_packages_file" | sha256sum | awk '{print $1}')"
  printf 'pre-extended-states-sha256\t%s\n' "$(sed 's/^/pre-/' "$pre_extended_states_file" | sha256sum | awk '{print $1}')"
  printf 'post-sources-sha256\t%s\n' "$(sed 's/^/post-/' "$post_sources_file" | sha256sum | awk '{print $1}')"
  printf 'indexes-sha256\t%s\n' "$(sha256sum "$indexes_file" | awk '{print $1}')"
  printf 'post-keyrings-sha256\t%s\n' "$(sed 's/^/post-/' "$post_keyrings_file" | sha256sum | awk '{print $1}')"
  printf 'post-apt-configs-sha256\t%s\n' "$(sed 's/^/post-/' "$post_apt_configs_file" | sha256sum | awk '{print $1}')"
  printf 'post-preferences-sha256\t%s\n' "$(sed 's/^/post-/' "$post_preferences_file" | sha256sum | awk '{print $1}')"
  printf 'post-auto-packages-sha256\t%s\n' "$(sed 's/^/post-auto-package\t/' "$post_auto_packages_file" | sha256sum | awk '{print $1}')"
  printf 'post-extended-states-sha256\t%s\n' "$(sed 's/^/post-/' "$post_extended_states_file" | sha256sum | awk '{print $1}')"
  printf 'mark-auto-inputs-sha256\t%s\n' "$(sed 's/^/apt-mark-auto\t/' "$mark_auto_inputs_file" | sha256sum | awk '{print $1}')"
  printf 'packages-sha256\t%s\n' "$(sha256sum "$packages_file" | awk '{print $1}')"
  sed 's/^/pre-/' "$pre_sources_file"
  sed 's/^/pre-/' "$pre_keyrings_file"
  sed 's/^/pre-/' "$pre_apt_configs_file"
  sed 's/^/pre-/' "$pre_preferences_file"
  sed 's/^/pre-auto-package\t/' "$pre_auto_packages_file"
  sed 's/^/pre-/' "$pre_extended_states_file"
  sed 's/^/post-/' "$post_sources_file"
  cat "$indexes_file"
  sed 's/^/post-/' "$post_keyrings_file"
  sed 's/^/post-/' "$post_apt_configs_file"
  sed 's/^/post-/' "$post_preferences_file"
  sed 's/^/post-auto-package\t/' "$post_auto_packages_file"
  sed 's/^/post-/' "$post_extended_states_file"
  while IFS=$'\t' read -r package version architecture; do
    printf 'package\t%s\t%s\t%s\n' "$package" "$version" "$architecture"
  done < "$packages_file"
  cat "$local_debs_file"
  sed 's/^/apt-mark-auto\t/' "$mark_auto_inputs_file"
} > "$record"
chmod 0600 "$record"
touch -d "@$SOURCE_DATE_EPOCH" "$record"
mv -f -- "$record" "$transaction_dir/${transaction_id}-${phase}-${operation}.tsv"
printf '%s\n' "$((next + 1))" > "$counter_file"
chmod 0600 "$counter_file"
touch -d "@$SOURCE_DATE_EPOCH" "$counter_file"
trap - EXIT INT TERM
cleanup
