#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

readonly CANONICAL_KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY=GUF296/ubuntu-y700-build-ci

usage() {
  cat <<'EOF'
Usage: verify-kernel-bundle.sh

Required environment:
  KERNEL_ARTIFACT_ARCHIVE
  KERNEL_ARTIFACT_ARCHIVE_SHA256
  DEB_ARCHIVE
  DEB_ARCHIVE_SHA256
  SENSOR_DEB_ARCHIVE
  SENSOR_DEB_ARCHIVE_SHA256
  EXPECTED_SENSOR_PRODUCER_COMMIT
  HAPTICS_DEB_ARCHIVE and HAPTICS_DEB_ARCHIVE_SHA256,
    or HAPTICS_DEB_DIR
  EXPECTED_HAPTICS_PRODUCER_COMMIT
  EXPECTED_HAPTICS_MODULE_SHA256
  EXPECTED_HAPTICS_HELPER_BINARY_SHA256

Optional environment:
  OUTPUT_DIR       default: out/tb321fu-verified-kernel-bundle
  DTB_NAME         default: sm8650-lenovo-tb321fu.dtb
  MODINFO          test/alternate modinfo executable

The verifier stages the already-verified inputs and writes verified.env for
later rootfs/GRUB steps, avoiding duplicate downloads and extraction.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

for command in bash dash env sha256sum find sort cmp dpkg dpkg-deb realpath install awk python3 head grep stat git sed tr; do
  ci_require_cmd "$command"
done

: "${KERNEL_ARTIFACT_ARCHIVE:?set KERNEL_ARTIFACT_ARCHIVE}"
: "${KERNEL_ARTIFACT_ARCHIVE_SHA256:?set KERNEL_ARTIFACT_ARCHIVE_SHA256}"
: "${DEB_ARCHIVE:?set DEB_ARCHIVE}"
: "${DEB_ARCHIVE_SHA256:?set DEB_ARCHIVE_SHA256}"
: "${SENSOR_DEB_ARCHIVE:?set SENSOR_DEB_ARCHIVE}"
: "${SENSOR_DEB_ARCHIVE_SHA256:?set SENSOR_DEB_ARCHIVE_SHA256}"
: "${EXPECTED_SENSOR_PRODUCER_COMMIT:?set EXPECTED_SENSOR_PRODUCER_COMMIT}"
: "${EXPECTED_HAPTICS_PRODUCER_COMMIT:?set EXPECTED_HAPTICS_PRODUCER_COMMIT}"
: "${EXPECTED_HAPTICS_MODULE_SHA256:?set EXPECTED_HAPTICS_MODULE_SHA256}"
: "${EXPECTED_HAPTICS_HELPER_BINARY_SHA256:?set EXPECTED_HAPTICS_HELPER_BINARY_SHA256}"

HAPTICS_DEB_ARCHIVE=${HAPTICS_DEB_ARCHIVE:-}
HAPTICS_DEB_ARCHIVE_SHA256=${HAPTICS_DEB_ARCHIVE_SHA256:-}
HAPTICS_DEB_DIR=${HAPTICS_DEB_DIR:-}
OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-verified-kernel-bundle}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
MODINFO=${MODINFO:-modinfo}

[[ $KERNEL_ARTIFACT_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid kernel archive SHA-256"
[[ $DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid device archive SHA-256"
[[ $SENSOR_DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid sensor archive SHA-256"
[[ $EXPECTED_SENSOR_PRODUCER_COMMIT =~ ^[0-9a-f]{40}$ ]] ||
  ci_die "EXPECTED_SENSOR_PRODUCER_COMMIT must be 40 lowercase hex characters"
[[ $EXPECTED_HAPTICS_PRODUCER_COMMIT =~ ^[0-9a-f]{40}$ ]] ||
  ci_die "EXPECTED_HAPTICS_PRODUCER_COMMIT must be 40 lowercase hex characters"
[[ $EXPECTED_HAPTICS_MODULE_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
  ci_die "EXPECTED_HAPTICS_MODULE_SHA256 must be 64 lowercase hex characters"
[[ $EXPECTED_HAPTICS_HELPER_BINARY_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
  ci_die "EXPECTED_HAPTICS_HELPER_BINARY_SHA256 must be 64 lowercase hex characters"
[[ $DTB_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\.dtb$ ]] || ci_die "unsafe DTB_NAME"
if [ -n "$HAPTICS_DEB_ARCHIVE" ] && [ -n "$HAPTICS_DEB_DIR" ]; then
  ci_die "set only one of HAPTICS_DEB_ARCHIVE and HAPTICS_DEB_DIR"
fi
if [ -n "$HAPTICS_DEB_ARCHIVE" ]; then
  [[ $HAPTICS_DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid haptics archive SHA-256"
elif [ -n "$HAPTICS_DEB_DIR" ]; then
  [ -z "$HAPTICS_DEB_ARCHIVE_SHA256" ] || ci_die "HAPTICS_DEB_ARCHIVE_SHA256 is invalid with HAPTICS_DEB_DIR"
else
  ci_die "set HAPTICS_DEB_ARCHIVE or HAPTICS_DEB_DIR"
fi
if [[ $MODINFO == */* ]]; then
  [ -x "$MODINFO" ] || ci_die "MODINFO is not executable: $MODINFO"
else
  ci_require_cmd "$MODINFO"
fi

output_parent=$(dirname -- "$OUTPUT_DIR")
output_name=$(basename -- "$OUTPUT_DIR")
case "$output_name" in
  tb321fu-verified-kernel-bundle*) ;;
  *) ci_die "OUTPUT_DIR basename must start with tb321fu-verified-kernel-bundle" ;;
esac
mkdir -p "$output_parent"
output_parent=$(realpath -e -- "$output_parent")
output_path="$output_parent/$output_name"
if [ -e "$output_path" ]; then
  ci_safe_rmtree "$output_path" "$output_parent" tb321fu-verified-kernel-bundle
fi

work=$(mktemp -d "$output_parent/.tb321fu-verified-kernel-bundle.XXXXXX")
cleanup() {
  if [ -d "$work" ]; then
    ci_safe_rmtree "$work" "$output_parent" .tb321fu-verified-kernel-bundle
  fi
}
trap cleanup EXIT

kernel_archive="$work/kernel-artifacts.archive"
device_archive="$work/device-debs.archive"
sensor_archive="$work/sensor-debs.archive"
haptics_archive="$work/haptics-debs.archive"
kernel_root="$work/kernel-artifacts"
device_root="$work/device-debs"
sensor_root="$work/sensor-debs"
haptics_root="$work/haptics-debs"

ci_download "$KERNEL_ARTIFACT_ARCHIVE" "$kernel_archive" "$KERNEL_ARTIFACT_ARCHIVE_SHA256"
ci_extract_archive "$kernel_archive" "$kernel_root"
ci_download "$DEB_ARCHIVE" "$device_archive" "$DEB_ARCHIVE_SHA256"
ci_extract_archive "$device_archive" "$device_root"
ci_download "$SENSOR_DEB_ARCHIVE" "$sensor_archive" "$SENSOR_DEB_ARCHIVE_SHA256"
ci_extract_archive "$sensor_archive" "$sensor_root"
if [ -n "$HAPTICS_DEB_ARCHIVE" ]; then
  ci_download "$HAPTICS_DEB_ARCHIVE" "$haptics_archive" "$HAPTICS_DEB_ARCHIVE_SHA256"
  ci_extract_archive "$haptics_archive" "$haptics_root"
else
  haptics_source=$(realpath -e -- "$HAPTICS_DEB_DIR")
  [ -d "$haptics_source" ] || ci_die "HAPTICS_DEB_DIR is not a directory"
  mkdir -p "$haptics_root"
  cp -a "$haptics_source/." "$haptics_root/"
fi

find_unique_file() {
  local -n result=$1
  local root=$2 pattern=$3 label=$4
  local -a matches=()

  mapfile -d '' -t matches < <(find "$root" -type f -name "$pattern" -print0 | sort -z)
  [ "${#matches[@]}" -eq 1 ] || ci_die "$label must occur exactly once in $root"
  result=${matches[0]}
}

validate_device_package_namespace() {
  local invalid deb package
  declare -A package_owner=()

  invalid=$(find "$device_root" -mindepth 1 -name '*.deb' ! -type f -print -quit)
  [ -z "$invalid" ] ||
    ci_die "device archive contains a non-regular DEB path: $invalid"
  while IFS= read -r -d '' deb; do
    package=$(dpkg-deb -f "$deb" Package) ||
      ci_die "cannot read device DEB package identity: $deb"
    case "$package" in
      qcom-sns-libssc|qcom-sns-hexagonrpc|qcom-sns-iio-sensor-proxy|tb321fu-sensors|y700-sensors|\
      tb321fu-haptics|tb321fu-haptics-common|tb321fu-haptics-modules-*|y700-haptics)
        ci_die "device archive contains reserved component package: $package"
        ;;
    esac
    [ -z "${package_owner[$package]+x}" ] ||
      ci_die "device archive contains duplicate Package '$package'"
    package_owner[$package]=$deb
  done < <(find "$device_root" -type f -name '*.deb' -print0 | sort -z)
}

load_tsv() {
  local file=$1
  local -n values=$2
  local line key value extra

  reject_nul_bytes "$file" 'TSV'
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line != *$'\r'* ]] || ci_die "TSV contains CR: $file"
    IFS=$'\t' read -r key value extra <<<"$line"
    [ -n "$key" ] && [ -n "$value" ] && [ -z "$extra" ] || ci_die "malformed TSV: $file"
    [[ $key =~ ^[a-z0-9_-]+$ ]] || ci_die "unsafe TSV key $key: $file"
    [ -z "${values[$key]+x}" ] || ci_die "duplicate TSV key $key: $file"
    values[$key]=$value
  done < "$file"
}

require_exact_tsv_order() {
  local file=$1
  shift
  local -a expected=("$@") lines=()
  local index key value extra

  reject_nul_bytes "$file" 'TSV'
  mapfile -t lines < "$file"
  [ "${#lines[@]}" -eq "${#expected[@]}" ] ||
    ci_die "unexpected TSV field count: $file"
  for index in "${!expected[@]}"; do
    IFS=$'\t' read -r key value extra <<<"${lines[$index]}"
    [ "$key" = "${expected[$index]}" ] ||
      ci_die "unexpected TSV field order at line $((index + 1)): expected ${expected[$index]}, got ${key:-empty}: $file"
  done
}

require_tsv_key() {
  local -n values=$1
  local key=$2 file=$3
  [ -n "${values[$key]:-}" ] || ci_die "missing TSV key $key: $file"
}

require_bounded_metadata_file() {
  local file=$1 label=$2 maximum=$3 size

  [ -f "$file" ] && [ ! -L "$file" ] ||
    ci_die "$label must be a regular file: $file"
  size=$(stat -c '%s' "$file")
  [[ $size =~ ^[0-9]+$ ]] && [ "$size" -le "$maximum" ] ||
    ci_die "$label exceeds size limit: $file"
  reject_nul_bytes "$file" "$label"
}

require_tsv_printable_scalar() {
  local value=$1 label=$2

  [ -n "$value" ] && [ "${#value}" -le 512 ] ||
    ci_die "invalid $label"
  [[ $value != *$'\t'* && $value != *$'\r'* && $value != *$'\n'* ]] ||
    ci_die "invalid $label"
  LC_ALL=C grep -Eq '^[ -~]+$' <<<"$value" || ci_die "invalid $label"
}

check_sha() {
  local file=$1 expected=$2 label=$3 actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "$expected" ] || ci_die "$label SHA-256 mismatch: expected $expected, got $actual"
}

verify_modules_manifest() {
  local manifest=$1 data_root=$2 expected_sha=$3 expected_count=$4 expected actual_count

  require_bounded_metadata_file "$manifest" 'kernel MODULES.sha256' 16777216
  require_regular_mode "$manifest" 644 'kernel MODULES.sha256'
  check_sha "$manifest" "$expected_sha" 'kernel MODULES.sha256'
  [[ $expected_count =~ ^[1-9][0-9]{0,8}$ ]] ||
    ci_die 'invalid modules manifest file count'
  expected="$work/MODULES.expected.sha256"
  (
    cd "$data_root"
    find ./usr/lib/modules -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --
  ) > "$expected"
  actual_count=$(wc -l < "$expected")
  [ "$actual_count" = "$expected_count" ] ||
    ci_die "kernel MODULES.sha256 file count mismatch: expected $expected_count, got $actual_count"
  cmp -s "$manifest" "$expected" ||
    ci_die 'kernel MODULES.sha256 does not cover the exact modules DEB payload'
}

validate_root_file_set() {
  local root=$1 label=$2 member
  shift 2
  local -A expected=()

  for member in "$@"; do
    [ -n "$member" ] && [ -z "${expected[$member]+x}" ] ||
      ci_die "internal duplicate expected $label archive member"
    expected[$member]=1
  done
  while IFS= read -r -d '' member; do
    member=${member#"$root"/}
    [ -n "${expected[$member]+x}" ] ||
      ci_die "$label archive contains an unexpected root member: $member"
    [ -f "$root/$member" ] && [ ! -L "$root/$member" ] ||
      ci_die "$label archive member is not a regular file: $member"
    [ "$(stat -c '%a' "$root/$member")" = 644 ] ||
      ci_die "$label archive member is not mode 0644: $member"
    expected[$member]=0
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)
  for member in "${!expected[@]}"; do
    [ "${expected[$member]}" -eq 0 ] ||
      ci_die "$label archive is missing a required root member: $member"
  done
}

require_regular_mode() {
  local file=$1 mode=$2 label=$3

  [ -f "$file" ] && [ ! -L "$file" ] || ci_die "$label must be a regular file: $file"
  [ "$(stat -c '%a' "$file")" = "$mode" ] ||
    ci_die "$label must have mode 0$mode: $file"
}

verify_haptics_checksum_manifest() {
  local manifest=$1
  shift
  local -a expected=("$@") lines=()
  local index line digest suffix

  reject_nul_bytes "$manifest" 'haptics checksum manifest'
  mapfile -t lines < "$manifest"
  [ "${#lines[@]}" -eq "${#expected[@]}" ] ||
    ci_die "haptics checksum manifest has an unexpected entry count"
  for index in "${!expected[@]}"; do
    line=${lines[$index]}
    [ "${#line}" -ge 67 ] || ci_die "malformed haptics checksum entry at line $((index + 1))"
    digest=${line:0:64}
    suffix=${line:64}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] ||
      ci_die "invalid haptics checksum digest at line $((index + 1))"
    [ "$suffix" = "  ${expected[$index]}" ] ||
      ci_die "unexpected haptics checksum path/order at line $((index + 1))"
  done
  (cd "$(dirname -- "$manifest")" &&
    sha256sum --strict --check "$(basename -- "$manifest")" >/dev/null) ||
    ci_die "haptics checksum manifest verification failed"
}

extract_haptics_git_blob() {
  local repo=$1 commit=$2 relative=$3 destination=$4
  local expected_mode=${5:-100644}
  local entry mode type object tmp
  local -a clean_git=(
    env -i
    PATH="$PATH"
    HOME="$work/git-home"
    LC_ALL=C
    GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_NO_REPLACE_OBJECTS=1
    git --no-replace-objects --git-dir="$repo"
  )

  case "$relative" in
    ''|/*|../*|*/../*|*/..|*\\*) ci_die "unsafe haptics producer Git path: $relative" ;;
  esac
  entry=$("${clean_git[@]}" ls-tree "$commit" -- "$relative") ||
    ci_die "cannot inspect haptics producer Git path: $relative"
  [ -n "$entry" ] && [ "$(wc -l <<<"$entry")" -eq 1 ] ||
    ci_die "haptics producer Git path must occur exactly once: $relative"
  mode=${entry%% *}
  entry=${entry#* }
  type=${entry%% *}
  entry=${entry#* }
  object=${entry%%$'\t'*}
  [ "$mode" = "$expected_mode" ] && [ "$type" = blob ] && [[ $object =~ ^[0-9a-f]{40}$ ]] ||
    ci_die "haptics producer Git path is not a regular blob: $relative"
  mkdir -p "$(dirname -- "$destination")"
  tmp="${destination}.part.$$"
  rm -f -- "$tmp"
  if ! "${clean_git[@]}" cat-file blob "$object" > "$tmp"; then
    rm -f -- "$tmp"
    ci_die "cannot export haptics producer Git blob: $relative"
  fi
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$destination"
}

extract_haptics_heredoc() {
  local builder=$1 marker=$2 destination=$3
  python3 "$SCRIPT_DIR/extract-shell-heredoc.py" \
    "$builder" "$marker" "$destination" ||
    ci_die "cannot derive committed haptics payload template: $marker"
}

render_haptics_maintainer_template() {
  local template=$1 destination=$2 kernel_release=$3 placeholders placeholder_count

  [ -f "$template" ] && [ ! -L "$template" ] ||
    ci_die "haptics maintainer template is not a regular file: $template"
  [[ $kernel_release =~ ^[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}$ ]] ||
    ci_die "unsafe kernel release for haptics maintainer template"
  reject_nul_bytes "$template" 'haptics maintainer template'
  if LC_ALL=C grep -aq $'\r' "$template"; then
    ci_die "haptics maintainer template contains CR: $template"
  fi
  placeholders=$(LC_ALL=C grep -aoE '@[A-Z0-9_]+@' "$template" | sort -u || true)
  [ "$placeholders" = '@KERNEL_RELEASE@' ] ||
    ci_die "haptics maintainer template has unsupported placeholders: $template"
  placeholder_count=$(LC_ALL=C grep -aoF '@KERNEL_RELEASE@' "$template" | wc -l)
  [ "$placeholder_count" -eq 1 ] ||
    ci_die "haptics maintainer template must contain exactly one kernel-release placeholder: $template"
  sed "s/@KERNEL_RELEASE@/$kernel_release/g" "$template" > "$destination"
  grep -Fq '@KERNEL_RELEASE@' "$destination" &&
    ci_die "haptics maintainer template render left a placeholder: $template"
  dash -n "$destination" ||
    ci_die "rendered haptics maintainer template is not POSIX shell: $template"
  chmod 0755 "$destination"
}

validate_haptics_maintainer_helper_contract() {
  local helper=$1 token

  require_regular_mode "$helper" 644 'committed haptics maintainer-script helper'
  reject_nul_bytes "$helper" 'haptics maintainer-script helper'
  if LC_ALL=C grep -aq $'\r' "$helper"; then
    ci_die "haptics maintainer-script helper contains CR: $helper"
  fi
  bash -n "$helper" ||
    ci_die "haptics maintainer-script helper has invalid Bash syntax: $helper"
  if grep -Fq 'HAPTICS_MAINTAINER_TEMPLATE_DIR=${' "$helper"; then
    ci_die "haptics producer maintainer helper must not allow an environment template override"
  fi
  grep -Fq '$(dirname -- "${BASH_SOURCE[0]}")/haptics-control-templates' "$helper" ||
    ci_die "haptics producer maintainer helper must derive templates from its committed location"
  for token in \
    haptics_validate_kernel_release \
    haptics_render_maintainer_template \
    haptics_write_maintainer_scripts \
    HAPTICS_MAINTAINER_TEMPLATE_DIR; do
    grep -Fq -- "$token" "$helper" ||
      ci_die "haptics producer maintainer helper lacks required contract token: $token"
  done
}

reject_nul_bytes() {
  local file=$1 label=$2

  if ! LC_ALL=C tr -d '\000' < "$file" | cmp -s -- "$file" -; then
    ci_die "$label contains NUL"
  fi
}

validate_sensor_archive() {
  local LC_ALL=C
  local root=$1 deb package architecture version common_version= member basename line digest
  local source_lock checksum_file device_data component repository revision extra index
  local expected_basename device_path path_component previous_device_path=
  local producer_commit= device_data_manifest_sha= device_record_count=0
  local sensor_libssc_deb sensor_hexagonrpc_deb sensor_iio_deb sensor_device_deb
  local -A expected=(
    [qcom-sns-libssc]=0
    [qcom-sns-hexagonrpc]=0
    [qcom-sns-iio-sensor-proxy]=0
    [tb321fu-sensors]=0
  )
  local -A sensor_deb_by_package=()
  local -A expected_members=(
    [SOURCE-LOCK.tsv]=0
    [DEVICE-DATA.sha256]=0
    [SHA256SUMS-y700-sensor-debs.txt]=0
  )
  local -a package_order=(
    qcom-sns-hexagonrpc
    qcom-sns-iio-sensor-proxy
    qcom-sns-libssc
    tb321fu-sensors
  )
  local -a source_components=(
    sensor-producer
    libssc
    iio-sensor-proxy
    hexagonrpc
    device-data-manifest
    producer-state
  )
  local -a source_repositories=(
    https://github.com/GUF296/tb321fu-sensor-debs
    https://github.com/GUF296/libssc.git
    https://github.com/GUF296/iio-sensor-proxy.git
    https://github.com/GUF296/hexagonrpc.git
    local-tree
    git-status
  )
  local -a source_revisions=(
    "$EXPECTED_SENSOR_PRODUCER_COMMIT"
    b7719402d5d45f64d8ac533ff02698fdd84e1edc
    4054d61222b473c1b172a04faf0677845201ec7f
    86d7a139ef35bb2e62ea13bd7b166a1ec08a4b97
    ''
    clean
  )
  local -a sensor_debs=() sensor_members=() source_lines=() checksum_lines=()
  local -a path_components=()

  mapfile -d '' -t sensor_debs < <(
    find "$root" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -print0 | sort -z
  )
  [ "${#sensor_debs[@]}" -eq "${#expected[@]}" ] ||
    ci_die "sensor archive must contain exactly four DEBs"
  device_data="$root/DEVICE-DATA.sha256"
  find_unique_file sensor_libssc_deb "$root" 'qcom-sns-libssc_*.deb' \
    'qcom-sns-libssc sensor DEB'
  find_unique_file sensor_hexagonrpc_deb "$root" 'qcom-sns-hexagonrpc_*.deb' \
    'qcom-sns-hexagonrpc sensor DEB'
  find_unique_file sensor_iio_deb "$root" 'qcom-sns-iio-sensor-proxy_*.deb' \
    'qcom-sns-iio-sensor-proxy sensor DEB'
  find_unique_file sensor_device_deb "$root" 'tb321fu-sensors_*.deb' \
    'tb321fu-sensors sensor DEB'
  python3 "$SCRIPT_DIR/verify-sensor-deb-structure.py" \
    --libssc-deb "$sensor_libssc_deb" \
    --hexagonrpc-deb "$sensor_hexagonrpc_deb" \
    --iio-sensor-proxy-deb "$sensor_iio_deb" \
    --tb321fu-sensors-deb "$sensor_device_deb" \
    --device-data-manifest "$device_data" ||
    ci_die "sensor DEB structure verification failed"
  for deb in "${sensor_debs[@]}"; do
    package=$(dpkg-deb -f "$deb" Package)
    architecture=$(dpkg-deb -f "$deb" Architecture)
    version=$(dpkg-deb -f "$deb" Version)
    [ -n "${expected[$package]+x}" ] || ci_die "unexpected sensor package: $package"
    [ "${expected[$package]}" -eq 0 ] || ci_die "duplicate sensor package: $package"
    [ "$architecture" = arm64 ] || ci_die "sensor package is not arm64: $package"
    [[ $version =~ ^[0-9][0-9A-Za-z.+~_-]{0,63}$ ]] &&
      dpkg --validate-version "$version" >/dev/null ||
      ci_die "unsafe sensor package version: $package"
    if [ -z "$common_version" ]; then
      common_version=$version
    else
      [ "$version" = "$common_version" ] || ci_die "sensor package versions differ"
    fi
    basename=$(basename -- "$deb")
    expected_basename="${package}_${version}_arm64.deb"
    [ "$basename" = "$expected_basename" ] ||
      ci_die "sensor DEB basename mismatch: expected $expected_basename"
    [ -z "${expected_members[$basename]+x}" ] ||
      ci_die "duplicate sensor archive member: $basename"
    expected_members[$basename]=0
    sensor_deb_by_package[$package]=$deb
    expected[$package]=1
  done
  for package in "${!expected[@]}"; do
    [ "${expected[$package]}" -eq 1 ] || ci_die "missing sensor package: $package"
  done

  mapfile -d '' -t sensor_members < <(
    find "$root" -mindepth 1 -printf '%P\0' | sort -z
  )
  [ "${#sensor_members[@]}" -eq "${#expected_members[@]}" ] ||
    ci_die "sensor archive must contain exactly seven root members"
  for member in "${sensor_members[@]}"; do
    [ -n "${expected_members[$member]+x}" ] ||
      ci_die "unexpected sensor archive member: $member"
    [ -f "$root/$member" ] && [ ! -L "$root/$member" ] ||
      ci_die "sensor archive member is not a regular file: $member"
    [ "$(stat -c '%a' "$root/$member")" = 644 ] ||
      ci_die "sensor archive member is not mode 0644: $member"
    expected_members[$member]=1
  done
  for member in "${!expected_members[@]}"; do
    [ "${expected_members[$member]}" -eq 1 ] ||
      ci_die "missing sensor archive member: $member"
  done

  source_lock="$root/SOURCE-LOCK.tsv"
  [ "$(stat -c '%s' "$source_lock")" -le 4096 ] ||
    ci_die "sensor source lock exceeds size limit"
  reject_nul_bytes "$source_lock" 'sensor source lock'
  mapfile -t source_lines < "$source_lock"
  [ "${#source_lines[@]}" -eq 7 ] ||
    ci_die "sensor source lock must contain exactly seven records"
  [ "${source_lines[0]}" = $'component\trepository\tcommit' ] ||
    ci_die "sensor source lock has an invalid header"
  for ((index = 0; index < ${#source_components[@]}; index++)); do
    line=${source_lines[index + 1]}
    [[ $line != *$'\r'* ]] || ci_die "sensor source lock contains CR"
    case "$line" in
      *$'\t'*$'\t'*$'\t'*) ci_die "sensor source lock has too many fields" ;;
    esac
    IFS=$'\t' read -r component repository revision extra <<<"$line"
    [ -n "$component" ] && [ -n "$repository" ] && [ -n "$revision" ] && [ -z "$extra" ] ||
      ci_die "sensor source lock has a malformed record"
    [ "$component" = "${source_components[index]}" ] ||
      ci_die "sensor source lock has unexpected record order"
    [ "$repository" = "${source_repositories[index]}" ] ||
      ci_die "sensor source lock repository mismatch: $component"
    if [ "$component" = sensor-producer ]; then
      [[ $revision =~ ^[0-9a-f]{40}$ ]] ||
        ci_die "sensor source lock has a malformed source revision: $component"
      producer_commit=$revision
    elif [ "$component" = device-data-manifest ]; then
      [[ $revision =~ ^[0-9a-f]{64}$ ]] ||
        ci_die "sensor source lock has a malformed device-data record"
      device_data_manifest_sha=$revision
    else
      [ "$revision" = "${source_revisions[index]}" ] ||
        ci_die "sensor source lock revision mismatch: $component"
      if [ "$component" != producer-state ]; then
        [[ $revision =~ ^[0-9a-f]{40}$ ]] ||
          ci_die "sensor source lock has a malformed source revision: $component"
      fi
    fi
  done
  [ "$producer_commit" = "$EXPECTED_SENSOR_PRODUCER_COMMIT" ] ||
    ci_die "sensor producer commit mismatch"

  [ -s "$device_data" ] || ci_die "sensor device-data manifest is empty"
  [ "$(stat -c '%s' "$device_data")" -le 1048576 ] ||
    ci_die "sensor device-data manifest exceeds size limit"
  reject_nul_bytes "$device_data" 'sensor device-data manifest'
  [ "$(sha256sum "$device_data" | awk '{print $1}')" = "$device_data_manifest_sha" ] ||
    ci_die "sensor device-data manifest digest mismatch"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line != *$'\r'* ]] || ci_die "sensor device-data manifest contains CR"
    [[ $line =~ ^[0-9a-f]{64}\ \ \./([-A-Za-z0-9._+/]+)$ ]] ||
      ci_die "sensor device-data manifest has a malformed record"
    device_path=${BASH_REMATCH[1]}
    [ "${#device_path}" -lt 4096 ] && [[ $device_path != /* ]] &&
      [[ $device_path != *//* ]] && [[ $device_path != */ ]] ||
      ci_die "sensor device-data manifest has an unsafe path"
    IFS=/ read -r -a path_components <<<"$device_path"
    for path_component in "${path_components[@]}"; do
      [ -n "$path_component" ] && [ "$path_component" != . ] &&
        [ "$path_component" != .. ] && [ "${#path_component}" -le 255 ] ||
        ci_die "sensor device-data manifest has an unsafe path"
    done
    if [ -n "$previous_device_path" ] && [[ ! $previous_device_path < $device_path ]]; then
      ci_die "sensor device-data manifest paths are not strictly ordered"
    fi
    previous_device_path=$device_path
    device_record_count=$((device_record_count + 1))
    [ "$device_record_count" -le 4096 ] ||
      ci_die "sensor device-data manifest has too many records"
  done < "$device_data"
  [ "$device_record_count" -eq 541 ] ||
    ci_die "sensor device-data manifest must contain exactly 541 records"

  checksum_file="$root/SHA256SUMS-y700-sensor-debs.txt"
  [ "$(stat -c '%s' "$checksum_file")" -le 4096 ] ||
    ci_die "sensor checksum manifest exceeds size limit"
  reject_nul_bytes "$checksum_file" 'sensor checksum manifest'
  mapfile -t checksum_lines < "$checksum_file"
  [ "${#checksum_lines[@]}" -eq "${#package_order[@]}" ] ||
    ci_die "sensor checksum manifest must contain exactly four records"
  for ((index = 0; index < ${#package_order[@]}; index++)); do
    line=${checksum_lines[index]}
    [[ $line != *$'\r'* ]] || ci_die "sensor checksum manifest contains CR"
    [[ $line =~ ^([0-9a-f]{64})\ \ \./([-A-Za-z0-9._+~]*\.deb)$ ]] ||
      ci_die "sensor checksum manifest has a malformed record"
    digest=${BASH_REMATCH[1]}
    basename=${BASH_REMATCH[2]}
    expected_basename="${package_order[index]}_${common_version}_arm64.deb"
    [ "${#basename}" -le 255 ] && [ "$basename" = "$expected_basename" ] ||
      ci_die "sensor checksum manifest has unexpected DEB order or name"
    [ "$(sha256sum "$root/$basename" | awk '{print $1}')" = "$digest" ] ||
      ci_die "sensor package checksum mismatch: $basename"
  done
  (cd "$root" && sha256sum --strict --check "$(basename -- "$checksum_file")" >/dev/null) ||
    ci_die "sensor package checksum verification failed"
  sensor_source_lock=$source_lock
  sensor_package_version=$common_version
}

validate_device_package_namespace
find_unique_file kernel_bundle "$kernel_root" KERNEL-BUNDLE.tsv 'kernel KERNEL-BUNDLE.tsv'
find_unique_file device_bundle "$device_root" KERNEL-BUNDLE.tsv 'device KERNEL-BUNDLE.tsv'
find_unique_file kernel_source_lock "$kernel_root" SOURCE-LOCK.tsv 'kernel SOURCE-LOCK.tsv'
find_unique_file device_source_lock "$device_root" SOURCE-LOCK.tsv 'device SOURCE-LOCK.tsv'
find_unique_file kernel_modules_manifest "$kernel_root" MODULES.sha256 'kernel MODULES.sha256'
find_unique_file kernel_sdk_manifest "$kernel_root" KERNEL-SDK-MANIFEST.tsv 'kernel SDK manifest'
find_unique_file device_sdk_manifest "$device_root" KERNEL-SDK-MANIFEST.tsv 'device SDK manifest'
find_unique_file kernel_toolchain_manifest "$kernel_root" KERNEL-TOOLCHAIN.tsv 'kernel toolchain manifest'
find_unique_file device_toolchain_manifest "$device_root" KERNEL-TOOLCHAIN.tsv 'device toolchain manifest'
find_unique_file kernel_kbuild_flags "$kernel_root" KBUILD-FLAGS.tsv 'kernel Kbuild flags'
find_unique_file device_kbuild_flags "$device_root" KBUILD-FLAGS.tsv 'device Kbuild flags'
find_unique_file kernel_image "$kernel_root" Image 'kernel Image'
find_unique_file kernel_dtb "$kernel_root" "$DTB_NAME" "kernel $DTB_NAME"
find_unique_file kernel_config "$kernel_root" kernel.config 'kernel config'
find_unique_file modules_deb "$device_root" 'y700-daily-kernel-modules_*.deb' 'kernel modules DEB'
find_unique_file baseline_rootfs_deb "$device_root" 'y700-daily-rootfs-overlay_*.deb' 'baseline rootfs DEB'
find_unique_file baseline_compat_archive "$device_root" 'y700-compat1-extra-rootfs-overlay.tar.gz' 'baseline compat archive'
validate_root_file_set "$kernel_root" kernel \
  Image "$DTB_NAME" kernel.config KERNEL-BUNDLE.tsv SOURCE-LOCK.tsv MODULES.sha256 \
  KERNEL-SDK-MANIFEST.tsv KERNEL-TOOLCHAIN.tsv KBUILD-FLAGS.tsv
validate_root_file_set "$device_root" device \
  "$(basename -- "$modules_deb")" "$(basename -- "$baseline_rootfs_deb")" \
  "$(basename -- "$baseline_compat_archive")" KERNEL-BUNDLE.tsv SOURCE-LOCK.tsv \
  KERNEL-SDK-MANIFEST.tsv KERNEL-TOOLCHAIN.tsv KBUILD-FLAGS.tsv
for metadata_file in \
  "$kernel_bundle" "$device_bundle" "$kernel_source_lock" "$device_source_lock" \
  "$kernel_sdk_manifest" "$device_sdk_manifest" \
  "$kernel_toolchain_manifest" "$device_toolchain_manifest" \
  "$kernel_kbuild_flags" "$device_kbuild_flags" "$kernel_modules_manifest"; do
  require_bounded_metadata_file "$metadata_file" 'kernel bundle metadata' 33554432
  require_regular_mode "$metadata_file" 644 'kernel bundle metadata'
done
cmp -s "$kernel_source_lock" "$device_source_lock" || ci_die "kernel and device source locks differ"
cmp -s "$kernel_sdk_manifest" "$device_sdk_manifest" || ci_die "kernel and device SDK manifests differ"
cmp -s "$kernel_toolchain_manifest" "$device_toolchain_manifest" || ci_die "kernel and device toolchain manifests differ"
cmp -s "$kernel_kbuild_flags" "$device_kbuild_flags" || ci_die "kernel and device Kbuild flags differ"
validated_bundle="$work/KERNEL-BUNDLE.validated.tsv"
python3 "$SCRIPT_DIR/verify-kernel-bundle.py" \
  "$kernel_bundle" --identical "$device_bundle" \
  --kbuild-flags "$kernel_kbuild_flags" \
  --toolchain "$kernel_toolchain_manifest" \
  --sdk-manifest "$kernel_sdk_manifest" --emit-tsv > "$validated_bundle" ||
  ci_die "kernel and device bundle metadata verification failed"
declare -A kernel_meta=()
load_tsv "$validated_bundle" kernel_meta
declare -A kbuild_flags_meta=()
declare -A toolchain_meta=()
load_tsv "$kernel_kbuild_flags" kbuild_flags_meta
load_tsv "$kernel_toolchain_manifest" toolchain_meta
[ "$DTB_NAME" = "${kernel_meta[kernel-dtb-name]}" ] ||
  ci_die "kernel DTB input does not match bundle metadata"

declare -a kernel_source_lock_fields=(
  schema
  kernel_bundle_id
  kernel_commit
  kernel_release
  source_date_epoch
  config_sha256
  image_sha256
  dtb_name
  dtb_sha256
  modules_deb_sha256
  modules_manifest_sha256
  modules_manifest_file_count
  kernel_sdk_archive_sha256
  kernel_sdk_manifest_sha256
  kernel_toolchain_manifest_sha256
  kbuild_flags_sha256
  baseline_archive_sha256
  baseline_rootfs_sha256
  baseline_compat_sha256
  producer_repository
  producer_commit
  producer_tree
  producer_tree_sha256
  producer_state
  packager_sha256
  common_sh_sha256
  compiler_sha256
  compiler
  rustc_sha256
  rustc
  kbuild_build_timestamp
  kbuild_build_user
  kbuild_build_host
  kbuild_build_version
  make_sha256
  make
  dpkg_deb_sha256
  dpkg_deb
  module_count
)
require_bounded_metadata_file "$kernel_source_lock" 'kernel source lock' 65536
require_exact_tsv_order "$kernel_source_lock" "${kernel_source_lock_fields[@]}"
declare -A source_lock=()
load_tsv "$kernel_source_lock" source_lock
[ "${source_lock[schema]}" = tb321fu.kernel-bootstrap/v3 ] || ci_die "unsupported kernel source-lock schema"
[ "${source_lock[kernel_bundle_id]}" = "${kernel_meta[kernel-bundle-id]}" ] || ci_die "source lock kernel bundle ID mismatch"
[ "${source_lock[kernel_commit]}" = "${kernel_meta[kernel-source-commit]}" ] || ci_die "source lock kernel commit mismatch"
[ "${source_lock[kernel_release]}" = "${kernel_meta[kernel-release]}" ] || ci_die "source lock kernel release mismatch"
[ "${source_lock[config_sha256]}" = "${kernel_meta[kernel-config-sha256]}" ] || ci_die "source lock kernel config mismatch"
[ "${source_lock[source_date_epoch]}" = "${kernel_meta[source-date-epoch]}" ] || ci_die "source lock source-date-epoch mismatch"
[ "${source_lock[image_sha256]}" = "${kernel_meta[kernel-image-sha256]}" ] || ci_die "source lock kernel Image mismatch"
[ "${source_lock[dtb_name]}" = "${kernel_meta[kernel-dtb-name]}" ] || ci_die "source lock kernel DTB name mismatch"
[ "${source_lock[dtb_sha256]}" = "${kernel_meta[kernel-dtb-sha256]}" ] || ci_die "source lock kernel DTB mismatch"
[ "${source_lock[modules_deb_sha256]}" = "${kernel_meta[kernel-modules-deb-sha256]}" ] || ci_die "source lock modules DEB mismatch"
[ "${source_lock[modules_manifest_sha256]}" = "${kernel_meta[kernel-modules-manifest-sha256]}" ] || ci_die "source lock modules manifest mismatch"
[ "${source_lock[kernel_sdk_archive_sha256]}" = "${kernel_meta[kernel-sdk-archive-sha256]}" ] || ci_die "source lock kernel SDK archive mismatch"
[ "${source_lock[kernel_sdk_manifest_sha256]}" = "${kernel_meta[kernel-sdk-manifest-sha256]}" ] || ci_die "source lock kernel SDK manifest mismatch"
[ "${source_lock[kernel_toolchain_manifest_sha256]}" = "${kernel_meta[kernel-toolchain-manifest-sha256]}" ] || ci_die "source lock kernel toolchain manifest mismatch"
[ "${source_lock[kbuild_flags_sha256]}" = "${kernel_meta[kbuild-flags-sha256]}" ] || ci_die "source lock Kbuild flags mismatch"
for key in \
  baseline_archive_sha256 baseline_rootfs_sha256 baseline_compat_sha256 \
  packager_sha256 common_sh_sha256 compiler_sha256 rustc_sha256 make_sha256 dpkg_deb_sha256; do
  [[ ${source_lock[$key]} =~ ^[0-9a-f]{64}$ ]] || ci_die "invalid kernel source-lock SHA-256: $key"
done
[ "${source_lock[producer_repository]}" = "$CANONICAL_KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY" ] ||
  ci_die 'invalid kernel source-lock producer repository'
[[ ${source_lock[producer_commit]} =~ ^[0-9a-f]{40}$ ]] || ci_die 'invalid kernel source-lock producer commit'
[[ ${source_lock[producer_tree]} =~ ^[0-9a-f]{40}$ ]] || ci_die 'invalid kernel source-lock producer tree'
[[ ${source_lock[producer_tree_sha256]} =~ ^[0-9a-f]{64}$ ]] ||
  ci_die 'invalid kernel source-lock producer tree SHA-256'
[ "${source_lock[producer_state]}" = clean ] || ci_die 'kernel source-lock producer state is not clean'
[[ ${source_lock[modules_manifest_file_count]} =~ ^[1-9][0-9]{0,8}$ ]] ||
  ci_die 'invalid kernel source-lock modules manifest file count'
[[ ${source_lock[module_count]} =~ ^[1-9][0-9]{0,8}$ ]] ||
  ci_die 'invalid kernel source-lock module count'
for key in compiler rustc make dpkg_deb; do
  require_tsv_printable_scalar "${source_lock[$key]}" "kernel source-lock $key"
done
[ "${source_lock[compiler_sha256]}" = "${toolchain_meta[gcc-sha256]}" ] || ci_die 'source lock compiler SHA-256 mismatch'
[ "${source_lock[compiler]}" = "${toolchain_meta[gcc-version]}" ] || ci_die 'source lock compiler version mismatch'
[ "${source_lock[rustc_sha256]}" = "${toolchain_meta[rustc-sha256]}" ] || ci_die 'source lock rustc SHA-256 mismatch'
[ "${source_lock[rustc]}" = "${toolchain_meta[rustc-version]}" ] || ci_die 'source lock rustc version mismatch'
[ "${source_lock[rustc_sha256]}" = "${kernel_meta[rustc-sha256]}" ] || ci_die 'source lock rustc differs from bundle'
[ "${source_lock[rustc]}" = "${kernel_meta[rustc]}" ] || ci_die 'source lock rustc version differs from bundle'
[ "${source_lock[make_sha256]}" = "${toolchain_meta[make-sha256]}" ] || ci_die 'source lock make SHA-256 mismatch'
[ "${source_lock[make]}" = "${toolchain_meta[make-version]}" ] || ci_die 'source lock make version mismatch'
[ "${source_lock[dpkg_deb_sha256]}" = "${toolchain_meta[dpkg-deb-sha256]}" ] || ci_die 'source lock dpkg-deb SHA-256 mismatch'
[ "${source_lock[dpkg_deb]}" = "${toolchain_meta[dpkg-deb-version]}" ] || ci_die 'source lock dpkg-deb version mismatch'
for key in source_date_epoch kbuild_build_timestamp kbuild_build_user kbuild_build_host kbuild_build_version; do
  bundle_key=${key//_/-}
  [ "${source_lock[$key]}" = "${kernel_meta[$bundle_key]}" ] ||
    ci_die "source lock $key differs from bundle"
done
[ "${source_lock[source_date_epoch]}" = "${kbuild_flags_meta[source-date-epoch]}" ] || ci_die 'source lock source-date-epoch differs from Kbuild flags'
[ "${source_lock[kbuild_build_timestamp]}" = "${kbuild_flags_meta[kbuild-build-timestamp]}" ] || ci_die 'source lock Kbuild timestamp differs from Kbuild flags'
[ "${source_lock[kbuild_build_user]}" = "${kbuild_flags_meta[kbuild-build-user]}" ] || ci_die 'source lock Kbuild user differs from Kbuild flags'
[ "${source_lock[kbuild_build_host]}" = "${kbuild_flags_meta[kbuild-build-host]}" ] || ci_die 'source lock Kbuild host differs from Kbuild flags'
[ "${source_lock[kbuild_build_version]}" = "${kbuild_flags_meta[kbuild-build-version]}" ] || ci_die 'source lock Kbuild version differs from Kbuild flags'
check_sha "$kernel_image" "${source_lock[image_sha256]}" 'kernel Image'
check_sha "$kernel_dtb" "${source_lock[dtb_sha256]}" 'kernel DTB'
check_sha "$kernel_config" "${source_lock[config_sha256]}" 'kernel config'
check_sha "$modules_deb" "${source_lock[modules_deb_sha256]}" 'kernel modules DEB'
check_sha "$baseline_rootfs_deb" "${source_lock[baseline_rootfs_sha256]}" 'baseline rootfs DEB'
check_sha "$baseline_compat_archive" "${source_lock[baseline_compat_sha256]}" 'baseline compat archive'

sensor_source_lock=
sensor_package_version=
validate_sensor_archive "$sensor_root"

[ "$(dpkg-deb -f "$modules_deb" Package)" = y700-daily-kernel-modules ] || ci_die "unexpected kernel modules package name"
[ "$(dpkg-deb -f "$modules_deb" Architecture)" = arm64 ] || ci_die "unexpected kernel modules package architecture"
device_data_tar="$work/device-data.tar"
device_data="$work/device-data"
device_control_tar="$work/device-control.tar"
device_control="$work/device-control"
dpkg-deb --fsys-tarfile "$modules_deb" > "$device_data_tar"
ci_extract_archive "$device_data_tar" "$device_data"
[ -z "$(find "$device_data" -type d ! -perm 0755 -print -quit)" ] ||
  ci_die "kernel modules DEB contains a non-0755 data directory"
[ -z "$(find "$device_data" -type f ! -perm 0644 -print -quit)" ] ||
  ci_die "kernel modules DEB contains a non-0644 data file"
[ -z "$(find "$device_data" ! -type d ! -type f -print -quit)" ] ||
  ci_die "kernel modules DEB data contains a non-regular member"
dpkg-deb --ctrl-tarfile "$modules_deb" > "$device_control_tar"
ci_extract_archive "$device_control_tar" "$device_control"
[ -z "$(find "$device_control" -type d ! -perm 0755 -print -quit)" ] ||
  ci_die "kernel modules DEB contains a non-0755 control directory"
[ -z "$(find "$device_control" ! -type d ! -type f -print -quit)" ] ||
  ci_die "kernel modules DEB control contains a non-regular member"
[ "$(stat -c '%a' "$device_control/control")" = 644 ] ||
  ci_die "kernel modules DEB control must be mode 0644"
[ "$(stat -c '%a' "$device_control/postinst")" = 755 ] ||
  ci_die "kernel modules DEB postinst must be mode 0755"
while IFS= read -r -d '' control_file; do
  case $(basename -- "$control_file") in
    preinst|postinst|prerm|postrm|config)
      [ "$(stat -c '%a' "$control_file")" = 755 ] ||
        ci_die "kernel modules DEB maintainer script must be mode 0755: $control_file"
      ;;
    *)
      [ "$(stat -c '%a' "$control_file")" = 644 ] ||
        ci_die "kernel modules DEB control file must be mode 0644: $control_file"
      ;;
  esac
done < <(find "$device_control" -type f -print0)
modules_parent="$device_data/usr/lib/modules"
[ -d "$modules_parent" ] || ci_die "kernel modules DEB lacks usr/lib/modules"
mapfile -d '' -t module_dirs < <(find "$modules_parent" -mindepth 1 -maxdepth 1 -type d -print0)
[ "${#module_dirs[@]}" -eq 1 ] || ci_die "kernel modules DEB must contain exactly one release"
[ "$(basename -- "${module_dirs[0]}")" = "${kernel_meta[kernel-release]}" ] || ci_die "kernel modules directory release mismatch"
module_count=0
kernel_vermagic=
while IFS= read -r -d '' module; do
  vermagic=$("$MODINFO" -F vermagic "$module")
  case "$vermagic" in
    "${kernel_meta[kernel-release]}"|"${kernel_meta[kernel-release]} "*) ;;
    *) ci_die "kernel module vermagic mismatch: $module: $vermagic" ;;
  esac
  if [ -z "$kernel_vermagic" ]; then
    kernel_vermagic=$vermagic
  else
    [ "$vermagic" = "$kernel_vermagic" ] ||
      ci_die "kernel module vermagic flags mismatch: $module: $vermagic"
  fi
  module_count=$((module_count + 1))
done < <(find "${module_dirs[0]}" -type f -name '*.ko*' -print0)
[ "$module_count" -gt 0 ] || ci_die "kernel modules DEB contains no modules"
[ -n "$kernel_vermagic" ] || ci_die "kernel modules DEB has no canonical vermagic"
verify_modules_manifest \
  "$kernel_modules_manifest" "$device_data" \
  "${source_lock[modules_manifest_sha256]}" \
  "${source_lock[modules_manifest_file_count]}"
[ "$module_count" = "${source_lock[module_count]}" ] ||
  ci_die "kernel module count differs from the source lock: expected ${source_lock[module_count]}, got $module_count"

find_unique_file haptics_deb "$haptics_root" 'tb321fu-haptics_*.deb' 'haptics DEB'
find_unique_file haptics_lock "$haptics_root" HAPTICS-SOURCE-LOCK.tsv 'HAPTICS-SOURCE-LOCK.tsv'
find_unique_file haptics_checksum_manifest "$haptics_root" \
  SHA256SUMS-tb321fu-haptics-debs.txt 'haptics checksum manifest'
find_unique_file haptics_producer_bundle "$haptics_root" \
  HAPTICS-PRODUCER.bundle 'haptics producer Git bundle'
[ "$haptics_deb" = "$haptics_root/$(basename -- "$haptics_deb")" ] ||
  ci_die "haptics DEB must be at the archive root"
[ "$haptics_lock" = "$haptics_root/HAPTICS-SOURCE-LOCK.tsv" ] ||
  ci_die "HAPTICS-SOURCE-LOCK.tsv must be at the archive root"
[ "$haptics_checksum_manifest" = "$haptics_root/SHA256SUMS-tb321fu-haptics-debs.txt" ] ||
  ci_die "haptics checksum manifest must be at the archive root"
[ "$haptics_producer_bundle" = "$haptics_root/HAPTICS-PRODUCER.bundle" ] ||
  ci_die "haptics producer Git bundle must be at the archive root"
require_regular_mode "$haptics_lock" 644 'HAPTICS-SOURCE-LOCK.tsv'
require_regular_mode "$haptics_checksum_manifest" 644 'haptics checksum manifest'
require_regular_mode "$haptics_producer_bundle" 644 'haptics producer Git bundle'
require_bounded_metadata_file "$haptics_lock" 'haptics source lock' 65536
require_bounded_metadata_file "$haptics_checksum_manifest" 'haptics checksum manifest' 1048576
declare -a haptics_lock_fields=(
  schema
  haptics-output-mode
  haptics-producer-commit
  haptics-producer-state
  aw86937-driver-sha256
  aw86937-build-source-sha256
  haptic-ram-firmware-sha256
  haptic-click-firmware-sha256
  haptic-test-helper-sha256
  aw86937-module-sha256
  haptic-test-helper-binary-sha256
  kernel-bundle-id
  kernel-release
  kernel-source-commit
  kernel-config-sha256
  kernel-build-input
  kernel-build-archive-sha256
  source-date-epoch
)
require_exact_tsv_order "$haptics_lock" "${haptics_lock_fields[@]}"
declare -A haptics_meta=()
load_tsv "$haptics_lock" haptics_meta
[ "${haptics_meta[schema]}" = tb321fu.haptics-source-lock/v2 ] ||
  ci_die "unsupported haptics source-lock schema"
[ "${haptics_meta[haptics-output-mode]}" = release-candidate ] ||
  ci_die 'haptics source lock is not a release candidate'
[ "${haptics_meta[haptics-producer-commit]}" = "$EXPECTED_HAPTICS_PRODUCER_COMMIT" ] ||
  ci_die "haptics producer commit mismatch"
[ "${haptics_meta[haptics-producer-state]}" = clean ] ||
  ci_die "haptics producer source lock is not clean"
for key in \
  aw86937-driver-sha256 \
  aw86937-build-source-sha256 \
  haptic-ram-firmware-sha256 \
  haptic-click-firmware-sha256 \
  haptic-test-helper-sha256 \
  aw86937-module-sha256 \
  haptic-test-helper-binary-sha256; do
  [[ ${haptics_meta[$key]} =~ ^[0-9a-f]{64}$ ]] ||
    ci_die "invalid haptics source SHA-256 field: $key"
done
[ "${haptics_meta[aw86937-module-sha256]}" = "$EXPECTED_HAPTICS_MODULE_SHA256" ] ||
  ci_die "haptics module SHA-256 differs from the external expected digest"
[ "${haptics_meta[haptic-test-helper-binary-sha256]}" = \
    "$EXPECTED_HAPTICS_HELPER_BINARY_SHA256" ] ||
  ci_die "haptics helper binary SHA-256 differs from the external expected digest"
[ "${haptics_meta[kernel-bundle-id]}" = "${kernel_meta[kernel-bundle-id]}" ] || ci_die "haptics kernel-bundle-id mismatch"
[ "${haptics_meta[kernel-release]}" = "${kernel_meta[kernel-release]}" ] || ci_die "haptics kernel-release mismatch"
[ "${haptics_meta[kernel-source-commit]}" = "${kernel_meta[kernel-source-commit]}" ] || ci_die "haptics kernel-source-commit mismatch"
[ "${haptics_meta[kernel-config-sha256]}" = "${kernel_meta[kernel-config-sha256]}" ] || ci_die "haptics kernel-config-sha256 mismatch"
[ "${haptics_meta[kernel-build-input]}" = kernel-sdk-archive ] ||
  ci_die 'haptics kernel build input is not the verified SDK archive'
[[ ${haptics_meta[kernel-build-archive-sha256]} =~ ^[0-9a-f]{64}$ ]] ||
  ci_die "invalid haptics kernel build archive SHA-256"
[ "${haptics_meta[kernel-build-archive-sha256]}" = "${kernel_meta[kernel-sdk-archive-sha256]}" ] ||
  ci_die 'haptics kernel build archive SHA-256 mismatch'
[[ ${haptics_meta[source-date-epoch]} =~ ^[0-9]{1,10}$ ]] ||
  ci_die "invalid haptics source-date-epoch"
[ "${haptics_meta[source-date-epoch]}" = "${kernel_meta[source-date-epoch]}" ] ||
  ci_die "haptics source-date-epoch mismatch"

haptics_snapshot="$haptics_root/HAPTICS-SOURCE-SNAPSHOT"
[ -d "$haptics_snapshot" ] && [ ! -L "$haptics_snapshot" ] ||
  ci_die "missing exact HAPTICS-SOURCE-SNAPSHOT directory"
haptics_snapshot_driver="$haptics_snapshot/source/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c"
haptics_snapshot_build_source="$haptics_snapshot/build/aw86937-haptics.c"
haptics_snapshot_ram="$haptics_snapshot/source/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin"
haptics_snapshot_click="$haptics_snapshot/source/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin"
haptics_snapshot_helper="$haptics_snapshot/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c"
mapfile -d '' -t haptics_snapshot_files < <(find "$haptics_snapshot" -type f -print0 | sort -z)
[ "${#haptics_snapshot_files[@]}" -eq 5 ] ||
  ci_die "HAPTICS-SOURCE-SNAPSHOT must contain exactly five files"
[ -z "$(find "$haptics_snapshot" ! -type d ! -type f -print -quit)" ] ||
  ci_die "HAPTICS-SOURCE-SNAPSHOT contains a non-regular member"
[ -z "$(find "$haptics_snapshot" -type d -empty -print -quit)" ] ||
  ci_die "HAPTICS-SOURCE-SNAPSHOT contains an unexpected empty directory"
[ -z "$(find "$haptics_snapshot" -type d ! -perm 0755 -print -quit)" ] ||
  ci_die "HAPTICS-SOURCE-SNAPSHOT contains a non-0755 directory"
for source_file in \
  "$haptics_snapshot_driver" \
  "$haptics_snapshot_build_source" \
  "$haptics_snapshot_ram" \
  "$haptics_snapshot_click" \
  "$haptics_snapshot_helper"; do
  require_regular_mode "$source_file" 644 'haptics source snapshot file'
done
check_sha "$haptics_snapshot_driver" "${haptics_meta[aw86937-driver-sha256]}" \
  'AW86937 original driver source'
check_sha "$haptics_snapshot_build_source" "${haptics_meta[aw86937-build-source-sha256]}" \
  'AW86937 patched build source'
check_sha "$haptics_snapshot_ram" "${haptics_meta[haptic-ram-firmware-sha256]}" \
  'haptic_ram.bin source snapshot'
check_sha "$haptics_snapshot_click" "${haptics_meta[haptic-click-firmware-sha256]}" \
  'haptic_click.bin source snapshot'
check_sha "$haptics_snapshot_helper" "${haptics_meta[haptic-test-helper-sha256]}" \
  'haptics test helper source'

declare -A expected_haptics_root=(
  ["$haptics_deb"]=1
  ["$haptics_lock"]=1
  ["$haptics_checksum_manifest"]=1
  ["$haptics_producer_bundle"]=1
  ["$haptics_snapshot"]=1
)
while IFS= read -r -d '' haptics_root_member; do
  [ -n "${expected_haptics_root[$haptics_root_member]+x}" ] ||
    ci_die "haptics archive root contains an unexpected member: $(basename -- "$haptics_root_member")"
  unset 'expected_haptics_root[$haptics_root_member]'
done < <(find "$haptics_root" -mindepth 1 -maxdepth 1 -print0)
[ "${#expected_haptics_root[@]}" -eq 0 ] ||
  ci_die "haptics archive root is missing a required member"

verify_haptics_checksum_manifest "$haptics_checksum_manifest" \
  "./$(basename -- "$haptics_deb")" \
  ./HAPTICS-SOURCE-LOCK.tsv \
  ./HAPTICS-PRODUCER.bundle \
  ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c \
  ./HAPTICS-SOURCE-SNAPSHOT/build/aw86937-haptics.c \
  ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin \
  ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin \
  ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c

require_regular_mode "$haptics_deb" 644 'haptics DEB'
haptics_data_tar="$work/haptics-data.tar"
haptics_data="$work/haptics-data"
haptics_control_tar="$work/haptics-control.tar"
haptics_control="$work/haptics-control"
python3 "$SCRIPT_DIR/verify-haptics-deb-structure.py" \
  --deb "$haptics_deb" \
  --control-tar "$haptics_control_tar" \
  --data-tar "$haptics_data_tar" \
  --kernel-release "${kernel_meta[kernel-release]}" \
  --source-date-epoch "${haptics_meta[source-date-epoch]}" \
  --extract-only || ci_die "bounded haptics DEB extraction failed"

declare -a clean_git_env=(
  env -i
  PATH="$PATH"
  HOME="$work/git-home"
  LC_ALL=C
  GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_NO_REPLACE_OBJECTS=1
)
haptics_bundle_repo="$work/haptics-producer.git"
install -d -m 0700 "$work/git-home"
"${clean_git_env[@]}" git init --bare -q "$haptics_bundle_repo" ||
  ci_die "cannot initialize haptics producer bundle verifier"
haptics_bundle_heads=$("${clean_git_env[@]}" git bundle list-heads "$haptics_producer_bundle") ||
  ci_die "cannot list haptics producer Git bundle heads"
mapfile -t haptics_bundle_head_lines <<<"$haptics_bundle_heads"
[ "${#haptics_bundle_head_lines[@]}" -eq 1 ] && [ -n "${haptics_bundle_head_lines[0]}" ] ||
  ci_die "haptics producer Git bundle must advertise exactly one ref"
IFS=' ' read -r haptics_bundle_commit haptics_bundle_ref haptics_bundle_extra \
  <<<"${haptics_bundle_head_lines[0]}"
[ -z "$haptics_bundle_extra" ] &&
  [ "$haptics_bundle_ref" = refs/heads/tb321fu-haptics-producer ] ||
  ci_die "haptics producer Git bundle advertises an unexpected ref"
[ "$haptics_bundle_commit" = "$EXPECTED_HAPTICS_PRODUCER_COMMIT" ] ||
  ci_die "haptics producer Git bundle commit mismatch"
"${clean_git_env[@]}" git -C "$haptics_bundle_repo" bundle verify \
  "$haptics_producer_bundle" >/dev/null 2>&1 ||
  ci_die "haptics producer Git bundle verification failed"
"${clean_git_env[@]}" git -C "$haptics_bundle_repo" bundle unbundle \
  "$haptics_producer_bundle" >/dev/null ||
  ci_die "cannot import haptics producer Git bundle"
"${clean_git_env[@]}" git --no-replace-objects --git-dir="$haptics_bundle_repo" \
  cat-file -e "$EXPECTED_HAPTICS_PRODUCER_COMMIT^{commit}" ||
  ci_die "haptics producer Git bundle lacks the expected commit"
"${clean_git_env[@]}" git --git-dir="$haptics_bundle_repo" update-ref \
  refs/heads/tb321fu-haptics-producer "$EXPECTED_HAPTICS_PRODUCER_COMMIT" ||
  ci_die "cannot anchor the imported haptics producer commit"
"${clean_git_env[@]}" git --git-dir="$haptics_bundle_repo" symbolic-ref HEAD \
  refs/heads/tb321fu-haptics-producer ||
  ci_die "cannot anchor the haptics producer verifier HEAD"
haptics_fsck_output=$("${clean_git_env[@]}" git --git-dir="$haptics_bundle_repo" \
  fsck --strict --no-reflogs --unreachable 2>&1) ||
  ci_die "haptics producer Git bundle object verification failed"
[ -z "$haptics_fsck_output" ] ||
  ci_die "haptics producer Git bundle contains unreachable or unexpected objects"

haptics_committed="$work/haptics-producer-committed"
haptics_committed_driver="$haptics_committed/aw86937-y700.c"
haptics_committed_ram="$haptics_committed/haptic_ram.bin"
haptics_committed_click="$haptics_committed/haptic_click.bin"
haptics_committed_helper="$haptics_committed/y700-haptic-test.c"
haptics_committed_builder="$haptics_committed/build-tb321fu-haptics-deb.sh"
haptics_committed_maintainer_helper="$haptics_committed/haptics-maintainer-scripts.sh"
haptics_committed_postinst_template="$haptics_committed/postinst.in"
haptics_committed_prerm_template="$haptics_committed/prerm.in"
haptics_committed_postrm_template="$haptics_committed/postrm.in"
extract_haptics_git_blob "$haptics_bundle_repo" "$EXPECTED_HAPTICS_PRODUCER_COMMIT" \
  haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c "$haptics_committed_driver"
extract_haptics_git_blob "$haptics_bundle_repo" "$EXPECTED_HAPTICS_PRODUCER_COMMIT" \
  haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin "$haptics_committed_ram"
extract_haptics_git_blob "$haptics_bundle_repo" "$EXPECTED_HAPTICS_PRODUCER_COMMIT" \
  haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin "$haptics_committed_click"
extract_haptics_git_blob "$haptics_bundle_repo" "$EXPECTED_HAPTICS_PRODUCER_COMMIT" \
  haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c "$haptics_committed_helper"
extract_haptics_git_blob "$haptics_bundle_repo" "$EXPECTED_HAPTICS_PRODUCER_COMMIT" \
  scripts/ci/build-tb321fu-haptics-deb.sh "$haptics_committed_builder" 100755
extract_haptics_git_blob "$haptics_bundle_repo" "$EXPECTED_HAPTICS_PRODUCER_COMMIT" \
  scripts/ci/haptics-maintainer-scripts.sh "$haptics_committed_maintainer_helper" 100644
for haptics_template in postinst prerm postrm; do
  extract_haptics_git_blob "$haptics_bundle_repo" "$EXPECTED_HAPTICS_PRODUCER_COMMIT" \
    "scripts/ci/haptics-control-templates/$haptics_template.in" \
    "$haptics_committed/$haptics_template.in" 100644
done
validate_haptics_maintainer_helper_contract "$haptics_committed_maintainer_helper"
grep -Fq -- '. "$SCRIPT_DIR/haptics-maintainer-scripts.sh"' "$haptics_committed_builder" ||
  ci_die "haptics producer builder does not source the committed maintainer helper"
cmp -s "$haptics_committed_driver" "$haptics_snapshot_driver" ||
  ci_die "AW86937 source snapshot does not match the producer commit"
cmp -s "$haptics_committed_ram" "$haptics_snapshot_ram" ||
  ci_die "haptic_ram.bin snapshot does not match the producer commit"
cmp -s "$haptics_committed_click" "$haptics_snapshot_click" ||
  ci_die "haptic_click.bin snapshot does not match the producer commit"
cmp -s "$haptics_committed_helper" "$haptics_snapshot_helper" ||
  ci_die "haptics helper source snapshot does not match the producer commit"
haptics_reproduced_build_source="$haptics_committed/aw86937-haptics.c"
install -m 0644 "$haptics_committed_driver" "$haptics_reproduced_build_source"
sed -i \
  -e 's/Lenovo Y700 AW86937 input force-feedback haptics driver/Lenovo TB321FU AW86937 input force-feedback haptics driver/g' \
  -e 's/\.name = "aw86937-y700"/.name = "aw86937-haptics"/g' \
  "$haptics_reproduced_build_source"
if ! grep -q '"aw86937_haptics"' "$haptics_reproduced_build_source"; then
  sed -i '/{ "aw86937_y700" }/i\	{ "aw86937_haptics" },' \
    "$haptics_reproduced_build_source"
fi
cmp -s "$haptics_reproduced_build_source" "$haptics_snapshot_build_source" ||
  ci_die "AW86937 patched build source is not the deterministic producer transform"

ci_extract_archive "$haptics_data_tar" "$haptics_data"
ci_extract_archive "$haptics_control_tar" "$haptics_control"
haptics_package_version=$(dpkg-deb -f "$haptics_deb" Version)
[[ $haptics_package_version =~ ^[0-9][0-9A-Za-z.+~_-]{0,63}$ ]] ||
  ci_die "unsafe haptics package version"
dpkg --validate-version "$haptics_package_version" >/dev/null ||
  ci_die "invalid haptics package version"
[ "$(basename -- "$haptics_deb")" = "tb321fu-haptics_${haptics_package_version}_arm64.deb" ] ||
  ci_die "haptics DEB filename does not match its package version"
haptics_expected_control="$work/haptics-expected-control"
cat > "$haptics_expected_control" <<EOF_HAPTICS_CONTROL
Package: tb321fu-haptics
Version: $haptics_package_version
Section: misc
Priority: optional
Architecture: arm64
Maintainer: GUF296 <guf296@users.noreply.github.com>
Depends: kmod, systemd, udev, coreutils, findutils, feedbackd, feedbackd-device-themes
Conflicts: y700-haptics
Replaces: y700-haptics
Description: AW86937 haptics support for Lenovo Legion Y700 TB321FU
 Source-built AW86937 force-feedback haptics module, firmware, feedbackd udev
 integration and TB321FU boot-time binding glue.
EOF_HAPTICS_CONTROL
cmp -s "$haptics_expected_control" "$haptics_control/control" ||
  ci_die "haptics DEB control metadata differs from the producer contract"
for haptics_template in postinst prerm postrm; do
  render_haptics_maintainer_template \
    "$haptics_committed/$haptics_template.in" \
    "$work/haptics-template-$haptics_template" "${kernel_meta[kernel-release]}"
  cmp -s "$work/haptics-template-$haptics_template" \
    "$haptics_control/$haptics_template" ||
    ci_die "haptics DEB $haptics_template differs from the producer template"
done
declare -A haptics_template_targets=(
  [EOF_BIND]="$haptics_data/usr/libexec/tb321fu-haptics/bind-aw86937"
  [EOF_SERVICE]="$haptics_data/usr/lib/systemd/system/tb321fu-haptics.service"
  [EOF_UDEV]="$haptics_data/usr/lib/udev/rules.d/90-tb321fu-haptics.rules"
  [EOF_CONF]="$haptics_data/etc/skel/.config/plasmakeyboardrc"
)
for haptics_template in EOF_BIND EOF_SERVICE EOF_UDEV EOF_CONF; do
  haptics_expected_template="$work/haptics-template-$haptics_template"
  extract_haptics_heredoc \
    "$haptics_committed_builder" "$haptics_template" "$haptics_expected_template"
  cmp -s "$haptics_expected_template" "${haptics_template_targets[$haptics_template]}" ||
    ci_die "haptics DEB payload differs from committed template: $haptics_template"
done
find_unique_file haptics_ram_firmware "$haptics_data" haptic_ram.bin 'haptic_ram.bin'
find_unique_file haptics_click_firmware "$haptics_data" haptic_click.bin 'haptic_click.bin'
haptics_expected_ram="$haptics_data/usr/lib/firmware/haptic_ram.bin"
haptics_expected_click="$haptics_data/usr/lib/firmware/haptic_click.bin"
[ "$haptics_ram_firmware" = "$haptics_expected_ram" ] ||
  ci_die "haptic_ram.bin is not installed at usr/lib/firmware/haptic_ram.bin"
[ "$haptics_click_firmware" = "$haptics_expected_click" ] ||
  ci_die "haptic_click.bin is not installed at usr/lib/firmware/haptic_click.bin"
require_regular_mode "$haptics_ram_firmware" 644 'haptic_ram.bin'
require_regular_mode "$haptics_click_firmware" 644 'haptic_click.bin'
check_sha "$haptics_ram_firmware" "${haptics_meta[haptic-ram-firmware-sha256]}" \
  'haptic_ram.bin'
check_sha "$haptics_click_firmware" "${haptics_meta[haptic-click-firmware-sha256]}" \
  'haptic_click.bin'
mapfile -d '' -t haptics_modules < <(find "$haptics_data" -type f -name 'aw86937-haptics.ko*' -print0 2>/dev/null)
[ "${#haptics_modules[@]}" -eq 1 ] || ci_die "haptics DEB must contain exactly one aw86937-haptics module"
haptics_expected_module="$haptics_data/usr/lib/modules/${kernel_meta[kernel-release]}/extra/aw86937-haptics.ko"
[ "${haptics_modules[0]}" = "$haptics_expected_module" ] ||
  ci_die "haptics module path release mismatch"
require_regular_mode "$haptics_expected_module" 644 'aw86937-haptics.ko'
check_sha "$haptics_expected_module" "$EXPECTED_HAPTICS_MODULE_SHA256" \
  'aw86937-haptics.ko'
haptics_vermagic=$("$MODINFO" -F vermagic "${haptics_modules[0]}")
[ "$haptics_vermagic" = "$kernel_vermagic" ] ||
  ci_die "haptics module vermagic differs from kernel modules: $haptics_vermagic"
find_unique_file haptics_helper "$haptics_data" tb321fu-haptic-test 'tb321fu-haptic-test'
haptics_expected_helper="$haptics_data/usr/bin/tb321fu-haptic-test"
[ "$haptics_helper" = "$haptics_expected_helper" ] ||
  ci_die "tb321fu-haptic-test is not installed at usr/bin/tb321fu-haptic-test"
require_regular_mode "$haptics_expected_helper" 755 'tb321fu-haptic-test'
check_sha "$haptics_expected_helper" "$EXPECTED_HAPTICS_HELPER_BINARY_SHA256" \
  'tb321fu-haptic-test'
python3 "$SCRIPT_DIR/verify-haptics-deb-structure.py" \
  --deb "$haptics_deb" \
  --control-tar "$haptics_control_tar" \
  --data-tar "$haptics_data_tar" \
  --kernel-release "${kernel_meta[kernel-release]}" \
  --source-date-epoch "${haptics_meta[source-date-epoch]}" ||
  ci_die "haptics DEB structure verification failed"
stage="$work/stage"
mkdir -p "$stage"
install -m 0644 "$kernel_archive" "$stage/kernel-artifacts.archive"
install -m 0644 "$device_archive" "$stage/device-debs.archive"
install -m 0644 "$sensor_archive" "$stage/sensor-debs.archive"
install -m 0644 "$kernel_bundle" "$stage/KERNEL-BUNDLE.tsv"
install -m 0644 "$kernel_source_lock" "$stage/KERNEL-SOURCE-LOCK.tsv"
install -m 0644 "$sensor_source_lock" "$stage/SENSOR-SOURCE-LOCK.tsv"
install -m 0644 "$haptics_lock" "$stage/HAPTICS-SOURCE-LOCK.tsv"
install -m 0644 "$kernel_modules_manifest" "$stage/MODULES.sha256"
install -m 0644 "$kernel_sdk_manifest" "$stage/KERNEL-SDK-MANIFEST.tsv"
install -m 0644 "$kernel_toolchain_manifest" "$stage/KERNEL-TOOLCHAIN.tsv"
install -m 0644 "$kernel_kbuild_flags" "$stage/KBUILD-FLAGS.tsv"
if [ -n "$HAPTICS_DEB_ARCHIVE" ]; then
  install -m 0644 "$haptics_archive" "$stage/haptics-debs.archive"
else
  mkdir -p "$stage/haptics-debs"
  cp -a "$haptics_root/." "$stage/haptics-debs/"
fi

kernel_archive_sha=$(sha256sum "$stage/kernel-artifacts.archive" | awk '{print $1}')
device_archive_sha=$(sha256sum "$stage/device-debs.archive" | awk '{print $1}')
sensor_archive_sha=$(sha256sum "$stage/sensor-debs.archive" | awk '{print $1}')
haptics_archive_sha=
if [ -n "$HAPTICS_DEB_ARCHIVE" ]; then
  haptics_archive_sha=$(sha256sum "$stage/haptics-debs.archive" | awk '{print $1}')
fi
{
  printf 'schema\ttb321fu.verified-kernel-bundle/v2\n'
  printf 'kernel-bundle-id\t%s\n' "${kernel_meta[kernel-bundle-id]}"
  printf 'kernel-release\t%s\n' "${kernel_meta[kernel-release]}"
  printf 'kernel-source-commit\t%s\n' "${kernel_meta[kernel-source-commit]}"
  printf 'kernel-config-sha256\t%s\n' "${kernel_meta[kernel-config-sha256]}"
  printf 'kernel-image-sha256\t%s\n' "${kernel_meta[kernel-image-sha256]}"
  printf 'kernel-dtb-name\t%s\n' "${kernel_meta[kernel-dtb-name]}"
  printf 'kernel-dtb-sha256\t%s\n' "${kernel_meta[kernel-dtb-sha256]}"
  printf 'kernel-modules-deb-sha256\t%s\n' "${kernel_meta[kernel-modules-deb-sha256]}"
  printf 'kernel-modules-manifest-sha256\t%s\n' "${kernel_meta[kernel-modules-manifest-sha256]}"
  printf 'kernel-sdk-archive-sha256\t%s\n' "${kernel_meta[kernel-sdk-archive-sha256]}"
  printf 'kernel-sdk-manifest-sha256\t%s\n' "${kernel_meta[kernel-sdk-manifest-sha256]}"
  printf 'kernel-toolchain-manifest-sha256\t%s\n' "${kernel_meta[kernel-toolchain-manifest-sha256]}"
  printf 'kbuild-flags-sha256\t%s\n' "${kernel_meta[kbuild-flags-sha256]}"
  printf 'rustc-sha256\t%s\n' "${kernel_meta[rustc-sha256]}"
  printf 'rustc\t%s\n' "${kernel_meta[rustc]}"
  printf 'kernel-archive-sha256\t%s\n' "$kernel_archive_sha"
  printf 'device-archive-sha256\t%s\n' "$device_archive_sha"
  printf 'sensor-archive-sha256\t%s\n' "$sensor_archive_sha"
  printf 'sensor-package-version\t%s\n' "$sensor_package_version"
  printf 'sensor-producer-commit\t%s\n' "$EXPECTED_SENSOR_PRODUCER_COMMIT"
  printf 'haptics-archive-sha256\t%s\n' "${haptics_archive_sha:-directory-input}"
  printf 'haptics-producer-commit\t%s\n' "${haptics_meta[haptics-producer-commit]}"
  printf 'kernel-module-count\t%s\n' "$module_count"
} > "$stage/VERIFIED-BUNDLE.tsv"

write_verified_input() {
  local key=$1 value=$2
  case "$value" in
    *$'\t'*|*$'\r'*|*$'\n'*) ci_die "verified input contains a TSV control character: $key" ;;
  esac
  printf '%s\t%s\n' "$key" "$value"
}
{
  write_verified_input schema tb321fu.verified-inputs/v1
  write_verified_input kernel-artifact-archive "$KERNEL_ARTIFACT_ARCHIVE"
  write_verified_input kernel-artifact-archive-sha256 "${KERNEL_ARTIFACT_ARCHIVE_SHA256,,}"
  write_verified_input device-deb-archive "$DEB_ARCHIVE"
  write_verified_input device-deb-archive-sha256 "${DEB_ARCHIVE_SHA256,,}"
  write_verified_input sensor-deb-archive "$SENSOR_DEB_ARCHIVE"
  write_verified_input sensor-deb-archive-sha256 "${SENSOR_DEB_ARCHIVE_SHA256,,}"
  write_verified_input sensor-producer-commit "$EXPECTED_SENSOR_PRODUCER_COMMIT"
  write_verified_input haptics-deb-archive "${HAPTICS_DEB_ARCHIVE:-directory:$HAPTICS_DEB_DIR}"
  write_verified_input haptics-deb-archive-sha256 "${HAPTICS_DEB_ARCHIVE_SHA256,,}"
  write_verified_input haptics-producer-commit "$EXPECTED_HAPTICS_PRODUCER_COMMIT"
  write_verified_input haptics-module-sha256 "$EXPECTED_HAPTICS_MODULE_SHA256"
  write_verified_input haptics-helper-binary-sha256 \
    "$EXPECTED_HAPTICS_HELPER_BINARY_SHA256"
} > "$stage/VERIFIED-INPUTS.tsv"

{
  printf 'KERNEL_ARTIFACT_ARCHIVE=%s/kernel-artifacts.archive\n' "$output_path"
  printf 'KERNEL_ARTIFACT_ARCHIVE_SHA256=%s\n' "$kernel_archive_sha"
  printf 'DEB_ARCHIVE=%s/device-debs.archive\n' "$output_path"
  printf 'DEB_ARCHIVE_SHA256=%s\n' "$device_archive_sha"
  printf 'DEB_DIR=\n'
  printf 'SENSOR_DEB_ARCHIVE=%s/sensor-debs.archive\n' "$output_path"
  printf 'SENSOR_DEB_ARCHIVE_SHA256=%s\n' "$sensor_archive_sha"
  printf 'SENSOR_DEB_DIR=\n'
  if [ -n "$HAPTICS_DEB_ARCHIVE" ]; then
    printf 'HAPTICS_DEB_ARCHIVE=%s/haptics-debs.archive\n' "$output_path"
    printf 'HAPTICS_DEB_ARCHIVE_SHA256=%s\n' "$haptics_archive_sha"
    printf 'HAPTICS_DEB_DIR=\n'
  else
    printf 'HAPTICS_DEB_ARCHIVE=\n'
    printf 'HAPTICS_DEB_ARCHIVE_SHA256=\n'
    printf 'HAPTICS_DEB_DIR=%s/haptics-debs\n' "$output_path"
  fi
  printf 'KERNEL_BUNDLE_ID=%s\n' "${kernel_meta[kernel-bundle-id]}"
  printf 'KERNEL_BUNDLE_RELEASE=%s\n' "${kernel_meta[kernel-release]}"
  printf 'KERNEL_BUNDLE_METADATA=%s/KERNEL-BUNDLE.tsv\n' "$output_path"
  printf 'VERIFIED_KERNEL_BUNDLE_DIR=%s\n' "$output_path"
} > "$stage/verified.env"

mv "$stage" "$output_path"
trap - EXIT
cleanup
printf 'KERNEL_BUNDLE_VERIFY=PASS bundle=%s release=%s modules=%d output=%s\n' \
  "${kernel_meta[kernel-bundle-id]}" "${kernel_meta[kernel-release]}" "$module_count" "$output_path"
