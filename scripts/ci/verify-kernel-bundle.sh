#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

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
  HAPTICS_DEB_ARCHIVE and HAPTICS_DEB_ARCHIVE_SHA256,
    or HAPTICS_DEB_DIR

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

for command in sha256sum find sort cmp dpkg-deb realpath install awk python3 head grep stat; do
  ci_require_cmd "$command"
done

: "${KERNEL_ARTIFACT_ARCHIVE:?set KERNEL_ARTIFACT_ARCHIVE}"
: "${KERNEL_ARTIFACT_ARCHIVE_SHA256:?set KERNEL_ARTIFACT_ARCHIVE_SHA256}"
: "${DEB_ARCHIVE:?set DEB_ARCHIVE}"
: "${DEB_ARCHIVE_SHA256:?set DEB_ARCHIVE_SHA256}"
: "${SENSOR_DEB_ARCHIVE:?set SENSOR_DEB_ARCHIVE}"
: "${SENSOR_DEB_ARCHIVE_SHA256:?set SENSOR_DEB_ARCHIVE_SHA256}"

HAPTICS_DEB_ARCHIVE=${HAPTICS_DEB_ARCHIVE:-}
HAPTICS_DEB_ARCHIVE_SHA256=${HAPTICS_DEB_ARCHIVE_SHA256:-}
HAPTICS_DEB_DIR=${HAPTICS_DEB_DIR:-}
OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-verified-kernel-bundle}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
MODINFO=${MODINFO:-modinfo}

[[ $KERNEL_ARTIFACT_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid kernel archive SHA-256"
[[ $DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid device archive SHA-256"
[[ $SENSOR_DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid sensor archive SHA-256"
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

load_tsv() {
  local file=$1
  local -n values=$2
  local line key value extra

  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line != *$'\r'* ]] || ci_die "TSV contains CR: $file"
    IFS=$'\t' read -r key value extra <<<"$line"
    [ -n "$key" ] && [ -n "$value" ] && [ -z "$extra" ] || ci_die "malformed TSV: $file"
    [[ $key =~ ^[a-z0-9_-]+$ ]] || ci_die "unsafe TSV key $key: $file"
    [ -z "${values[$key]+x}" ] || ci_die "duplicate TSV key $key: $file"
    values[$key]=$value
  done < "$file"
}

require_tsv_key() {
  local -n values=$1
  local key=$2 file=$3
  [ -n "${values[$key]:-}" ] || ci_die "missing TSV key $key: $file"
}

check_sha() {
  local file=$1 expected=$2 label=$3 actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "$expected" ] || ci_die "$label SHA-256 mismatch: expected $expected, got $actual"
}

validate_sensor_archive() {
  local root=$1 deb package architecture version common_version=
  local source_lock checksum_file checksum_dir
  local -A expected=(
    [qcom-sns-libssc]=0
    [qcom-sns-hexagonrpc]=0
    [qcom-sns-iio-sensor-proxy]=0
    [tb321fu-sensors]=0
  )
  local -a sensor_debs=()

  mapfile -d '' -t sensor_debs < <(find "$root" -type f -name '*.deb' -print0 | sort -z)
  [ "${#sensor_debs[@]}" -eq "${#expected[@]}" ] ||
    ci_die "sensor archive must contain exactly four DEBs"
  for deb in "${sensor_debs[@]}"; do
    package=$(dpkg-deb -f "$deb" Package)
    architecture=$(dpkg-deb -f "$deb" Architecture)
    version=$(dpkg-deb -f "$deb" Version)
    [ -n "${expected[$package]+x}" ] || ci_die "unexpected sensor package: $package"
    [ "${expected[$package]}" -eq 0 ] || ci_die "duplicate sensor package: $package"
    [ "$architecture" = arm64 ] || ci_die "sensor package is not arm64: $package"
    if [ -z "$common_version" ]; then
      common_version=$version
    else
      [ "$version" = "$common_version" ] || ci_die "sensor package versions differ"
    fi
    expected[$package]=1
  done
  for package in "${!expected[@]}"; do
    [ "${expected[$package]}" -eq 1 ] || ci_die "missing sensor package: $package"
  done

  find_unique_file source_lock "$root" SOURCE-LOCK.tsv 'sensor SOURCE-LOCK.tsv'
  head -n 1 "$source_lock" | grep -Fxq $'component\trepository\tcommit' ||
    ci_die "sensor source lock has an invalid header"
  grep -Fxq $'producer-state\tgit-status\tclean' "$source_lock" ||
    ci_die "sensor source lock is not from a clean producer"
  find_unique_file checksum_file "$root" SHA256SUMS-y700-sensor-debs.txt \
    'sensor package checksum manifest'
  checksum_dir=$(dirname -- "$checksum_file")
  (cd "$checksum_dir" && sha256sum -c "$(basename -- "$checksum_file")" >/dev/null) ||
    ci_die "sensor package checksum verification failed"
  sensor_source_lock=$source_lock
  sensor_package_version=$common_version
}

find_unique_file kernel_bundle "$kernel_root" KERNEL-BUNDLE.tsv 'kernel KERNEL-BUNDLE.tsv'
find_unique_file device_bundle "$device_root" KERNEL-BUNDLE.tsv 'device KERNEL-BUNDLE.tsv'
validated_bundle="$work/KERNEL-BUNDLE.validated.tsv"
python3 "$SCRIPT_DIR/verify-kernel-bundle.py" \
  "$kernel_bundle" --identical "$device_bundle" --emit-tsv > "$validated_bundle" ||
  ci_die "kernel and device bundle metadata verification failed"
declare -A kernel_meta=()
load_tsv "$validated_bundle" kernel_meta

find_unique_file kernel_source_lock "$kernel_root" SOURCE-LOCK.tsv 'kernel SOURCE-LOCK.tsv'
find_unique_file device_source_lock "$device_root" SOURCE-LOCK.tsv 'device SOURCE-LOCK.tsv'
cmp -s "$kernel_source_lock" "$device_source_lock" || ci_die "kernel and device source locks differ"
declare -A source_lock=()
load_tsv "$kernel_source_lock" source_lock
for key in schema kernel_bundle_id kernel_commit kernel_release config_sha256 image_sha256 dtb_sha256 modules_deb_sha256; do
  require_tsv_key source_lock "$key" "$kernel_source_lock"
done
[ "${source_lock[schema]}" = tb321fu.kernel-bootstrap/v2 ] || ci_die "unsupported kernel source-lock schema"
[ "${source_lock[kernel_bundle_id]}" = "${kernel_meta[kernel-bundle-id]}" ] || ci_die "source lock kernel bundle ID mismatch"
[ "${source_lock[kernel_commit]}" = "${kernel_meta[kernel-source-commit]}" ] || ci_die "source lock kernel commit mismatch"
[ "${source_lock[kernel_release]}" = "${kernel_meta[kernel-release]}" ] || ci_die "source lock kernel release mismatch"
[ "${source_lock[config_sha256]}" = "${kernel_meta[kernel-config-sha256]}" ] || ci_die "source lock kernel config mismatch"

find_unique_file kernel_image "$kernel_root" Image 'kernel Image'
find_unique_file kernel_dtb "$kernel_root" "$DTB_NAME" "kernel $DTB_NAME"
find_unique_file kernel_config "$kernel_root" kernel.config 'kernel config'
find_unique_file modules_deb "$device_root" 'y700-daily-kernel-modules_*.deb' 'kernel modules DEB'
check_sha "$kernel_image" "${source_lock[image_sha256]}" 'kernel Image'
check_sha "$kernel_dtb" "${source_lock[dtb_sha256]}" 'kernel DTB'
check_sha "$kernel_config" "${source_lock[config_sha256]}" 'kernel config'
check_sha "$modules_deb" "${source_lock[modules_deb_sha256]}" 'kernel modules DEB'

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
while IFS= read -r -d '' module; do
  vermagic=$("$MODINFO" -F vermagic "$module")
  case "$vermagic" in
    "${kernel_meta[kernel-release]}"|"${kernel_meta[kernel-release]} "*) ;;
    *) ci_die "kernel module vermagic mismatch: $module: $vermagic" ;;
  esac
  module_count=$((module_count + 1))
done < <(find "${module_dirs[0]}" -type f -name '*.ko*' -print0)
[ "$module_count" -gt 0 ] || ci_die "kernel modules DEB contains no modules"

find_unique_file haptics_lock "$haptics_root" HAPTICS-SOURCE-LOCK.tsv 'HAPTICS-SOURCE-LOCK.tsv'
declare -A haptics_meta=()
load_tsv "$haptics_lock" haptics_meta
for key in kernel-bundle-id kernel-release kernel-source-commit kernel-config-sha256; do
  require_tsv_key haptics_meta "$key" "$haptics_lock"
done
[ "${haptics_meta[kernel-bundle-id]}" = "${kernel_meta[kernel-bundle-id]}" ] || ci_die "haptics kernel-bundle-id mismatch"
[ "${haptics_meta[kernel-release]}" = "${kernel_meta[kernel-release]}" ] || ci_die "haptics kernel-release mismatch"
[ "${haptics_meta[kernel-source-commit]}" = "${kernel_meta[kernel-source-commit]}" ] || ci_die "haptics kernel-source-commit mismatch"
[ "${haptics_meta[kernel-config-sha256]}" = "${kernel_meta[kernel-config-sha256]}" ] || ci_die "haptics kernel-config-sha256 mismatch"

find_unique_file haptics_deb "$haptics_root" 'tb321fu-haptics_*.deb' 'haptics DEB'
[ "$(dpkg-deb -f "$haptics_deb" Package)" = tb321fu-haptics ] || ci_die "unexpected haptics package name"
[ "$(dpkg-deb -f "$haptics_deb" Architecture)" = arm64 ] || ci_die "unexpected haptics package architecture"
haptics_data_tar="$work/haptics-data.tar"
haptics_data="$work/haptics-data"
dpkg-deb --fsys-tarfile "$haptics_deb" > "$haptics_data_tar"
ci_extract_archive "$haptics_data_tar" "$haptics_data"
mapfile -d '' -t haptics_modules < <(find "$haptics_data/usr/lib/modules" -type f -name 'aw86937-haptics.ko*' -print0 2>/dev/null)
[ "${#haptics_modules[@]}" -eq 1 ] || ci_die "haptics DEB must contain exactly one aw86937-haptics module"
case "${haptics_modules[0]}" in
  */usr/lib/modules/"${kernel_meta[kernel-release]}"/extra/aw86937-haptics.ko*) ;;
  *) ci_die "haptics module path release mismatch" ;;
esac
haptics_vermagic=$("$MODINFO" -F vermagic "${haptics_modules[0]}")
case "$haptics_vermagic" in
  "${kernel_meta[kernel-release]}"|"${kernel_meta[kernel-release]} "*) ;;
  *) ci_die "haptics module vermagic mismatch: $haptics_vermagic" ;;
esac

stage="$work/stage"
mkdir -p "$stage"
install -m 0644 "$kernel_archive" "$stage/kernel-artifacts.archive"
install -m 0644 "$device_archive" "$stage/device-debs.archive"
install -m 0644 "$sensor_archive" "$stage/sensor-debs.archive"
install -m 0644 "$kernel_bundle" "$stage/KERNEL-BUNDLE.tsv"
install -m 0644 "$kernel_source_lock" "$stage/KERNEL-SOURCE-LOCK.tsv"
install -m 0644 "$sensor_source_lock" "$stage/SENSOR-SOURCE-LOCK.tsv"
install -m 0644 "$haptics_lock" "$stage/HAPTICS-SOURCE-LOCK.tsv"
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
  printf 'schema\ttb321fu.verified-kernel-bundle/v1\n'
  printf 'kernel-bundle-id\t%s\n' "${kernel_meta[kernel-bundle-id]}"
  printf 'kernel-release\t%s\n' "${kernel_meta[kernel-release]}"
  printf 'kernel-source-commit\t%s\n' "${kernel_meta[kernel-source-commit]}"
  printf 'kernel-config-sha256\t%s\n' "${kernel_meta[kernel-config-sha256]}"
  printf 'kernel-archive-sha256\t%s\n' "$kernel_archive_sha"
  printf 'device-archive-sha256\t%s\n' "$device_archive_sha"
  printf 'sensor-archive-sha256\t%s\n' "$sensor_archive_sha"
  printf 'sensor-package-version\t%s\n' "$sensor_package_version"
  printf 'haptics-archive-sha256\t%s\n' "${haptics_archive_sha:-directory-input}"
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
  write_verified_input haptics-deb-archive "${HAPTICS_DEB_ARCHIVE:-directory:$HAPTICS_DEB_DIR}"
  write_verified_input haptics-deb-archive-sha256 "${HAPTICS_DEB_ARCHIVE_SHA256,,}"
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
