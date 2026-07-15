#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build source-based Qualcomm SNS sensor Debian packages for Lenovo TB321FU.

Environment inputs:
  OUTPUT_DIR                       default: out/y700-sensor-debs
  ARCH                             default: arm64
  SENSOR_DEB_VERSION               default: 20260715.1
  SENSOR_SOURCE_ARCHIVE            source freeze archive containing sensor/daily-current
  SENSOR_SOURCE_DIR                source freeze directory containing sensor/daily-current
  SENSOR_BASELINE_OVERLAY_ARCHIVE  rootfs overlay archive extracted from the verified userdata image
  SENSOR_BASELINE_OVERLAY_DIR      rootfs overlay directory extracted from the verified userdata image
  SENSOR_STRIP                     strip binaries after build, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd meson
ci_require_cmd ninja
ci_require_cmd rsync
ci_require_cmd dpkg-deb
ci_require_cmd sha256sum
ci_require_cmd pkg-config
ci_require_cmd patch
ci_require_cmd flock
ci_require_cmd protoc
ci_require_cmd protoc-gen-c
ci_require_cmd aarch64-linux-gnu-gcc
ci_require_cmd aarch64-linux-gnu-ar
ci_require_cmd aarch64-linux-gnu-readelf
ci_require_cmd aarch64-linux-gnu-strip

OUTPUT_DIR=${OUTPUT_DIR:-out/y700-sensor-debs}
ARCH=${ARCH:-arm64}
SENSOR_DEB_VERSION=${SENSOR_DEB_VERSION:-20260715.1}
SENSOR_SOURCE_ARCHIVE=${SENSOR_SOURCE_ARCHIVE:-}
SENSOR_SOURCE_ARCHIVE_SHA256=${SENSOR_SOURCE_ARCHIVE_SHA256:-}
SENSOR_SOURCE_DIR=${SENSOR_SOURCE_DIR:-}
SENSOR_BASELINE_OVERLAY_ARCHIVE=${SENSOR_BASELINE_OVERLAY_ARCHIVE:-}
SENSOR_BASELINE_OVERLAY_ARCHIVE_SHA256=${SENSOR_BASELINE_OVERLAY_ARCHIVE_SHA256:-}
SENSOR_BASELINE_OVERLAY_DIR=${SENSOR_BASELINE_OVERLAY_DIR:-}
SENSOR_STRIP=${SENSOR_STRIP:-0}

[ "$ARCH" = arm64 ] || ci_die "unsupported ARCH=$ARCH; only arm64 is supported"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
rm -f -- \
  "$OUTPUT_DIR"/qcom-sns-*.deb \
  "$OUTPUT_DIR"/tb321fu-sensors_*.deb \
  "$OUTPUT_DIR"/SHA256SUMS-y700-sensor-debs.txt
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/y700-sensor-build.XXXXXX")
stable_libssc_prefix=/tmp/tb321fu-sensor-libssc-prefix
stable_libssc_lock=/tmp/tb321fu-sensor-libssc-prefix.lock
cleanup() {
  if [ -L "$stable_libssc_prefix" ] && \
     [ "$(readlink -- "$stable_libssc_prefix")" = "${libssc_pkg_prefix:-}" ]; then
    rm -f -- "$stable_libssc_prefix"
  fi
  ci_safe_rmtree "$work_dir" "${TMPDIR:-/tmp}" y700-sensor-build.
}
trap cleanup EXIT
exec 9>"$stable_libssc_lock"
flock -x 9
if [ -e "$stable_libssc_prefix" ] || [ -L "$stable_libssc_prefix" ]; then
  if [ -L "$stable_libssc_prefix" ]; then
    stale_target=$(readlink -- "$stable_libssc_prefix")
    case "$stale_target" in
      "${TMPDIR:-/tmp}"/y700-sensor-build.??????/libssc-prefix)
        rm -f -- "$stable_libssc_prefix"
        ;;
      *) ci_die "refusing unexpected stable libssc symlink: $stable_libssc_prefix -> $stale_target" ;;
    esac
  else
    ci_die "stable libssc path is not a symlink: $stable_libssc_prefix"
  fi
fi
SOURCE_DATE_EPOCH=$(ci_source_date_epoch)
export SOURCE_DATE_EPOCH
mapfile -t reproducible_prefix_flags < <(
  ci_reproducible_prefix_flags "$work_dir" /build/tb321fu-sensors
)
export CFLAGS="${CFLAGS:+$CFLAGS }${reproducible_prefix_flags[*]}"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }${reproducible_prefix_flags[*]}"

copy_source() {
  local src=$1
  local dst=$2
  mkdir -p "$(dirname "$dst")"
  rsync -a --delete \
    --exclude 'build-arm64' \
    --exclude 'build-arm64-y700' \
    --exclude 'build-arm64-y700-ssc' \
    --exclude 'build-y700-aarch64' \
    --exclude 'build-native' \
    "$src/" "$dst/"
}

find_sensor_source_root() {
  local root=$1 marker found
  local -a candidates=()

  marker=/sensor/daily-current/libssc
  while IFS= read -r -d '' found; do
    found=${found%"$marker"}
    [ -d "$found/sensor/daily-current/iio-sensor-proxy" ] || continue
    [ -d "$found/sensor/daily-current/hexagonrpc" ] || continue
    candidates+=("$found")
  done < <(find -H "$root" -type d -path "*$marker" -print0)

  [ "${#candidates[@]}" -eq 1 ] || {
    printf 'expected exactly one sensor source root below %s, found %s\n' \
      "$root" "${#candidates[@]}" >&2
    return 1
  }
  printf '%s\n' "${candidates[0]}"
}

find_baseline_overlay_root() {
  local root=$1 marker found
  local -a candidates=()

  marker=/usr/local/share/y700-sns/hexagonfs/sensors/registry
  while IFS= read -r -d '' found; do
    found=${found%"$marker"}
    [ -d "$found/usr/local/share/y700-sns/hexagonfs/sensors/config" ] || continue
    candidates+=("$found")
  done < <(find -H "$root" -type d -path "*$marker" -print0)

  [ "${#candidates[@]}" -eq 1 ] || {
    printf 'expected exactly one sensor baseline root below %s, found %s\n' \
      "$root" "${#candidates[@]}" >&2
    return 1
  }
  printf '%s\n' "${candidates[0]}"
}

prepare_inputs() {
  local src_extract baseline_extract src_archive baseline_archive

  if [ -n "$SENSOR_SOURCE_DIR" ]; then
    source_root=$(find_sensor_source_root "$SENSOR_SOURCE_DIR") || ci_die "SENSOR_SOURCE_DIR does not contain sensor/daily-current sources"
  else
    [ -n "$SENSOR_SOURCE_ARCHIVE" ] || ci_die "set SENSOR_SOURCE_ARCHIVE or SENSOR_SOURCE_DIR"
    src_archive="$work_dir/sensor-source.archive"
    src_extract="$work_dir/sensor-source"
    ci_download "$SENSOR_SOURCE_ARCHIVE" "$src_archive" "$SENSOR_SOURCE_ARCHIVE_SHA256"
    ci_extract_archive "$src_archive" "$src_extract"
    source_root=$(find_sensor_source_root "$src_extract") || ci_die "SENSOR_SOURCE_ARCHIVE does not contain sensor/daily-current sources"
  fi

  if [ -n "$SENSOR_BASELINE_OVERLAY_DIR" ]; then
    baseline_root=$(find_baseline_overlay_root "$SENSOR_BASELINE_OVERLAY_DIR") || ci_die "SENSOR_BASELINE_OVERLAY_DIR does not contain verified sensor overlay"
  else
    [ -n "$SENSOR_BASELINE_OVERLAY_ARCHIVE" ] || ci_die "set SENSOR_BASELINE_OVERLAY_ARCHIVE or SENSOR_BASELINE_OVERLAY_DIR"
    baseline_archive="$work_dir/sensor-baseline-overlay.archive"
    baseline_extract="$work_dir/sensor-baseline-overlay"
    ci_download "$SENSOR_BASELINE_OVERLAY_ARCHIVE" "$baseline_archive" "$SENSOR_BASELINE_OVERLAY_ARCHIVE_SHA256"
    ci_extract_archive "$baseline_archive" "$baseline_extract"
    baseline_root=$(find_baseline_overlay_root "$baseline_extract") || ci_die "SENSOR_BASELINE_OVERLAY_ARCHIVE does not contain verified sensor overlay"
  fi

  ci_log "sensor source root: $source_root"
  ci_log "sensor baseline overlay root: $baseline_root"
}

make_iio_cross_file() {
  local file=$1
  local libssc_prefix=$2

  cat > "$file" <<EOF_CROSS
[binaries]
c = 'aarch64-linux-gnu-gcc'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = true
  pkg_config_libdir = ['$libssc_prefix/lib/aarch64-linux-gnu/pkgconfig', '/usr/lib/aarch64-linux-gnu/pkgconfig', '/usr/share/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF_CROSS
}

write_control() {
  local pkgdir=$1
  local package=$2
  local section=$3
  local depends=$4
  local description=$5
  local long_description=$6
  shift 6

  mkdir -p "$pkgdir/DEBIAN"
  {
    printf 'Package: %s\n' "$package"
    printf 'Version: %s\n' "$SENSOR_DEB_VERSION"
    printf 'Section: %s\n' "$section"
    printf 'Priority: optional\n'
    printf 'Architecture: %s\n' "$ARCH"
    printf 'Maintainer: GUF296 <guf296@users.noreply.github.com>\n'
    for field in "$@"; do
      printf '%s\n' "$field"
    done
    if [ -n "$depends" ]; then
      printf 'Depends: %s\n' "$depends"
    fi
    printf 'Description: %s\n' "$description"
    printf ' %s\n' "$long_description"
  } > "$pkgdir/DEBIAN/control"
}

write_ldconfig_maintainer_scripts() {
  local pkgdir=$1

  cat > "$pkgdir/DEBIAN/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
exit 0
EOF_POSTINST
  cat > "$pkgdir/DEBIAN/postrm" <<'EOF_POSTRM'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
exit 0
EOF_POSTRM
  chmod 0755 "$pkgdir/DEBIAN/postinst" "$pkgdir/DEBIAN/postrm"
}

write_systemd_maintainer_scripts() {
  local pkgdir=$1

  cat > "$pkgdir/DEBIAN/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -e
rm -f /etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf
rm -f /usr/local/libexec/y700-iio-sensor-proxy
rm -rf /usr/local/lib/y700-sns
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_POSTINST
  cat > "$pkgdir/DEBIAN/postrm" <<'EOF_POSTRM'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_POSTRM
  chmod 0755 "$pkgdir/DEBIAN/postinst" "$pkgdir/DEBIAN/postrm"
}

write_tb321fu_maintainer_scripts() {
  local pkgdir=$1

  cat > "$pkgdir/DEBIAN/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop y700-sns-init.service >/dev/null 2>&1 || true
  systemctl disable y700-sns-init.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf
  rm -f /etc/systemd/system/y700-sns-init.service
  rm -f /usr/local/libexec/y700-iio-sensor-proxy
  rm -rf /usr/local/lib/y700-sns
  systemctl daemon-reload || true
  systemctl enable qcom-sns-init.service >/dev/null
  systemctl is-enabled --quiet qcom-sns-init.service
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_POSTINST
  cat > "$pkgdir/DEBIAN/prerm" <<'EOF_PRERM'
#!/bin/sh
set -e
case "${1:-}" in
  remove|deconfigure)
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop qcom-sns-init.service >/dev/null 2>&1 || true
      systemctl disable qcom-sns-init.service >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/multi-user.target.wants/qcom-sns-init.service
    ;;
esac
exit 0
EOF_PRERM
  cat > "$pkgdir/DEBIAN/postrm" <<'EOF_POSTRM'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_POSTRM
  chmod 0755 \
    "$pkgdir/DEBIAN/postinst" \
    "$pkgdir/DEBIAN/prerm" \
    "$pkgdir/DEBIAN/postrm"
}

build_deb() {
  local pkgdir=$1
  local name=$2
  local deb="$OUTPUT_DIR/${name}_${SENSOR_DEB_VERSION}_${ARCH}.deb"

  ci_normalize_system_payload_modes "$pkgdir"
  ci_assert_normalized_system_payload_modes "$pkgdir"
  ci_assert_privileged_payload_security "$pkgdir"
  ci_normalize_package_tree "$pkgdir"
  dpkg-deb --build --root-owner-group "$pkgdir" "$deb" >/dev/null
  sha256sum "$deb"
}

strip_if_requested() {
  [ "$SENSOR_STRIP" = 1 ] || return 0
  aarch64-linux-gnu-strip --strip-unneeded "$@"
}

patch_hexagonrpc_for_qcom_sns() {
  local source_dir=$1
  local src=$source_dir/hexagonrpcd/apps_std.c
  local patch_file="$SCRIPT_DIR/patches/hexagonrpc-qcom-sns-generation.patch"

  [ -f "$patch_file" ] || ci_die "missing HexagonRPC qcom-sns generation patch"
  grep -q 'Y700_REGISTRY_ROOT' "$src" || \
    ci_die "hexagonrpc apps_std.c no longer contains expected registry root marker"
  (cd "$source_dir" && patch --batch --forward --fuzz=0 -p1 <"$patch_file") || \
    ci_die "failed to apply HexagonRPC qcom-sns generation patch"
  grep -q 'QCOM_SNS_REGISTRY_ROOT' "$src" || \
    ci_die "patched HexagonRPC lacks generation root support"
  grep -q 'QCOM_SNS_REGISTRY_ACCESS' "$src" || \
    ci_die "patched HexagonRPC lacks current-run access evidence"
}

build_libssc_package() {
  local src="$work_dir/src/libssc"
  local build="$src/build-qcom-sns-aarch64"
  local prefix="$work_dir/libssc-prefix"
  local pkg="$work_dir/pkg/qcom-sns-libssc"

  ci_log "building qcom-sns-libssc"
  copy_source "$source_root/sensor/daily-current/libssc" "$src"
  (cd "$src" && meson setup "$build" \
    --cross-file "$src/cross-aarch64.txt" \
    --prefix="$prefix" \
    --libdir=lib/aarch64-linux-gnu \
    --buildtype=release \
    --wrap-mode=nodownload)
  ninja -C "$build"
  meson install -C "$build" --no-rebuild

  mkdir -p "$pkg/usr"
  rsync -a "$prefix/" "$pkg/usr/"
  sed -i 's#^prefix=.*#prefix=/usr#' "$pkg/usr/lib/aarch64-linux-gnu/pkgconfig/libssc.pc"
  find "$pkg/usr/include" -type f -exec chmod 0644 {} +
  find "$pkg/usr/lib/aarch64-linux-gnu/pkgconfig" -type f -exec chmod 0644 {} +
  chmod 0644 "$pkg/usr/lib/aarch64-linux-gnu/libssc.so.2"
  chmod 0755 "$pkg/usr/bin/ssccli"
  strip_if_requested "$pkg/usr/bin/ssccli" "$pkg/usr/lib/aarch64-linux-gnu/libssc.so.2"
  write_control "$pkg" qcom-sns-libssc libs \
    'libc6, libglib2.0-0, libprotobuf-c1, libqmi-glib5' \
    'Qualcomm SSC userspace library' \
    'Source-built libssc and ssccli for Qualcomm Sensor Core devices.' \
    'Provides: libssc'
  write_ldconfig_maintainer_scripts "$pkg"
  build_deb "$pkg" qcom-sns-libssc

  libssc_pkg_prefix="$prefix"
}

build_hexagonrpc_package() {
  local src="$work_dir/src/hexagonrpc"
  local build="$src/build-qcom-sns-aarch64"
  local pkg="$work_dir/pkg/qcom-sns-hexagonrpc"

  ci_log "building qcom-sns-hexagonrpc"
  copy_source "$source_root/sensor/daily-current/hexagonrpc" "$src"
  patch_hexagonrpc_for_qcom_sns "$src"
  (cd "$src" && meson setup "$build" \
    --cross-file "$src/cross-aarch64.txt" \
    --prefix=/usr \
    --libdir=lib/aarch64-linux-gnu \
    --buildtype=release \
    --wrap-mode=nodownload)
  ninja -C "$build" hexagonrpcd/hexagonrpcd libhexagonrpc/libhexagonrpc.so.0.4

  install -d -m 0755 "$pkg/usr/bin" "$pkg/usr/lib/aarch64-linux-gnu"
  install -m 0755 "$build/hexagonrpcd/hexagonrpcd" "$pkg/usr/bin/hexagonrpcd"
  install -m 0644 "$build/libhexagonrpc/libhexagonrpc.so.0.4" "$pkg/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4"
  ln -s libhexagonrpc.so.0.4 "$pkg/usr/lib/aarch64-linux-gnu/libhexagonrpc.so"
  chmod 0755 "$pkg/usr/bin/hexagonrpcd"
  chmod 0644 "$pkg/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4"
  strip_if_requested "$pkg/usr/bin/hexagonrpcd" "$pkg/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4"
  write_control "$pkg" qcom-sns-hexagonrpc libs \
    'libc6' \
    'Qualcomm HexagonRPC userspace daemon' \
    'Source-built hexagonrpcd with generic qcom-sns persistent registry mapping.' \
    'Provides: hexagonrpcd'
  write_ldconfig_maintainer_scripts "$pkg"
  build_deb "$pkg" qcom-sns-hexagonrpc
}

build_iio_sensor_proxy_package() {
  local src="$work_dir/src/iio-sensor-proxy"
  local build="$src/build-qcom-sns-aarch64"
  local dest="$work_dir/stage/iio-sensor-proxy"
  local pkg="$work_dir/pkg/qcom-sns-iio-sensor-proxy"
  local cross="$work_dir/iio-cross-aarch64-qcom-sns.txt"

  ci_log "building qcom-sns-iio-sensor-proxy"
  copy_source "$source_root/sensor/daily-current/iio-sensor-proxy" "$src"
  [ ! -e "$stable_libssc_prefix" ] && [ ! -L "$stable_libssc_prefix" ] || \
    ci_die "stable libssc prefix unexpectedly exists before iio build"
  ln -s -- "$libssc_pkg_prefix" "$stable_libssc_prefix"
  sed -i "s#^prefix=.*#prefix=$stable_libssc_prefix#" \
    "$libssc_pkg_prefix/lib/aarch64-linux-gnu/pkgconfig/libssc.pc"
  make_iio_cross_file "$cross" "$stable_libssc_prefix"
  PKG_CONFIG_LIBDIR="$stable_libssc_prefix/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig" \
    pkg-config --modversion gudev-1.0 udev polkit-gobject-1 gio-2.0 libssc >/dev/null
  export PKG_CONFIG_LIBDIR="$stable_libssc_prefix/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
  (cd "$src" && meson setup "$build" \
    --cross-file "$cross" \
    --prefix=/usr \
    --buildtype=release \
    -Dssc-support=enabled \
    -Dtests=false \
    -Dgtk-tests=false \
    -Dgtk_doc=false \
    --wrap-mode=nodownload)
  ninja -C "$build"
  DESTDIR="$dest" meson install -C "$build" --no-rebuild

  mkdir -p "$pkg"
  rsync -a "$dest/" "$pkg/"
  chmod 0755 "$pkg/usr/bin/monitor-sensor" "$pkg/usr/libexec/iio-sensor-proxy"
  chmod 0644 \
    "$pkg/usr/lib/systemd/system/iio-sensor-proxy.service" \
    "$pkg/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules" \
    "$pkg/usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf" \
    "$pkg/usr/share/polkit-1/actions/net.hadess.SensorProxy.policy"
  install -d -m 0755 "$pkg/usr/share/dbus-1/system-services"
  cat > "$pkg/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service" <<'EOF_DBUS'
[D-BUS Service]
Name=net.hadess.SensorProxy
Exec=/usr/libexec/iio-sensor-proxy
User=root
SystemdService=iio-sensor-proxy.service
EOF_DBUS
  chmod 0644 "$pkg/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service"
  strip_if_requested "$pkg/usr/bin/monitor-sensor" "$pkg/usr/libexec/iio-sensor-proxy"
  if grep -aFq -- "$work_dir" "$pkg/usr/libexec/iio-sensor-proxy"; then
    ci_die "iio-sensor-proxy retained its random build workspace"
  fi
  if aarch64-linux-gnu-readelf -d "$pkg/usr/libexec/iio-sensor-proxy" | \
     grep -Eq '\((RPATH|RUNPATH)\)'; then
    ci_die "iio-sensor-proxy retained a build-time runtime search path"
  fi
  write_control "$pkg" qcom-sns-iio-sensor-proxy misc \
    'libc6, dbus, libglib2.0-0, libgudev-1.0-0, libpolkit-gobject-1-0, qcom-sns-libssc' \
    'IIO Sensor Proxy with Qualcomm SSC support' \
    'Source-built iio-sensor-proxy with Qualcomm SSC drivers enabled.' \
    'Provides: iio-sensor-proxy' \
    'Conflicts: iio-sensor-proxy' \
    'Replaces: iio-sensor-proxy'
  write_systemd_maintainer_scripts "$pkg"
  build_deb "$pkg" qcom-sns-iio-sensor-proxy
}

build_tb321fu_sensors_package() {
  local pkg="$work_dir/pkg/tb321fu-sensors"
  local qcom_root="$pkg/usr/share/qcom/sm8650/Lenovo/tb321fu"
  local source_hexagonfs="$baseline_root/usr/local/share/y700-sns/hexagonfs"
  local payload_dir="$SCRIPT_DIR/payloads"

  ci_log "building tb321fu-sensors"
  [ -d "$source_hexagonfs/sensors/registry" ] || ci_die "missing baseline sensors registry data"
  [ -d "$source_hexagonfs/sensors/config" ] || ci_die "missing baseline sensors config data"
  [ -d "$source_hexagonfs/socinfo" ] || ci_die "missing baseline socinfo data"

  install -d -m 0755 "$qcom_root"
  rsync -a "$source_hexagonfs/sensors" "$qcom_root/"
  rsync -a "$source_hexagonfs/socinfo" "$qcom_root/"
  find "$qcom_root" -type d -exec chmod 0755 {} +
  find "$qcom_root" -type f -exec chmod 0644 {} +
  install -d -m 0755 "$qcom_root/.tb321fu-manifests"
  (cd "$qcom_root" &&
    LC_ALL=C find sensors/registry -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 -r sha256sum -- >.tb321fu-manifests/registry.sha256)
  (cd "$qcom_root" &&
    LC_ALL=C find sensors/config -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 -r sha256sum -- >.tb321fu-manifests/config.sha256)
  [ -s "$qcom_root/.tb321fu-manifests/registry.sha256" ] || ci_die "empty registry manifest"
  [ -s "$qcom_root/.tb321fu-manifests/config.sha256" ] || ci_die "empty config manifest"
  (cd "$qcom_root" && sha256sum -c \
    .tb321fu-manifests/registry.sha256 \
    .tb321fu-manifests/config.sha256 >/dev/null) || \
    ci_die "sensor source manifest self-check failed"

  install -d -m 0755 "$pkg/usr/share/qcom/conf.d"
  cat > "$pkg/usr/share/qcom/conf.d/tb321fu.yaml" <<'EOF_YAML'
machines:
  "Lenovo Legion Y700 (2025) / TB321FU":
    DSP_LIBRARY_PATH: "/sm8650/Lenovo/tb321fu/"
EOF_YAML

  install -d -m 0755 "$pkg/usr/libexec/qcom-sns"
  install -m 0755 "$payload_dir/qcom-sns-init" \
    "$pkg/usr/libexec/qcom-sns/qcom-sns-init"

  install -d -m 0755 \
    "$pkg/usr/lib/systemd/system" \
    "$pkg/usr/lib/systemd/system-sleep" \
    "$pkg/etc/systemd/system/iio-sensor-proxy.service.d" \
    "$pkg/usr/lib/udev/rules.d"
  install -m 0755 "$payload_dir/qcom-sns-resume" \
    "$pkg/usr/lib/systemd/system-sleep/qcom-sns-resume"
  install -m 0644 "$payload_dir/qcom-sns-init.service" \
    "$pkg/usr/lib/systemd/system/qcom-sns-init.service"
  install -m 0644 "$payload_dir/99-qcom-sns.conf" \
    "$pkg/etc/systemd/system/iio-sensor-proxy.service.d/99-qcom-sns.conf"
  install -m 0644 "$payload_dir/80-tb321fu-qcom-sns.rules" \
    "$pkg/usr/lib/udev/rules.d/80-tb321fu-qcom-sns.rules"

  write_control "$pkg" tb321fu-sensors misc \
    'qcom-sns-hexagonrpc, qcom-sns-iio-sensor-proxy, qcom-sns-libssc, systemd, coreutils, findutils, util-linux' \
    'Sensor files for Lenovo Legion Y700 TB321FU' \
    'Verified TB321FU Qualcomm SNS device data and cold-boot initialization glue.' \
    'Conflicts: y700-sensors' \
    'Replaces: y700-sensors'
  write_tb321fu_maintainer_scripts "$pkg"
  ci_assert_privileged_payload_security "$pkg" \
    usr/libexec/qcom-sns/qcom-sns-init \
    usr/lib/systemd/system-sleep/qcom-sns-resume
  build_deb "$pkg" tb321fu-sensors

  registry_count=$(find "$qcom_root/sensors/registry" -type f | wc -l)
  config_count=$(find "$qcom_root/sensors/config" -type f | wc -l)
  [ "$registry_count" -ge 200 ] || ci_die "unexpected TB321FU registry file count: $registry_count"
  [ "$config_count" -ge 50 ] || ci_die "unexpected TB321FU config file count: $config_count"
  ci_log "tb321fu registry_files=$registry_count config_files=$config_count"
}

prepare_inputs
build_libssc_package
build_hexagonrpc_package
build_iio_sensor_proxy_package
build_tb321fu_sensors_package

ci_log "writing sensor package checksums"
(cd "$OUTPUT_DIR" && sha256sum ./*.deb > SHA256SUMS-y700-sensor-debs.txt)
ci_log "sensor package build complete: $OUTPUT_DIR"
