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
ci_require_cmd sha256sum

OUTPUT_DIR=${OUTPUT_DIR:-out/ci-grub}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-y700}
ci_validate_output_prefix "$OUTPUT_PREFIX"
BOOT_TEMPLATE_IMAGE=${BOOT_TEMPLATE_IMAGE:-${BOOT_TEMPLATE_IMAGE_URL:-}}
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
KERNEL_ARTIFACT_ARCHIVE_SHA256=${KERNEL_ARTIFACT_ARCHIVE_SHA256:-}
BOOTAA64_EFI_SHA256=${BOOTAA64_EFI_SHA256:-}
QCOMRAMP_EFI_SHA256=${QCOMRAMP_EFI_SHA256:-}
[[ $BOOT_FAT_VOLUME_ID =~ ^[A-Fa-f0-9]{8}$ ]] || ci_die "invalid BOOT_FAT_VOLUME_ID=$BOOT_FAT_VOLUME_ID"
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

[ -n "${KERNEL_IMAGE:-}" ] && [ -f "$KERNEL_IMAGE" ] || ci_die "KERNEL_IMAGE is required"
[ -n "${DTB_FILE:-}" ] && [ -f "$DTB_FILE" ] || ci_die "DTB_FILE is required"
[ -n "$BOOT_TEMPLATE_IMAGE" ] || { [ -n "${BOOTAA64_EFI:-}" ] && [ -f "$BOOTAA64_EFI" ]; } || ci_die "BOOTAA64_EFI or BOOTAA64_EFI_URL is required without BOOT_TEMPLATE_IMAGE"
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

if [ -n "${BOOTAA64_EFI:-}" ] && [ -f "$BOOTAA64_EFI" ]; then
  cp -a "$BOOTAA64_EFI" "$payload_dir/EFI/BOOT/BOOTAA64.EFI"
fi
cp -a "$KERNEL_IMAGE" "$payload_dir/Image"
cp -a "$DTB_FILE" "$payload_dir/dtb/$DTB_NAME"
if [ -n "${KERNEL_CONFIG:-}" ] && [ -f "$KERNEL_CONFIG" ]; then
  cp -a "$KERNEL_CONFIG" "$payload_dir/kernel.config"
fi

if [ -n "${QCOMRAMP_EFI:-}" ]; then
  [ -f "$QCOMRAMP_EFI" ] || ci_die "QCOMRAMP_EFI does not exist: $QCOMRAMP_EFI"
  y700_validate_cfg_name "$QCOMRAMP_CFG_NAME"
  y700_validate_efi_name "$Y700_DIRECT_BOOT_EFI_NAME"
  cp -a "$QCOMRAMP_EFI" "$payload_dir/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME"
  y700_write_direct_grub_cfg "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" "$DTB_NAME" "$generated_rootargs" "$STABLEARGS"
  y700_write_outer_grub_cfg "$payload_dir/EFI/BOOT/grub.cfg" "$GRUB_TIMEOUT" "$Y700_DIRECT_BOOT_EFI_NAME"
elif [ -z "$BOOT_TEMPLATE_IMAGE" ]; then
  y700_stage_direct_grub_payload "$payload_dir/EFI/BOOT" "$DTB_NAME" "$GRUB_TIMEOUT" "$generated_rootargs" "$STABLEARGS"
fi

cat > "$payload_dir/BOOT-INFO.txt" <<INFO
generated=$generated_timestamp
boot_template_image=${BOOT_TEMPLATE_IMAGE:-}
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
bootaa64_source=${BOOTAA64_EFI:-from-template}
qcomramp_source=${QCOMRAMP_EFI:-from-template}
qcomramp_cfg_name=$QCOMRAMP_CFG_NAME
INFO
(cd "$payload_dir" && find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum) > "$payload_dir/SHA256SUMS.txt"
ci_normalize_fat_tree "$payload_dir"

boot_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-grub-fat.img"
rm -f "$boot_img"
if [ -n "$BOOT_TEMPLATE_IMAGE" ]; then
  template_img="$work_dir/boot-template.img"
  ci_log "using verified boot template image: $BOOT_TEMPLATE_IMAGE"
  download_template_if_needed "$BOOT_TEMPLATE_IMAGE" "$template_img" "$BOOT_TEMPLATE_IMAGE_SHA256"
  cp -a "$template_img" "$boot_img"

  mdir -i "$boot_img" ::/EFI/BOOT >/dev/null
  mdir -i "$boot_img" ::/dtb >/dev/null
  mdir -i "$boot_img" ::/boot/grub/arm64-efi >/dev/null
  mcopy -o -m -i "$boot_img" "$payload_dir/Image" ::/Image
  mcopy -o -m -i "$boot_img" "$payload_dir/dtb/$DTB_NAME" "::/dtb/$DTB_NAME"
  mcopy -o -m -i "$boot_img" "$payload_dir/dtb/$DTB_NAME" ::/dtb/platform.dtb
  if [ -f "$payload_dir/EFI/BOOT/BOOTAA64.EFI" ]; then
    mcopy -o -m -i "$boot_img" "$payload_dir/EFI/BOOT/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI
  fi
  if [ -n "${QCOMRAMP_EFI:-}" ] && [ -f "$QCOMRAMP_EFI" ]; then
    mcopy -o -m -i "$boot_img" "$QCOMRAMP_EFI" ::/EFI/BOOT/$Y700_DIRECT_BOOT_EFI_NAME
    mcopy -o -m -i "$boot_img" "$payload_dir/EFI/BOOT/$QCOMRAMP_CFG_NAME" "::/EFI/BOOT/$QCOMRAMP_CFG_NAME"
    mcopy -o -m -i "$boot_img" "$payload_dir/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg
  fi
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
  mcopy -o -m -i "$boot_img" "$payload_dir/boot/grub/arm64-efi/grub.cfg" ::/boot/grub/arm64-efi/grub.cfg
  if [ -f "$payload_dir/kernel.config" ]; then
    mcopy -o -m -i "$boot_img" "$payload_dir/kernel.config" ::/kernel.config
  fi
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
