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
  BOOT_IMAGE_SIZE            default: 14G
  BOOT_FAT_BITS              12|16|32, default: 32
  BOOT_FAT_LABEL             default: Y700GRUB
  BOOT_SECTOR_SIZE           default: 512
  BOOT_CLUSTER_SECTORS       optional mkfs.vfat -s value
  KERNEL_IMAGE               required unless KERNEL_ARTIFACT_ARCHIVE supplies Image
  DTB_FILE                   required unless KERNEL_ARTIFACT_ARCHIVE supplies DTB_NAME
  DTB_NAME                   default: basename(DTB_FILE) or sm8650-lenovo-tb321fu.dtb
  KERNEL_CONFIG              optional
  BOOTAA64_EFI               required unless BOOTAA64_EFI_URL set
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
  BOOT_CHUNK_SIZE            optional 7z volume size, default: 1500m
  KEEP_BOOT_IMAGE            keep uncompressed boot image after packaging, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd mkfs.vfat
ci_require_cmd mcopy
ci_require_cmd mmd
ci_require_cmd sha256sum

OUTPUT_DIR=${OUTPUT_DIR:-out/ci-grub}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-y700}
BOOT_IMAGE_SIZE=${BOOT_IMAGE_SIZE:-14G}
BOOT_FAT_BITS=${BOOT_FAT_BITS:-32}
BOOT_FAT_LABEL=${BOOT_FAT_LABEL:-Y700GRUB}
BOOT_SECTOR_SIZE=${BOOT_SECTOR_SIZE:-512}
GRUB_TIMEOUT=${GRUB_TIMEOUT:-3}
ROOT_PARTLABEL=${ROOT_PARTLABEL:-userdata}
ROOT_SELECTOR=${ROOT_SELECTOR:-partlabel}
STABLEARGS=${STABLEARGS:-drm_client_lib.active=none}
QCOMRAMP_CFG_NAME=${QCOMRAMP_CFG_NAME:-qcomramp.cfg}
BOOT_COMPRESS=${BOOT_COMPRESS:-7z}
BOOT_CHUNK_SIZE=${BOOT_CHUNK_SIZE:-1500m}
KEEP_BOOT_IMAGE=${KEEP_BOOT_IMAGE:-0}

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.grub-build.XXXXXX")
payload_dir="$work_dir/payload"
mkdir -p "$payload_dir/EFI/BOOT" "$payload_dir/dtb"
trap 'rm -rf "$work_dir"' EXIT

if [ -n "${KERNEL_ARTIFACT_ARCHIVE:-}" ]; then
  archive="$work_dir/kernel-artifacts.archive"
  ci_download "$KERNEL_ARTIFACT_ARCHIVE" "$archive"
  ci_extract_archive "$archive" "$work_dir/kernel-artifacts"
  KERNEL_IMAGE=${KERNEL_IMAGE:-$(find "$work_dir/kernel-artifacts" -type f -name Image | head -n1 || true)}
  DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
  DTB_FILE=${DTB_FILE:-$(find "$work_dir/kernel-artifacts" -type f -name "$DTB_NAME" | head -n1 || true)}
  KERNEL_CONFIG=${KERNEL_CONFIG:-$(find "$work_dir/kernel-artifacts" -type f -name kernel.config | head -n1 || true)}
fi

if [ -n "${BOOTAA64_EFI_URL:-}" ]; then
  BOOTAA64_EFI="$work_dir/BOOTAA64.EFI"
  ci_download "$BOOTAA64_EFI_URL" "$BOOTAA64_EFI"
fi
if [ -n "${QCOMRAMP_EFI_URL:-}" ]; then
  QCOMRAMP_EFI="$work_dir/QCOMRAMP.EFI"
  ci_download "$QCOMRAMP_EFI_URL" "$QCOMRAMP_EFI"
fi

[ -n "${KERNEL_IMAGE:-}" ] && [ -f "$KERNEL_IMAGE" ] || ci_die "KERNEL_IMAGE is required"
[ -n "${DTB_FILE:-}" ] && [ -f "$DTB_FILE" ] || ci_die "DTB_FILE is required"
[ -n "${BOOTAA64_EFI:-}" ] && [ -f "$BOOTAA64_EFI" ] || ci_die "BOOTAA64_EFI or BOOTAA64_EFI_URL is required"
DTB_NAME=${DTB_NAME:-$(basename "$DTB_FILE")}

case "$ROOT_SELECTOR" in
  partlabel)
    generated_rootargs="root=PARTLABEL=$ROOT_PARTLABEL rw rootwait"
    ;;
  uuid)
    [ -n "${ROOT_UUID:-}" ] || ci_die "ROOT_SELECTOR=uuid requires ROOT_UUID"
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

cp -a "$BOOTAA64_EFI" "$payload_dir/EFI/BOOT/BOOTAA64.EFI"
cp -a "$KERNEL_IMAGE" "$payload_dir/Image"
cp -a "$DTB_FILE" "$payload_dir/dtb/$DTB_NAME"
if [ -n "${KERNEL_CONFIG:-}" ] && [ -f "$KERNEL_CONFIG" ]; then
  cp -a "$KERNEL_CONFIG" "$payload_dir/kernel.config"
fi

if [ -n "${QCOMRAMP_EFI:-}" ]; then
  [ -f "$QCOMRAMP_EFI" ] || ci_die "QCOMRAMP_EFI does not exist: $QCOMRAMP_EFI"
  cp -a "$QCOMRAMP_EFI" "$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME"
  y700_write_direct_grub_cfg "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" "$DTB_NAME" "$generated_rootargs" "$STABLEARGS"
  y700_write_outer_grub_cfg "$payload_dir/EFI/BOOT/grub.cfg" "$GRUB_TIMEOUT" "$Y700_DIRECT_BOOT_EFI_NAME"
else
  y700_stage_direct_grub_payload "$payload_dir/EFI/BOOT" "$DTB_NAME" "$GRUB_TIMEOUT" "$generated_rootargs" "$STABLEARGS"
fi

cat > "$payload_dir/BOOT-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
boot_image_size=$BOOT_IMAGE_SIZE
boot_fat_bits=$BOOT_FAT_BITS
boot_fat_label=$BOOT_FAT_LABEL
root_selector=$ROOT_SELECTOR
root_partlabel=$ROOT_PARTLABEL
root_uuid=${ROOT_UUID:-}
rootargs=$generated_rootargs
stableargs=$STABLEARGS
dtb_name=$DTB_NAME
kernel_image_source=$KERNEL_IMAGE
dtb_source=$DTB_FILE
bootaa64_source=$BOOTAA64_EFI
qcomramp_source=${QCOMRAMP_EFI:-generated-from-grub-build-dir}
qcomramp_cfg_name=$QCOMRAMP_CFG_NAME
INFO
(cd "$payload_dir" && find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum) > "$payload_dir/SHA256SUMS.txt"

boot_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.img"
rm -f "$boot_img"
truncate -s "$BOOT_IMAGE_SIZE" "$boot_img"
mkfs_args=(-F "$BOOT_FAT_BITS" -S "$BOOT_SECTOR_SIZE" -n "$BOOT_FAT_LABEL")
if [ -n "${BOOT_CLUSTER_SECTORS:-}" ]; then
  mkfs_args+=(-s "$BOOT_CLUSTER_SECTORS")
fi
mkfs.vfat "${mkfs_args[@]}" "$boot_img"

ci_log "copying boot payload into FAT image"
mmd -i "$boot_img" ::/EFI ::/EFI/BOOT ::/dtb
mcopy -i "$boot_img" "$payload_dir/Image" "$payload_dir/BOOT-INFO.txt" "$payload_dir/SHA256SUMS.txt" ::/
if [ -f "$payload_dir/kernel.config" ]; then
  mcopy -i "$boot_img" "$payload_dir/kernel.config" ::/
fi
mcopy -i "$boot_img" "$payload_dir/dtb/$DTB_NAME" ::/dtb/
mcopy -i "$boot_img" "$payload_dir/EFI/BOOT/"* ::/EFI/BOOT/

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
      7z a "$sevenz_out" "$boot_img" -t7z -m0=lzma2 -mx=9 -mmt=on "-v$BOOT_CHUNK_SIZE" >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")")
    else
      7z a "$sevenz_out" "$boot_img" -t7z -m0=lzma2 -mx=9 -mmt=on >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")")
    fi
    ;;
  *) ci_die "unsupported BOOT_COMPRESS=$BOOT_COMPRESS" ;;
esac

if [ "$BOOT_COMPRESS" != none ] && [ "$KEEP_BOOT_IMAGE" != 1 ]; then
  rm -f "$boot_img"
fi

ci_log "GRUB boot image complete: $OUTPUT_DIR"
