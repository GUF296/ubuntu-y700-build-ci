#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") BOOT_IMAGE ROOTFS_IMAGE OUTPUT_IMAGE

Compose a GPT disk image from an existing FAT boot image and ext4 rootfs image.

Environment inputs:
  BOOT_PARTLABEL            default: ESP
  ROOTFS_PARTLABEL          default: userdata
  ROOTFS_UUID               optional ext4 UUID to set before embedding
USAGE
}

[ $# -eq 3 ] || { usage >&2; exit 2; }

BOOT_IMAGE=$1
ROOTFS_IMAGE=$2
OUTPUT_IMAGE=$3
BOOT_PARTLABEL=${BOOT_PARTLABEL:-ESP}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}

ci_require_cmd sgdisk
ci_require_cmd truncate
ci_require_cmd dd
ci_require_cmd stat
ci_require_cmd e2fsck
ci_require_cmd tune2fs
ci_require_cmd losetup
ci_require_cmd sha256sum

[ -f "$BOOT_IMAGE" ] || ci_die "missing boot image: $BOOT_IMAGE"
[ -f "$ROOTFS_IMAGE" ] || ci_die "missing rootfs image: $ROOTFS_IMAGE"
ci_require_distinct_paths \
  BOOT_IMAGE "$BOOT_IMAGE" \
  ROOTFS_IMAGE "$ROOTFS_IMAGE" \
  OUTPUT_IMAGE "$OUTPUT_IMAGE"
rootfs_input_sha256=$(sha256sum "$ROOTFS_IMAGE" | awk '{print $1}')

ceil_div() { echo $(( ($1 + $2 - 1) / $2 )); }
align_up() { echo $(( (($1 + $2 - 1) / $2) * $2 )); }

sector_size=512
first_sector=2048
align_sectors=2048
boot_size=$(stat -c%s "$BOOT_IMAGE")
root_size=$(stat -c%s "$ROOTFS_IMAGE")
boot_sectors=$(ceil_div "$boot_size" "$sector_size")
root_sectors=$(ceil_div "$root_size" "$sector_size")
boot_start=$first_sector
root_start=$(align_up $((boot_start + boot_sectors)) "$align_sectors")
root_end=$((root_start + root_sectors))
total_sectors=$(( $(align_up "$root_end" "$align_sectors") + 34 ))
total_bytes=$((total_sectors * sector_size))

tmp=$(mktemp "$(dirname "$OUTPUT_IMAGE")/.$(basename "$OUTPUT_IMAGE").XXXXXX")
root_loop=
cleanup() {
  set +e
  if [ -n "$root_loop" ]; then
    losetup -d "$root_loop"
  fi
  rm -f -- "$tmp"
}
trap cleanup EXIT
truncate -s "$total_bytes" "$tmp"

sgdisk -o "$tmp" >/dev/null
sgdisk -n "1:${boot_start}:+${boot_sectors}" -t 1:ef00 -c 1:"$BOOT_PARTLABEL" -A 1:set:2 "$tmp" >/dev/null
sgdisk -n "2:${root_start}:+${root_sectors}" -t 2:8300 -c 2:"$ROOTFS_PARTLABEL" "$tmp" >/dev/null

dd if="$BOOT_IMAGE" of="$tmp" bs=4M conv=notrunc,fsync oflag=seek_bytes seek=$((boot_start * sector_size)) status=none
dd if="$ROOTFS_IMAGE" of="$tmp" bs=4M conv=notrunc,fsync oflag=seek_bytes seek=$((root_start * sector_size)) status=none
root_loop=$(losetup --find --show \
  --offset $((root_start * sector_size)) \
  --sizelimit "$root_size" \
  "$tmp")
ci_e2fsck_repair "$root_loop"
if [ -n "${ROOTFS_UUID:-}" ]; then
  tune2fs -U "$ROOTFS_UUID" "$root_loop"
fi
sync
losetup -d "$root_loop"
root_loop=

[ "$(sha256sum "$ROOTFS_IMAGE" | awk '{print $1}')" = "$rootfs_input_sha256" ] ||
  ci_die "input rootfs image changed while composing disk image"

mv "$tmp" "$OUTPUT_IMAGE"
trap - EXIT
(cd "$(dirname "$OUTPUT_IMAGE")" &&
  sha256sum "$(basename "$OUTPUT_IMAGE")" > "$(basename "$OUTPUT_IMAGE").sha256")
