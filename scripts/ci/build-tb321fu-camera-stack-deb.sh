#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build the live-verified Lenovo TB321FU camera userspace stack Debian package.

Environment inputs:
  OUTPUT_DIR                 default: out/tb321fu-camera-stack-debs
  ARCH                       default: arm64
  CAMERA_STACK_DEB_VERSION   default: 20260627.4
  CAMERA_STACK_ARCHIVE       optional archive containing y700-camera-rootfs-overlay
  CAMERA_STACK_DIR           optional directory containing y700-camera-rootfs-overlay

If CAMERA_STACK_ARCHIVE and CAMERA_STACK_DIR are empty, the script uses the
repository copy at source/tb321fu-camera-rootfs-overlay.
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd dpkg-deb
ci_require_cmd rsync
ci_require_cmd sha256sum
ci_require_cmd strings

OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-camera-stack-debs}
ARCH=${ARCH:-arm64}
CAMERA_STACK_DEB_VERSION=${CAMERA_STACK_DEB_VERSION:-20260627.4}
CAMERA_STACK_ARCHIVE=${CAMERA_STACK_ARCHIVE:-}
CAMERA_STACK_ARCHIVE_SHA256=${CAMERA_STACK_ARCHIVE_SHA256:-}
CAMERA_STACK_DIR=${CAMERA_STACK_DIR:-}

[ "$ARCH" = arm64 ] || ci_die "unsupported ARCH=$ARCH; only arm64 is supported"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-camera-stack-build.XXXXXX")

cleanup() {
  ci_safe_rmtree "$work_dir" "${TMPDIR:-/tmp}" tb321fu-camera-stack-build.
}
trap cleanup EXIT

find_camera_source_root() {
  local root=$1 found candidate
  local -a markers=() candidates=()
  local -A seen=()

  if [ -d "$root/rootfs-overlay/opt/libcamera-y700" ] && \
     [ -f "$root/rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" ]; then
    printf '%s\n' "$root"
    return 0
  fi

  if [ -d "$root/opt/libcamera-y700" ] && \
     [ -f "$root/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" ]; then
    printf '%s\n' "$root"
    return 0
  fi

  mapfile -d '' -t markers < <(find "$root" -type f \
    -path '*/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so' -print0 | sort -z)
  for found in "${markers[@]}"; do
    case "$found" in
      */rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so)
        candidate=${found%/rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so}
        [ -d "$candidate/rootfs-overlay/opt/libcamera-y700" ] || continue
        ;;
      *)
        candidate=${found%/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so}
        [ -d "$candidate/opt/libcamera-y700" ] || continue
        ;;
    esac
    if [ -z "${seen[$candidate]+set}" ]; then
      seen[$candidate]=1
      candidates+=("$candidate")
    fi
  done
  case ${#candidates[@]} in
    0) return 1 ;;
    1) printf '%s\n' "${candidates[0]}" ;;
    *)
      printf 'ambiguous camera source roots:\n' >&2
      printf '  %s\n' "${candidates[@]}" >&2
      return 2
      ;;
  esac
}

prepare_inputs() {
  local archive extract default_dir
  default_dir="$SCRIPT_DIR/../../source/tb321fu-camera-rootfs-overlay"

  if [ -n "$CAMERA_STACK_DIR" ]; then
    camera_source_root=$(find_camera_source_root "$CAMERA_STACK_DIR") || ci_die "CAMERA_STACK_DIR does not contain the verified camera overlay"
  elif [ -n "$CAMERA_STACK_ARCHIVE" ]; then
    archive="$work_dir/camera-stack.archive"
    extract="$work_dir/camera-stack"
    ci_download "$CAMERA_STACK_ARCHIVE" "$archive" "$CAMERA_STACK_ARCHIVE_SHA256"
    ci_extract_archive "$archive" "$extract"
    camera_source_root=$(find_camera_source_root "$extract") || ci_die "CAMERA_STACK_ARCHIVE does not contain the verified camera overlay"
  else
    camera_source_root=$(find_camera_source_root "$default_dir") || ci_die "repository camera overlay is missing: $default_dir"
  fi

  if [ -d "$camera_source_root/rootfs-overlay" ]; then
    camera_overlay_root="$camera_source_root/rootfs-overlay"
    camera_checksums="$camera_source_root/SHA256SUMS"
  else
    camera_overlay_root="$camera_source_root"
    camera_checksums=""
  fi

  ci_log "camera source root: $camera_source_root"
  ci_log "camera overlay root: $camera_overlay_root"
}

validate_camera_payload() {
  local root=$1 checksums=${2:-}
  local plugin="$root/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
  local cam="$root/opt/libcamera-y700/bin/cam"
  local libcamera="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1"
  local libcamera_base="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1"
  local soft_ipa="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so"
  local soft_proxy="$root/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy"
  local gst_plugin="$root/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
  local gst_system_plugin="$root/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"

  [ -x "$cam" ] || ci_die "camera payload missing executable /opt/libcamera-y700/bin/cam"
  [ -f "$libcamera" ] || ci_die "camera payload missing libcamera.so.0.7.1"
  [ -f "$libcamera_base" ] || ci_die "camera payload missing libcamera-base.so.0.7.1"
  [ -f "$soft_ipa" ] || ci_die "camera payload missing ipa_soft_simple.so"
  [ -x "$soft_proxy" ] || ci_die "camera payload missing executable soft_ipa_proxy"
  [ -f "$gst_plugin" ] || ci_die "camera payload missing GStreamer libcamera plugin"
  [ -L "$gst_system_plugin" ] || ci_die "camera payload missing system GStreamer libcamera symlink"
  [ "$(readlink "$gst_system_plugin")" = "/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so" ] || ci_die "system GStreamer libcamera symlink points at wrong target"
  [ -f "$plugin" ] || ci_die "camera payload missing PipeWire SPA libcamera plugin"
  [ -f "$root/opt/libcamera-y700/share/libcamera/ipa/simple/gc13a0.yaml" ] || ci_die "camera payload missing gc13a0 tuning"
  [ -f "$root/opt/libcamera-y700/share/libcamera/ipa/simple/sc202cs.yaml" ] || ci_die "camera payload missing sc202cs tuning"
  [ -f "$root/opt/libcamera-y700/share/libcamera/ipa/simple/sc820cs.yaml" ] || ci_die "camera payload missing sc820cs tuning"
  [ -f "$root/etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf" ] || ci_die "camera payload missing PipeWire namespace drop-in"
  [ -f "$root/etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf" ] || ci_die "camera payload missing PipeWire libcamera paths drop-in"
  [ -f "$root/etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf" ] || ci_die "camera payload missing WirePlumber libcamera paths drop-in"
  [ -f "$root/etc/udev/rules.d/70-y700-camera-dma-heap.rules" ] || ci_die "camera payload missing DMA heap udev rule"
  [ -f "$root/etc/ld.so.conf.d/y700-libcamera.conf" ] || ci_die "camera payload missing libcamera ldconfig path"

  if [ -n "$checksums" ] && [ -f "$checksums" ]; then
    (cd "$root" && sha256sum -c "$checksums" >/dev/null)
  fi

  if strings "$plugin" "$cam" "$soft_ipa" "$soft_proxy" "$gst_plugin" | grep -F 'libcamera-y700-test' >/dev/null; then
    ci_die "camera payload still references rejected libcamera-y700-test app-chain"
  fi

  grep -q '^/opt/libcamera-y700/lib/aarch64-linux-gnu$' "$root/etc/ld.so.conf.d/y700-libcamera.conf" || ci_die "camera ldconfig path does not point at /opt/libcamera-y700"
}

write_control() {
  local pkgdir=$1

  mkdir -p "$pkgdir/DEBIAN"
  # The daily overlay keeps unrelated device payload. Its rewritten package
  # explicitly provides the migration capability before this package can be
  # unpacked, while distro-owned camera plugins are replaced as a unit.
  cat > "$pkgdir/DEBIAN/control" <<EOF_CONTROL
Package: tb321fu-camera-stack
Version: $CAMERA_STACK_DEB_VERSION
Section: video
Priority: optional
Architecture: $ARCH
Maintainer: GUF296 <guf296@users.noreply.github.com>
Depends: libc6, libstdc++6, libgcc-s1, pipewire, wireplumber, udev, libspa-0.2-modules, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libglib2.0-0t64, libyaml-0-2, libudev1, libegl1, libgles2, libevent-2.1-7t64, libevent-pthreads-2.1-7t64, libunwind8
Recommends: gnome-snapshot
Pre-Depends: tb321fu-camera-payload-migrated (>= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)
Replaces: y700-daily-rootfs-overlay, libspa-0.2-libcamera, gstreamer1.0-libcamera
Conflicts: libspa-0.2-libcamera, gstreamer1.0-libcamera
Provides: y700-camera-stack
Description: Lenovo TB321FU verified camera userspace stack
 Source-built libcamera and the live-verified PipeWire libcamera integration used by the non-GitHub rootfs.
EOF_CONTROL
}

write_maintainer_scripts() {
  local pkgdir=$1

  ci_write_tb321fu_camera_preinst "$pkgdir"

  cat > "$pkgdir/DEBIAN/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
fi
exit 0
EOF_POSTINST

  cat > "$pkgdir/DEBIAN/postrm" <<'EOF_POSTRM'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
fi
exit 0
EOF_POSTRM

  chmod 0755 "$pkgdir/DEBIAN/preinst" "$pkgdir/DEBIAN/postinst" "$pkgdir/DEBIAN/postrm"
}

build_camera_package() {
  local pkg="$work_dir/pkg/tb321fu-camera-stack"
  local deb="$OUTPUT_DIR/tb321fu-camera-stack_${CAMERA_STACK_DEB_VERSION}_${ARCH}.deb"
  local report="$OUTPUT_DIR/tb321fu-camera-stack-build-report.txt"

  validate_camera_payload "$camera_overlay_root" "$camera_checksums"

  rm -rf "$pkg"
  install -d -m 0755 "$pkg"
  rsync -aH --numeric-ids "$camera_overlay_root"/ "$pkg"/

  rm -f \
    "$pkg/etc/udev/rules.d/70-y700-dma-heap.rules" \
    "$pkg/etc/y700-camera-display-transform-mode" \
    "$pkg/etc/y700-camera-display-rotation-base" \
    "$pkg/etc/systemd/user/y700-display-rotation-update.path" \
    "$pkg/etc/systemd/user/y700-display-rotation-update.service" \
    "$pkg/etc/systemd/user/y700-display-rotation-dbus.service" \
    "$pkg/etc/systemd/user/y700-display-rotation-sync.service" \
    "$pkg/usr/local/libexec/y700-display-rotation-update" \
    "$pkg/usr/local/libexec/y700-display-rotation-dbus" \
    "$pkg/usr/local/bin/y700-display-rotation-sync" \
    "$pkg/run/y700-camera-display-rotation"

  find "$pkg/etc" -type f -exec chmod 0644 {} + 2>/dev/null || true
  find "$pkg/opt/libcamera-y700" "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera" -type f -name '*.so*' -exec chmod 0644 {} +
  chmod 0755 \
    "$pkg/opt/libcamera-y700/bin/cam" \
    "$pkg/opt/libcamera-y700/bin/libcamera-bug-report" \
    "$pkg/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
    "$pkg/usr/local/bin/y700-camera-env" \
    "$pkg/usr/local/bin/y700-camera-cam" \
    "$pkg/usr/local/bin/y700-camera-preview"

  write_control "$pkg"
  write_maintainer_scripts "$pkg"
  validate_camera_payload "$pkg" ""

  ci_normalize_system_payload_modes "$pkg"
  ci_assert_normalized_system_payload_modes "$pkg"
  ci_assert_privileged_payload_security "$pkg" \
    opt/libcamera-y700/bin/cam \
    opt/libcamera-y700/bin/libcamera-bug-report \
    opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy \
    usr/local/bin/y700-camera-env \
    usr/local/bin/y700-camera-cam \
    usr/local/bin/y700-camera-preview
  ci_normalize_package_tree "$pkg"
  dpkg-deb --build --root-owner-group "$pkg" "$deb" >/dev/null
  ci_assert_tb321fu_camera_stack_deb "$deb" "$work_dir/camera-package-policy-check"

  {
    echo "TB321FU_CAMERA_STACK_DEB_BUILD=PASS"
    echo "version=$CAMERA_STACK_DEB_VERSION"
    echo "arch=$ARCH"
    echo "camera_source_root=$camera_source_root"
    echo "camera_overlay_root=$camera_overlay_root"
    echo "deb=$deb"
    sha256sum "$deb"
    echo
    echo "== package control =="
    dpkg-deb -I "$deb"
    echo
    echo "== key hashes =="
    sha256sum \
      "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1" \
      "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1" \
      "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so" \
      "$pkg/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so" \
      "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
    echo
    echo "== plugin markers =="
    strings -a "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" | grep -E 'kwinoutputconfig|kscreen-doctor|y700_camera|spa_system_eventfd|camera-display-transform-mode|display-rotation-base|libcamera-y700-test|api.libcamera.rotation' | head -n 120 || true
  } > "$report"

  cat "$report"
}

prepare_inputs
build_camera_package

ci_log "writing camera package checksums"
(cd "$OUTPUT_DIR" && sha256sum ./*.deb > SHA256SUMS-tb321fu-camera-stack-debs.txt)
ci_log "camera package build complete: $OUTPUT_DIR"
