#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# Aggregate validated rootfs transaction records. These outputs contain only
# normalized evidence; raw sources.list data, proxy values and APT index
# contents never leave the temporary rootfs.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat >&2 <<USAGE
usage:
  $(basename "$0") capture-bootstrap ROOTFS_DIR BOOTSTRAP_TSV \\
    DEBOOTSTRAP_VERSION DEBOOTSTRAP_SHA256 DISTRO ARCH VARIANT MIRROR
  $(basename "$0") finalize ROOTFS_DIR BOOTSTRAP_TSV PROVENANCE_TSV SOURCES_TSV
USAGE
}

[ "$#" -ge 1 ] || { usage; exit 2; }
mode=$1
shift

case "$mode" in
  capture-bootstrap)
    [ "$#" -eq 8 ] || { usage; exit 2; }
    rootfs_dir=$(realpath -e -- "$1")
    bootstrap_output=$2
    debootstrap_version=$3
    debootstrap_sha256=$4
    bootstrap_distro=$5
    bootstrap_arch=$6
    bootstrap_variant=$7
    bootstrap_mirror=$8
    ;;
  finalize)
    [ "$#" -eq 4 ] || { usage; exit 2; }
    rootfs_dir=$(realpath -e -- "$1")
    bootstrap_input=$2
    provenance_output=$3
    sources_output=$4
    transaction_dir="$rootfs_dir/var/lib/tb321fu-build-provenance/apt-transactions/transactions"
    ;;
  *)
    usage
    exit 2
    ;;
esac

[ -d "$rootfs_dir" ] && [ ! -L "$rootfs_dir" ] ||
  ci_die 'APT provenance rootfs directory is missing or unsafe'
if [ "$mode" = finalize ]; then
  [ -d "$transaction_dir" ] && [ ! -L "$transaction_dir" ] ||
    ci_die 'APT provenance transaction directory is missing or unsafe'
fi

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]{1,10}$ ]] ||
  ci_die 'invalid SOURCE_DATE_EPOCH for APT provenance'

readonly MAX_APT_TEXT_FILE_BYTES=1048576
readonly MAX_APT_KEYRING_FILE_BYTES=16777216
readonly MAX_APT_INDEX_FILE_BYTES=536870912
readonly MAX_APT_EVIDENCE_FILES=512
readonly MAX_APT_AUTO_PACKAGES=32768

validate_hash() {
  [[ $1 =~ ^[0-9a-f]{64}$ ]] ||
    ci_die 'invalid APT provenance SHA-256 digest'
}

validate_regular_file_size() {
  local path=$1 label=$2 maximum=$3 size

  [ -f "$path" ] && [ ! -L "$path" ] ||
    ci_die "$label must be a regular file"
  size=$(stat -c '%s' -- "$path")
  [[ $size =~ ^[0-9]+$ ]] && [ "$size" -le "$maximum" ] ||
    ci_die "$label is too large or has an invalid size"
}

validate_source_relative() {
  [[ $1 =~ ^etc/apt/sources\.list$ ||
     $1 =~ ^etc/apt/sources\.list\.d/[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.list$ ]] ||
    ci_die 'invalid sanitized APT source path'
}

validate_keyring_relative() {
  [[ $1 = etc/apt/trusted.gpg ||
     $1 =~ ^etc/apt/trusted\.gpg\.d/[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.(asc|gpg)$ ||
     $1 =~ ^etc/apt/keyrings/[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.(asc|gpg)$ ||
     $1 =~ ^usr/share/keyrings/[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.(asc|gpg)$ ]] ||
    ci_die 'invalid APT keyring evidence path'
}

validate_apt_config_relative() {
  [[ $1 = etc/apt/apt.conf ||
     $1 =~ ^etc/apt/apt\.conf\.d/[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
    ci_die 'invalid APT config evidence path'
}

validate_preference_relative() {
  [[ $1 = etc/apt/preferences ||
     $1 =~ ^etc/apt/preferences\.d/[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
    ci_die 'invalid APT preference evidence path'
}

source_file_has_active_entries() {
  local path=$1

  awk 'NF && $1 !~ /^#/ { found=1 } END { exit found ? 0 : 1 }' "$path"
}

emit_final_source_file() {
  local path=$1 relative=$2 output=$3
  local contents= line index option closed uri suite components line_digest
  local -a fields=() component_fields=()

  validate_regular_file_size "$path" 'final APT source' "$MAX_APT_TEXT_FILE_BYTES"
  [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$path" | wc -c)" -eq 0 ] ||
    ci_die 'final APT source contains non-printable data'
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
      [ "$closed" -eq 1 ] || ci_die 'unterminated final APT source option block'
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

collect_final_sources() {
  local output=$1 sources_file="$rootfs_dir/etc/apt/sources.list"
  local sources_dir="$rootfs_dir/etc/apt/sources.list.d" path basename

  : > "$output"
  [ ! -L "$sources_file" ] || ci_die 'final sources.list must not be a symlink'
  emit_final_source_file "$sources_file" etc/apt/sources.list "$output"
  if [ -e "$sources_dir" ] || [ -L "$sources_dir" ]; then
    [ -d "$sources_dir" ] && [ ! -L "$sources_dir" ] ||
      ci_die 'final sources.list.d must be a real directory'
    [ -z "$(find -P "$sources_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
      ci_die 'final sources.list.d must not contain symlinks'
    while IFS= read -r -d '' path; do
      basename=$(basename -- "$path")
      case "$basename" in
        *.list)
          emit_final_source_file \
            "$path" "etc/apt/sources.list.d/$basename" "$output"
          ;;
        *) ci_die 'unsupported final APT source file type' ;;
      esac
    done < <(find -P "$sources_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
  fi
  [ -s "$output" ] ||
    ci_die 'final rootfs has no active APT source entries across sources.list and sources.list.d'
  LC_ALL=C sort -u -o "$output" "$output"
}

validate_final_evidence_directory() {
  local directory=$1 label=$2

  if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
    return 0
  fi
  [ -d "$directory" ] && [ ! -L "$directory" ] ||
    ci_die "final $label directory is unsafe"
  [ -z "$(find -P "$directory" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
    ci_die "final $label directory contains a symlink"
}

validate_final_keyring_and_config_layout() {
  local trusted_keyring="$rootfs_dir/etc/apt/trusted.gpg"
  local apt_conf="$rootfs_dir/etc/apt/apt.conf"
  local apt_conf_dir="$rootfs_dir/etc/apt/apt.conf.d" path
  local preference="$rootfs_dir/etc/apt/preferences"
  local preference_dir="$rootfs_dir/etc/apt/preferences.d"

  [ ! -L "$trusted_keyring" ] || ci_die 'final trusted.gpg must not be a symlink'
  [ ! -L "$apt_conf" ] || ci_die 'final apt.conf must not be a symlink'
  [ ! -L "$preference" ] || ci_die 'final APT preferences must not be a symlink'
  if [ -e "$apt_conf" ]; then
    validate_regular_file_size "$apt_conf" 'final APT configuration' "$MAX_APT_TEXT_FILE_BYTES"
    ci_validate_apt_config_file "$apt_conf"
  fi
  if [ -e "$preference" ]; then
    validate_regular_file_size "$preference" 'final APT preference' "$MAX_APT_TEXT_FILE_BYTES"
    [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$preference" | wc -c)" -eq 0 ] ||
      ci_die 'final APT preference contains non-printable data'
  fi
  validate_final_evidence_directory "$rootfs_dir/etc/apt/trusted.gpg.d" 'APT trusted keyring'
  validate_final_evidence_directory "$rootfs_dir/etc/apt/keyrings" 'APT keyring'
  validate_final_evidence_directory "$rootfs_dir/usr/share/keyrings" 'shared keyring'
  validate_final_evidence_directory "$apt_conf_dir" 'APT config'
  validate_final_evidence_directory "$preference_dir" 'APT preference'
  if [ -d "$apt_conf_dir" ]; then
    while IFS= read -r -d '' path; do
      validate_regular_file_size "$path" 'final APT configuration' "$MAX_APT_TEXT_FILE_BYTES"
      ci_validate_apt_config_file "$path"
    done < <(find -P "$apt_conf_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
  fi
  if [ -d "$preference_dir" ]; then
    while IFS= read -r -d '' path; do
      validate_regular_file_size "$path" 'final APT preference' "$MAX_APT_TEXT_FILE_BYTES"
      [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$path" | wc -c)" -eq 0 ] ||
        ci_die 'final APT preference contains non-printable data'
    done < <(find -P "$preference_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
  fi
}

append_final_digest_fact() {
  local tag=$1 path=$2 relative=$3 output=$4 size digest maximum

  case "$tag" in
    final-keyring|bootstrap-keyring) maximum=$MAX_APT_KEYRING_FILE_BYTES ;;
    final-apt-config|bootstrap-apt-config|final-preference|bootstrap-preference)
      maximum=$MAX_APT_TEXT_FILE_BYTES
      ;;
    *) ci_die 'unsupported APT evidence tag' ;;
  esac
  validate_regular_file_size "$path" 'APT evidence file' "$maximum"
  size=$(stat -c '%s' -- "$path")
  [[ $size =~ ^[0-9]+$ ]] || ci_die 'invalid final APT evidence size'
  digest=$(sha256sum -- "$path" | awk '{print $1}')
  validate_hash "$digest"
  printf '%s\t%s\t%s\t%s\n' "$tag" "$relative" "$size" "$digest" >> "$output"
}

collect_final_keyring_directory() {
  local directory=$1 relative_prefix=$2 output=$3 path basename

  if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
    return 0
  fi
  validate_final_evidence_directory "$directory" 'APT keyring'
  while IFS= read -r -d '' path; do
    basename=$(basename -- "$path")
    case "$basename" in
      *.asc|*.gpg)
        [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.(asc|gpg)$ ]] ||
          ci_die 'unsafe final APT keyring filename'
        append_final_digest_fact final-keyring "$path" "$relative_prefix/$basename" "$output"
        ;;
    esac
  done < <(find -P "$directory" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
}

collect_final_keyrings() {
  local output=$1 trusted_keyring="$rootfs_dir/etc/apt/trusted.gpg"

  : > "$output"
  if [ -e "$trusted_keyring" ] || [ -L "$trusted_keyring" ]; then
    [ ! -L "$trusted_keyring" ] || ci_die 'final trusted.gpg must not be a symlink'
    append_final_digest_fact final-keyring "$trusted_keyring" etc/apt/trusted.gpg "$output"
  fi
  collect_final_keyring_directory \
    "$rootfs_dir/etc/apt/trusted.gpg.d" etc/apt/trusted.gpg.d "$output"
  collect_final_keyring_directory \
    "$rootfs_dir/etc/apt/keyrings" etc/apt/keyrings "$output"
  collect_final_keyring_directory \
    "$rootfs_dir/usr/share/keyrings" usr/share/keyrings "$output"
  [ -s "$output" ] || ci_die 'no final APT keyring files were recorded'
  LC_ALL=C sort -u -o "$output" "$output"
}

collect_final_apt_configs() {
  local output=$1 apt_conf="$rootfs_dir/etc/apt/apt.conf"
  local apt_conf_dir="$rootfs_dir/etc/apt/apt.conf.d" path basename

  : > "$output"
  if [ -e "$apt_conf" ] || [ -L "$apt_conf" ]; then
    [ ! -L "$apt_conf" ] || ci_die 'final apt.conf must not be a symlink'
    ci_validate_apt_config_file "$apt_conf"
    append_final_digest_fact final-apt-config "$apt_conf" etc/apt/apt.conf "$output"
  fi
  if [ -e "$apt_conf_dir" ] || [ -L "$apt_conf_dir" ]; then
    validate_final_evidence_directory "$apt_conf_dir" 'APT config'
    while IFS= read -r -d '' path; do
      basename=$(basename -- "$path")
      [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
        ci_die 'unsafe final APT config filename'
      ci_validate_apt_config_file "$path"
      append_final_digest_fact final-apt-config "$path" "etc/apt/apt.conf.d/$basename" "$output"
    done < <(find -P "$apt_conf_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
  fi
  [ -s "$output" ] || ci_die 'no final APT config files were recorded'
  LC_ALL=C sort -u -o "$output" "$output"
}

collect_final_preferences() {
  local output=$1 preference="$rootfs_dir/etc/apt/preferences"
  local preference_dir="$rootfs_dir/etc/apt/preferences.d" path basename count=0

  : > "$output"
  if [ -e "$preference" ] || [ -L "$preference" ]; then
    [ ! -L "$preference" ] || ci_die 'final APT preferences must not be a symlink'
    append_final_digest_fact final-preference "$preference" etc/apt/preferences "$output"
  fi
  if [ -e "$preference_dir" ] || [ -L "$preference_dir" ]; then
    validate_final_evidence_directory "$preference_dir" 'APT preference'
    while IFS= read -r -d '' path; do
      basename=$(basename -- "$path")
      [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
        ci_die 'unsafe final APT preference filename'
      append_final_digest_fact final-preference "$path" "etc/apt/preferences.d/$basename" "$output"
      count=$((count + 1))
      [ "$count" -le "$MAX_APT_EVIDENCE_FILES" ] ||
        ci_die 'too many final APT preference files'
    done < <(find -P "$preference_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
  fi
  LC_ALL=C sort -u -o "$output" "$output"
}

collect_final_auto_packages() {
  local output=$1 package count=0

  [ -f "$rootfs_dir/usr/bin/apt-mark" ] && [ ! -L "$rootfs_dir/usr/bin/apt-mark" ] &&
    [ -x "$rootfs_dir/usr/bin/apt-mark" ] ||
    ci_die 'final rootfs apt-mark is missing, unsafe, or not executable'
  LC_ALL=C chroot "$rootfs_dir" /usr/bin/apt-mark showauto | LC_ALL=C sort -u > "$output"
  while IFS= read -r package || [ -n "$package" ]; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.-]{0,127}(:[a-z0-9][a-z0-9+.-]{0,31})?$ ]] ||
      ci_die 'unsafe final apt-mark showauto package name'
    count=$((count + 1))
    [ "$count" -le "$MAX_APT_AUTO_PACKAGES" ] ||
      ci_die 'too many final apt-mark showauto packages'
  done < "$output"
}

collect_final_extended_states() {
  local output=$1 state_file="$rootfs_dir/var/lib/apt/extended_states" size digest

  : > "$output"
  if [ ! -e "$state_file" ] && [ ! -L "$state_file" ]; then
    digest=$(printf '' | sha256sum | awk '{print $1}')
    printf 'final-extended-state\tvar/lib/apt/extended_states\t0\t%s\n' "$digest" > "$output"
    return 0
  fi
  validate_regular_file_size "$state_file" 'final APT extended_states' "$MAX_APT_KEYRING_FILE_BYTES"
  [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$state_file" | wc -c)" -eq 0 ] ||
    ci_die 'final APT extended_states contains non-printable data'
  size=$(stat -c '%s' -- "$state_file")
  digest=$(sha256sum -- "$state_file" | awk '{print $1}')
  validate_hash "$digest"
  printf 'final-extended-state\tvar/lib/apt/extended_states\t%s\t%s\n' "$size" "$digest" > "$output"
}

collect_bootstrap_indexes() {
  local output=$1 lists_dir="$rootfs_dir/var/lib/apt/lists"
  local path basename size digest count=0

  : > "$output"
  if [ ! -e "$lists_dir" ] && [ ! -L "$lists_dir" ]; then
    return 0
  fi
  [ -d "$lists_dir" ] && [ ! -L "$lists_dir" ] ||
    ci_die 'bootstrap APT lists directory is unsafe'
  [ -z "$(find -P "$lists_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
    ci_die 'bootstrap APT lists directory contains a symlink'
  while IFS= read -r -d '' path; do
    basename=$(basename -- "$path")
    [[ $basename =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
      ci_die 'unsafe bootstrap APT index filename'
    size=$(stat -c '%s' -- "$path")
    [[ $size =~ ^[0-9]+$ ]] && [ "$size" -le "$MAX_APT_INDEX_FILE_BYTES" ] ||
      ci_die 'invalid or oversized bootstrap APT index size'
    digest=$(sha256sum -- "$path" | awk '{print $1}')
    validate_hash "$digest"
    printf 'bootstrap-index\t%s\t%s\t%s\n' "$basename" "$size" "$digest" >> "$output"
    count=$((count + 1))
    [ "$count" -le "$MAX_APT_EVIDENCE_FILES" ] ||
      ci_die 'too many bootstrap APT index files'
  done < <(find -P "$lists_dir" -mindepth 1 -maxdepth 1 -type f ! -name lock -print0 | sort -z)
  LC_ALL=C sort -u -o "$output" "$output"
}

collect_bootstrap_packages() {
  local output=$1 package version architecture count=0

  LC_ALL=C chroot "$rootfs_dir" dpkg-query -W \
    -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Architecture}\n' |
    LC_ALL=C awk -F '\t' '$1 == "ii " { print $2 "\t" $3 "\t" $4 }' |
    LC_ALL=C sort -u > "$output"
  [ -s "$output" ] || ci_die 'bootstrap package inventory is empty'
  while IFS=$'\t' read -r package version architecture; do
    [[ $package =~ ^[A-Za-z0-9][A-Za-z0-9+.:_-]{0,127}$ ]] ||
      ci_die 'unsafe bootstrap package name'
    [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]{0,255}$ ]] ||
      ci_die 'unsafe bootstrap package version'
    [[ $architecture =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
      ci_die 'unsafe bootstrap package architecture'
    count=$((count + 1))
    [ "$count" -le "$MAX_APT_AUTO_PACKAGES" ] ||
      ci_die 'too many bootstrap packages'
  done < "$output"
}

validate_bootstrap_metadata() {
  [[ $debootstrap_version =~ ^[A-Za-z0-9.+:~_-]{1,255}$ ]] ||
    ci_die 'invalid debootstrap version for bootstrap provenance'
  validate_hash "$debootstrap_sha256"
  [[ $bootstrap_distro =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
    ci_die 'invalid bootstrap distribution'
  [[ $bootstrap_arch =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
    ci_die 'invalid bootstrap architecture'
  [[ $bootstrap_variant = default ||
     $bootstrap_variant =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
    ci_die 'invalid bootstrap variant'
  ci_validate_https_apt_uri "$bootstrap_mirror"
}

write_bootstrap_file() {
  local temp_dir output_tmp sources_tmp keyrings_tmp configs_tmp preferences_tmp
  local indexes_tmp packages_tmp

  validate_bootstrap_metadata
  mkdir -p "$(dirname -- "$bootstrap_output")"
  temp_dir=$(mktemp -d "${bootstrap_output}.stage.XXXXXX")
  output_tmp="$temp_dir/bootstrap.tsv"
  sources_tmp="$temp_dir/sources.tsv"
  keyrings_tmp="$temp_dir/keyrings.tsv"
  configs_tmp="$temp_dir/configs.tsv"
  preferences_tmp="$temp_dir/preferences.tsv"
  indexes_tmp="$temp_dir/indexes.tsv"
  packages_tmp="$temp_dir/packages.tsv"
  trap 'rm -rf -- "$temp_dir"' RETURN

  collect_final_sources "$sources_tmp"
  sed -i 's/^/bootstrap-/' "$sources_tmp"
  collect_final_keyrings "$keyrings_tmp"
  sed -i 's/^final-/bootstrap-/' "$keyrings_tmp"
  collect_final_apt_configs "$configs_tmp"
  sed -i 's/^final-/bootstrap-/' "$configs_tmp"
  collect_final_preferences "$preferences_tmp"
  sed -i 's/^final-/bootstrap-/' "$preferences_tmp"
  collect_bootstrap_indexes "$indexes_tmp"
  collect_bootstrap_packages "$packages_tmp"

  {
    printf 'schema\ttb321fu.apt-bootstrap/v1\n'
    printf 'timestamp\t%s\n' "$SOURCE_DATE_EPOCH"
    printf 'debootstrap-version\t%s\n' "$debootstrap_version"
    printf 'debootstrap-binary-sha256\t%s\n' "$debootstrap_sha256"
    printf 'bootstrap-distro\t%s\n' "$bootstrap_distro"
    printf 'bootstrap-arch\t%s\n' "$bootstrap_arch"
    printf 'bootstrap-variant\t%s\n' "$bootstrap_variant"
    printf 'bootstrap-mirror\t%s\n' "$bootstrap_mirror"
    printf 'bootstrap-sources-sha256\t%s\n' "$(sha256sum "$sources_tmp" | awk '{print $1}')"
    printf 'bootstrap-keyrings-sha256\t%s\n' "$(sha256sum "$keyrings_tmp" | awk '{print $1}')"
    printf 'bootstrap-apt-configs-sha256\t%s\n' "$(sha256sum "$configs_tmp" | awk '{print $1}')"
    printf 'bootstrap-preferences-sha256\t%s\n' "$(sha256sum "$preferences_tmp" | awk '{print $1}')"
    printf 'bootstrap-indexes-sha256\t%s\n' "$(sha256sum "$indexes_tmp" | awk '{print $1}')"
    printf 'bootstrap-packages-sha256\t%s\n' "$(sha256sum "$packages_tmp" | awk '{print $1}')"
    cat "$sources_tmp"
    cat "$keyrings_tmp"
    cat "$configs_tmp"
    cat "$preferences_tmp"
    cat "$indexes_tmp"
    while IFS=$'\t' read -r package version architecture; do
      printf 'bootstrap-package\t%s\t%s\t%s\n' "$package" "$version" "$architecture"
    done < "$packages_tmp"
  } > "$output_tmp"
  chmod 0600 "$output_tmp"
  touch -d "@$SOURCE_DATE_EPOCH" "$output_tmp"
  mv -f -- "$output_tmp" "$bootstrap_output"
  trap - RETURN
  rm -rf -- "$temp_dir"
}

validate_bootstrap_file() {
  local file=$1
  local line= tag= a= b= c= d= e= extra=
  local schema=0 timestamp=0 debootstrap_version_seen=0 debootstrap_sha_seen=0
  local distro_seen=0 arch_seen=0 variant_seen=0 mirror_seen=0
  local sources_seen=0 keyrings_seen=0 configs_seen=0 preferences_seen=0 indexes_seen=0 packages_seen=0
  local source_count=0 keyring_count=0 config_count=0 preference_count=0 index_count=0 package_count=0
  local previous_source= previous_keyring= previous_config= previous_preference= previous_index= previous_package=
  local sources_digest= keyrings_digest= configs_digest= preferences_digest= indexes_digest= packages_digest=

  validate_regular_file_size "$file" 'bootstrap provenance record' 8388608
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line != *$'\r'* && $line != *[!$'\t'[:print:]]* ]] ||
      ci_die 'bootstrap provenance record has unsafe characters'
    IFS=$'\t' read -r tag a b c d e extra <<< "$line"
    case "$tag" in
      schema)
        [ "$line" = $'schema\ttb321fu.apt-bootstrap/v1' ] && [ "$schema" -eq 0 ] ||
          ci_die 'invalid bootstrap provenance schema'
        schema=1
        ;;
      timestamp)
        [[ $a =~ ^[0-9]{1,10}$ ]] && [ "$a" = "$SOURCE_DATE_EPOCH" ] && [ -z "$b" ] &&
          [ "$timestamp" -eq 0 ] || ci_die 'invalid bootstrap provenance timestamp'
        timestamp=1
        ;;
      debootstrap-version)
        [[ $a =~ ^[A-Za-z0-9.+:~_-]{1,255}$ ]] && [ -z "$b" ] &&
          [ "$debootstrap_version_seen" -eq 0 ] || ci_die 'invalid bootstrap debootstrap version'
        debootstrap_version_seen=1
        ;;
      debootstrap-binary-sha256)
        [ -z "$b" ] && [ "$debootstrap_sha_seen" -eq 0 ] ||
          ci_die 'invalid bootstrap debootstrap digest'
        validate_hash "$a"
        debootstrap_sha_seen=1
        ;;
      bootstrap-distro)
        [[ $a =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && [ -z "$b" ] &&
          [ "$distro_seen" -eq 0 ] || ci_die 'invalid bootstrap distribution'
        distro_seen=1
        ;;
      bootstrap-arch)
        [[ $a =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && [ -z "$b" ] &&
          [ "$arch_seen" -eq 0 ] || ci_die 'invalid bootstrap architecture'
        arch_seen=1
        ;;
      bootstrap-variant)
        [[ $a = default || $a =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && [ -z "$b" ] &&
          [ "$variant_seen" -eq 0 ] || ci_die 'invalid bootstrap variant'
        variant_seen=1
        ;;
      bootstrap-mirror)
        [ -z "$b" ] && [ "$mirror_seen" -eq 0 ] ||
          ci_die 'invalid bootstrap mirror'
        ci_validate_https_apt_uri "$a"
        mirror_seen=1
        ;;
      bootstrap-sources-sha256|bootstrap-keyrings-sha256|bootstrap-apt-configs-sha256|bootstrap-preferences-sha256|bootstrap-indexes-sha256|bootstrap-packages-sha256)
        [ -z "$b" ] || ci_die 'malformed bootstrap provenance digest record'
        validate_hash "$a"
        case "$tag" in
          bootstrap-sources-sha256)
            [ "$sources_seen" -eq 0 ] || ci_die 'duplicate bootstrap source digest'
            sources_seen=1
            sources_digest=$a
            ;;
          bootstrap-keyrings-sha256)
            [ "$keyrings_seen" -eq 0 ] || ci_die 'duplicate bootstrap keyring digest'
            keyrings_seen=1
            keyrings_digest=$a
            ;;
          bootstrap-apt-configs-sha256)
            [ "$configs_seen" -eq 0 ] || ci_die 'duplicate bootstrap APT config digest'
            configs_seen=1
            configs_digest=$a
            ;;
          bootstrap-preferences-sha256)
            [ "$preferences_seen" -eq 0 ] || ci_die 'duplicate bootstrap preference digest'
            preferences_seen=1
            preferences_digest=$a
            ;;
          bootstrap-indexes-sha256)
            [ "$indexes_seen" -eq 0 ] || ci_die 'duplicate bootstrap index digest'
            indexes_seen=1
            indexes_digest=$a
            ;;
          bootstrap-packages-sha256)
            [ "$packages_seen" -eq 0 ] || ci_die 'duplicate bootstrap package digest'
            packages_seen=1
            packages_digest=$a
            ;;
        esac
        ;;
      bootstrap-source)
        validate_source_relative "$a"
        [[ $b = deb || $b = deb-src ]] || ci_die 'invalid bootstrap APT source type'
        ci_validate_https_apt_uri "$c"
        [[ $d =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
          ci_die 'invalid bootstrap APT suite'
        [[ $e =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}(,[A-Za-z0-9][A-Za-z0-9._-]{0,127})*$ ]] ||
          ci_die 'invalid bootstrap APT component list'
        validate_hash "$extra"
        [ -z "$previous_source" ] || [[ $line > $previous_source ]] ||
          ci_die 'bootstrap APT source records are not ordered'
        previous_source=$line
        source_count=$((source_count + 1))
        ;;
      bootstrap-keyring)
        [ -z "$d" ] && [ -z "$e" ] && [ -z "$extra" ] ||
          ci_die 'malformed bootstrap keyring evidence record'
        validate_keyring_relative "$a"
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid bootstrap keyring evidence size'
        validate_hash "$c"
        [ -z "$previous_keyring" ] || [[ $line > $previous_keyring ]] ||
          ci_die 'bootstrap keyring evidence records are not ordered'
        previous_keyring=$line
        keyring_count=$((keyring_count + 1))
        ;;
      bootstrap-apt-config)
        [ -z "$d" ] && [ -z "$e" ] && [ -z "$extra" ] ||
          ci_die 'malformed bootstrap APT config evidence record'
        validate_apt_config_relative "$a"
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid bootstrap APT config evidence size'
        validate_hash "$c"
        [ -z "$previous_config" ] || [[ $line > $previous_config ]] ||
          ci_die 'bootstrap APT config evidence records are not ordered'
        previous_config=$line
        config_count=$((config_count + 1))
        ;;
      bootstrap-preference)
        [ -z "$d" ] && [ -z "$e" ] && [ -z "$extra" ] ||
          ci_die 'malformed bootstrap APT preference evidence record'
        validate_preference_relative "$a"
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid bootstrap APT preference evidence size'
        validate_hash "$c"
        [ -z "$previous_preference" ] || [[ $line > $previous_preference ]] ||
          ci_die 'bootstrap APT preference evidence records are not ordered'
        previous_preference=$line
        preference_count=$((preference_count + 1))
        ;;
      bootstrap-index)
        [ -z "$d" ] && [ -z "$e" ] && [ -z "$extra" ] ||
          ci_die 'malformed bootstrap APT index record'
        [[ $a =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
          ci_die 'invalid bootstrap APT index filename'
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid bootstrap APT index size'
        validate_hash "$c"
        [ -z "$previous_index" ] || [[ $line > $previous_index ]] ||
          ci_die 'bootstrap APT index records are not ordered'
        previous_index=$line
        index_count=$((index_count + 1))
        ;;
      bootstrap-package)
        [ -z "$d" ] && [ -z "$e" ] && [ -z "$extra" ] ||
          ci_die 'malformed bootstrap package record'
        [[ $a =~ ^[A-Za-z0-9][A-Za-z0-9+.:_-]{0,127}$ ]] ||
          ci_die 'invalid bootstrap package name'
        [[ $b =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]{0,255}$ ]] ||
          ci_die 'invalid bootstrap package version'
        [[ $c =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
          ci_die 'invalid bootstrap package architecture'
        [ -z "$previous_package" ] || [[ $line > $previous_package ]] ||
          ci_die 'bootstrap package records are not ordered'
        previous_package=$line
        package_count=$((package_count + 1))
        ;;
      *) ci_die 'unsupported bootstrap provenance record type' ;;
    esac
  done < "$file"

  [ "$schema" -eq 1 ] && [ "$timestamp" -eq 1 ] &&
    [ "$debootstrap_version_seen" -eq 1 ] && [ "$debootstrap_sha_seen" -eq 1 ] &&
    [ "$distro_seen" -eq 1 ] && [ "$arch_seen" -eq 1 ] &&
    [ "$variant_seen" -eq 1 ] && [ "$mirror_seen" -eq 1 ] &&
    [ "$sources_seen" -eq 1 ] && [ "$keyrings_seen" -eq 1 ] &&
    [ "$configs_seen" -eq 1 ] && [ "$preferences_seen" -eq 1 ] &&
    [ "$indexes_seen" -eq 1 ] && [ "$packages_seen" -eq 1 ] &&
    [ "$source_count" -gt 0 ] && [ "$keyring_count" -gt 0 ] &&
    [ "$package_count" -gt 0 ] ||
    ci_die 'bootstrap provenance record is incomplete'
  [ "$(record_group_digest "$file" bootstrap-source)" = "$sources_digest" ] ||
    ci_die 'bootstrap source digest does not match provenance records'
  [ "$(record_group_digest "$file" bootstrap-keyring)" = "$keyrings_digest" ] ||
    ci_die 'bootstrap keyring digest does not match provenance records'
  [ "$(record_group_digest "$file" bootstrap-apt-config)" = "$configs_digest" ] ||
    ci_die 'bootstrap APT config digest does not match provenance records'
  [ "$(record_group_digest "$file" bootstrap-preference)" = "$preferences_digest" ] ||
    ci_die 'bootstrap preference digest does not match provenance records'
  [ "$(record_group_digest "$file" bootstrap-index)" = "$indexes_digest" ] ||
    ci_die 'bootstrap index digest does not match provenance records'
  [ "$(record_group_digest "$file" bootstrap-package)" = "$packages_digest" ] ||
    ci_die 'bootstrap package digest does not match provenance records'
}

record_group_digest() {
  local file=$1 group=$2

  case "$group" in
    pre-source|post-source|index|pre-keyring|post-keyring|pre-apt-config|post-apt-config|pre-preference|post-preference|pre-auto-package|post-auto-package|pre-extended-state|post-extended-state|apt-mark-auto|bootstrap-source|bootstrap-keyring|bootstrap-apt-config|bootstrap-preference|bootstrap-index)
      awk -F '\t' -v group="$group" '$1 == group { print }' "$file" |
        sort | sha256sum | awk '{print $1}'
      ;;
    package)
      awk -F '\t' '$1 == "package" { print $2 "\t" $3 "\t" $4 }' "$file" |
        sort | sha256sum | awk '{print $1}'
      ;;
    bootstrap-package)
      awk -F '\t' '$1 == "bootstrap-package" { print $2 "\t" $3 "\t" $4 }' "$file" |
        sort | sha256sum | awk '{print $1}'
      ;;
    *) ci_die 'unsupported APT provenance digest group' ;;
  esac
}

validate_transaction_file() {
  local file=$1 expected_id=$2 expected_phase=$3 expected_operation=$4
  local line tag a b c d e extra
  local schema=0 transaction=0 timestamp=0 phase=0 operation=0 request=0 indexes=0 packages=0
  local pre_sources=0 pre_keyrings=0 pre_configs=0 pre_preferences=0 pre_auto=0 pre_extended=0
  local post_sources=0 post_keyrings=0 post_configs=0 post_preferences=0 post_auto=0 post_extended=0
  local mark_auto_inputs=0
  local pre_source_count=0 pre_keyring_count=0 pre_config_count=0 pre_preference_count=0
  local post_source_count=0 post_keyring_count=0 post_config_count=0 post_preference_count=0
  local pre_auto_count=0 post_auto_count=0 pre_extended_count=0 post_extended_count=0
  local index_count=0 package_count=0 mark_auto_input_count=0
  local previous_pre_source= previous_pre_keyring= previous_pre_config= previous_pre_preference=
  local previous_post_source= previous_post_keyring= previous_post_config= previous_post_preference=
  local previous_pre_auto= previous_post_auto= previous_mark_auto=
  local previous_index= previous_package=
  local pre_sources_digest= pre_keyrings_digest= pre_configs_digest= pre_preferences_digest=
  local pre_auto_digest= pre_extended_digest=
  local post_sources_digest= post_keyrings_digest= post_configs_digest= post_preferences_digest=
  local post_auto_digest= post_extended_digest= mark_auto_inputs_digest=
  local indexes_digest= packages_digest=

  [ -f "$file" ] && [ ! -L "$file" ] ||
    ci_die 'APT transaction record is not a regular file'
  [ "$(stat -c '%s' -- "$file")" -le 8388608 ] ||
    ci_die 'APT transaction record is too large'

  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line != *$'\r'* && $line != *[!$'\t'[:print:]]* ]] ||
      ci_die 'APT transaction record has unsafe characters'
    IFS=$'\t' read -r tag a b c d e extra <<< "$line"
    case "$tag" in
      schema)
        [ "$line" = $'schema\ttb321fu.apt-transaction/v3' ] &&
          [ "$schema" -eq 0 ] || ci_die 'invalid APT transaction schema'
        schema=1
        ;;
      transaction)
        [ -z "${b:-}" ] && [ "$a" = "$expected_id" ] &&
          [ "$transaction" -eq 0 ] || ci_die 'invalid APT transaction identifier'
        transaction=1
        ;;
      timestamp)
        [[ ${a:-} =~ ^[0-9]{1,10}$ ]] && [ "$a" = "$SOURCE_DATE_EPOCH" ] && [ -z "${b:-}" ] &&
          [ "$timestamp" -eq 0 ] || ci_die 'invalid APT transaction timestamp'
        timestamp=1
        ;;
      phase)
        [ -z "${b:-}" ] && [ "$a" = "$expected_phase" ] &&
          [ "$phase" -eq 0 ] || ci_die 'invalid APT transaction phase'
        phase=1
        ;;
      operation)
        [ -z "${b:-}" ] && [ "$a" = "$expected_operation" ] &&
          [ "$operation" -eq 0 ] || ci_die 'invalid APT transaction operation'
        operation=1
        ;;
      request-sha256|pre-sources-sha256|pre-keyrings-sha256|pre-apt-configs-sha256|pre-preferences-sha256|pre-auto-packages-sha256|pre-extended-states-sha256|post-sources-sha256|indexes-sha256|post-keyrings-sha256|post-apt-configs-sha256|post-preferences-sha256|post-auto-packages-sha256|post-extended-states-sha256|mark-auto-inputs-sha256|packages-sha256)
        [ -z "${b:-}" ] || ci_die 'malformed APT transaction digest record'
        validate_hash "$a"
        case "$tag" in
          request-sha256)
            [ "$request" -eq 0 ] || ci_die 'duplicate APT request digest'
            request=1
            ;;
          pre-sources-sha256)
            [ "$pre_sources" -eq 0 ] || ci_die 'duplicate pre-APT source digest'
            pre_sources=1
            pre_sources_digest=$a
            ;;
          pre-keyrings-sha256)
            [ "$pre_keyrings" -eq 0 ] || ci_die 'duplicate pre-APT keyring digest'
            pre_keyrings=1
            pre_keyrings_digest=$a
            ;;
          pre-apt-configs-sha256)
            [ "$pre_configs" -eq 0 ] || ci_die 'duplicate pre-APT config digest'
            pre_configs=1
            pre_configs_digest=$a
            ;;
          pre-preferences-sha256)
            [ "$pre_preferences" -eq 0 ] || ci_die 'duplicate pre-APT preference digest'
            pre_preferences=1
            pre_preferences_digest=$a
            ;;
          pre-auto-packages-sha256)
            [ "$pre_auto" -eq 0 ] || ci_die 'duplicate pre-APT auto package digest'
            pre_auto=1
            pre_auto_digest=$a
            ;;
          pre-extended-states-sha256)
            [ "$pre_extended" -eq 0 ] || ci_die 'duplicate pre-APT extended_states digest'
            pre_extended=1
            pre_extended_digest=$a
            ;;
          post-sources-sha256)
            [ "$post_sources" -eq 0 ] || ci_die 'duplicate post-APT source digest'
            post_sources=1
            post_sources_digest=$a
            ;;
          indexes-sha256)
            [ "$indexes" -eq 0 ] || ci_die 'duplicate APT index digest'
            indexes=1
            indexes_digest=$a
            ;;
          post-keyrings-sha256)
            [ "$post_keyrings" -eq 0 ] || ci_die 'duplicate post-APT keyring digest'
            post_keyrings=1
            post_keyrings_digest=$a
            ;;
          post-apt-configs-sha256)
            [ "$post_configs" -eq 0 ] || ci_die 'duplicate post-APT config digest'
            post_configs=1
            post_configs_digest=$a
            ;;
          post-preferences-sha256)
            [ "$post_preferences" -eq 0 ] || ci_die 'duplicate post-APT preference digest'
            post_preferences=1
            post_preferences_digest=$a
            ;;
          post-auto-packages-sha256)
            [ "$post_auto" -eq 0 ] || ci_die 'duplicate post-APT auto package digest'
            post_auto=1
            post_auto_digest=$a
            ;;
          post-extended-states-sha256)
            [ "$post_extended" -eq 0 ] || ci_die 'duplicate post-APT extended_states digest'
            post_extended=1
            post_extended_digest=$a
            ;;
          mark-auto-inputs-sha256)
            [ "$mark_auto_inputs" -eq 0 ] || ci_die 'duplicate apt-mark auto input digest'
            mark_auto_inputs=1
            mark_auto_inputs_digest=$a
            ;;
          packages-sha256)
            [ "$packages" -eq 0 ] || ci_die 'duplicate APT package digest'
            packages=1
            packages_digest=$a
            ;;
        esac
        ;;
      pre-source|post-source)
        validate_source_relative "$a"
        [[ $b = deb || $b = deb-src ]] ||
          ci_die 'invalid sanitized APT source type'
        ci_validate_https_apt_uri "$c"
        [[ $d =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
          ci_die 'invalid sanitized APT suite'
        [[ $e =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}(,[A-Za-z0-9][A-Za-z0-9._-]{0,127})*$ ]] ||
          ci_die 'invalid sanitized APT component list'
        validate_hash "$extra"
        if [ "$tag" = pre-source ]; then
          [ -z "$previous_pre_source" ] || [[ $line > $previous_pre_source ]] ||
            ci_die 'pre-APT source records are not ordered'
          previous_pre_source=$line
          pre_source_count=$((pre_source_count + 1))
        else
          [ -z "$previous_post_source" ] || [[ $line > $previous_post_source ]] ||
            ci_die 'post-APT source records are not ordered'
          previous_post_source=$line
          post_source_count=$((post_source_count + 1))
        fi
        ;;
      index)
        [ -z "${d:-}" ] && [ -z "${e:-}" ] && [ -z "${extra:-}" ] ||
          ci_die 'malformed APT index record'
        [[ $a =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$ ]] ||
          ci_die 'invalid APT index filename'
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid APT index size'
        validate_hash "$c"
        [ -z "$previous_index" ] || [[ $line > $previous_index ]] ||
          ci_die 'APT index records are not ordered'
        previous_index=$line
        index_count=$((index_count + 1))
        ;;
      pre-keyring|post-keyring)
        [ -z "${d:-}" ] && [ -z "${e:-}" ] && [ -z "${extra:-}" ] ||
          ci_die 'malformed APT keyring evidence record'
        validate_keyring_relative "$a"
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid APT keyring evidence size'
        validate_hash "$c"
        if [ "$tag" = pre-keyring ]; then
          [ -z "$previous_pre_keyring" ] || [[ $line > $previous_pre_keyring ]] ||
            ci_die 'pre-APT keyring evidence records are not ordered'
          previous_pre_keyring=$line
          pre_keyring_count=$((pre_keyring_count + 1))
        else
          [ -z "$previous_post_keyring" ] || [[ $line > $previous_post_keyring ]] ||
            ci_die 'post-APT keyring evidence records are not ordered'
          previous_post_keyring=$line
          post_keyring_count=$((post_keyring_count + 1))
        fi
        ;;
      pre-apt-config|post-apt-config)
        [ -z "${d:-}" ] && [ -z "${e:-}" ] && [ -z "${extra:-}" ] ||
          ci_die 'malformed APT config evidence record'
        validate_apt_config_relative "$a"
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid APT config evidence size'
        validate_hash "$c"
        if [ "$tag" = pre-apt-config ]; then
          [ -z "$previous_pre_config" ] || [[ $line > $previous_pre_config ]] ||
            ci_die 'pre-APT config evidence records are not ordered'
          previous_pre_config=$line
          pre_config_count=$((pre_config_count + 1))
        else
          [ -z "$previous_post_config" ] || [[ $line > $previous_post_config ]] ||
            ci_die 'post-APT config evidence records are not ordered'
          previous_post_config=$line
          post_config_count=$((post_config_count + 1))
        fi
        ;;
      pre-preference|post-preference)
        [ -z "${d:-}" ] && [ -z "${e:-}" ] && [ -z "${extra:-}" ] ||
          ci_die 'malformed APT preference evidence record'
        validate_preference_relative "$a"
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid APT preference evidence size'
        validate_hash "$c"
        if [ "$tag" = pre-preference ]; then
          [ -z "$previous_pre_preference" ] || [[ $line > $previous_pre_preference ]] ||
            ci_die 'pre-APT preference evidence records are not ordered'
          previous_pre_preference=$line
          pre_preference_count=$((pre_preference_count + 1))
        else
          [ -z "$previous_post_preference" ] || [[ $line > $previous_post_preference ]] ||
            ci_die 'post-APT preference evidence records are not ordered'
          previous_post_preference=$line
          post_preference_count=$((post_preference_count + 1))
        fi
        ;;
      pre-auto-package|post-auto-package|apt-mark-auto)
        [ -z "${b:-}" ] && [ -z "${c:-}" ] && [ -z "${d:-}" ] &&
          [ -z "${e:-}" ] && [ -z "${extra:-}" ] ||
          ci_die 'malformed APT solver package record'
        [[ $a =~ ^[a-z0-9][a-z0-9+.-]{0,127}(:[a-z0-9][a-z0-9+.-]{0,31})?$ ]] ||
          ci_die 'invalid APT solver package name'
        case "$tag" in
          pre-auto-package)
            [ -z "$previous_pre_auto" ] || [[ $line > $previous_pre_auto ]] ||
              ci_die 'pre-APT auto package records are not ordered'
            previous_pre_auto=$line
            pre_auto_count=$((pre_auto_count + 1))
            ;;
          post-auto-package)
            [ -z "$previous_post_auto" ] || [[ $line > $previous_post_auto ]] ||
              ci_die 'post-APT auto package records are not ordered'
            previous_post_auto=$line
            post_auto_count=$((post_auto_count + 1))
            ;;
          apt-mark-auto)
            [ -z "$previous_mark_auto" ] || [[ $line > $previous_mark_auto ]] ||
              ci_die 'apt-mark auto input records are not ordered'
            previous_mark_auto=$line
            mark_auto_input_count=$((mark_auto_input_count + 1))
            ;;
        esac
        ;;
      pre-extended-state|post-extended-state)
        [ -z "${d:-}" ] && [ -z "${e:-}" ] && [ -z "${extra:-}" ] ||
          ci_die 'malformed APT extended_states evidence record'
        [ "$a" = var/lib/apt/extended_states ] ||
          ci_die 'invalid APT extended_states evidence path'
        [[ $b =~ ^[0-9]+$ ]] || ci_die 'invalid APT extended_states evidence size'
        validate_hash "$c"
        if [ "$tag" = pre-extended-state ]; then
          [ "$pre_extended_count" -eq 0 ] ||
            ci_die 'duplicate pre-APT extended_states evidence record'
          pre_extended_count=1
        else
          [ "$post_extended_count" -eq 0 ] ||
            ci_die 'duplicate post-APT extended_states evidence record'
          post_extended_count=1
        fi
        ;;
      package)
        [ -z "${d:-}" ] && [ -z "${e:-}" ] && [ -z "${extra:-}" ] ||
          ci_die 'malformed installed package record'
        [[ $a =~ ^[A-Za-z0-9][A-Za-z0-9+.:_-]{0,127}$ ]] ||
          ci_die 'invalid installed package name'
        [[ $b =~ ^[A-Za-z0-9][A-Za-z0-9+.:~_-]{0,255}$ ]] ||
          ci_die 'invalid installed package version'
        [[ $c =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
          ci_die 'invalid installed package architecture'
        [ -z "$previous_package" ] || [[ $line > $previous_package ]] ||
          ci_die 'installed package records are not ordered'
        previous_package=$line
        package_count=$((package_count + 1))
        ;;
      local-deb)
        [ -z "${c:-}" ] && [ -z "${d:-}" ] && [ -z "${e:-}" ] &&
          [ -z "${extra:-}" ] || ci_die 'malformed local APT package record'
        [[ $a =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}\.deb$ ]] ||
          ci_die 'invalid local APT package filename'
        validate_hash "$b"
        ;;
      *) ci_die 'unsupported APT transaction record type' ;;
    esac
  done < "$file"

  [ "$schema" -eq 1 ] && [ "$transaction" -eq 1 ] &&
    [ "$timestamp" -eq 1 ] && [ "$phase" -eq 1 ] &&
    [ "$operation" -eq 1 ] && [ "$request" -eq 1 ] &&
    [ "$pre_sources" -eq 1 ] && [ "$pre_keyrings" -eq 1 ] &&
    [ "$pre_configs" -eq 1 ] && [ "$pre_preferences" -eq 1 ] &&
    [ "$pre_auto" -eq 1 ] && [ "$pre_extended" -eq 1 ] &&
    [ "$post_sources" -eq 1 ] &&
    [ "$indexes" -eq 1 ] && [ "$post_keyrings" -eq 1 ] &&
    [ "$post_configs" -eq 1 ] && [ "$post_preferences" -eq 1 ] &&
    [ "$post_auto" -eq 1 ] && [ "$post_extended" -eq 1 ] &&
    [ "$mark_auto_inputs" -eq 1 ] && [ "$packages" -eq 1 ] &&
    [ "$pre_source_count" -gt 0 ] && [ "$pre_keyring_count" -gt 0 ] &&
    [ "$pre_config_count" -gt 0 ] && [ "$post_source_count" -gt 0 ] &&
    [ "$index_count" -gt 0 ] && [ "$post_keyring_count" -gt 0 ] &&
    [ "$post_config_count" -gt 0 ] && [ "$pre_extended_count" -eq 1 ] &&
    [ "$post_extended_count" -eq 1 ] && [ "$package_count" -gt 0 ] ||
    ci_die 'APT transaction record is incomplete'
  if [ "$expected_operation" = mark-auto ]; then
    [ "$mark_auto_input_count" -gt 0 ] ||
      ci_die 'apt-mark auto transaction has no package inputs'
  else
    [ "$mark_auto_input_count" -eq 0 ] ||
      ci_die 'non-apt-mark transaction contains apt-mark auto package inputs'
  fi
  [ "$(record_group_digest "$file" pre-source)" = "$pre_sources_digest" ] ||
    ci_die 'pre-APT source digest does not match transaction records'
  [ "$(record_group_digest "$file" pre-keyring)" = "$pre_keyrings_digest" ] ||
    ci_die 'pre-APT keyring digest does not match transaction records'
  [ "$(record_group_digest "$file" pre-apt-config)" = "$pre_configs_digest" ] ||
    ci_die 'pre-APT config digest does not match transaction records'
  [ "$(record_group_digest "$file" pre-preference)" = "$pre_preferences_digest" ] ||
    ci_die 'pre-APT preference digest does not match transaction records'
  [ "$(record_group_digest "$file" pre-auto-package)" = "$pre_auto_digest" ] ||
    ci_die 'pre-APT auto package digest does not match transaction records'
  [ "$(record_group_digest "$file" pre-extended-state)" = "$pre_extended_digest" ] ||
    ci_die 'pre-APT extended_states digest does not match transaction records'
  [ "$(record_group_digest "$file" post-source)" = "$post_sources_digest" ] ||
    ci_die 'post-APT source digest does not match transaction records'
  [ "$(record_group_digest "$file" index)" = "$indexes_digest" ] ||
    ci_die 'APT index digest does not match transaction records'
  [ "$(record_group_digest "$file" post-keyring)" = "$post_keyrings_digest" ] ||
    ci_die 'post-APT keyring digest does not match transaction records'
  [ "$(record_group_digest "$file" post-apt-config)" = "$post_configs_digest" ] ||
    ci_die 'post-APT config digest does not match transaction records'
  [ "$(record_group_digest "$file" post-preference)" = "$post_preferences_digest" ] ||
    ci_die 'post-APT preference digest does not match transaction records'
  [ "$(record_group_digest "$file" post-auto-package)" = "$post_auto_digest" ] ||
    ci_die 'post-APT auto package digest does not match transaction records'
  [ "$(record_group_digest "$file" post-extended-state)" = "$post_extended_digest" ] ||
    ci_die 'post-APT extended_states digest does not match transaction records'
  [ "$(record_group_digest "$file" apt-mark-auto)" = "$mark_auto_inputs_digest" ] ||
    ci_die 'apt-mark auto input digest does not match transaction records'
  [ "$(record_group_digest "$file" package)" = "$packages_digest" ] ||
    ci_die 'APT package digest does not match transaction records'
}

if [ "$mode" = capture-bootstrap ]; then
  write_bootstrap_file
  validate_bootstrap_file "$bootstrap_output"
  exit 0
fi

validate_bootstrap_file "$bootstrap_input"

mapfile -d '' -t records < <(
  find -P "$transaction_dir" -mindepth 1 -maxdepth 1 -type f -name '*.tsv' -print0 |
    sort -z
)
[ "${#records[@]}" -gt 0 ] || ci_die 'APT provenance has no transaction records'
[ -z "$(find -P "$transaction_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] ||
  ci_die 'APT provenance transaction directory contains a symlink'

expected_number=1
for record in "${records[@]}"; do
  basename=$(basename -- "$record")
  [[ $basename =~ ^([0-9]{4})-([a-z][a-z0-9-]{0,63})-(update|install|purge|autoremove|mark-auto)\.tsv$ ]] ||
    ci_die 'unsafe APT transaction filename'
  expected_id=$(printf '%04d' "$expected_number")
  [ "${BASH_REMATCH[1]}" = "$expected_id" ] ||
    ci_die 'APT transaction identifiers are not contiguous'
  expected_phase=${BASH_REMATCH[2]}
  expected_operation=${BASH_REMATCH[3]}
  validate_transaction_file "$record" "$expected_id" "$expected_phase" "$expected_operation"
  expected_number=$((expected_number + 1))
done

mkdir -p "$(dirname -- "$provenance_output")" "$(dirname -- "$sources_output")"
provenance_tmp=$(mktemp "${provenance_output}.tmp.XXXXXX")
sources_tmp=$(mktemp "${sources_output}.tmp.XXXXXX")
current_sources_tmp=$(mktemp "${sources_output}.current.XXXXXX")
final_keyrings_tmp=$(mktemp "${sources_output}.keyrings.XXXXXX")
final_configs_tmp=$(mktemp "${sources_output}.configs.XXXXXX")
final_preferences_tmp=$(mktemp "${sources_output}.preferences.XXXXXX")
final_auto_packages_tmp=$(mktemp "${sources_output}.auto-packages.XXXXXX")
final_extended_states_tmp=$(mktemp "${sources_output}.extended-states.XXXXXX")
cleanup() {
  rm -f -- "$provenance_tmp" "$sources_tmp" \
    "$current_sources_tmp" "$final_keyrings_tmp" "$final_configs_tmp" \
    "$final_preferences_tmp" "$final_auto_packages_tmp" "$final_extended_states_tmp"
}
trap cleanup EXIT INT TERM

collect_final_sources "$current_sources_tmp"
validate_final_keyring_and_config_layout
collect_final_keyrings "$final_keyrings_tmp"
collect_final_apt_configs "$final_configs_tmp"
collect_final_preferences "$final_preferences_tmp"
collect_final_auto_packages "$final_auto_packages_tmp"
collect_final_extended_states "$final_extended_states_tmp"

{
  printf 'schema\ttb321fu.apt-provenance/v3\n'
  printf 'bootstrap-provenance-sha256\t%s\n' "$(sha256sum "$bootstrap_input" | awk '{print $1}')"
  printf 'transaction-count\t%s\n' "${#records[@]}"
  for record in "${records[@]}"; do
    cat "$record"
  done
  printf 'final-sources-sha256\t%s\n' "$(sha256sum "$current_sources_tmp" | awk '{print $1}')"
  printf 'final-keyrings-sha256\t%s\n' "$(sha256sum "$final_keyrings_tmp" | awk '{print $1}')"
  printf 'final-apt-configs-sha256\t%s\n' "$(sha256sum "$final_configs_tmp" | awk '{print $1}')"
  printf 'final-preferences-sha256\t%s\n' "$(sha256sum "$final_preferences_tmp" | awk '{print $1}')"
  printf 'final-auto-packages-sha256\t%s\n' \
    "$(sed 's/^/final-auto-package\t/' "$final_auto_packages_tmp" | sha256sum | awk '{print $1}')"
  printf 'final-extended-states-sha256\t%s\n' \
    "$(sha256sum "$final_extended_states_tmp" | awk '{print $1}')"
  sed 's/^/final-/' "$current_sources_tmp"
  cat "$final_keyrings_tmp"
  cat "$final_configs_tmp"
  cat "$final_preferences_tmp"
  sed 's/^/final-auto-package\t/' "$final_auto_packages_tmp"
  cat "$final_extended_states_tmp"
} > "$provenance_tmp"
{
  printf 'schema\ttb321fu.apt-sources/v1\n'
  cat "$current_sources_tmp"
} > "$sources_tmp"

chmod 0644 "$provenance_tmp" "$sources_tmp"
touch -d "@$SOURCE_DATE_EPOCH" "$provenance_tmp" "$sources_tmp"
mv -f -- "$provenance_tmp" "$provenance_output"
mv -f -- "$sources_tmp" "$sources_output"
trap - EXIT INT TERM
