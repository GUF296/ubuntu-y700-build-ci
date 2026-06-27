#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

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

OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-haptics-debs}
ARCH=${ARCH:-arm64}
HAPTICS_DEB_VERSION=${HAPTICS_DEB_VERSION:-20260627.1}
HAPTICS_SOURCE_ARCHIVE=${HAPTICS_SOURCE_ARCHIVE:-}
HAPTICS_SOURCE_DIR=${HAPTICS_SOURCE_DIR:-}
KERNEL_SOURCE_ARCHIVE=${KERNEL_SOURCE_ARCHIVE:-}
KERNEL_SOURCE_DIR=${KERNEL_SOURCE_DIR:-}
KERNEL_BUILD_ARCHIVE=${KERNEL_BUILD_ARCHIVE:-}
KERNEL_BUILD_DIR=${KERNEL_BUILD_DIR:-}
HAPTICS_STRIP=${HAPTICS_STRIP:-0}

[ "$ARCH" = arm64 ] || ci_die "unsupported ARCH=$ARCH; only arm64 is supported"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(ci_abs_path "$OUTPUT_DIR")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-haptics-build.XXXXXX")

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

find_haptics_source_root() {
  local root=$1 found

  if [ -f "$root/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c" ] && \
     [ -f "$root/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" ] && \
     [ -f "$root/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" ]; then
    printf '%s\n' "$root"
    return 0
  fi

  found=$(find "$root" -type f -path '*/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c}
  [ -f "$found/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" ] || return 1
  [ -f "$found/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" ] || return 1
  printf '%s\n' "$found"
}

find_kernel_source_root() {
  local root=$1 found

  if [ -f "$root/Makefile" ] && [ -d "$root/scripts" ] && [ -d "$root/drivers" ]; then
    printf '%s\n' "$root"
    return 0
  fi

  found=$(find "$root" -type f -path '*/scripts/Makefile.build' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/scripts/Makefile.build}
  [ -f "$found/Makefile" ] || return 1
  [ -d "$found/drivers" ] || return 1
  printf '%s\n' "$found"
}

find_kernel_build_root() {
  local root=$1 found

  if [ -f "$root/.config" ] && \
     [ -f "$root/Module.symvers" ] && \
     [ -f "$root/include/generated/autoconf.h" ] && \
     [ -f "$root/include/config/kernel.release" ]; then
    printf '%s\n' "$root"
    return 0
  fi

  found=$(find "$root" -type f -path '*/include/config/kernel.release' -print -quit)
  [ -n "$found" ] || return 1
  found=${found%/include/config/kernel.release}
  [ -f "$found/.config" ] || return 1
  [ -f "$found/Module.symvers" ] || return 1
  [ -f "$found/include/generated/autoconf.h" ] || return 1
  printf '%s\n' "$found"
}

prepare_inputs() {
  local archive extract

  if [ -n "$HAPTICS_SOURCE_DIR" ]; then
    haptics_root=$(find_haptics_source_root "$HAPTICS_SOURCE_DIR") || ci_die "HAPTICS_SOURCE_DIR does not contain haptics source freeze"
  else
    [ -n "$HAPTICS_SOURCE_ARCHIVE" ] || ci_die "set HAPTICS_SOURCE_ARCHIVE or HAPTICS_SOURCE_DIR"
    archive="$work_dir/haptics-source.archive"
    extract="$work_dir/haptics-source"
    ci_download "$HAPTICS_SOURCE_ARCHIVE" "$archive"
    ci_extract_archive "$archive" "$extract"
    haptics_root=$(find_haptics_source_root "$extract") || ci_die "HAPTICS_SOURCE_ARCHIVE does not contain haptics source freeze"
  fi

  if [ -n "$KERNEL_SOURCE_DIR" ]; then
    kernel_source_root=$(find_kernel_source_root "$KERNEL_SOURCE_DIR") || ci_die "KERNEL_SOURCE_DIR does not contain kernel source"
  else
    [ -n "$KERNEL_SOURCE_ARCHIVE" ] || ci_die "set KERNEL_SOURCE_ARCHIVE or KERNEL_SOURCE_DIR"
    archive="$work_dir/kernel-source.archive"
    extract="$work_dir/kernel-source"
    ci_download "$KERNEL_SOURCE_ARCHIVE" "$archive"
    ci_extract_archive "$archive" "$extract"
    kernel_source_root=$(find_kernel_source_root "$extract") || ci_die "KERNEL_SOURCE_ARCHIVE does not contain kernel source"
  fi

  if [ -n "$KERNEL_BUILD_DIR" ]; then
    kernel_build_root=$(find_kernel_build_root "$KERNEL_BUILD_DIR") || ci_die "KERNEL_BUILD_DIR does not contain kernel build output"
  else
    [ -n "$KERNEL_BUILD_ARCHIVE" ] || ci_die "set KERNEL_BUILD_ARCHIVE or KERNEL_BUILD_DIR"
    archive="$work_dir/kernel-build.archive"
    extract="$work_dir/kernel-build"
    ci_download "$KERNEL_BUILD_ARCHIVE" "$archive"
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

write_control() {
  local pkgdir=$1

  mkdir -p "$pkgdir/DEBIAN"
  cat > "$pkgdir/DEBIAN/control" <<EOF_CONTROL
Package: tb321fu-haptics
Version: $HAPTICS_DEB_VERSION
Section: misc
Priority: optional
Architecture: $ARCH
Maintainer: GUF296 <guf296@users.noreply.github.com>
Depends: kmod, systemd, udev, coreutils, findutils, feedbackd, feedbackd-device-themes
Conflicts: y700-haptics
Replaces: y700-haptics
Description: AW86937 haptics support for Lenovo Legion Y700 TB321FU
 Source-built AW86937 force-feedback haptics module, firmware, feedbackd udev
 integration and TB321FU boot-time binding glue.
EOF_CONTROL
}

write_maintainer_scripts() {
  local pkgdir=$1

  cat > "$pkgdir/DEBIAN/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -e

if command -v depmod >/dev/null 2>&1; then
  depmod -a || true
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop y700-aw86937-haptics.service >/dev/null 2>&1 || true
  systemctl disable y700-aw86937-haptics.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/y700-aw86937-haptics.service
  rm -f /etc/udev/rules.d/90-y700-haptics.rules
  rm -f /usr/local/sbin/y700-aw86937-bind
  systemctl daemon-reload || true
  systemctl enable tb321fu-haptics.service >/dev/null 2>&1 || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_POSTINST

  cat > "$pkgdir/DEBIAN/postrm" <<'EOF_POSTRM'
#!/bin/sh
set -e

if command -v depmod >/dev/null 2>&1; then
  depmod -a || true
fi
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
	if lsmod | awk '{print $1}' | grep -Eq '^(aw86937_haptics|aw86937_y700)$'; then
		return 0
	fi
	modprobe aw86937_haptics 2>/dev/null && return 0
	modprobe aw86937_y700 2>/dev/null && return 0

	krel=$(uname -r)
	for module_path in \
		"/lib/modules/$krel/extra/aw86937-haptics.ko" \
		"/lib/modules/$krel/extra/aw86937-y700.ko" \
		"/usr/lib/modules/$krel/extra/aw86937-haptics.ko" \
		"/usr/lib/modules/$krel/extra/aw86937-y700.ko"; do
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
	for driver in aw86937-haptics aw86937-y700; do
		[ -d "/sys/bus/i2c/drivers/$driver" ] || continue
		printf '%s\n' "/sys/bus/i2c/drivers/$driver"
		return 0
	done
	return 1
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
		case "$driver" in
			aw86937-haptics|aw86937-y700) return 0 ;;
		esac
		echo "$dev is already bound to unexpected driver $driver" >&2
		exit 1
	fi

	printf '%s\n' "$busdev" > "$driver_dir/bind" 2>/dev/null || true

	for _ in $(seq 1 20); do
		if [ -e "$dev/driver" ]; then
			driver=$(basename "$(readlink -f "$dev/driver")")
			case "$driver" in
				aw86937-haptics|aw86937-y700) return 0 ;;
			esac
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
	printf 'aw86937_haptics %s\n' "$addr" > "/sys/bus/i2c/devices/i2c-$adapter/new_device" 2>/dev/null || \
		printf 'aw86937_y700 %s\n' "$addr" > "/sys/bus/i2c/devices/i2c-$adapter/new_device"
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
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="aw86937-haptics-left", GROUP="input", MODE="0666", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra", SYMLINK+="input/tb321fu-haptics-left"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="aw86937-haptics-right", GROUP="input", MODE="0666", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra", SYMLINK+="input/tb321fu-haptics-right"
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
  local pkg="$work_dir/pkg/tb321fu-haptics"
  local module="$src/aw86937-haptics.ko"
  local helper_src="$haptics_root/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c"

  ci_log "building aw86937-haptics external module"
  mkdir -p "$src"
  cp -a "$haptics_root/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c" "$src/aw86937-haptics.c"
  patch_source_for_standard_module_name "$src/aw86937-haptics.c"
  cat > "$src/Makefile" <<'EOF_MAKE'
obj-m := aw86937-haptics.o
EOF_MAKE

  make -C "$kernel_source_root" O="$kernel_build_root" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M="$src" modules
  [ -f "$module" ] || ci_die "missing built module: $module"
  modinfo "$module" | tee "$work_dir/aw86937-haptics.modinfo"
  grep -q '^name:[[:space:]]*aw86937_haptics$' "$work_dir/aw86937-haptics.modinfo" || ci_die "unexpected module name"
  grep -q '^alias:[[:space:]]*i2c:aw86937_haptics$' "$work_dir/aw86937-haptics.modinfo" || ci_die "missing standard i2c alias"
  grep -q "^vermagic:[[:space:]]*$kernel_release " "$work_dir/aw86937-haptics.modinfo" || ci_die "module vermagic does not match $kernel_release"

  install -d -m 0755 \
    "$pkg/usr/lib/modules/$kernel_release/extra" \
    "$pkg/usr/lib/firmware" \
    "$pkg/usr/libexec/tb321fu-haptics" \
    "$pkg/usr/lib/systemd/system" \
    "$pkg/usr/lib/udev/rules.d" \
    "$pkg/etc/skel/.config" \
    "$pkg/usr/bin"

  install -m 0644 "$module" "$pkg/usr/lib/modules/$kernel_release/extra/aw86937-haptics.ko"
  install -m 0644 "$haptics_root/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin" "$pkg/usr/lib/firmware/haptic_ram.bin"
  install -m 0644 "$haptics_root/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin" "$pkg/usr/lib/firmware/haptic_click.bin"
  write_bind_script "$pkg/usr/libexec/tb321fu-haptics/bind-aw86937"
  write_systemd_unit "$pkg/usr/lib/systemd/system/tb321fu-haptics.service"
  write_udev_rules "$pkg/usr/lib/udev/rules.d/90-tb321fu-haptics.rules"
  write_plasma_keyboard_default "$pkg/etc/skel/.config/plasmakeyboardrc"

  if [ -f "$helper_src" ]; then
    aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o "$pkg/usr/bin/tb321fu-haptic-test" "$helper_src"
    chmod 0755 "$pkg/usr/bin/tb321fu-haptic-test"
    strip_if_requested "$pkg/usr/bin/tb321fu-haptic-test"
  fi

  strip_if_requested "$pkg/usr/lib/modules/$kernel_release/extra/aw86937-haptics.ko"
  write_control "$pkg"
  write_maintainer_scripts "$pkg"

  find "$pkg" -type d -exec chmod 0755 {} +
  deb="$OUTPUT_DIR/tb321fu-haptics_${HAPTICS_DEB_VERSION}_${ARCH}.deb"
  dpkg-deb --build --root-owner-group "$pkg" "$deb" >/dev/null
  sha256sum "$deb"
}

prepare_inputs
build_haptics_package

ci_log "writing haptics package checksums"
(cd "$OUTPUT_DIR" && sha256sum ./*.deb > SHA256SUMS-tb321fu-haptics-debs.txt)
ci_log "haptics package build complete: $OUTPUT_DIR"
