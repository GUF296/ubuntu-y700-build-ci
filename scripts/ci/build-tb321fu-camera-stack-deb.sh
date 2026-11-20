#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build the Lenovo TB321FU camera userspace stack Debian package.

Environment inputs:
  OUTPUT_DIR                 default: out/tb321fu-camera-stack-debs
  ARCH                       default: arm64
  CAMERA_STACK_DEB_VERSION   default: committed CAMERA-PACKAGE-VERSION policy
  CAMERA_STACK_ARCHIVE       optional archive containing y700-camera-rootfs-overlay
  CAMERA_STACK_DIR           optional directory containing y700-camera-rootfs-overlay
  CAMERA_PLUGIN_BUILD_JOBS   default: 2; bounded to 1..8

If CAMERA_STACK_ARCHIVE and CAMERA_STACK_DIR are empty, the script uses the
repository copy at source/tb321fu-camera-rootfs-overlay.
The builder reserves .tb321fu-camera-package-transaction-v1 in OUTPUT_DIR
for interrupted publication recovery and publishes the validated DEB last.
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd dpkg-deb
ci_require_cmd dpkg
ci_require_cmd aarch64-linux-gnu-g++-13
ci_require_cmd aarch64-linux-gnu-gcc-13
ci_require_cmd aarch64-linux-gnu-readelf
ci_require_cmd aarch64-linux-gnu-strings
ci_require_cmd aarch64-linux-gnu-strip
ci_require_cmd cmp
ci_require_cmd meson
ci_require_cmd ninja
ci_require_cmd pkg-config
ci_require_cmd python3
ci_require_cmd rsync
ci_require_cmd sha256sum

OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-camera-stack-debs}
ARCH=${ARCH:-arm64}
CAMERA_STACK_DEB_VERSION=${CAMERA_STACK_DEB_VERSION:-$(python3 -I -B "$SCRIPT_DIR/camera-package-policy.py" version)}
CAMERA_STACK_ARCHIVE=${CAMERA_STACK_ARCHIVE:-}
CAMERA_STACK_ARCHIVE_SHA256=${CAMERA_STACK_ARCHIVE_SHA256:-}
CAMERA_STACK_DIR=${CAMERA_STACK_DIR:-}
CAMERA_PLUGIN_BUILD_JOBS=${CAMERA_PLUGIN_BUILD_JOBS:-2}

[ "$ARCH" = arm64 ] || ci_die "unsupported ARCH=$ARCH; only arm64 is supported"
[[ ${#CAMERA_STACK_DEB_VERSION} -le 64 &&
   $CAMERA_STACK_DEB_VERSION =~ ^[0-9][0-9A-Za-z.+:~-]*$ ]] ||
  ci_die "CAMERA_STACK_DEB_VERSION must be a filename-safe Debian version"
dpkg --validate-version "$CAMERA_STACK_DEB_VERSION" >/dev/null 2>&1 ||
  ci_die "CAMERA_STACK_DEB_VERSION is not a valid Debian version"
if [ -n "$CAMERA_STACK_ARCHIVE" ] && [ -n "$CAMERA_STACK_DIR" ]; then
  ci_die "CAMERA_STACK_ARCHIVE and CAMERA_STACK_DIR are mutually exclusive"
fi
if [ -n "$CAMERA_STACK_ARCHIVE_SHA256" ] && [ -z "$CAMERA_STACK_ARCHIVE" ]; then
  ci_die "CAMERA_STACK_ARCHIVE_SHA256 requires CAMERA_STACK_ARCHIVE"
fi
case "$CAMERA_PLUGIN_BUILD_JOBS" in
  ''|*[!0-9]*) ci_die "CAMERA_PLUGIN_BUILD_JOBS must be a decimal integer" ;;
esac
[ "$CAMERA_PLUGIN_BUILD_JOBS" -ge 1 ] && [ "$CAMERA_PLUGIN_BUILD_JOBS" -le 8 ] ||
  ci_die "CAMERA_PLUGIN_BUILD_JOBS must be between 1 and 8"

final_output_dir=$(ci_abs_path "$OUTPUT_DIR")
ci_validate_no_symlink_ancestors "$final_output_dir" camera-output-directory
if [ -e "$final_output_dir" ]; then
  [ -d "$final_output_dir" ] && [ ! -L "$final_output_dir" ] ||
    ci_die "camera output directory is not a real directory: $final_output_dir"
else
  mkdir -p -- "$final_output_dir"
fi
deb_name="tb321fu-camera-stack_${CAMERA_STACK_DEB_VERSION}_${ARCH}.deb"
ci_require_cmd flock
# Keep one open directory description through preflight, build and publish.
exec 9<"$final_output_dir"
flock -n 9 || ci_die "camera output directory is already being built: $final_output_dir"
python3 -I -B "$SCRIPT_DIR/publish-camera-package.py" "$final_output_dir" "$deb_name" --lock-fd 9
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-camera-stack-build.XXXXXX")

cleanup() {
  if [ "${CAMERA_KEEP_WORKDIR:-0}" = 1 ]; then
    ci_log "keeping camera producer work directory: $work_dir"
  else
    ci_safe_rmtree "$work_dir" "${TMPDIR:-/tmp}" tb321fu-camera-stack-build.
  fi
}
trap cleanup EXIT
OUTPUT_DIR="$work_dir/output"
mkdir -- "$OUTPUT_DIR"

find_camera_source_root() {
  local root=$1 found candidate markers_file
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

  markers_file=$(mktemp "$work_dir/camera-markers.XXXXXX")
  if ! find "$root" -type f \
      -path '*/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so' \
      -print0 | LC_ALL=C sort -z >"$markers_file"; then
    rm -f -- "$markers_file"
    return 1
  fi
  mapfile -d '' -t markers <"$markers_file"
  rm -f -- "$markers_file"
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
    camera_input_kind=directory
    camera_source_root=$(find_camera_source_root "$CAMERA_STACK_DIR") || ci_die "CAMERA_STACK_DIR does not contain the verified camera overlay"
  elif [ -n "$CAMERA_STACK_ARCHIVE" ]; then
    camera_input_kind=archive
    archive="$work_dir/camera-stack.archive"
    extract="$work_dir/camera-stack"
    ci_download "$CAMERA_STACK_ARCHIVE" "$archive" "$CAMERA_STACK_ARCHIVE_SHA256"
    ci_extract_archive "$archive" "$extract"
    camera_source_root=$(find_camera_source_root "$extract") || ci_die "CAMERA_STACK_ARCHIVE does not contain the verified camera overlay"
  else
    camera_input_kind=repository
    camera_source_root=$(find_camera_source_root "$default_dir") || ci_die "repository camera overlay is missing: $default_dir"
  fi

  if [ -d "$camera_source_root/rootfs-overlay" ]; then
    camera_overlay_root="$camera_source_root/rootfs-overlay"
  else
    camera_overlay_root="$camera_source_root"
  fi

  camera_overlay_manifest="$camera_source_root/OVERLAY-MANIFEST.tsv"
  camera_producer_root="$camera_source_root/source/spa-libcamera-producer"
  camera_plugin_source="$camera_source_root/source/libcamera-source.cpp.clean-minimal-daily"
  [ -f "$camera_overlay_manifest" ] && [ ! -L "$camera_overlay_manifest" ] ||
    ci_die "camera overlay manifest is missing or symlinked"
  [ -d "$camera_producer_root" ] && [ ! -L "$camera_producer_root" ] ||
    ci_die "camera SPA producer source is missing or symlinked"
  [ -f "$camera_plugin_source" ] && [ ! -L "$camera_plugin_source" ] ||
    ci_die "camera SPA implementation source is missing or symlinked"

  ci_log "camera source root: $camera_source_root"
  ci_log "camera overlay root: $camera_overlay_root"
}

validate_camera_payload() {
  local root=$1 manifest=${2:-} replacement_plugin=${3:-} replacement_runtime=${4:-}
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

  if [ -n "$manifest" ]; then
    local -a verify_args=("$root" "$manifest")
    if [ -n "$replacement_plugin" ]; then
      verify_args+=(--replacement-plugin "$replacement_plugin")
    fi
    if [ -n "$replacement_runtime" ]; then
      verify_args+=(--replacement-runtime "$replacement_runtime")
    fi
    python3 "$SCRIPT_DIR/verify-camera-overlay.py" "${verify_args[@]}" >/dev/null
  fi

  if aarch64-linux-gnu-strings "$plugin" "$cam" "$soft_ipa" "$soft_proxy" "$gst_plugin" | grep -F 'libcamera-y700-test' >/dev/null; then
    ci_die "camera payload still references rejected libcamera-y700-test app-chain"
  fi

  grep -q '^/opt/libcamera-y700/lib/aarch64-linux-gnu$' "$root/etc/ld.so.conf.d/y700-libcamera.conf" || ci_die "camera ldconfig path does not point at /opt/libcamera-y700"
}

prepare_camera_producer() {
  ci_log "verifying camera SPA producer source and toolchain"
  python3 "$SCRIPT_DIR/verify-camera-plugin-producer.py" \
    --check-tools "$camera_producer_root"
  python3 "$SCRIPT_DIR/test-camera-source-contract.py" "$camera_plugin_source"

  camera_verified_producer="$work_dir/producer-verified"
  camera_verified_plugin_source="$work_dir/libcamera-source.cpp"
  install -d -m 0755 "$camera_verified_producer"
  rsync -a -- "$camera_producer_root/" "$camera_verified_producer/"
  python3 "$SCRIPT_DIR/verify-camera-plugin-producer.py" \
    "$camera_verified_producer" >/dev/null
  install -m 0644 "$camera_plugin_source" "$camera_verified_plugin_source"
  cmp -s -- "$camera_plugin_source" "$camera_verified_plugin_source" ||
    ci_die "camera SPA implementation changed while snapshotting"
  python3 "$SCRIPT_DIR/test-camera-source-contract.py" \
    "$camera_verified_plugin_source" >/dev/null

  ci_log "building the complete paired libcamera runtime from locked source"
  camera_runtime_output="$work_dir/libcamera-runtime"
  python3 -I -B "$SCRIPT_DIR/build-tb321fu-libcamera-runtime.py" \
    --output-root "$camera_runtime_output" \
    --jobs "$((CAMERA_PLUGIN_BUILD_JOBS * 2))"
  camera_libcamera_stage="$camera_runtime_output/runtime"
  local digest_input

  camera_link_build_id=$(
    for digest_input in \
      "$camera_verified_plugin_source" \
      "$camera_verified_producer/SOURCE-MANIFEST.tsv" \
      "$camera_verified_producer/TOOLCHAIN.tsv" \
      "$camera_runtime_output/RUNTIME-MANIFEST.tsv" \
      "$camera_runtime_output/BUILD-PROVENANCE.json" \
      "$camera_libcamera_stage/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1" \
      "$camera_libcamera_stage/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1"; do
      sha256sum "$digest_input" | cut -d ' ' -f 1
    done | sha256sum | cut -c 1-40
  )
  [[ $camera_link_build_id =~ ^[0-9a-f]{40}$ ]] ||
    ci_die "camera link build-id derivation failed"
}

write_camera_cross_file() {
  local destination=$1 prefix_flags_text flag
  local -a prefix_flags=()
  prefix_flags_text=$(ci_reproducible_prefix_flags \
    "$work_dir" /usr/src/tb321fu-camera-plugin) || return
  mapfile -t prefix_flags <<<"$prefix_flags_text"
  [ "${#prefix_flags[@]}" -eq 3 ] || ci_die "camera prefix-map contract is incomplete"
  {
    cat <<EOF_CROSS
[binaries]
cpp = '/usr/bin/aarch64-linux-gnu-g++-13'
pkg-config = '/usr/bin/pkg-config'
strip = '/usr/bin/aarch64-linux-gnu-strip'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
cpp_link_args = ['-Wl,--build-id=0x${camera_link_build_id}']
EOF_CROSS
    printf 'cpp_args = ['
    for flag in \
      "-ffile-prefix-map=$work_dir/producer-a=/usr/src/tb321fu-camera-plugin" \
      "-ffile-prefix-map=$work_dir/producer-b=/usr/src/tb321fu-camera-plugin" \
      "-fdebug-prefix-map=$work_dir/producer-a=/usr/src/tb321fu-camera-plugin" \
      "-fdebug-prefix-map=$work_dir/producer-b=/usr/src/tb321fu-camera-plugin" \
      "-fmacro-prefix-map=$work_dir/producer-a=/usr/src/tb321fu-camera-plugin" \
      "-fmacro-prefix-map=$work_dir/producer-b=/usr/src/tb321fu-camera-plugin" \
      "-ffile-prefix-map=$work_dir/build-a=/usr/src/tb321fu-camera-plugin-build" \
      "-ffile-prefix-map=$work_dir/build-b=/usr/src/tb321fu-camera-plugin-build" \
      "-fdebug-prefix-map=$work_dir/build-a=/usr/src/tb321fu-camera-plugin-build" \
      "-fdebug-prefix-map=$work_dir/build-b=/usr/src/tb321fu-camera-plugin-build" \
      "-fmacro-prefix-map=$work_dir/build-a=/usr/src/tb321fu-camera-plugin-build" \
      "-fmacro-prefix-map=$work_dir/build-b=/usr/src/tb321fu-camera-plugin-build" \
      "-ffile-prefix-map=../producer-a=/usr/src/tb321fu-camera-plugin" \
      "-ffile-prefix-map=../producer-b=/usr/src/tb321fu-camera-plugin" \
      "-fdebug-prefix-map=../producer-a=/usr/src/tb321fu-camera-plugin" \
      "-fdebug-prefix-map=../producer-b=/usr/src/tb321fu-camera-plugin" \
      "-fmacro-prefix-map=../producer-a=/usr/src/tb321fu-camera-plugin" \
      "-fmacro-prefix-map=../producer-b=/usr/src/tb321fu-camera-plugin" \
      "-ffile-prefix-map=$work_dir=/usr/src/tb321fu-camera-plugin" \
      "-fdebug-prefix-map=$work_dir=/usr/src/tb321fu-camera-plugin" \
      "-fmacro-prefix-map=$work_dir=/usr/src/tb321fu-camera-plugin" \
      "${prefix_flags[@]}" \
      '-Wdate-time'; do
      printf "'%s'," "$flag"
    done
    printf ']\n'
  } >"$destination"
  chmod 0644 "$destination"
}

build_camera_plugin_once() {
  local label=$1
  local source_dir="$work_dir/producer-$label"
  local build_dir="$work_dir/build-$label"
  local install_dir="$work_dir/install-$label"
  local cross_file="$work_dir/cross-$label.ini"
  local epoch

  install -d -m 0755 "$source_dir"
  rsync -a -- "$camera_verified_producer/" "$source_dir/"
  python3 "$SCRIPT_DIR/verify-camera-plugin-producer.py" "$source_dir" >/dev/null
  install -m 0644 "$camera_verified_plugin_source" \
    "$source_dir/spa/plugins/libcamera/libcamera-source.cpp"
  write_camera_cross_file "$cross_file"
  epoch=$(ci_source_date_epoch) || return

  env -u PKG_CONFIG_PATH -u PKG_CONFIG_SYSROOT_DIR \
    LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="$epoch" \
    PKG_CONFIG_LIBDIR=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig \
    meson setup "$build_dir" "$source_dir" \
      --cross-file "$cross_file" \
      --prefix=/usr \
      --libdir=lib/aarch64-linux-gnu \
      --buildtype=release \
      --werror \
      --wrap-mode=nodownload \
      -Dlibcamera_staging="$camera_libcamera_stage"
  ninja -C "$build_dir" -j "$CAMERA_PLUGIN_BUILD_JOBS"
  DESTDIR="$install_dir" meson install -C "$build_dir" --no-rebuild
  camera_last_plugin="$install_dir/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
  [ -f "$camera_last_plugin" ] && [ ! -L "$camera_last_plugin" ] ||
    ci_die "camera producer did not install the SPA plugin ($label)"
  aarch64-linux-gnu-strip --strip-unneeded "$camera_last_plugin"
  chmod 0644 "$camera_last_plugin"
}

verify_camera_plugin_elf() {
  local plugin=$1 header dynamic notes strings_file actual_needed expected_needed
  local actual_build_id
  header=$(aarch64-linux-gnu-readelf -h "$plugin") ||
    ci_die "cannot inspect camera plugin ELF header"
  dynamic=$(aarch64-linux-gnu-readelf -d "$plugin") ||
    ci_die "cannot inspect camera plugin dynamic section"
  notes=$(aarch64-linux-gnu-readelf -n "$plugin") ||
    ci_die "cannot inspect camera plugin ELF notes"
  grep -Eq 'Class:[[:space:]]+ELF64[[:space:]]*$' <<<"$header" ||
    ci_die "camera plugin is not ELF64"
  grep -Eq 'Machine:[[:space:]]+AArch64[[:space:]]*$' <<<"$header" ||
    ci_die "camera plugin does not target AArch64"
  grep -Eq '\(SONAME\).*\[libspa-libcamera\.so\][[:space:]]*$' <<<"$dynamic" ||
    ci_die "camera plugin SONAME mismatch"
  grep -Eq '\(RUNPATH\).*\[/opt/libcamera-y700/lib/aarch64-linux-gnu\][[:space:]]*$' \
    <<<"$dynamic" ||
    ci_die "camera plugin RUNPATH mismatch"
  if grep -Fq '(RPATH)' <<<"$dynamic"; then
    ci_die "camera plugin contains deprecated RPATH"
  fi
  grep -Eq '\(FLAGS_1\).*NODELETE' <<<"$dynamic" ||
    ci_die "camera plugin is missing ELF NODELETE"
  actual_build_id=$(sed -n 's/^[[:space:]]*Build ID: \([0-9a-f][0-9a-f]*\)[[:space:]]*$/\1/p' \
    <<<"$notes")
  [ "$actual_build_id" = "$camera_link_build_id" ] ||
    ci_die "camera plugin build-id mismatch: $actual_build_id"
  actual_needed=$(sed -n \
    's/^.*(NEEDED).*Shared library: \[\([^]]*\)\].*$/\1/p' \
    <<<"$dynamic" | LC_ALL=C sort)
  expected_needed=$(printf '%s\n' \
    ld-linux-aarch64.so.1 \
    libc.so.6 \
    libcamera-base.so.0.7 \
    libcamera.so.0.7 \
    libgcc_s.so.1 \
    libm.so.6 \
    libstdc++.so.6)
  [ "$actual_needed" = "$expected_needed" ] ||
    ci_die "camera plugin dependency closure mismatch: $actual_needed"
  strings_file="$work_dir/camera-plugin.strings"
  aarch64-linux-gnu-strings -a "$plugin" >"$strings_file"
  if grep -Fq "$work_dir" "$strings_file" ||
     grep -Fq '/home/guf296/' "$strings_file"; then
    ci_die "camera plugin contains a private build path"
  fi
}

build_camera_plugin() {
  prepare_camera_producer
  build_camera_plugin_once a
  camera_built_plugin=$camera_last_plugin
  build_camera_plugin_once b
  camera_second_plugin=$camera_last_plugin
  if ! cmp -s -- "$camera_built_plugin" "$camera_second_plugin"; then
    sha256sum "$camera_built_plugin" "$camera_second_plugin" >&2
    aarch64-linux-gnu-readelf -n "$camera_built_plugin" >&2 || true
    aarch64-linux-gnu-readelf -n "$camera_second_plugin" >&2 || true
    ci_die "independent camera SPA plugin builds are not byte-identical"
  fi
  [ "$(sha256sum "$camera_built_plugin" | cut -d ' ' -f 1)" = \
    "$(sha256sum "$camera_second_plugin" | cut -d ' ' -f 1)" ] ||
    ci_die "independent camera SPA plugin digests differ"
  verify_camera_plugin_elf "$camera_built_plugin"
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
Depends: libc6, libstdc++6, libgcc-s1, pipewire, wireplumber, udev, libspa-0.2-modules, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libglib2.0-0t64, libyaml-0-2, libudev1, libegl1, libgles2, libevent-2.1-7t64, libevent-pthreads-2.1-7t64, libunwind8, libdw1t64, libgnutls30t64
Recommends: gnome-snapshot
Pre-Depends: tb321fu-camera-payload-migrated (>= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)
Replaces: y700-daily-rootfs-overlay, libspa-0.2-libcamera, gstreamer1.0-libcamera
Conflicts: libspa-0.2-libcamera, gstreamer1.0-libcamera
Provides: y700-camera-stack
Description: Lenovo TB321FU camera userspace stack
 Source-built libcamera, IPA, GStreamer and PipeWire integration candidate.
 Hardware validation against the historically tested baseline remains required.
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

  validate_camera_payload "$camera_overlay_root" "$camera_overlay_manifest"
  camera_verified_overlay_root="$work_dir/camera-overlay-verified"
  install -d -m 0755 "$camera_verified_overlay_root"
  rsync -aH --numeric-ids "$camera_overlay_root"/ "$camera_verified_overlay_root"/
  validate_camera_payload \
    "$camera_verified_overlay_root" "$camera_overlay_manifest"
  build_camera_plugin

  rm -rf "$pkg"
  install -d -m 0755 "$pkg"
  rsync -aH --numeric-ids "$camera_verified_overlay_root"/ "$pkg"/

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

  install -m 0644 "$camera_built_plugin" \
    "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"

  # Only the authenticated compiled members replace the baseline. Development
  # headers/pkg-config files remain build inputs, never package additions.
  local runtime_member
  for runtime_member in \
    opt/libcamera-y700/bin/cam \
    opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1 \
    opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1 \
    opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so \
    opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so.sign \
    opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy \
    opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so; do
    cp -- "$camera_libcamera_stage/$runtime_member" "$pkg/$runtime_member"
  done

  ci_normalize_system_payload_modes "$pkg"
  ci_assert_normalized_system_payload_modes "$pkg"
  validate_camera_payload \
    "$pkg" "$camera_overlay_manifest" "$camera_built_plugin" "$camera_runtime_output"

  write_control "$pkg"
  write_maintainer_scripts "$pkg"
  validate_camera_payload "$pkg" ""

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
  python3 -I -B "$SCRIPT_DIR/test-camera-runtime-dependencies.py" --deb "$deb"

  {
    echo "TB321FU_CAMERA_STACK_DEB_BUILD=PASS"
    echo "version=$CAMERA_STACK_DEB_VERSION"
    echo "arch=$ARCH"
    echo "camera_input_kind=$camera_input_kind"
    echo "deb=$(basename -- "$deb")"
    echo "camera_source_sha256=$(sha256sum "$camera_verified_plugin_source" | cut -d ' ' -f 1)"
    echo "camera_producer_manifest_sha256=$(sha256sum "$camera_verified_producer/SOURCE-MANIFEST.tsv" | cut -d ' ' -f 1)"
    echo "camera_toolchain_sha256=$(sha256sum "$camera_verified_producer/TOOLCHAIN.tsv" | cut -d ' ' -f 1)"
    echo "camera_link_build_id=$camera_link_build_id"
    echo "camera_overlay_manifest_sha256=$(sha256sum "$camera_overlay_manifest" | cut -d ' ' -f 1)"
    echo "camera_plugin_sha256=$(sha256sum "$camera_built_plugin" | cut -d ' ' -f 1)"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename -- "$deb")")
    echo
    echo "libcamera_runtime_manifest_sha256=$(sha256sum "$camera_runtime_output/RUNTIME-MANIFEST.tsv" | cut -d ' ' -f 1)"
    echo "libcamera_build_provenance_sha256=$(sha256sum "$camera_runtime_output/BUILD-PROVENANCE.json" | cut -d ' ' -f 1)"
    echo "== complete runtime build provenance (public inputs only) =="
    cat "$camera_runtime_output/BUILD-PROVENANCE.json"
    echo "== complete build runtime manifest (includes build-only headers) =="
    cat "$camera_runtime_output/RUNTIME-MANIFEST.tsv"
    echo
    echo "== package control =="
    dpkg-deb -I "$deb"
    echo
    echo "== key hashes =="
    (cd "$pkg" && sha256sum \
      opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1 \
      opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1 \
      opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so \
      opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so \
      usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so)
    echo
    echo "== plugin dynamic section =="
    aarch64-linux-gnu-readelf -d \
      "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
    echo
    echo "== plugin markers =="
    aarch64-linux-gnu-strings -a "$pkg/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" | grep -E 'kwinoutputconfig|kscreen-doctor|y700_camera|spa_system_eventfd|camera-display-transform-mode|display-rotation-base|libcamera-y700-test|api.libcamera.rotation' | head -n 120 || true
  } > "$report"

  cat "$report"
}

prepare_inputs
build_camera_package

ci_log "writing camera package checksums"
(cd "$OUTPUT_DIR" && sha256sum \
  "tb321fu-camera-stack_${CAMERA_STACK_DEB_VERSION}_${ARCH}.deb" \
  > SHA256SUMS-tb321fu-camera-stack-debs.txt)
python3 -I -B "$SCRIPT_DIR/publish-camera-package.py" "$final_output_dir" "$deb_name" "$OUTPUT_DIR" --lock-fd 9
ci_log "camera package build complete: $final_output_dir"
