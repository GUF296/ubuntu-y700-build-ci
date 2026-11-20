#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

scratch=$(mktemp -d)
cleanup() {
  case $scratch in /tmp/tmp.*) rm -rf -- "$scratch" ;; esac
}
trap cleanup EXIT INT TERM

mkdir -p "$scratch/safe/etc"
ci_validate_rootfs_overlay_tree "$scratch/safe"

ln -s "$scratch/safe" "$scratch/root-link"
if (ci_validate_rootfs_overlay_tree "$scratch/root-link") >/dev/null 2>&1; then
  printf 'overlay root symlink was accepted\n' >&2
  exit 1
fi

mkfifo "$scratch/safe/fifo"
if (ci_validate_rootfs_overlay_tree "$scratch/safe") >/dev/null 2>&1; then
  printf 'overlay special file was accepted\n' >&2
  exit 1
fi
rm -f "$scratch/safe/fifo"

install -m 0644 /dev/null "$scratch/safe/hardlink-source"
ln "$scratch/safe/hardlink-source" "$scratch/safe/hardlink-copy"
if (ci_validate_rootfs_overlay_tree "$scratch/safe") >/dev/null 2>&1; then
  printf 'overlay hard-linked file was accepted\n' >&2
  exit 1
fi
rm -f "$scratch/safe/hardlink-source" "$scratch/safe/hardlink-copy"

install -m 0644 /dev/null "$scratch/safe/setuid-file"
chmod 4644 "$scratch/safe/setuid-file"
if (ci_validate_rootfs_overlay_tree "$scratch/safe") >/dev/null 2>&1; then
  printf 'overlay setuid file was accepted\n' >&2
  exit 1
fi
rm -f "$scratch/safe/setuid-file"

for relative in dev proc sys run; do
  candidate="$scratch/reject-$relative"
  mkdir -p "$candidate/$relative"
  if (ci_validate_rootfs_overlay_tree "$candidate") >/dev/null 2>&1; then
    printf 'runtime overlay path was accepted: %s\n' "$relative" >&2
    exit 1
  fi
done

mkdir -p "$scratch/reject-link"
ln -s /run "$scratch/reject-link/run"
if (ci_validate_rootfs_overlay_tree "$scratch/reject-link") >/dev/null 2>&1; then
  printf 'runtime overlay symlink was accepted\n' >&2
  exit 1
fi

mkdir -p "$scratch/reject-absolute/etc"
ln -s /etc "$scratch/reject-absolute/etc/host-etc"
if (ci_validate_rootfs_overlay_tree "$scratch/reject-absolute") >/dev/null 2>&1; then
  printf 'absolute overlay symlink was accepted\n' >&2
  exit 1
fi

mkdir -p "$scratch/reject-escape/etc"
ln -s ../../outside "$scratch/reject-escape/etc/host-outside"
if (ci_validate_rootfs_overlay_tree "$scratch/reject-escape") >/dev/null 2>&1; then
  printf 'escaping relative overlay symlink was accepted\n' >&2
  exit 1
fi

mkdir -p "$scratch/contained/lib" "$scratch/contained/etc/systemd/system/multi-user.target.wants"
touch "$scratch/contained/lib/libcontained.so.1"
ln -s libcontained.so.1 "$scratch/contained/lib/libcontained.so"
ln -s ../contained.service \
  "$scratch/contained/etc/systemd/system/multi-user.target.wants/contained.service"
ci_validate_rootfs_overlay_tree "$scratch/contained"

case $(basename -- "$SCRIPT_DIR/../../..") in
  ubuntu) rootfs_script="$SCRIPT_DIR/build-rootfs-image.sh" ;;
  arch) rootfs_script="$SCRIPT_DIR/build-arch-rootfs-image.sh" ;;
  *) rootfs_script=$(find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'build*rootfs-image.sh' -print -quit) ;;
esac
[ -f "$rootfs_script" ]

! grep -Fq 'ci_extract_archive "$tmp_overlay" "$rootfs_dir"' "$rootfs_script"

# Keep camera lifecycle and buffer contracts in their dedicated mutation-tested
# fixture instead of duplicating stale lexical assertions here.
camera_source=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)/source/tb321fu-camera-rootfs-overlay/source/libcamera-source.cpp.clean-minimal-daily
[ -f "$camera_source" ] || {
  printf 'camera source contract input is missing: %s\n' "$camera_source" >&2
  exit 1
}
python3 "$SCRIPT_DIR/test-camera-source-contract.py" "$camera_source"
unmount_line=$(grep -n '^unmount_chroot_runtime$' "$rootfs_script" | tail -n1 | cut -d: -f1)
apply_line=$(grep -n 'applying staged overlay archive' "$rootfs_script" | tail -n1 | cut -d: -f1)
snapshot_line=$(grep -n 'ci_snapshot_local_deb_payload' "$rootfs_script" | tail -n1 | cut -d: -f1)
verify_line=$(grep -n 'ci_verify_local_deb_payload_snapshot' "$rootfs_script" | tail -n1 | cut -d: -f1)
[ -n "$unmount_line" ] && [ -n "$apply_line" ] && [ "$unmount_line" -lt "$apply_line" ]
[ -n "$snapshot_line" ] && [ -n "$verify_line" ] && \
  [ "$snapshot_line" -lt "$unmount_line" ] && [ "$verify_line" -gt "$apply_line" ]

printf 'rootfs overlay mount boundary: PASS\n'
