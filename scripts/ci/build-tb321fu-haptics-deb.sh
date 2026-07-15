#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build source-based TB321FU AW86937 haptics Debian package.

Environment inputs:
  OUTPUT_DIR                 default: out/tb321fu-haptics-debs
  ARCH                       default: arm64
  HAPTICS_DEB_VERSION        default: 20260627.1
  HAPTICS_SOURCE_ARCHIVE     source freeze archive containing haptics/daily-current
  HAPTICS_SOURCE_DIR         source freeze directory containing haptics/daily-current
  KERNEL_SOURCE_ARCHIVE      kernel source archive
  KERNEL_SOURCE_DIR          kernel source directory
  KERNEL_BUILD_ARCHIVE       kernel build output archive containing generated headers
  KERNEL_BUILD_DIR           kernel build output directory
  HAPTICS_STRIP              strip binaries/modules after build, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd make
ci_require_cmd rsync
ci_require_cmd dpkg-deb
ci_require_cmd sha256sum
ci_require_cmd aarch64-linux-gnu-gcc
ci_require_cmd aarch64-linux-gnu-strip
ci_require_cmd modinfo
ci_require_cmd patch
ci_require_cmd cut
ci_require_cmd sed
ci_require_cmd tr

OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-haptics-debs}
ARCH=${ARCH:-arm64}
HAPTICS_DEB_VERSION=${HAPTICS_DEB_VERSION:-20260627.1}
HAPTICS_SOURCE_ARCHIVE=${HAPTICS_SOURCE_ARCHIVE:-}
HAPTICS_SOURCE_ARCHIVE_SHA256=${HAPTICS_SOURCE_ARCHIVE_SHA256:-}
HAPTICS_SOURCE_DIR=${HAPTICS_SOURCE_DIR:-}
KERNEL_SOURCE_ARCHIVE=${KERNEL_SOURCE_ARCHIVE:-}
KERNEL_SOURCE_ARCHIVE_SHA256=${KERNEL_SOURCE_ARCHIVE_SHA256:-}
KERNEL_SOURCE_DIR=${KERNEL_SOURCE_DIR:-}
KERNEL_BUILD_ARCHIVE=${KERNEL_BUILD_ARCHIVE:-}
KERNEL_BUILD_ARCHIVE_SHA256=${KERNEL_BUILD_ARCHIVE_SHA256:-}
KERNEL_BUILD_DIR=${KERNEL_BUILD_DIR:-}
HAPTICS_STRIP=${HAPTICS_STRIP:-0}

[ "$ARCH" = arm64 ] || ci_die "unsupported ARCH=$ARCH; only arm64 is supported"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
rm -f -- \
  "$OUTPUT_DIR"/tb321fu-haptics_*.deb \
  "$OUTPUT_DIR"/tb321fu-haptics-common_*.deb \
  "$OUTPUT_DIR"/tb321fu-haptics-modules-*.deb \
  "$OUTPUT_DIR"/HAPTICS-SOURCE-LOCK.tsv \
  "$OUTPUT_DIR"/SHA256SUMS-tb321fu-haptics-debs.txt
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-haptics-build.XXXXXX")
SOURCE_DATE_EPOCH=$(ci_source_date_epoch)
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP="@$SOURCE_DATE_EPOCH"
export KBUILD_BUILD_USER=tb321fu
export KBUILD_BUILD_HOST=reproducible

cleanup() {
  ci_safe_rmtree "$work_dir" "${TMPDIR:-/tmp}" tb321fu-haptics-build.
}
trap cleanup EXIT

find_haptics_source_root() {
  local root=$1 marker found
  local -a candidates=()

  marker=/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c
  while IFS= read -r -d '' found; do
    found=${found%"$marker"}
    [ -f "$found/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" ] || continue
    [ -f "$found/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" ] || continue
    candidates+=("$found")
  done < <(find -H "$root" -type f -path "*$marker" -print0)

  [ "${#candidates[@]}" -eq 1 ] || {
    printf 'expected exactly one haptics source root below %s, found %s\n' \
      "$root" "${#candidates[@]}" >&2
    return 1
  }
  printf '%s\n' "${candidates[0]}"
}

find_kernel_source_root() {
  local root=$1 marker found
  local -a candidates=()

  marker=/scripts/Makefile.build
  while IFS= read -r -d '' found; do
    found=${found%"$marker"}
    [ -f "$found/Makefile" ] || continue
    [ -d "$found/drivers" ] || continue
    candidates+=("$found")
  done < <(find -H "$root" -type f -path "*$marker" -print0)

  [ "${#candidates[@]}" -eq 1 ] || {
    printf 'expected exactly one kernel source root below %s, found %s\n' \
      "$root" "${#candidates[@]}" >&2
    return 1
  }
  printf '%s\n' "${candidates[0]}"
}

find_kernel_build_root() {
  local root=$1 marker found
  local -a candidates=()

  marker=/include/config/kernel.release
  while IFS= read -r -d '' found; do
    found=${found%"$marker"}
    [ -f "$found/.config" ] || continue
    [ -f "$found/Module.symvers" ] || continue
    [ -f "$found/include/generated/autoconf.h" ] || continue
    candidates+=("$found")
  done < <(find -H "$root" -type f -path "*$marker" -print0)

  [ "${#candidates[@]}" -eq 1 ] || {
    printf 'expected exactly one kernel build root below %s, found %s\n' \
      "$root" "${#candidates[@]}" >&2
    return 1
  }
  printf '%s\n' "${candidates[0]}"
}

prepare_inputs() {
  local archive extract

  if [ -n "$HAPTICS_SOURCE_DIR" ]; then
    haptics_root=$(find_haptics_source_root "$HAPTICS_SOURCE_DIR") || ci_die "HAPTICS_SOURCE_DIR does not contain haptics source freeze"
  else
    [ -n "$HAPTICS_SOURCE_ARCHIVE" ] || ci_die "set HAPTICS_SOURCE_ARCHIVE or HAPTICS_SOURCE_DIR"
    archive="$work_dir/haptics-source.archive"
    extract="$work_dir/haptics-source"
    ci_download "$HAPTICS_SOURCE_ARCHIVE" "$archive" "$HAPTICS_SOURCE_ARCHIVE_SHA256"
    ci_extract_archive "$archive" "$extract"
    haptics_root=$(find_haptics_source_root "$extract") || ci_die "HAPTICS_SOURCE_ARCHIVE does not contain haptics source freeze"
  fi

  if [ -n "$KERNEL_SOURCE_DIR" ]; then
    kernel_source_root=$(find_kernel_source_root "$KERNEL_SOURCE_DIR") || ci_die "KERNEL_SOURCE_DIR does not contain kernel source"
  else
    [ -n "$KERNEL_SOURCE_ARCHIVE" ] || ci_die "set KERNEL_SOURCE_ARCHIVE or KERNEL_SOURCE_DIR"
    archive="$work_dir/kernel-source.archive"
    extract="$work_dir/kernel-source"
    ci_download "$KERNEL_SOURCE_ARCHIVE" "$archive" "$KERNEL_SOURCE_ARCHIVE_SHA256"
    ci_extract_archive "$archive" "$extract"
    kernel_source_root=$(find_kernel_source_root "$extract") || ci_die "KERNEL_SOURCE_ARCHIVE does not contain kernel source"
  fi

  if [ -n "$KERNEL_BUILD_DIR" ]; then
    kernel_build_root=$(find_kernel_build_root "$KERNEL_BUILD_DIR") || ci_die "KERNEL_BUILD_DIR does not contain kernel build output"
  else
    [ -n "$KERNEL_BUILD_ARCHIVE" ] || ci_die "set KERNEL_BUILD_ARCHIVE or KERNEL_BUILD_DIR"
    archive="$work_dir/kernel-build.archive"
    extract="$work_dir/kernel-build"
    ci_download "$KERNEL_BUILD_ARCHIVE" "$archive" "$KERNEL_BUILD_ARCHIVE_SHA256"
    ci_extract_archive "$archive" "$extract"
    kernel_build_root=$(find_kernel_build_root "$extract") || ci_die "KERNEL_BUILD_ARCHIVE does not contain kernel build output"
  fi

  kernel_release=$(cat "$kernel_build_root/include/config/kernel.release")
  ci_log "haptics source root: $haptics_root"
  ci_log "kernel source root: $kernel_source_root"
  ci_log "kernel build root: $kernel_build_root"
  ci_log "kernel release: $kernel_release"
}

patch_source_for_standard_module_name() {
  local src=$1

  sed -i \
    -e 's/Lenovo Y700 AW86937 input force-feedback haptics driver/Lenovo TB321FU AW86937 input force-feedback haptics driver/g' \
    -e 's/\.name = "aw86937-y700"/.name = "aw86937-haptics"/g' \
    "$src"

  if ! grep -q '"aw86937_haptics"' "$src"; then
    sed -i '/{ "aw86937_y700" }/i\	{ "aw86937_haptics" },' "$src"
  fi

  grep -q '\.name = "aw86937-haptics"' "$src" || ci_die "failed to patch i2c driver name"
  grep -q '"aw86937_haptics"' "$src" || ci_die "failed to add standard i2c id"
}

write_common_control() {
  local pkgdir=$1

  mkdir -p "$pkgdir/DEBIAN"
  cat > "$pkgdir/DEBIAN/control" <<EOF_CONTROL
Package: tb321fu-haptics-common
Version: $HAPTICS_DEB_VERSION
Section: misc
Priority: optional
Architecture: $ARCH
Maintainer: GUF296 <guf296@users.noreply.github.com>
Depends: systemd, udev, coreutils, findutils, feedbackd, feedbackd-device-themes
Provides: tb321fu-haptics
Conflicts: tb321fu-haptics, y700-haptics
Replaces: tb321fu-haptics, y700-haptics
Description: Shared AW86937 haptics support for Lenovo Legion Y700 TB321FU
 Firmware, feedbackd udev integration and standardized TB321FU boot-time
 binding glue shared by release-specific kernel module packages.
EOF_CONTROL
}

write_common_maintainer_scripts() {
  local pkgdir=$1

  cat > "$pkgdir/DEBIAN/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop y700-aw86937-haptics.service >/dev/null 2>&1 || true
  systemctl disable y700-aw86937-haptics.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/y700-aw86937-haptics.service
  rm -f /etc/udev/rules.d/90-y700-haptics.rules
  rm -f /usr/local/sbin/y700-aw86937-bind
  systemctl daemon-reload || true
  systemctl enable tb321fu-haptics.service >/dev/null
  systemctl is-enabled --quiet tb321fu-haptics.service
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

write_module_control() {
  local pkgdir=$1 package_name=$2

  mkdir -p "$pkgdir/DEBIAN"
  cat > "$pkgdir/DEBIAN/control" <<EOF_CONTROL
Package: $package_name
Version: $HAPTICS_DEB_VERSION
Section: kernel
Priority: optional
Architecture: $ARCH
Maintainer: GUF296 <guf296@users.noreply.github.com>
Depends: kmod, tb321fu-haptics-common (= $HAPTICS_DEB_VERSION)
Provides: tb321fu-haptics-modules
Description: AW86937 haptics module for Linux $kernel_release
 Source-built TB321FU AW86937 force-feedback module tied to the exact target
 kernel release. Other kernel-release module packages remain co-installable.
EOF_CONTROL
}

write_module_maintainer_scripts() {
  local pkgdir=$1

  cat > "$pkgdir/DEBIAN/postinst" <<EOF_POSTINST
#!/bin/sh
set -e
depmod "$kernel_release"
exit 0
EOF_POSTINST
  cat > "$pkgdir/DEBIAN/postrm" <<EOF_POSTRM
#!/bin/sh
set -e
depmod "$kernel_release" || true
exit 0
EOF_POSTRM
  chmod 0755 "$pkgdir/DEBIAN/postinst" "$pkgdir/DEBIAN/postrm"
}

write_bind_script() {
  local dest=$1

  cat > "$dest" <<'EOF_BIND'
#!/bin/sh
set -eu

find_haptic_adapter()
{
	for dev in /sys/bus/i2c/devices/i2c-*; do
		[ -e "$dev/name" ] || continue
		real=$(readlink -f "$dev" || true)
		case "$real" in
			*a9c000.i2c*) basename "$dev" | sed 's/^i2c-//'; return 0 ;;
		esac
	done
	return 1
}

load_driver()
{
	if lsmod | awk '{print $1}' | grep -Fxq aw86937_haptics; then
		return 0
	fi
	modprobe aw86937_haptics 2>/dev/null && return 0

	krel=$(uname -r)
	for module_path in \
		"/lib/modules/$krel/extra/aw86937-haptics.ko" \
		"/usr/lib/modules/$krel/extra/aw86937-haptics.ko"; do
		[ -f "$module_path" ] || continue
		insmod "$module_path" && return 0
	done

	echo "no AW86937 haptics module could be loaded" >&2
	return 1
}

is_known_haptic_name()
{
	case "$1" in
		aw86937_haptics|aw86937_y700|aw86937|haptic_hv|haptic_hv_r|haptic_hv_l|tb321fu-aw86937|y700-aw86937)
			return 0
			;;
	esac
	return 1
}

find_driver_dir()
{
	[ -d /sys/bus/i2c/drivers/aw86937-haptics ] || return 1
	printf '%s\n' /sys/bus/i2c/drivers/aw86937-haptics
}

bind_existing_client()
{
	dev="$1"
	name="$2"
	driver_dir="$3"
	busdev=$(basename "$dev")

	if ! is_known_haptic_name "$name"; then
		echo "$dev already exists as $name" >&2
		exit 1
	fi

	if [ -e "$dev/driver" ]; then
		driver=$(basename "$(readlink -f "$dev/driver")")
		[ "$driver" = aw86937-haptics ] && return 0
		echo "$dev is already bound to unexpected driver $driver" >&2
		exit 1
	fi

	printf '%s\n' "$busdev" > "$driver_dir/bind" 2>/dev/null || true

	for _ in $(seq 1 20); do
		if [ -e "$dev/driver" ]; then
			driver=$(basename "$(readlink -f "$dev/driver")")
			[ "$driver" = aw86937-haptics ] && return 0
		fi
		sleep 0.1
	done

	echo "$dev did not bind to AW86937 haptics driver" >&2
	exit 1
}

adapter=""
for _ in $(seq 1 80); do
	adapter=$(find_haptic_adapter 2>/dev/null || true)
	[ -n "$adapter" ] && break
	sleep 0.25
done

if [ -z "$adapter" ]; then
	echo "a9c000.i2c adapter not found" >&2
	exit 1
fi

load_driver
driver_dir=$(find_driver_dir) || { echo "AW86937 haptics i2c driver not registered" >&2; exit 1; }

for spec in "0x5a:right" "0x5b:left"; do
	addr=${spec%%:*}
	dev="/sys/bus/i2c/devices/${adapter}-00${addr#0x}"
	if [ -e "$dev/name" ]; then
		name=$(cat "$dev/name")
		bind_existing_client "$dev" "$name" "$driver_dir"
		continue
	fi
	printf 'aw86937_haptics %s\n' "$addr" > "/sys/bus/i2c/devices/i2c-$adapter/new_device"
done
EOF_BIND
  chmod 0755 "$dest"
}

write_systemd_unit() {
  local dest=$1

  cat > "$dest" <<'EOF_SERVICE'
[Unit]
Description=Bind Lenovo TB321FU AW86937 haptics
DefaultDependencies=no
After=systemd-udevd.service local-fs.target
Wants=systemd-udevd.service
Conflicts=y700-aw86937-haptics.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/tb321fu-haptics/bind-aw86937
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  chmod 0644 "$dest"
}

write_udev_rules() {
  local dest=$1

  cat > "$dest" <<'EOF_UDEV'
# TB321FU AW86937 haptics expose standard Linux input force-feedback devices.
ACTION=="remove", GOTO="tb321fu_haptics_end"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="aw86937-haptics-left", GROUP="input", MODE="0660", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra", SYMLINK+="input/tb321fu-haptics-left"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="aw86937-haptics-right", GROUP="input", MODE="0660", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra", SYMLINK+="input/tb321fu-haptics-right"
LABEL="tb321fu_haptics_end"
EOF_UDEV
  chmod 0644 "$dest"
}

write_plasma_keyboard_default() {
  local dest=$1

  cat > "$dest" <<'EOF_CONF'
[General]
enabledLocales=en_US
soundEnabled=true
vibrationEnabled=true
vibrationMs=20
EOF_CONF
  chmod 0644 "$dest"
}

strip_if_requested() {
  [ "$HAPTICS_STRIP" = 1 ] || return 0
  aarch64-linux-gnu-strip --strip-unneeded "$@"
}

build_haptics_package() {
  local src="$work_dir/module-src"
  local common_pkg="$work_dir/pkg/tb321fu-haptics-common"
  local module_pkg="$work_dir/pkg/tb321fu-haptics-modules"
  local module="$src/aw86937-haptics.ko"
  local helper_src="$haptics_root/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c"
  local driver_patch="$SCRIPT_DIR/patches/aw86937-cancellable-playback.patch"
  local release_id release_hash module_package common_deb module_deb
  local source_sha256 build_source_sha256

  ci_log "building aw86937-haptics external module"
  mkdir -p "$src"
  cp -a "$haptics_root/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c" "$src/aw86937-haptics.c"
  source_sha256=$(sha256sum "$src/aw86937-haptics.c" | awk '{print $1}')
  case "$source_sha256" in
    c03dcc47b4006e74b441b803b44162f7e715971ea6f7cf8d7c0c92e9f4ead5d4)
      [ -f "$driver_patch" ] || ci_die "missing AW86937 cancellation patch: $driver_patch"
      patch --batch --forward --fuzz=0 -d "$src" -p1 < "$driver_patch"
      ;;
    2e0cb7b739496ff6cf4011244ec9c0b2a2367896de65784041018b9d62186e48)
      ;;
    *)
      ci_die "AW86937 driver source is neither the tested freeze nor the canonical corrected source: $source_sha256"
      ;;
  esac
  source_sha256=$(sha256sum "$src/aw86937-haptics.c" | awk '{print $1}')
  [ "$source_sha256" = 2e0cb7b739496ff6cf4011244ec9c0b2a2367896de65784041018b9d62186e48 ] ||
    ci_die "AW86937 corrected driver source identity mismatch: $source_sha256"
  grep -q 'wait_event_timeout(haptics->play_wait' "$src/aw86937-haptics.c" ||
    ci_die "AW86937 driver patch did not install cancellable playback"
  grep -q 'pm_sleep_ptr(&aw86937_y700_pm_ops)' "$src/aw86937-haptics.c" ||
    ci_die "AW86937 driver patch did not install PM callbacks"
  if grep -Eq 'msleep\((duration_ms|play_ms)\)' "$src/aw86937-haptics.c"; then
    ci_die "AW86937 driver still contains an uninterruptible effect wait"
  fi
  patch_source_for_standard_module_name "$src/aw86937-haptics.c"
  build_source_sha256=$(sha256sum "$src/aw86937-haptics.c" | awk '{print $1}')
  cat > "$src/Makefile" <<'EOF_MAKE'
obj-m := aw86937-haptics.o
EOF_MAKE

  make -C "$kernel_source_root" O="$kernel_build_root" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M="$src" modules
  [ -f "$module" ] || ci_die "missing built module: $module"
  modinfo "$module" | tee "$work_dir/aw86937-haptics.modinfo"
  grep -q '^name:[[:space:]]*aw86937_haptics$' "$work_dir/aw86937-haptics.modinfo" || ci_die "unexpected module name"
  grep -q '^alias:[[:space:]]*i2c:aw86937_haptics$' "$work_dir/aw86937-haptics.modinfo" || ci_die "missing standard i2c alias"
  grep -q "^vermagic:[[:space:]]*$kernel_release " "$work_dir/aw86937-haptics.modinfo" || ci_die "module vermagic does not match $kernel_release"

  release_id=$(printf '%s' "$kernel_release" | tr '[:upper:]_' '[:lower:]-' | \
    sed -E 's/[^a-z0-9.+-]+/-/g; s/^-+//; s/-+$//')
  case "$release_id" in
    ''|[!a-z0-9]*|*[!a-z0-9.+-]*) ci_die "kernel release cannot form a package suffix: $kernel_release" ;;
  esac
  release_hash=$(printf '%s' "$kernel_release" | sha256sum | cut -c1-12)
  module_package="tb321fu-haptics-modules-$release_id-$release_hash"

  install -d -m 0755 \
    "$module_pkg/usr/lib/modules/$kernel_release/extra" \
    "$common_pkg/usr/lib/firmware" \
    "$common_pkg/usr/libexec/tb321fu-haptics" \
    "$common_pkg/usr/lib/systemd/system" \
    "$common_pkg/usr/lib/udev/rules.d" \
    "$common_pkg/etc/skel/.config" \
    "$common_pkg/usr/bin"

  install -m 0644 "$module" "$module_pkg/usr/lib/modules/$kernel_release/extra/aw86937-haptics.ko"
  install -m 0644 "$haptics_root/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" "$common_pkg/usr/lib/firmware/haptic_ram.bin"
  install -m 0644 "$haptics_root/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" "$common_pkg/usr/lib/firmware/haptic_click.bin"
  write_bind_script "$common_pkg/usr/libexec/tb321fu-haptics/bind-aw86937"
  write_systemd_unit "$common_pkg/usr/lib/systemd/system/tb321fu-haptics.service"
  write_udev_rules "$common_pkg/usr/lib/udev/rules.d/90-tb321fu-haptics.rules"
  write_plasma_keyboard_default "$common_pkg/etc/skel/.config/plasmakeyboardrc"

  if [ -f "$helper_src" ]; then
    aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o "$common_pkg/usr/bin/tb321fu-haptic-test" "$helper_src"
    chmod 0755 "$common_pkg/usr/bin/tb321fu-haptic-test"
    strip_if_requested "$common_pkg/usr/bin/tb321fu-haptic-test"
  fi

  strip_if_requested "$module_pkg/usr/lib/modules/$kernel_release/extra/aw86937-haptics.ko"
  write_common_control "$common_pkg"
  write_common_maintainer_scripts "$common_pkg"
  write_module_control "$module_pkg" "$module_package"
  write_module_maintainer_scripts "$module_pkg"

  ci_normalize_system_payload_modes "$common_pkg"
  ci_normalize_system_payload_modes "$module_pkg"
  ci_assert_normalized_system_payload_modes "$common_pkg"
  ci_assert_normalized_system_payload_modes "$module_pkg"
  ci_assert_privileged_payload_security "$common_pkg" \
    usr/libexec/tb321fu-haptics/bind-aw86937
  ci_normalize_package_tree "$common_pkg"
  ci_normalize_package_tree "$module_pkg"
  common_deb="$OUTPUT_DIR/tb321fu-haptics-common_${HAPTICS_DEB_VERSION}_${ARCH}.deb"
  module_deb="$OUTPUT_DIR/${module_package}_${HAPTICS_DEB_VERSION}_${ARCH}.deb"
  dpkg-deb --build --root-owner-group "$common_pkg" "$common_deb" >/dev/null
  dpkg-deb --build --root-owner-group "$module_pkg" "$module_deb" >/dev/null
  {
    printf 'aw86937-driver-sha256\t%s\n' "$source_sha256"
    printf 'aw86937-build-source-sha256\t%s\n' "$build_source_sha256"
    printf 'kernel-release\t%s\n' "$kernel_release"
  } > "$OUTPUT_DIR/HAPTICS-SOURCE-LOCK.tsv"
  sha256sum "$common_deb" "$module_deb"
}

prepare_inputs
build_haptics_package

ci_log "writing haptics package checksums"
(cd "$OUTPUT_DIR" && \
  sha256sum ./tb321fu-haptics-common_*.deb ./tb321fu-haptics-modules-*.deb \
    ./HAPTICS-SOURCE-LOCK.tsv > \
    SHA256SUMS-tb321fu-haptics-debs.txt)
ci_log "haptics package build complete: $OUTPUT_DIR"
