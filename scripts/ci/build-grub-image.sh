#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

log() { ci_log "$@"; }
die() { ci_die "$@"; }

REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
. "$REPO_ROOT/scripts/lib/y700-direct-grub.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build a FAT boot image containing BOOTAA64.EFI, QCOMRAMP.EFI, Image, DTB and GRUB config.

Environment inputs:
  OUTPUT_DIR                 default: out/ci-grub
  OUTPUT_PREFIX              default: y700
  BOOT_TEMPLATE_IMAGE        optional verified FAT image template path/URL
  BOOT_TEMPLATE_IMAGE_URL    optional verified FAT image template URL/path
  BOOT_IMAGE_SIZE            default: 14G
  BOOT_FAT_BITS              12|16|32, default: 32
  BOOT_FAT_LABEL             default: Y700GRUB
  BOOT_FAT_VOLUME_ID         fresh-image 8-hex volume id, default: 00000000
  BOOT_SECTOR_SIZE           default: 512
  BOOT_CLUSTER_SECTORS       optional mkfs.vfat -s value
  KERNEL_IMAGE               required unless KERNEL_ARTIFACT_ARCHIVE supplies Image
  DTB_FILE                   required unless KERNEL_ARTIFACT_ARCHIVE supplies DTB_NAME
  DTB_NAME                   default: basename(DTB_FILE) or sm8650-lenovo-tb321fu.dtb
  KERNEL_CONFIG              optional
  BOOTAA64_EFI               required unless BOOTAA64_EFI_URL set; optional with BOOT_TEMPLATE_IMAGE
  BOOTAA64_EFI_URL           optional URL/local path
  QCOMRAMP_EFI               optional prebuilt direct GRUB EFI
  QCOMRAMP_EFI_URL           optional URL/local path for prebuilt direct GRUB EFI
  QCOMRAMP_CFG_NAME          external config name expected by prebuilt EFI, default: qcomramp.cfg
  KERNEL_ARTIFACT_ARCHIVE    optional URL/local path extracted before lookup
  Y700_GRUB_BUILD_DIR        directory containing grub-mkstandalone and grub-core; only needed without QCOMRAMP_EFI_URL
  GRUB_TIMEOUT               default: 3
  ROOT_PARTLABEL             default: userdata
  ROOT_UUID                  optional; used if ROOT_SELECTOR=uuid
  ROOT_SELECTOR              partlabel|uuid|raw, default: partlabel
  ROOTARGS                   optional full rootargs override
  ROOTARGS_EXTRA             appended to generated rootargs
  STABLEARGS                 default: drm_client_lib.active=none
  BOOT_COMPRESS              none|zstd|xz|7z, default: 7z
  BOOT_CHUNK_SIZE            optional 7z volume size; empty disables volumes
  KEEP_BOOT_IMAGE            keep uncompressed boot image after packaging, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd mkfs.vfat
ci_require_cmd mcopy
ci_require_cmd mdir
ci_require_cmd mtype
ci_require_cmd fsck.fat
ci_require_cmd cmp
ci_require_cmd sha256sum
ci_require_cmd dd
ci_require_cmd od
ci_require_cmd stat

OUTPUT_DIR=${OUTPUT_DIR:-out/ci-grub}
ci_validate_output_dir "$OUTPUT_DIR"
OUTPUT_PREFIX=${OUTPUT_PREFIX:-y700}
ci_validate_output_prefix "$OUTPUT_PREFIX"
BOOT_TEMPLATE_IMAGE=${BOOT_TEMPLATE_IMAGE:-}
BOOT_TEMPLATE_IMAGE_URL=${BOOT_TEMPLATE_IMAGE_URL:-}
if [ -n "$BOOT_TEMPLATE_IMAGE" ] && [ -n "$BOOT_TEMPLATE_IMAGE_URL" ]; then
  ci_die 'BOOT_TEMPLATE_IMAGE and BOOT_TEMPLATE_IMAGE_URL are mutually exclusive'
fi
BOOT_TEMPLATE_IMAGE=${BOOT_TEMPLATE_IMAGE:-$BOOT_TEMPLATE_IMAGE_URL}
BOOT_TEMPLATE_IMAGE_SHA256=${BOOT_TEMPLATE_IMAGE_SHA256:-}
BOOT_IMAGE_SIZE=${BOOT_IMAGE_SIZE:-14G}
BOOT_FAT_BITS=${BOOT_FAT_BITS:-32}
BOOT_FAT_LABEL=${BOOT_FAT_LABEL:-Y700GRUB}
BOOT_FAT_VOLUME_ID=${BOOT_FAT_VOLUME_ID:-00000000}
BOOT_SECTOR_SIZE=${BOOT_SECTOR_SIZE:-512}
GRUB_TIMEOUT=${GRUB_TIMEOUT:-3}
ROOT_PARTLABEL=${ROOT_PARTLABEL:-userdata}
ROOT_SELECTOR=${ROOT_SELECTOR:-partlabel}
STABLEARGS=${STABLEARGS:-drm_client_lib.active=none}
QCOMRAMP_CFG_NAME=${QCOMRAMP_CFG_NAME:-qcomramp.cfg}
BOOT_COMPRESS=${BOOT_COMPRESS:-7z}
BOOT_CHUNK_SIZE=${BOOT_CHUNK_SIZE:-}
KEEP_BOOT_IMAGE=${KEEP_BOOT_IMAGE:-0}
KERNEL_ARTIFACT_ARCHIVE=${KERNEL_ARTIFACT_ARCHIVE:-}
KERNEL_ARTIFACT_ARCHIVE_SHA256=${KERNEL_ARTIFACT_ARCHIVE_SHA256:-}
BOOTAA64_EFI=${BOOTAA64_EFI:-}
BOOTAA64_EFI_URL=${BOOTAA64_EFI_URL:-}
BOOTAA64_EFI_SHA256=${BOOTAA64_EFI_SHA256:-}
QCOMRAMP_EFI=${QCOMRAMP_EFI:-}
QCOMRAMP_EFI_URL=${QCOMRAMP_EFI_URL:-}
QCOMRAMP_EFI_SHA256=${QCOMRAMP_EFI_SHA256:-}
[[ $BOOT_FAT_VOLUME_ID =~ ^[A-Fa-f0-9]{8}$ ]] || ci_die "invalid BOOT_FAT_VOLUME_ID=$BOOT_FAT_VOLUME_ID"
ci_validate_image_size BOOT_IMAGE_SIZE "$BOOT_IMAGE_SIZE" 16 131072
[[ "$BOOT_FAT_BITS" =~ ^(12|16|32)$ ]] || ci_die "invalid BOOT_FAT_BITS=$BOOT_FAT_BITS"
[[ "$BOOT_FAT_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,10}$ ]] || ci_die "invalid BOOT_FAT_LABEL=$BOOT_FAT_LABEL"
ci_validate_volume_size "$BOOT_CHUNK_SIZE" BOOT_CHUNK_SIZE
[[ "$BOOT_SECTOR_SIZE" =~ ^(512|1024|2048|4096)$ ]] || ci_die "invalid BOOT_SECTOR_SIZE=$BOOT_SECTOR_SIZE"
if [ -n "${BOOT_CLUSTER_SECTORS:-}" ]; then
  [[ "$BOOT_CLUSTER_SECTORS" =~ ^[1-9][0-9]{0,2}$ ]] || ci_die "invalid BOOT_CLUSTER_SECTORS=$BOOT_CLUSTER_SECTORS"
  (( BOOT_CLUSTER_SECTORS <= 128 )) || ci_die "BOOT_CLUSTER_SECTORS exceeds 128"
fi
y700_validate_timeout "$GRUB_TIMEOUT"
[[ "$ROOT_PARTLABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,35}$ ]] || ci_die "unsafe ROOT_PARTLABEL=$ROOT_PARTLABEL"
ci_validate_download_source BOOT_TEMPLATE_IMAGE "$BOOT_TEMPLATE_IMAGE" "$BOOT_TEMPLATE_IMAGE_SHA256"
ci_validate_download_source KERNEL_ARTIFACT_ARCHIVE "$KERNEL_ARTIFACT_ARCHIVE" "$KERNEL_ARTIFACT_ARCHIVE_SHA256"
ci_validate_download_source BOOTAA64_EFI_URL "$BOOTAA64_EFI_URL" "$BOOTAA64_EFI_SHA256"
ci_validate_download_source QCOMRAMP_EFI_URL "$QCOMRAMP_EFI_URL" "$QCOMRAMP_EFI_SHA256"
if [ -n "$BOOTAA64_EFI" ] && [ -n "$BOOTAA64_EFI_URL" ]; then
  ci_die 'BOOTAA64_EFI and BOOTAA64_EFI_URL are mutually exclusive'
fi
if [ -n "$QCOMRAMP_EFI" ] && [ -n "$QCOMRAMP_EFI_URL" ]; then
  ci_die 'QCOMRAMP_EFI and QCOMRAMP_EFI_URL are mutually exclusive'
fi
require_regular_file() {
  local label=$1 path=$2
  [ -n "$path" ] && [ -f "$path" ] && [ ! -L "$path" ] ||
    ci_die "$label must be an existing regular non-symlink file: $path"
}
if [ -n "$BOOTAA64_EFI" ]; then
  require_regular_file BOOTAA64_EFI "$BOOTAA64_EFI"
fi
if [ -n "$QCOMRAMP_EFI" ]; then
  require_regular_file QCOMRAMP_EFI "$QCOMRAMP_EFI"
fi
SOURCE_DATE_EPOCH=$(ci_source_date_epoch)
export SOURCE_DATE_EPOCH
generated_timestamp=$(ci_iso8601_timestamp)

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.grub-build.XXXXXX")
payload_dir="$work_dir/payload"
mkdir -p "$payload_dir/EFI/BOOT" "$payload_dir/dtb"
cleanup() {
  ci_safe_rmtree "$work_dir" "$OUTPUT_DIR" .grub-build.
}
trap cleanup EXIT

find_unique_artifact() {
  local -n result=$1
  local root=$2 pattern=$3 label=$4
  local -a matches=()
  mapfile -d '' -t matches < <(find "$root" -type f -name "$pattern" -print0 | sort -z)
  case ${#matches[@]} in
    0) result= ;;
    1) result=${matches[0]} ;;
    *)
      printf 'ambiguous %s candidates in artifact archive:\n' "$label" >&2
      printf '  %s\n' "${matches[@]}" >&2
      ci_die "artifact archive must contain at most one $label"
      ;;
  esac
}

download_template_if_needed() {
  local src=$1
  local dst=$2 verifier=$3
  [ -n "$src" ] || return 1
  ci_download "$src" "$dst" "$verifier"
}

portable_source_basename() {
  local source=$1 label=$2 name
  name=$(basename -- "$source")
  [[ -n "$name" && ${#name} -le 256 &&
     "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._~@%+,-]*$ ]] ||
    ci_die "$label has a non-portable basename"
  printf '%s\n' "$name"
}

file_sha256() {
  local path=$1 digest remainder
  read -r digest remainder < <(sha256sum -- "$path")
  ci_validate_sha256 file_sha256 "$digest"
  printf '%s\n' "$digest"
}

fat_readback_index=0
verify_fat_file() {
  local image=$1 expected=$2 image_path=$3 actual
  fat_readback_index=$((fat_readback_index + 1))
  actual="$work_dir/fat-readback/file-$fat_readback_index"
  mkdir -p "$(dirname -- "$actual")"
  mcopy -i "$image" "::$image_path" "$actual"
  cmp -s -- "$expected" "$actual" ||
    ci_die "FAT readback differs for $image_path"
}

fat_namespace_key() {
  local path=$1
  LC_ALL=C printf '%s\n' "$path" | tr '[:lower:]' '[:upper:]'
}

fat_validate_namespace_path() {
  local path=$1 label=${2:-FAT path} component
  local LC_ALL=C

  [[ "$path" == /* && "$path" != */ && "$path" != *'//'*
     && "$path" != *$'\t'* && "$path" != *$'\r'* && "$path" != *$'\n'* ]] ||
    ci_die "$label has an unsafe FAT path: $path"
  [[ "$path" =~ ^/[[:print:]]+$ ]] ||
    ci_die "$label contains a non-printable FAT path: $path"
  case "$path" in
    *'*'*|*'?'*|*'['*|*']'*|*':'*|*'\'*)
      ci_die "$label contains an mtools metacharacter: $path" ;;
  esac
  IFS=/ read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] ||
      ci_die "$label contains an invalid path component: $path"
  done
}

fat_read_le() {
  local image=$1 offset=$2 width=$3 value=0 byte index
  for ((index = 0; index < width; ++index)); do
    byte=$(od -An -tu1 -j "$((offset + index))" -N 1 "$image" | tr -d '[:space:]')
    [[ "$byte" =~ ^[0-9]+$ ]] || return 1
    value=$((value + byte * (1 << (8 * index))))
  done
  printf '%u\n' "$value"
}

fat_profile_snapshot() {
  local image=$1 output=$2 image_size bytes_per_sector sectors_per_cluster
  local reserved_sectors fat_count root_entries total16 fat_size16 total32 fat_size32
  local total_sectors fat_size volume_id_offset volume_id boot_sector boot_digest

  mkdir -p "$(dirname -- "$output")"
  image_size=$(stat -c '%s' -- "$image") ||
    ci_die "cannot stat FAT image: $image"
  [[ "$image_size" =~ ^[0-9]+$ && "$image_size" -gt 0 ]] ||
    ci_die "FAT image has an invalid size: $image"
  bytes_per_sector=$(fat_read_le "$image" 11 2) ||
    ci_die "cannot read FAT bytes-per-sector: $image"
  sectors_per_cluster=$(fat_read_le "$image" 13 1) ||
    ci_die "cannot read FAT sectors-per-cluster: $image"
  reserved_sectors=$(fat_read_le "$image" 14 2) ||
    ci_die "cannot read FAT reserved-sector count: $image"
  fat_count=$(fat_read_le "$image" 16 1) ||
    ci_die "cannot read FAT count: $image"
  root_entries=$(fat_read_le "$image" 17 2) ||
    ci_die "cannot read FAT root-entry count: $image"
  total16=$(fat_read_le "$image" 19 2) ||
    ci_die "cannot read FAT total-sector field: $image"
  fat_size16=$(fat_read_le "$image" 22 2) ||
    ci_die "cannot read FAT size field: $image"
  total32=$(fat_read_le "$image" 32 4) ||
    ci_die "cannot read FAT extended total-sector field: $image"
  fat_size32=$(fat_read_le "$image" 36 4) ||
    ci_die "cannot read FAT extended size field: $image"
  (( bytes_per_sector == 512 || bytes_per_sector == 1024 ||
     bytes_per_sector == 2048 || bytes_per_sector == 4096 )) ||
    ci_die "FAT image has an unsupported sector size: $bytes_per_sector"
  (( sectors_per_cluster > 0 && sectors_per_cluster <= 128 )) ||
    ci_die "FAT image has an invalid cluster geometry"
  (( fat_count > 0 )) || ci_die "FAT image has no FAT tables"
  total_sectors=$((total16 != 0 ? total16 : total32))
  fat_size=$((fat_size16 != 0 ? fat_size16 : fat_size32))
  (( total_sectors > 0 && fat_size > 0 )) ||
    ci_die "FAT image has incomplete BPB geometry"
  (( image_size >= bytes_per_sector )) ||
    ci_die "FAT image is shorter than its boot sector"
  if (( fat_size16 != 0 )); then
    volume_id_offset=39
  else
    volume_id_offset=67
  fi
  volume_id=$(fat_read_le "$image" "$volume_id_offset" 4) ||
    ci_die "cannot read FAT volume id: $image"
  boot_sector="$output.boot-sector"
  dd if="$image" of="$boot_sector" bs=1 count="$bytes_per_sector" status=none 2>/dev/null ||
    ci_die "cannot read FAT boot sector: $image"
  [ "$(stat -c '%s' -- "$boot_sector")" = "$bytes_per_sector" ] ||
    ci_die "FAT boot sector is truncated: $image"
  boot_digest=$(sha256sum -- "$boot_sector" | awk '{print $1}')
  rm -f -- "$boot_sector"
  cat > "$output" <<PROFILE
image_size=$image_size
bytes_per_sector=$bytes_per_sector
sectors_per_cluster=$sectors_per_cluster
reserved_sectors=$reserved_sectors
fat_count=$fat_count
root_entries=$root_entries
total_sectors=$total_sectors
fat_size=$fat_size
volume_id=$volume_id
boot_sector_sha256=$boot_digest
PROFILE
}

verify_fat_profile() {
  local expected_profile=$1 image=$2 actual_profile="$work_dir/fat-readback/final-fat-profile.txt"
  fat_profile_snapshot "$image" "$actual_profile"
  cmp -s -- "$expected_profile" "$actual_profile" ||
    ci_die 'FAT image size or boot-sector/BPB profile changed'
}

capture_fat_namespace() {
  local image=$1 output=$2 entry path type key
  local listing="$output.raw"
  mkdir -p "$(dirname -- "$output")"
  LC_ALL=C mdir -a -s -b -i "$image" :: > "$listing" ||
    ci_die "cannot enumerate FAT namespace: $image"
  : > "$output"
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry=${entry%$'\r'}
    [ -n "$entry" ] || continue
    [[ "$entry" == ::/* ]] || ci_die "mdir emitted an invalid FAT namespace entry: $entry"
    path=${entry#::}
    type=f
    if [[ "$path" == */ ]]; then
      type=d
      path=${path%/}
    fi
    fat_validate_namespace_path "$path" 'FAT namespace entry'
    key=$(fat_namespace_key "$path")
    printf '%s\t%s\t%s\n' "$key" "$type" "$path" >> "$output"
  done < "$listing"
  rm -f -- "$listing"
  LC_ALL=C sort -t $'\t' -k1,1 "$output" -o "$output"
  awk -F '\t' 'NR > 1 && $1 == previous { exit 1 } { previous = $1 }' "$output" ||
    ci_die "FAT namespace contains duplicate case-folded paths: $image"
}

build_payload_namespace() {
  local root=$1 output=$2 relative path key invalid
  [ -d "$root" ] || ci_die "payload directory does not exist: $root"
  invalid=$(find "$root" -mindepth 1 ! -type d ! -type f -print -quit)
  [ -z "$invalid" ] || ci_die "payload contains a non-regular entry: $invalid"
  mkdir -p "$(dirname -- "$output")"
  : > "$output"
  while IFS= read -r -d '' relative; do
    path="/$relative"
    fat_validate_namespace_path "$path" 'payload directory'
    key=$(fat_namespace_key "$path")
    printf '%s\td\t%s\n' "$key" "$path" >> "$output"
  done < <(cd "$root" && find . -mindepth 1 -type d -printf '%P\0' | LC_ALL=C sort -z)
  while IFS= read -r -d '' relative; do
    path="/$relative"
    fat_validate_namespace_path "$path" 'payload file'
    key=$(fat_namespace_key "$path")
    printf '%s\tf\t%s\n' "$key" "$path" >> "$output"
  done < <(cd "$root" && find . -mindepth 1 -type f -printf '%P\0' | LC_ALL=C sort -z)
  LC_ALL=C sort -t $'\t' -k1,1 "$output" -o "$output"
  awk -F '\t' 'NR > 1 && $1 == previous { exit 1 } { previous = $1 }' "$output" ||
    ci_die "payload namespace contains duplicate case-folded paths: $root"
}

fat_lookup_path() {
  local namespace=$1 path=$2 key
  key=$(fat_namespace_key "$path")
  awk -F '\t' -v wanted="$key" '$1 == wanted { print $2 "\t" $3; found = 1; exit }
    END { if (!found) exit 1 }' "$namespace"
}

fat_overlay_add() {
  local output=$1 path=$2 type=$3 source=$4 key existing parent parent_entry
  fat_validate_namespace_path "$path" 'template overlay'
  [ "$type" = f ] || ci_die "template overlay supports regular files only: $path"
  [ -f "$source" ] && [ ! -L "$source" ] ||
    ci_die "template overlay source is not a regular file: $source"
  if [ -n "${template_namespace:-}" ]; then
    if existing=$(fat_lookup_path "$template_namespace" "$path"); then
      [ "${existing%%$'\t'*}" = f ] ||
        ci_die "template overlay target is not a regular file: $path"
    fi
    parent=${path%/*}
    [ -n "$parent" ] || parent=/
    [ "$parent" = "$path" ] && parent=/
    if [ "$parent" != / ]; then
      parent_entry=$(fat_lookup_path "$template_namespace" "$parent") ||
        ci_die "template overlay parent is missing from the FAT template: $parent"
      [ "${parent_entry%%$'\t'*}" = d ] ||
        ci_die "template overlay parent is not a directory: $parent"
    fi
  fi
  key=$(fat_namespace_key "$path")
  if existing=$(awk -F '\t' -v wanted="$key" '$1 == wanted { print $2 "\t" $3 "\t" $4; exit }' "$output") &&
     [ -n "$existing" ]; then
    [ "$existing" = "$key"$'\t'"$type"$'\t'"$path"$'\t'"$source" ] ||
      ci_die "template overlay registers conflicting writes for $path"
    return
  fi
  printf '%s\t%s\t%s\t%s\n' "$key" "$type" "$path" "$source" >> "$output"
}

build_template_expected_namespace() {
  local original=$1 overlay=$2 output=$3
  awk -F '\t' -v overlay_file="$overlay" '
    FILENAME == overlay_file { overlay_path[$1] = $2 "\t" $3; next }
    { if ($1 in overlay_path) { print $1 "\t" overlay_path[$1]; delete overlay_path[$1] } else print }
    END { for (key in overlay_path) print key "\t" overlay_path[key] }
  ' "$overlay" "$original" | LC_ALL=C sort -t $'\t' -k1,1 > "$output"
  awk -F '\t' 'NR > 1 && $1 == previous { exit 1 } { previous = $1 }' "$output" ||
    ci_die 'template expected namespace contains duplicate paths'
}

verify_template_preserved_file() {
  local template=$1 image=$2 path=$3 index=$4 original="$work_dir/fat-readback/preserved-$4.template"
  local final="$work_dir/fat-readback/preserved-$4.final"
  rm -f -- "$original" "$final"
  mcopy -i "$template" "::$path" "$original" ||
    ci_die "cannot read preserved template file: $path"
  mcopy -i "$image" "::$path" "$final" ||
    ci_die "cannot read preserved final FAT file: $path"
  cmp -s -- "$original" "$final" ||
    ci_die "template-preserved FAT file changed: $path"
  rm -f -- "$original" "$final"
}

verify_template_fat_closure() {
  local template=$1 image=$2 original=$3 overlay=$4 profile=$5
  local final_namespace="$work_dir/fat-readback/final-namespace.tsv"
  local expected_namespace="$work_dir/fat-readback/expected-template-namespace.tsv"
  local key type path source index=0
  local -A replaced=()
  capture_fat_namespace "$image" "$final_namespace"
  build_template_expected_namespace "$original" "$overlay" "$expected_namespace"
  cmp -s -- "$expected_namespace" "$final_namespace" ||
    ci_die 'final FAT namespace differs from template plus staged overlay'
  verify_fat_profile "$profile" "$image"
  while IFS=$'\t' read -r key type path source; do
    [ -n "$key" ] || continue
    replaced["$key"]=1
    verify_fat_file "$image" "$source" "$path"
  done < "$overlay"
  while IFS=$'\t' read -r key type path; do
    [ "$type" = f ] || continue
    [ "${replaced[$key]+yes}" = yes ] && continue
    index=$((index + 1))
    verify_template_preserved_file "$template" "$image" "$path" "$index"
  done < "$original"
}

verify_fresh_fat_tree() {
  local image=$1 expected_root=$2
  local expected_namespace="$work_dir/fat-readback/expected-fresh-namespace.tsv"
  local actual_namespace="$work_dir/fat-readback/actual-fresh-namespace.tsv"
  local key type path relative
  build_payload_namespace "$expected_root" "$expected_namespace"
  capture_fat_namespace "$image" "$actual_namespace"
  cmp -s -- "$expected_namespace" "$actual_namespace" ||
    ci_die 'fresh FAT image inventory differs from the staged payload'
  while IFS=$'\t' read -r key type path; do
    [ "$type" = f ] || continue
    relative=${path#/}
    verify_fat_file "$image" "$expected_root/$relative" "$path"
  done < "$expected_namespace"
}

if [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  template_img="$work_dir/boot-template.img"
  ci_log "using verified boot template image: $BOOT_TEMPLATE_IMAGE"
  download_template_if_needed "$BOOT_TEMPLATE_IMAGE" "$template_img" "$BOOT_TEMPLATE_IMAGE_SHA256"
  fsck.fat -n "$template_img" >/dev/null ||
    ci_die 'verified boot template FAT filesystem is inconsistent'
  template_profile="$work_dir/fat-readback/template-fat-profile.txt"
  template_namespace="$work_dir/fat-readback/template-namespace.tsv"
  template_overlay="$work_dir/fat-readback/template-overlay.tsv"
  fat_profile_snapshot "$template_img" "$template_profile"
  capture_fat_namespace "$template_img" "$template_namespace"
  : > "$template_overlay"
fi

if [ -n "${KERNEL_ARTIFACT_ARCHIVE:-}" ]; then
  archive="$work_dir/kernel-artifacts.archive"
  ci_download "$KERNEL_ARTIFACT_ARCHIVE" "$archive" "$KERNEL_ARTIFACT_ARCHIVE_SHA256"
  ci_extract_archive "$archive" "$work_dir/kernel-artifacts"
  DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
  if [ -z "${KERNEL_IMAGE:-}" ]; then
    find_unique_artifact KERNEL_IMAGE "$work_dir/kernel-artifacts" Image 'kernel Image'
  fi
  if [ -z "${DTB_FILE:-}" ]; then
    find_unique_artifact DTB_FILE "$work_dir/kernel-artifacts" "$DTB_NAME" 'device tree'
  fi
  if [ -z "${KERNEL_CONFIG:-}" ]; then
    find_unique_artifact KERNEL_CONFIG "$work_dir/kernel-artifacts" kernel.config 'kernel config'
  fi
fi

if [ -n "${BOOTAA64_EFI_URL:-}" ]; then
  BOOTAA64_EFI="$work_dir/BOOTAA64.EFI"
  ci_download "$BOOTAA64_EFI_URL" "$BOOTAA64_EFI" "$BOOTAA64_EFI_SHA256"
fi
if [ -n "${QCOMRAMP_EFI_URL:-}" ]; then
  QCOMRAMP_EFI="$work_dir/QCOMRAMP.EFI"
  ci_download "$QCOMRAMP_EFI_URL" "$QCOMRAMP_EFI" "$QCOMRAMP_EFI_SHA256"
fi

[ -n "${KERNEL_IMAGE:-}" ] || ci_die "KERNEL_IMAGE is required"
[ -n "${DTB_FILE:-}" ] || ci_die "DTB_FILE is required"
require_regular_file KERNEL_IMAGE "$KERNEL_IMAGE"
require_regular_file DTB_FILE "$DTB_FILE"
if [ -n "${KERNEL_CONFIG:-}" ]; then
  require_regular_file KERNEL_CONFIG "$KERNEL_CONFIG"
fi
if [ -z "$BOOT_TEMPLATE_IMAGE" ]; then
  [ -n "${BOOTAA64_EFI:-}" ] || ci_die "BOOTAA64_EFI or BOOTAA64_EFI_URL is required without BOOT_TEMPLATE_IMAGE"
  require_regular_file BOOTAA64_EFI "$BOOTAA64_EFI"
fi
DTB_NAME=${DTB_NAME:-$(basename "$DTB_FILE")}
y700_validate_dtb_name "$DTB_NAME"
y700_validate_timeout "$GRUB_TIMEOUT"

case "$ROOT_SELECTOR" in
  partlabel)
    [[ $ROOT_PARTLABEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,35}$ ]] || ci_die "unsafe ROOT_PARTLABEL=$ROOT_PARTLABEL"
    generated_rootargs="root=PARTLABEL=$ROOT_PARTLABEL rw rootwait"
    ;;
  uuid)
    [ -n "${ROOT_UUID:-}" ] || ci_die "ROOT_SELECTOR=uuid requires ROOT_UUID"
    [[ $ROOT_UUID =~ ^[0-9A-Fa-f-]{4,64}$ ]] || ci_die "unsafe ROOT_UUID=$ROOT_UUID"
    generated_rootargs="root=UUID=$ROOT_UUID rw rootwait"
    ;;
  raw)
    [ -n "${ROOTARGS:-}" ] || ci_die "ROOT_SELECTOR=raw requires ROOTARGS"
    generated_rootargs="$ROOTARGS"
    ;;
  *) ci_die "unsupported ROOT_SELECTOR=$ROOT_SELECTOR" ;;
esac
if [ -n "${ROOTARGS:-}" ] && [ "$ROOT_SELECTOR" != raw ]; then
  generated_rootargs="$ROOTARGS"
fi
if [ -n "${ROOTARGS_EXTRA:-}" ]; then
  generated_rootargs="$generated_rootargs $ROOTARGS_EXTRA"
fi
y700_validate_kernel_args rootargs "$generated_rootargs"
y700_validate_kernel_args stableargs "$STABLEARGS"
y700_reserved_memory_line >/dev/null || ci_die 'invalid Y700_DIRECT_BOOT_RESERVED_MEMORY'

# A verified template can contain a direct-boot EFI with an embedded or
# template-owned configuration. Do not report caller-supplied root arguments
# as effective unless the matching direct EFI/config are replaced together.
if [ -n "$BOOT_TEMPLATE_IMAGE" ] && [ -z "${QCOMRAMP_EFI:-}" ]; then
  [ "$ROOT_SELECTOR" = partlabel ] ||
    ci_die "BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_SELECTOR"
  [ "$ROOT_PARTLABEL" = userdata ] ||
    ci_die "BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_PARTLABEL"
  [ -z "${ROOT_UUID:-}" ] ||
    ci_die "BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOT_UUID"
  [ -z "${ROOTARGS:-}" ] ||
    ci_die "BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS"
  [ -z "${ROOTARGS_EXTRA:-}" ] ||
    ci_die "BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS_EXTRA"
  [ "$STABLEARGS" = drm_client_lib.active=none ] ||
    ci_die "BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for non-template STABLEARGS"
  [ "$Y700_DIRECT_BOOT_RESERVED_MEMORY" = "/reserved-memory/qdss@82800000 /reserved-memory/splash-region /reserved-memory/trust-ui-vm@f3800000 /reserved-memory/oem-vm@f7c00000" ] ||
    ci_die 'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for non-template reserved memory'
  direct_boot_config_mode=template-preserved
elif [ -n "${QCOMRAMP_EFI:-}" ]; then
  direct_boot_config_mode=external-replaced
else
  direct_boot_config_mode=fresh-embedded
fi

if [ -n "${BOOTAA64_EFI:-}" ]; then
  cp -a "$BOOTAA64_EFI" "$payload_dir/EFI/BOOT/BOOTAA64.EFI"
fi
cp -a "$KERNEL_IMAGE" "$payload_dir/Image"
cp -a "$DTB_FILE" "$payload_dir/dtb/$DTB_NAME"
if [ -n "${KERNEL_CONFIG:-}" ]; then
  cp -a "$KERNEL_CONFIG" "$payload_dir/kernel.config"
fi

if [ -n "${QCOMRAMP_EFI:-}" ]; then
  require_regular_file QCOMRAMP_EFI "$QCOMRAMP_EFI"
  y700_validate_cfg_name "$QCOMRAMP_CFG_NAME"
  y700_validate_efi_name "$Y700_DIRECT_BOOT_EFI_NAME"
  cp -a "$QCOMRAMP_EFI" "$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME"
  y700_write_direct_grub_cfg "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" "$DTB_NAME" "$generated_rootargs" "$STABLEARGS"
  y700_write_outer_grub_cfg "$payload_dir/EFI/BOOT/grub.cfg" "$GRUB_TIMEOUT" "$Y700_DIRECT_BOOT_EFI_NAME"
elif [ -z "$BOOT_TEMPLATE_IMAGE" ]; then
  y700_stage_direct_grub_payload "$payload_dir/EFI/BOOT" "$DTB_NAME" "$GRUB_TIMEOUT" "$generated_rootargs" "$STABLEARGS"
fi

if [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  boot_template_origin=local
  [[ "$BOOT_TEMPLATE_IMAGE" == https://* ]] && boot_template_origin=https
  boot_template_name=$(portable_source_basename "$BOOT_TEMPLATE_IMAGE" BOOT_TEMPLATE_IMAGE)
  boot_template_digest=$(file_sha256 "$template_img")
else
  boot_template_origin=none
  boot_template_name=none
  boot_template_digest=none
fi

kernel_image_origin=local
dtb_origin=local
if [ -n "$KERNEL_ARTIFACT_ARCHIVE" ]; then
  kernel_image_origin=kernel-artifact-archive
  dtb_origin=kernel-artifact-archive
fi
kernel_image_digest=$(file_sha256 "$payload_dir/Image")
dtb_digest=$(file_sha256 "$payload_dir/dtb/$DTB_NAME")

bootaa64_metadata_file="$payload_dir/EFI/BOOT/BOOTAA64.EFI"
if [ -n "$BOOTAA64_EFI_URL" ]; then
  bootaa64_origin=https
elif [ -n "$BOOTAA64_EFI" ]; then
  bootaa64_origin=local
else
  bootaa64_origin=template-preserved
  bootaa64_metadata_file="$work_dir/template-BOOTAA64.EFI"
  mcopy -i "$template_img" ::/EFI/BOOT/BOOTAA64.EFI "$bootaa64_metadata_file"
fi
bootaa64_digest=$(file_sha256 "$bootaa64_metadata_file")

qcomramp_metadata_file="$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME"
if [ -n "$QCOMRAMP_EFI_URL" ]; then
  qcomramp_origin=https
elif [ -n "$QCOMRAMP_EFI" ]; then
  qcomramp_origin=local
elif [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  qcomramp_origin=template-preserved
  qcomramp_metadata_file="$work_dir/template-$Y700_DIRECT_BOOT_EFI_NAME"
  mcopy -i "$template_img" "::/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME" \
    "$qcomramp_metadata_file"
else
  qcomramp_origin=fresh-generated
fi
qcomramp_digest=$(file_sha256 "$qcomramp_metadata_file")

cat > "$payload_dir/BOOT-INFO.txt" <<INFO
generated=$generated_timestamp
boot_template_origin=$boot_template_origin
boot_template_name=$boot_template_name
boot_template_sha256=$boot_template_digest
boot_image_size=$BOOT_IMAGE_SIZE
boot_fat_bits=$BOOT_FAT_BITS
boot_fat_label=$BOOT_FAT_LABEL
root_selector=$ROOT_SELECTOR
root_partlabel=$ROOT_PARTLABEL
root_uuid=${ROOT_UUID:-}
requested_rootargs=$generated_rootargs
requested_stableargs=$STABLEARGS
direct_boot_config_mode=$direct_boot_config_mode
dtb_name=$DTB_NAME
kernel_image_origin=$kernel_image_origin
kernel_image_name=Image
kernel_image_sha256=$kernel_image_digest
dtb_origin=$dtb_origin
dtb_sha256=$dtb_digest
bootaa64_origin=$bootaa64_origin
bootaa64_name=BOOTAA64.EFI
bootaa64_sha256=$bootaa64_digest
qcomramp_origin=$qcomramp_origin
qcomramp_name=$Y700_DIRECT_BOOT_EFI_NAME
qcomramp_sha256=$qcomramp_digest
qcomramp_cfg_name=$QCOMRAMP_CFG_NAME
INFO
(cd "$payload_dir" && find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum) > "$payload_dir/SHA256SUMS.txt"
ci_normalize_fat_tree "$payload_dir"

boot_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.img"
rm -f "$boot_img" "$boot_img.zst" "$boot_img.xz" "$boot_img.7z" "$boot_img.7z".*
if [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  cp -a "$template_img" "$boot_img"

  mdir -i "$boot_img" ::/EFI/BOOT >/dev/null
  mdir -i "$boot_img" ::/dtb >/dev/null
  mdir -i "$boot_img" ::/boot/grub/arm64-efi >/dev/null
  mtype -i "$boot_img" ::/boot/grub/arm64-efi/grub.cfg >/dev/null
  fat_overlay_add "$template_overlay" /Image f "$payload_dir/Image"
  mcopy -o -m -i "$boot_img" "$payload_dir/Image" ::/Image
  fat_overlay_add "$template_overlay" "/dtb/$DTB_NAME" f "$payload_dir/dtb/$DTB_NAME"
  mcopy -o -m -i "$boot_img" "$payload_dir/dtb/$DTB_NAME" "::/dtb/$DTB_NAME"
  fat_overlay_add "$template_overlay" /dtb/platform.dtb f "$payload_dir/dtb/$DTB_NAME"
  mcopy -o -m -i "$boot_img" "$payload_dir/dtb/$DTB_NAME" ::/dtb/platform.dtb
  if [ -f "$payload_dir/EFI/BOOT/BOOTAA64.EFI" ]; then
    fat_overlay_add "$template_overlay" /EFI/BOOT/BOOTAA64.EFI f "$payload_dir/EFI/BOOT/BOOTAA64.EFI"
    mcopy -o -m -i "$boot_img" "$payload_dir/EFI/BOOT/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI
  fi
  if [ -n "${QCOMRAMP_EFI:-}" ]; then
    require_regular_file QCOMRAMP_EFI "$QCOMRAMP_EFI"
    fat_overlay_add "$template_overlay" "/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME" f "$QCOMRAMP_EFI"
    mcopy -o -m -i "$boot_img" "$QCOMRAMP_EFI" ::/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME
    fat_overlay_add "$template_overlay" "/EFI/BOOT/$QCOMRAMP_CFG_NAME" f "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME"
    mcopy -o -m -i "$boot_img" "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" "::/EFI/BOOT/$QCOMRAMP_CFG_NAME"
    fat_overlay_add "$template_overlay" /EFI/BOOT/grub.cfg f "$payload_dir/EFI/BOOT/grub.cfg"
    mcopy -o -m -i "$boot_img" "$payload_dir/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg
  fi
  if [ -n "${QCOMRAMP_EFI:-}" ]; then
    mkdir -p "$payload_dir/boot/grub/arm64-efi"
    cat > "$payload_dir/boot/grub/arm64-efi/grub.cfg" <<EOF
set timeout=$GRUB_TIMEOUT
set default=0
set gfxpayload=keep
set rootargs="video=efifb:off panic=10 efi=novamap $generated_rootargs init=/sbin/init console=tty1 console=ttyMSM0,115200n8 log_buf_len=64M consoleblank=0"
set stableargs="$STABLEARGS msm.fbdev=0 drm_kms_helper.fbdev_emulation=0"

menuentry "Y700 daily" {
    devicetree /dtb/$DTB_NAME
    linux /Image \${rootargs} \${stableargs} -- quiet splash
}

menuentry "Y700 verbose" {
    devicetree /dtb/$DTB_NAME
    linux /Image \${rootargs} \${stableargs} -- printk.time=1 loglevel=6 systemd.show_status=1
}

menuentry "Y700 no-DRM SSH rescue" {
    devicetree /dtb/$DTB_NAME
    linux /Image video=efifb:off panic=10 efi=novamap $generated_rootargs init=/sbin/init console=tty1 console=ttyMSM0,115200n8 log_buf_len=64M consoleblank=0 $STABLEARGS msm.fbdev=0 drm_kms_helper.fbdev_emulation=0 -- ignore_loglevel loglevel=8 printk.time=1 systemd.show_status=1
}
EOF
    (cd "$payload_dir" && find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum) > "$payload_dir/SHA256SUMS.txt"
    ci_normalize_fat_tree "$payload_dir"
    fat_overlay_add "$template_overlay" /boot/grub/arm64-efi/grub.cfg f "$payload_dir/boot/grub/arm64-efi/grub.cfg"
    mcopy -o -m -i "$boot_img" "$payload_dir/boot/grub/arm64-efi/grub.cfg" ::/boot/grub/arm64-efi/grub.cfg
  fi
  if [ -f "$payload_dir/kernel.config" ]; then
    fat_overlay_add "$template_overlay" /kernel.config f "$payload_dir/kernel.config"
    mcopy -o -m -i "$boot_img" "$payload_dir/kernel.config" ::/kernel.config
  fi
  fat_overlay_add "$template_overlay" /BOOT-INFO.txt f "$payload_dir/BOOT-INFO.txt"
  fat_overlay_add "$template_overlay" /SHA256SUMS.txt f "$payload_dir/SHA256SUMS.txt"
  mcopy -o -m -i "$boot_img" "$payload_dir/BOOT-INFO.txt" "$payload_dir/SHA256SUMS.txt" ::/
else
  truncate -s "$BOOT_IMAGE_SIZE" "$boot_img"
  mkfs_args=(--invariant -F "$BOOT_FAT_BITS" -S "$BOOT_SECTOR_SIZE" -n "$BOOT_FAT_LABEL" -i "$BOOT_FAT_VOLUME_ID")
  if [ -n "${BOOT_CLUSTER_SECTORS:-}" ]; then
    mkfs_args+=(-s "$BOOT_CLUSTER_SECTORS")
  fi
  mkfs.vfat "${mkfs_args[@]}" "$boot_img"

  ci_log "copying boot payload into FAT image"
  mcopy -m -i "$boot_img" "$payload_dir/Image" "$payload_dir/BOOT-INFO.txt" "$payload_dir/SHA256SUMS.txt" ::/
  if [ -f "$payload_dir/kernel.config" ]; then
    mcopy -m -i "$boot_img" "$payload_dir/kernel.config" ::/
  fi
  mcopy -s -m -i "$boot_img" "$payload_dir/dtb" ::/
  mcopy -s -m -i "$boot_img" "$payload_dir/EFI" ::/
fi

fsck.fat -n "$boot_img" >/dev/null
if [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  verify_fat_file "$boot_img" "$payload_dir/Image" /Image
  verify_fat_file "$boot_img" "$payload_dir/dtb/$DTB_NAME" "/dtb/$DTB_NAME"
  verify_fat_file "$boot_img" "$payload_dir/dtb/$DTB_NAME" /dtb/platform.dtb
  if [ -f "$payload_dir/EFI/BOOT/BOOTAA64.EFI" ]; then
    verify_fat_file "$boot_img" "$payload_dir/EFI/BOOT/BOOTAA64.EFI" \
      /EFI/BOOT/BOOTAA64.EFI
  fi
  if [ -n "${QCOMRAMP_EFI:-}" ]; then
    verify_fat_file "$boot_img" "$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME" \
      "/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME"
    verify_fat_file "$boot_img" "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" \
      "/EFI/BOOT/$QCOMRAMP_CFG_NAME"
    verify_fat_file "$boot_img" "$payload_dir/EFI/BOOT/grub.cfg" \
      /EFI/BOOT/grub.cfg
    verify_fat_file "$boot_img" "$payload_dir/boot/grub/arm64-efi/grub.cfg" \
      /boot/grub/arm64-efi/grub.cfg
  fi
  if [ -f "$payload_dir/kernel.config" ]; then
    verify_fat_file "$boot_img" "$payload_dir/kernel.config" /kernel.config
  fi
  verify_fat_file "$boot_img" "$payload_dir/BOOT-INFO.txt" /BOOT-INFO.txt
  verify_fat_file "$boot_img" "$payload_dir/SHA256SUMS.txt" /SHA256SUMS.txt
  verify_template_fat_closure "$template_img" "$boot_img" "$template_namespace" \
    "$template_overlay" "$template_profile"
else
  verify_fresh_fat_tree "$boot_img" "$payload_dir"
fi

raw_sha_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.raw.sha256"
checksum_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.SHA256SUMS"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img")" > "$(basename "$raw_sha_file")")
rm -f "$checksum_file"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$raw_sha_file")" > "$(basename "$checksum_file")")

case "$BOOT_COMPRESS" in
  none)
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img")" >> "$(basename "$checksum_file")")
    ;;
  zstd)
    ci_require_cmd zstd
    zstd -T0 -19 -f "$boot_img" -o "$boot_img.zst"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img").zst" >> "$(basename "$checksum_file")")
    ;;
  xz)
    xz -T0 -k -f "$boot_img"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$boot_img").xz" >> "$(basename "$checksum_file")")
    ;;
  7z)
    ci_require_cmd 7z
    sevenz_out="$boot_img.7z"
    rm -f "$sevenz_out" "$sevenz_out".*
    if [ -n "${BOOT_CHUNK_SIZE:-}" ]; then
      7z a "$sevenz_out" "$boot_img" -t7z -m0=lzma2 -mx=9 -mmt=on -mtm=off -mta=off -mtc=off "-v$BOOT_CHUNK_SIZE" >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")")
    else
      7z a "$sevenz_out" "$boot_img" -t7z -m0=lzma2 -mx=9 -mmt=on -mtm=off -mta=off -mtc=off >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")")
    fi
    ;;
  *) ci_die "unsupported BOOT_COMPRESS=$BOOT_COMPRESS" ;;
esac

if [ "$BOOT_COMPRESS" != none ] && [ "$KEEP_BOOT_IMAGE" != 1 ]; then
  rm -f "$boot_img"
fi

ci_log "GRUB boot image complete: $OUTPUT_DIR"
