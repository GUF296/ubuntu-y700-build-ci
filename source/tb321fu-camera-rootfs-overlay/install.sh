#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 ROOTFS" >&2
  exit 2
fi

rootfs=${1%/}
[ -n "$rootfs" ] || rootfs=/

if [ ! -d "$rootfs" ]; then
  echo "rootfs does not exist: $rootfs" >&2
  exit 1
fi

base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
overlay=$base/rootfs-overlay
manifest=$base/OVERLAY-MANIFEST.tsv
verifier=$base/../../scripts/ci/verify-camera-overlay.py
installer=$base/../../scripts/ci/install-camera-overlay.py

[ -d "$overlay/opt/libcamera-y700" ] || {
  echo "camera overlay missing opt/libcamera-y700" >&2
  exit 1
}
[ -f "$manifest" ] && [ ! -L "$manifest" ] || {
  echo "camera overlay missing closed OVERLAY-MANIFEST.tsv" >&2
  exit 1
}
[ -f "$verifier" ] && [ ! -L "$verifier" ] || {
  echo "camera overlay verifier is unavailable; run this installer from the repository checkout" >&2
  exit 1
}
[ -f "$installer" ] && [ ! -L "$installer" ] || {
  echo "camera overlay transaction helper is unavailable; run this installer from the repository checkout" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to verify the camera overlay" >&2
  exit 1
}

python3 -B "$verifier" "$overlay" "$manifest" >/dev/null
python3 -B "$installer" \
  --overlay "$overlay" \
  --manifest "$manifest" \
  --target "$rootfs" \
  --verifier "$verifier" >/dev/null

echo "installed Y700 camera overlay into $rootfs"
