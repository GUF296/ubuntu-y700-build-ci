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

case $(basename -- "$SCRIPT_DIR/../../..") in
  ubuntu) rootfs_script="$SCRIPT_DIR/build-rootfs-image.sh" ;;
  arch) rootfs_script="$SCRIPT_DIR/build-arch-rootfs-image.sh" ;;
  *) rootfs_script=$(find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'build*rootfs-image.sh' -print -quit) ;;
esac
[ -f "$rootfs_script" ]

! grep -Fq 'ci_extract_archive "$tmp_overlay" "$rootfs_dir"' "$rootfs_script"
unmount_line=$(grep -n '^unmount_chroot_runtime$' "$rootfs_script" | tail -n1 | cut -d: -f1)
apply_line=$(grep -n 'applying staged overlay archive' "$rootfs_script" | tail -n1 | cut -d: -f1)
[ -n "$unmount_line" ] && [ -n "$apply_line" ] && [ "$unmount_line" -lt "$apply_line" ]

printf 'rootfs overlay mount boundary: PASS\n'
