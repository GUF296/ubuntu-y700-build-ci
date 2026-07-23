#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-payload-policy-test.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

make_control() {
  local root=$1 package=$2 relation=${3:-}
  install -d -m 0755 "$root/DEBIAN"
  cat > "$root/DEBIAN/control" <<CONTROL
Package: $package
Version: 1
Architecture: arm64
Maintainer: CI <ci@example.invalid>
CONTROL
  if [ -n "$relation" ]; then
    printf '%s\n' "$relation" >> "$root/DEBIAN/control"
  fi
  cat >> "$root/DEBIAN/control" <<CONTROL
Description: payload policy fixture
CONTROL
}

daily_root="$tmp/daily-root"
haptics_root="$tmp/haptics-root"
payload="$tmp/payload"
install -d -m 0755 "$payload"
make_control "$daily_root" y700-daily-rootfs-overlay
install -d -m 0777 \
  "$daily_root/etc/dbus-1/system.d" \
  "$daily_root/etc/systemd/system" \
  "$daily_root/etc/wireplumber/wireplumber.conf.d" \
  "$daily_root/usr/lib/firmware" \
  "$daily_root/usr/lib/aarch64-linux-gnu" \
  "$daily_root/usr/bin" \
  "$daily_root/usr/local/bin" \
  "$daily_root/usr/share/wireplumber/scripts/y700" \
  "$daily_root/etc/systemd/system/multi-user.target.wants" \
  "$daily_root/etc/udev/rules.d" \
  "$daily_root/usr/local/lib/y700-sns" \
  "$daily_root/usr/local/libexec" \
  "$daily_root/usr/local/sbin" \
  "$daily_root/usr/local/share/y700-sns" \
  "$daily_root/opt/libcamera-y700/bin" \
  "$daily_root/opt/libcamera-y700/libexec/libcamera" \
  "$daily_root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa" \
  "$daily_root/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0" \
  "$daily_root/usr/lib/aarch64-linux-gnu/gstreamer-1.0" \
  "$daily_root/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera" \
  "$daily_root/etc/ld.so.conf.d" \
  "$daily_root/etc/systemd/user/pipewire.service.d" \
  "$daily_root/etc/systemd/user/wireplumber.service.d"
printf 'ram-firmware\n' > "$daily_root/usr/lib/firmware/haptic_ram.bin"
printf 'click-firmware\n' > "$daily_root/usr/lib/firmware/haptic_click.bin"
install -m 0644 "$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.conf" \
  "$daily_root/etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf"
install -m 0644 "$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.lua" \
  "$daily_root/usr/share/wireplumber/scripts/y700/headset-cleanup.lua"
printf 'unit\n' > "$daily_root/etc/systemd/system/fixture.service"
printf 'library\n' > "$daily_root/usr/lib/aarch64-linux-gnu/libfixture.so"
printf '#!/bin/sh\nexit 0\n' > "$daily_root/usr/bin/fixture-helper"
printf 'legacy sensor service\n' > "$daily_root/etc/systemd/system/y700-sns-init.service"
printf 'legacy haptics service\n' > \
  "$daily_root/etc/systemd/system/y700-aw86937-haptics.service"
ln -s ../y700-sns-init.service \
  "$daily_root/etc/systemd/system/multi-user.target.wants/y700-sns-init.service"
ln -s ../y700-aw86937-haptics.service \
  "$daily_root/etc/systemd/system/multi-user.target.wants/y700-aw86937-haptics.service"
printf 'legacy sensor rule\n' > \
  "$daily_root/etc/udev/rules.d/80-y700-iio-sensor-proxy.rules"
printf 'legacy sensor D-Bus policy\n' > \
  "$daily_root/etc/dbus-1/system.d/net.hadess.SensorProxy-y700-ssc.conf"
printf 'legacy haptics rule\n' > "$daily_root/etc/udev/rules.d/90-y700-haptics.rules"
printf '#!/bin/sh\nexit 0\n' > "$daily_root/usr/local/bin/y700-monitor-sensor"
printf '#!/bin/sh\nexit 0\n' > "$daily_root/usr/local/sbin/y700-sns-init.sh"
printf '#!/bin/sh\nexit 0\n' > "$daily_root/usr/local/libexec/y700-iio-sensor-proxy"
printf '#!/bin/sh\nexit 0\n' > "$daily_root/usr/local/sbin/y700-aw86937-bind"
printf 'legacy lib\n' > "$daily_root/usr/local/lib/y700-sns/libssc.so.2"
printf 'legacy data\n' > "$daily_root/usr/local/share/y700-sns/registry"
for executable in \
  "$daily_root/opt/libcamera-y700/bin/cam" \
  "$daily_root/opt/libcamera-y700/bin/libcamera-bug-report" \
  "$daily_root/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
  "$daily_root/usr/local/bin/y700-camera-env" \
  "$daily_root/usr/local/bin/y700-camera-cam" \
  "$daily_root/usr/local/bin/y700-camera-preview"; do
  printf '#!/bin/sh\nexit 0\n' > "$executable"
done
printf 'libcamera\n' > "$daily_root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1"
printf 'libcamera-base\n' > "$daily_root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1"
printf 'soft-ipa\n' > "$daily_root/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so"
printf 'gst-libcamera\n' > "$daily_root/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
ln -s /opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so \
  "$daily_root/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
printf 'spa-libcamera\n' > "$daily_root/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
printf '/opt/libcamera-y700/lib/aarch64-linux-gnu\n' > "$daily_root/etc/ld.so.conf.d/y700-libcamera.conf"
printf 'KERNEL=="dma_heap"\n' > "$daily_root/etc/udev/rules.d/70-y700-camera-dma-heap.rules"
printf '[Service]\n' > "$daily_root/etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf"
printf '[Service]\n' > "$daily_root/etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf"
printf '[Service]\n' > "$daily_root/etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf"
chmod 0777 \
  "$daily_root/usr/lib/firmware/haptic_ram.bin" \
  "$daily_root/usr/lib/firmware/haptic_click.bin" \
  "$daily_root/etc/systemd/system/fixture.service" \
  "$daily_root/usr/lib/aarch64-linux-gnu/libfixture.so"
chmod 0644 "$daily_root/usr/bin/fixture-helper"
chmod 0644 \
  "$daily_root/opt/libcamera-y700/bin/cam" \
  "$daily_root/opt/libcamera-y700/bin/libcamera-bug-report" \
  "$daily_root/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
  "$daily_root/usr/local/bin/y700-camera-env" \
  "$daily_root/usr/local/bin/y700-camera-cam" \
  "$daily_root/usr/local/bin/y700-camera-preview"
dpkg-deb --build --root-owner-group "$daily_root" "$payload/daily.deb" >/dev/null
cp "$payload/daily.deb" "$tmp/legacy-daily.deb"

make_control "$haptics_root" tb321fu-haptics-common
install -d -m 0755 \
  "$haptics_root/usr/lib/firmware" \
  "$haptics_root/usr/libexec/tb321fu-haptics"
cp "$daily_root/usr/lib/firmware/haptic_ram.bin" "$haptics_root/usr/lib/firmware/haptic_ram.bin"
cp "$daily_root/usr/lib/firmware/haptic_click.bin" "$haptics_root/usr/lib/firmware/haptic_click.bin"
printf '#!/bin/sh\nexit 0\n' > "$haptics_root/usr/libexec/tb321fu-haptics/bind-aw86937"
chmod 0644 "$haptics_root/usr/lib/firmware/"*.bin
chmod 0755 "$haptics_root/usr/libexec/tb321fu-haptics/bind-aw86937"
dpkg-deb --build --root-owner-group "$haptics_root" "$payload/haptics.deb" >/dev/null

camera_root="$tmp/camera-root"
make_control "$camera_root" tb321fu-camera-stack \
  "Pre-Depends: tb321fu-camera-payload-migrated (>= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)"$'\nReplaces: y700-daily-rootfs-overlay, libspa-0.2-libcamera, gstreamer1.0-libcamera\nConflicts: libspa-0.2-libcamera, gstreamer1.0-libcamera'
for relative in \
  opt/libcamera-y700/bin/cam \
  opt/libcamera-y700/bin/libcamera-bug-report \
  opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy \
  opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1 \
  opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera-base.so.0.7.1 \
  opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so \
  opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so \
  usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so \
  usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so \
  etc/ld.so.conf.d/y700-libcamera.conf \
  etc/udev/rules.d/70-y700-camera-dma-heap.rules \
  etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf \
  etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf \
  etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf \
  usr/local/bin/y700-camera-env \
  usr/local/bin/y700-camera-cam \
  usr/local/bin/y700-camera-preview; do
  install -d -m 0755 "$(dirname "$camera_root/$relative")"
  cp -a "$daily_root/$relative" "$camera_root/$relative"
done
ci_write_tb321fu_camera_preinst "$camera_root"
ci_normalize_system_payload_modes "$camera_root"
ci_assert_normalized_system_payload_modes "$camera_root"
dpkg-deb --build --root-owner-group "$camera_root" "$payload/camera.deb" >/dev/null

ci_assert_unique_deb_packages "$payload"
duplicate_package_dir="$tmp/duplicate-package"
install -d -m 0755 "$duplicate_package_dir"
cp "$payload/daily.deb" "$duplicate_package_dir/daily-a.deb"
cp "$payload/daily.deb" "$duplicate_package_dir/daily-b.deb"
if (ci_assert_unique_deb_packages "$duplicate_package_dir" >/dev/null 2>&1); then
  echo 'duplicate DEB Package identity was accepted' >&2
  exit 1
fi

symlink_package_dir="$tmp/symlink-package"
install -d -m 0755 "$symlink_package_dir"
cp "$payload/daily.deb" "$symlink_package_dir/payload.bin"
ln -s payload.bin "$symlink_package_dir/disguised.deb"
if (ci_assert_unique_deb_packages "$symlink_package_dir" >/dev/null 2>&1); then
  echo 'symlinked DEB path was accepted' >&2
  exit 1
fi

# A symlink whose target happens to be a directory must still be treated as a
# symlink. Otherwise another package can claim a child path below it and the
# ownership check misses a late dpkg filesystem collision.
symlink_parent_payload="$tmp/symlink-parent-payload"
symlink_parent_owner="$tmp/symlink-parent-owner"
symlink_parent_child="$tmp/symlink-parent-child"
install -d -m 0755 "$symlink_parent_payload"
make_control "$symlink_parent_owner" fixture-symlink-parent-owner
install -d -m 0755 "$symlink_parent_owner/usr/lib/fixture-symlink-target"
ln -s fixture-symlink-target "$symlink_parent_owner/usr/lib/fixture-symlink-parent"
dpkg-deb --build --root-owner-group "$symlink_parent_owner" \
  "$symlink_parent_payload/owner.deb" >/dev/null
make_control "$symlink_parent_child" fixture-symlink-parent-child
install -D -m 0644 /dev/null \
  "$symlink_parent_child/usr/lib/fixture-symlink-parent/child"
dpkg-deb --build --root-owner-group "$symlink_parent_child" \
  "$symlink_parent_payload/child.deb" >/dev/null
if (ci_assert_unique_deb_payload_paths "$symlink_parent_payload" \
    "$tmp/symlink-parent-ownership" >/dev/null 2>&1); then
  echo 'symlink parent and child payload collision was accepted' >&2
  exit 1
fi

# The ownership pass indexes extracted member paths, so it must reject an
# archive member name that cannot be represented safely in its line/path
# protocol before using that name as a key or parent path.
unsafe_member_payload="$tmp/unsafe-member-payload"
unsafe_member_root="$tmp/unsafe-member-root"
install -d -m 0755 "$unsafe_member_payload"
make_control "$unsafe_member_root" fixture-unsafe-member
install -d -m 0755 "$unsafe_member_root/usr/share"
printf 'unsafe member\n' > "$unsafe_member_root/usr/share/fixture"$'\t'"member"
dpkg-deb --build --root-owner-group "$unsafe_member_root" \
  "$unsafe_member_payload/unsafe-member.deb" >/dev/null
if (ci_assert_unique_deb_payload_paths "$unsafe_member_payload" \
    "$tmp/unsafe-member-ownership" >/dev/null 2>&1); then
  echo 'unsafe local DEB member path was accepted' >&2
  exit 1
fi

collision_source_a="$tmp/collision-a"
collision_source_b="$tmp/collision-b"
collision_destination="$tmp/collision-destination"
install -d -m 0755 "$collision_source_a" "$collision_source_b"
cp "$payload/daily.deb" "$collision_source_a/same.deb"
cp "$payload/haptics.deb" "$collision_source_b/same.deb"
ci_copy_deb_unique "$collision_source_a/same.deb" \
  "$collision_destination" 'collision fixture A'
if (ci_copy_deb_unique "$collision_source_b/same.deb" \
    "$collision_destination" 'collision fixture B' >/dev/null 2>&1); then
  echo 'DEB basename collision was accepted' >&2
  exit 1
fi

audio_drift_payload="$tmp/audio-drift-payload"
audio_drift_root="$tmp/audio-drift-root"
install -d -m 0755 "$audio_drift_payload"
cp "$payload/daily.deb" "$audio_drift_payload/daily.deb"
cp "$payload/haptics.deb" "$audio_drift_payload/haptics.deb"
dpkg-deb -R "$audio_drift_payload/daily.deb" "$audio_drift_root"
printf '\n# unexpected mutation\n' >> \
  "$audio_drift_root/usr/share/wireplumber/scripts/y700/headset-cleanup.lua"
dpkg-deb --build --root-owner-group "$audio_drift_root" \
  "$audio_drift_payload/daily.rebuilt.deb" >/dev/null
mv -f "$audio_drift_payload/daily.rebuilt.deb" "$audio_drift_payload/daily.deb"
if (ci_prepare_y700_daily_payload_deb \
    "$audio_drift_payload" "$tmp/audio-drift-rewrite" >/dev/null 2>&1); then
  echo 'unrecognized tested WirePlumber cleanup content was accepted' >&2
  exit 1
fi

mismatch_payload="$tmp/mismatch-payload"
install -d -m 0755 "$mismatch_payload"
cp "$payload/daily.deb" "$mismatch_payload/daily.deb"
printf 'different-ram-firmware\n' > "$haptics_root/usr/lib/firmware/haptic_ram.bin"
dpkg-deb --build --root-owner-group "$haptics_root" "$mismatch_payload/haptics.deb" >/dev/null
if (ci_prepare_y700_daily_payload_deb \
    "$mismatch_payload" "$tmp/mismatch-rewrite" >/dev/null 2>&1); then
  echo 'mismatched canonical haptics firmware was accepted' >&2
  exit 1
fi

duplicate_payload="$tmp/duplicate-payload"
duplicate_root="$tmp/duplicate-root"
install -d -m 0755 "$duplicate_payload"
cp "$payload/daily.deb" "$duplicate_payload/daily.deb"
cp "$payload/haptics.deb" "$duplicate_payload/haptics.deb"
make_control "$duplicate_root" unexpected-haptics-owner
install -D -m 0644 "$daily_root/usr/lib/firmware/haptic_ram.bin" \
  "$duplicate_root/usr/lib/firmware/haptic_ram.bin"
dpkg-deb --build --root-owner-group "$duplicate_root" "$duplicate_payload/unexpected.deb" >/dev/null
if (ci_prepare_y700_daily_payload_deb \
    "$duplicate_payload" "$tmp/duplicate-rewrite" >/dev/null 2>&1); then
  echo 'third package owner for haptics firmware was accepted' >&2
  exit 1
fi

install -d -m 0755 "$tmp/before" "$tmp/after"
dpkg-deb -x "$payload/daily.deb" "$tmp/before"
dpkg-deb -x "$payload/haptics.deb" "$tmp/before"
dpkg-deb -x "$payload/camera.deb" "$tmp/before"
(cd "$tmp/before" && find . -type f \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf' \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-tb321fu-headset-route-reconcile.conf' \
  ! -path './usr/share/wireplumber/scripts/y700/headset-cleanup.lua' \
  ! -path './usr/share/wireplumber/scripts/tb321fu/headset-route-reconcile.lua' \
  ! -path './etc/systemd/system/y700-sns-init.service' \
  ! -path './etc/systemd/system/y700-aw86937-haptics.service' \
  ! -path './etc/udev/rules.d/80-y700-iio-sensor-proxy.rules' \
  ! -path './etc/udev/rules.d/90-y700-haptics.rules' \
  ! -path './etc/dbus-1/system.d/net.hadess.SensorProxy-y700-ssc.conf' \
  ! -path './usr/local/bin/y700-monitor-sensor' \
  ! -path './usr/local/sbin/y700-sns-init.sh' \
  ! -path './usr/local/libexec/y700-iio-sensor-proxy' \
  ! -path './usr/local/sbin/y700-aw86937-bind' \
  ! -path './usr/local/lib/y700-sns/*' \
  ! -path './usr/local/share/y700-sns/*' \
  -print0 | sort -z | xargs -0 sha256sum) > "$tmp/before.sha256"

export SOURCE_DATE_EPOCH=0
ci_prepare_y700_daily_payload_deb "$payload" "$tmp/rewrite"
ci_assert_unique_deb_packages "$payload"

[ "$(ci_deb_member_owners "$payload" usr/lib/firmware/haptic_ram.bin | wc -l)" -eq 1 ]
[ "$(ci_deb_member_owners "$payload" usr/lib/firmware/haptic_click.bin | wc -l)" -eq 1 ]
ci_deb_member_owners "$payload" usr/lib/firmware/haptic_ram.bin | \
  cut -f1 | grep -Fx tb321fu-haptics-common >/dev/null
dpkg-deb -f "$payload/daily.deb" Provides | \
  grep -Fx "tb321fu-camera-payload-migrated (= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)" >/dev/null
dpkg-deb -f "$payload/camera.deb" Pre-Depends | \
  grep -Fx "tb321fu-camera-payload-migrated (>= $TB321FU_CAMERA_PAYLOAD_MIGRATION_ABI)" >/dev/null
for relative in \
  opt/libcamera-y700/bin/cam \
  opt/libcamera-y700/bin/libcamera-bug-report \
  opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy \
  usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so; do
  [ "$(ci_deb_member_owners "$payload" "$relative" | wc -l)" -eq 1 ]
  ci_deb_member_owners "$payload" "$relative" | cut -f1 | \
    grep -Fx tb321fu-camera-stack >/dev/null
done

camera_control="$tmp/camera-control"
camera_preinst="$camera_control/preinst"
dpkg-deb -e "$payload/camera.deb" "$camera_control"
[ -x "$camera_preinst" ] || { echo 'camera preinst is missing or not executable' >&2; exit 1; }
camera_query_bin="$tmp/camera-query-bin"
install -d -m 0755 "$camera_query_bin"
printf '%s\n' \
  '#!/bin/sh' \
  'case "$1" in' \
  '  -W) printf '\''installed\n'\'' ;;' \
  '  -L)' \
  '    if [ "${CAMERA_LEGACY_OWNS:-0}" = 1 ]; then' \
  '      printf '\''/opt/libcamera-y700/bin/cam\n'\''' \
  '    else' \
  '      printf '\''/usr/share/doc/y700-daily-rootfs-overlay\n'\''' \
  '    fi' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$camera_query_bin/dpkg-query"
chmod 0755 "$camera_query_bin/dpkg-query"
set +e
legacy_preinst_output=$(PATH="$camera_query_bin:$PATH" CAMERA_LEGACY_OWNS=1 \
  "$camera_preinst" install 2>&1)
legacy_preinst_status=$?
set -e
[ "$legacy_preinst_status" -ne 0 ] || \
  { echo 'camera preinst accepted an unmigrated daily package' >&2; exit 1; }
grep -Fq 'install the camera-less daily package first' <<<"$legacy_preinst_output" || \
  { echo 'camera preinst rejected legacy ownership with the wrong diagnostic' >&2; exit 1; }
PATH="$camera_query_bin:$PATH" CAMERA_LEGACY_OWNS=0 "$camera_preinst" install

make_dpkg_root() {
  local root=$1

  install -d -m 0755 "$root/var/lib/dpkg/info" "$root/var/lib/dpkg/updates" "$root/var/log"
  : > "$root/var/lib/dpkg/status"
}

dpkg_root() {
  local root=$1
  shift
  DPKG_ADMINDIR="$root/var/lib/dpkg" \
    dpkg --root "$root" --force-not-root --force-bad-path --force-architecture \
      --force-script-chrootless --log "$root/var/log/dpkg.log" "$@"
}

dpkg_owner_is() {
  local root=$1 path=$2 package=$3 owner

  owner=$(dpkg-query --admindir "$root/var/lib/dpkg" -S "$path" 2>/dev/null || true)
  case "$owner" in
    "$package"*) return 0 ;;
    *) return 1 ;;
  esac
}

camera_remove_bin="$tmp/camera-remove-bin"
install -d -m 0755 "$camera_remove_bin"
for command in ldconfig systemctl udevadm; do
  printf '#!/bin/sh\nexit 0\n' > "$camera_remove_bin/$command"
  chmod 0755 "$camera_remove_bin/$command"
done

migrated_daily_root="$tmp/migrated-daily-root"
migrated_daily_deb="$tmp/y700-daily-rootfs-overlay_2_arm64.deb"
dpkg-deb -R "$payload/daily.deb" "$migrated_daily_root"
sed -i 's/^Version: .*/Version: 2/' "$migrated_daily_root/DEBIAN/control"
dpkg-deb --build --root-owner-group "$migrated_daily_root" "$migrated_daily_deb" >/dev/null

# A fresh transaction must configure the camera-less daily package first. The
# versioned virtual Pre-Depends prevents an accidental unpack over the old overlay.
fresh_dpkg_root="$tmp/fresh-dpkg-root"
make_dpkg_root "$fresh_dpkg_root"
set +e
fresh_camera_output=$(dpkg_root "$fresh_dpkg_root" --unpack "$payload/camera.deb" 2>&1)
fresh_camera_status=$?
set -e
[ "$fresh_camera_status" -ne 0 ] || {
  echo 'camera package unpacked without tb321fu-camera-payload-migrated' >&2
  exit 1
}
grep -Eiq 'pre-depend|predepend' <<<"$fresh_camera_output" || {
  echo 'camera package failed before the Pre-Depends check' >&2
  exit 1
}

# An unversioned legacy provider must not accidentally satisfy this boundary
# after a future daily-package update adds more camera payload.
old_provider_root="$tmp/old-provider-root"
old_provider_deb="$tmp/y700-daily-rootfs-overlay-old-provider_arm64.deb"
make_control "$old_provider_root" y700-daily-rootfs-overlay \
  'Provides: tb321fu-camera-payload-migrated'
install -d -m 0755 "$old_provider_root/usr/bin"
printf '#!/bin/sh\nexit 0\n' > "$old_provider_root/usr/bin/old-provider-helper"
chmod 0755 "$old_provider_root/usr/bin/old-provider-helper"
dpkg-deb --build --root-owner-group "$old_provider_root" "$old_provider_deb" >/dev/null
old_provider_dpkg_root="$tmp/old-provider-dpkg-root"
make_dpkg_root "$old_provider_dpkg_root"
dpkg_root "$old_provider_dpkg_root" --unpack "$old_provider_deb" >/dev/null
dpkg_root "$old_provider_dpkg_root" --configure y700-daily-rootfs-overlay >/dev/null
set +e
old_provider_camera_output=$(dpkg_root "$old_provider_dpkg_root" --unpack "$payload/camera.deb" 2>&1)
old_provider_camera_status=$?
set -e
[ "$old_provider_camera_status" -ne 0 ] || {
  echo 'camera package accepted an unversioned legacy migration provider' >&2
  exit 1
}
grep -Eiq 'pre-depend|predepend' <<<"$old_provider_camera_output" || {
  echo 'old-provider camera install failed before the versioned Pre-Depends check' >&2
  exit 1
}
dpkg_root "$old_provider_dpkg_root" --remove y700-daily-rootfs-overlay >/dev/null

dpkg_root "$fresh_dpkg_root" --unpack "$migrated_daily_deb" >/dev/null
dpkg_root "$fresh_dpkg_root" --configure y700-daily-rootfs-overlay >/dev/null
dpkg_root "$fresh_dpkg_root" --unpack "$payload/camera.deb" >/dev/null
dpkg_root "$fresh_dpkg_root" --configure tb321fu-camera-stack >/dev/null
dpkg_owner_is "$fresh_dpkg_root" /opt/libcamera-y700/bin/cam tb321fu-camera-stack || {
  echo 'camera stack did not become the dpkg owner after a fresh migration transaction' >&2
  exit 1
}
if dpkg_root "$fresh_dpkg_root" --remove y700-daily-rootfs-overlay >/dev/null 2>&1; then
  echo 'daily migration provider was removable while camera Pre-Depends remained installed' >&2
  exit 1
fi
PATH="$camera_remove_bin:$PATH" dpkg_root "$fresh_dpkg_root" --remove tb321fu-camera-stack >/dev/null
[ ! -e "$fresh_dpkg_root/opt/libcamera-y700/bin/cam" ] || {
  echo 'camera payload survived removal of tb321fu-camera-stack' >&2
  exit 1
}
[ -x "$fresh_dpkg_root/usr/bin/fixture-helper" ] || {
  echo 'removing tb321fu-camera-stack removed unrelated daily payload' >&2
  exit 1
}
dpkg_root "$fresh_dpkg_root" --remove y700-daily-rootfs-overlay >/dev/null

# An existing legacy install must fail before file ownership changes. Upgrading
# the daily package to the camera-less provider then makes the camera install
# legal and leaves every camera file owned by the dedicated package.
legacy_dpkg_root="$tmp/legacy-dpkg-root"
make_dpkg_root "$legacy_dpkg_root"
dpkg_root "$legacy_dpkg_root" --unpack "$tmp/legacy-daily.deb" >/dev/null
dpkg_root "$legacy_dpkg_root" --configure y700-daily-rootfs-overlay >/dev/null
dpkg_owner_is "$legacy_dpkg_root" /opt/libcamera-y700/bin/cam y700-daily-rootfs-overlay || {
  echo 'legacy daily fixture did not own its camera payload' >&2
  exit 1
}
set +e
legacy_camera_output=$(dpkg_root "$legacy_dpkg_root" --unpack "$payload/camera.deb" 2>&1)
legacy_camera_status=$?
set -e
[ "$legacy_camera_status" -ne 0 ] || {
  echo 'camera package unpacked over an unmigrated legacy daily payload' >&2
  exit 1
}
grep -Eiq 'pre-depend|predepend' <<<"$legacy_camera_output" || {
  echo 'legacy camera install failed before the Pre-Depends check' >&2
  exit 1
}
dpkg_owner_is "$legacy_dpkg_root" /opt/libcamera-y700/bin/cam y700-daily-rootfs-overlay || {
  echo 'failed legacy camera install changed existing file ownership' >&2
  exit 1
}
dpkg_root "$legacy_dpkg_root" --unpack "$migrated_daily_deb" >/dev/null
dpkg_root "$legacy_dpkg_root" --configure y700-daily-rootfs-overlay >/dev/null
[ ! -e "$legacy_dpkg_root/opt/libcamera-y700/bin/cam" ] || {
  echo 'daily migration package retained a camera payload file' >&2
  exit 1
}
dpkg_root "$legacy_dpkg_root" --unpack "$payload/camera.deb" >/dev/null
dpkg_root "$legacy_dpkg_root" --configure tb321fu-camera-stack >/dev/null
dpkg_owner_is "$legacy_dpkg_root" /opt/libcamera-y700/bin/cam tb321fu-camera-stack || {
  echo 'camera stack did not take unique ownership after legacy migration' >&2
  exit 1
}
PATH="$camera_remove_bin:$PATH" dpkg_root "$legacy_dpkg_root" --remove tb321fu-camera-stack >/dev/null
dpkg_root "$legacy_dpkg_root" --remove y700-daily-rootfs-overlay >/dev/null

dpkg-deb -x "$payload/daily.deb" "$tmp/after"
dpkg-deb -x "$payload/haptics.deb" "$tmp/after"
dpkg-deb -x "$payload/camera.deb" "$tmp/after"

# The final rootfs overlay runs after package installation. Snapshot all local
# device payload members and prove that a later regular-file or symlink
# replacement is rejected before image assembly can continue.
protected_root="$tmp/protected-root"
protected_snapshot="$tmp/protected-local-debs.tsv"
cp -a "$tmp/after" "$protected_root"
ci_snapshot_local_deb_payload \
  "$protected_root" "$payload" "$tmp/protected-snapshot-stage" \
  "$protected_snapshot"
ci_verify_local_deb_payload_snapshot "$protected_root" "$protected_snapshot"
printf 'overlay replacement\n' > "$protected_root/usr/lib/firmware/haptic_ram.bin"
if (ci_verify_local_deb_payload_snapshot "$protected_root" "$protected_snapshot") \
  >/dev/null 2>&1; then
  echo 'local DEB payload snapshot accepted an overlay regular-file replacement' >&2
  exit 1
fi
restore_root="$tmp/protected-restore"
dpkg-deb -x "$payload/haptics.deb" "$restore_root"
cp "$restore_root/usr/lib/firmware/haptic_ram.bin" \
  "$protected_root/usr/lib/firmware/haptic_ram.bin"
camera_link="$protected_root/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
camera_link_target=$(readlink -- "$camera_link")
rm -f -- "$camera_link"
ln -s /unsafe-overlay-replacement "$camera_link"
if (ci_verify_local_deb_payload_snapshot "$protected_root" "$protected_snapshot") \
  >/dev/null 2>&1; then
  echo 'local DEB payload snapshot accepted an overlay symlink replacement' >&2
  exit 1
fi
rm -f -- "$camera_link"
ln -s "$camera_link_target" "$camera_link"
ci_verify_local_deb_payload_snapshot "$protected_root" "$protected_snapshot"

keyboard_root="$tmp/keyboard-root"
keyboard_uid=$(id -u)
keyboard_gid=$(id -g)
install -d -m 0755 \
  "$keyboard_root/etc/skel/.config" \
  "$keyboard_root/home/fixture/.config" \
  "$keyboard_root/var/lib/dpkg/info"
printf 'fixture:x:%s:%s::/home/fixture:/bin/sh\n' "$keyboard_uid" "$keyboard_gid" \
  > "$keyboard_root/etc/passwd"
: > "$keyboard_root/var/lib/dpkg/status"
printf '[Keyboard]\nEnableHapticFeedback=true\n' \
  > "$keyboard_root/etc/skel/.config/plasmakeyboardrc"
printf '[Keyboard]\nEnableHapticFeedback=false\n' \
  > "$keyboard_root/home/fixture/.config/plasmakeyboardrc"
ci_seed_default_user_keyboard_config "$keyboard_root" fixture
cmp "$keyboard_root/home/fixture/.config/plasmakeyboardrc" \
  <(printf '[Keyboard]\nEnableHapticFeedback=false\n')
rm -f -- "$keyboard_root/home/fixture/.config/plasmakeyboardrc"
ci_seed_default_user_keyboard_config "$keyboard_root" fixture
cmp "$keyboard_root/etc/skel/.config/plasmakeyboardrc" \
  "$keyboard_root/home/fixture/.config/plasmakeyboardrc"
rm -f -- "$keyboard_root/home/fixture/.config/plasmakeyboardrc"
ln -s ../../outside "$keyboard_root/home/fixture/.config/plasmakeyboardrc"
if (ci_seed_default_user_keyboard_config "$keyboard_root" fixture) \
  >/dev/null 2>&1; then
  echo 'keyboard seeding accepted a user configuration symlink' >&2
  exit 1
fi
rm -f -- "$keyboard_root/home/fixture/.config/plasmakeyboardrc"
mv "$keyboard_root/etc/skel/.config/plasmakeyboardrc" \
  "$keyboard_root/etc/skel/.config/plasmakeyboardrc.real"
ln -s plasmakeyboardrc.real "$keyboard_root/etc/skel/.config/plasmakeyboardrc"
if (ci_seed_default_user_keyboard_config "$keyboard_root" fixture) \
  >/dev/null 2>&1; then
  echo 'keyboard seeding accepted a symlinked /etc/skel configuration' >&2
  exit 1
fi
rm -f -- "$keyboard_root/etc/skel/.config/plasmakeyboardrc"
mv "$keyboard_root/etc/skel/.config/plasmakeyboardrc.real" \
  "$keyboard_root/etc/skel/.config/plasmakeyboardrc"
cat > "$keyboard_root/var/lib/dpkg/status" <<'STATUS'
Package: tb321fu-haptics
Status: install ok installed
Architecture: arm64
Version: 1
Description: fixture haptics package
STATUS
printf '/etc/skel/.config/plasmakeyboardrc\n' \
  > "$keyboard_root/var/lib/dpkg/info/tb321fu-haptics.list"
ci_seed_default_user_keyboard_config "$keyboard_root" fixture
cmp "$keyboard_root/etc/skel/.config/plasmakeyboardrc" \
  "$keyboard_root/home/fixture/.config/plasmakeyboardrc"

(cd "$tmp/after" && find . -type f \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf' \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-tb321fu-headset-route-reconcile.conf' \
  ! -path './usr/share/wireplumber/scripts/y700/headset-cleanup.lua' \
  ! -path './usr/share/wireplumber/scripts/tb321fu/headset-route-reconcile.lua' \
  ! -path './etc/systemd/system/y700-sns-init.service' \
  ! -path './etc/systemd/system/y700-aw86937-haptics.service' \
  ! -path './etc/udev/rules.d/80-y700-iio-sensor-proxy.rules' \
  ! -path './etc/udev/rules.d/90-y700-haptics.rules' \
  ! -path './etc/dbus-1/system.d/net.hadess.SensorProxy-y700-ssc.conf' \
  ! -path './usr/local/bin/y700-monitor-sensor' \
  ! -path './usr/local/sbin/y700-sns-init.sh' \
  ! -path './usr/local/libexec/y700-iio-sensor-proxy' \
  ! -path './usr/local/sbin/y700-aw86937-bind' \
  ! -path './usr/local/lib/y700-sns/*' \
  ! -path './usr/local/share/y700-sns/*' \
  -print0 | sort -z | xargs -0 sha256sum) > "$tmp/after.sha256"
cmp "$tmp/before.sha256" "$tmp/after.sha256"
[ ! -e "$tmp/after/etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf" ]
[ ! -e "$tmp/after/usr/share/wireplumber/scripts/y700/headset-cleanup.lua" ]
for forbidden in \
  etc/systemd/system/y700-sns-init.service \
  etc/systemd/system/y700-aw86937-haptics.service \
  etc/systemd/system/multi-user.target.wants/y700-sns-init.service \
  etc/systemd/system/multi-user.target.wants/y700-aw86937-haptics.service \
  etc/udev/rules.d/80-y700-iio-sensor-proxy.rules \
  etc/udev/rules.d/90-y700-haptics.rules \
  etc/dbus-1/system.d/net.hadess.SensorProxy-y700-ssc.conf \
  usr/local/bin/y700-monitor-sensor \
  usr/local/sbin/y700-sns-init.sh \
  usr/local/libexec/y700-iio-sensor-proxy \
  usr/local/sbin/y700-aw86937-bind \
  usr/local/lib/y700-sns \
  usr/local/share/y700-sns; do
  [ ! -e "$tmp/after/$forbidden" ] && [ ! -L "$tmp/after/$forbidden" ]
done
if dpkg-deb --fsys-tarfile "$payload/daily.deb" | tar -tf - | \
    grep -E '(y700-sns-init|y700-aw86937|y700-iio-sensor-proxy|y700-monitor-sensor|SensorProxy-y700-ssc|80-y700-iio|90-y700-haptics|usr/local/(lib|share)/y700-sns)' >/dev/null; then
  echo 'rewritten daily DEB still owns legacy sensor/haptics payload' >&2
  exit 1
fi
cmp "$SCRIPT_DIR/payloads/52-tb321fu-headset-route-reconcile.conf" \
  "$tmp/after/etc/wireplumber/wireplumber.conf.d/52-tb321fu-headset-route-reconcile.conf"
cmp "$SCRIPT_DIR/payloads/tb321fu-headset-route-reconcile.lua" \
  "$tmp/after/usr/share/wireplumber/scripts/tb321fu/headset-route-reconcile.lua"
[ "$(stat -c '%a' "$tmp/after/etc/systemd/system/fixture.service")" = 644 ]
[ "$(stat -c '%a' "$tmp/after/usr/lib/aarch64-linux-gnu/libfixture.so")" = 644 ]
[ "$(stat -c '%a' "$tmp/after/usr/bin/fixture-helper")" = 755 ]
ci_assert_privileged_payload_security "$tmp/after" \
  usr/bin/fixture-helper \
  usr/libexec/tb321fu-haptics/bind-aw86937 \
  opt/libcamera-y700/bin/cam \
  opt/libcamera-y700/bin/libcamera-bug-report \
  opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy \
  usr/local/bin/y700-camera-env \
  usr/local/bin/y700-camera-cam \
  usr/local/bin/y700-camera-preview
for executable in \
  "$tmp/after/opt/libcamera-y700/bin/cam" \
  "$tmp/after/opt/libcamera-y700/bin/libcamera-bug-report" \
  "$tmp/after/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
  "$tmp/after/usr/local/bin/y700-camera-env" \
  "$tmp/after/usr/local/bin/y700-camera-cam" \
  "$tmp/after/usr/local/bin/y700-camera-preview"; do
  [ "$(stat -c '%a' "$executable")" = 755 ]
done

chmod 0777 "$tmp/after/etc/systemd/system/fixture.service"
if (ci_assert_privileged_payload_security "$tmp/after" >/dev/null 2>&1); then
  echo '0777 privileged payload was accepted' >&2
  exit 1
fi
chmod 0644 "$tmp/after/etc/systemd/system/fixture.service"
if (ci_assert_privileged_payload_security "$tmp/after" etc/systemd/system/fixture.service >/dev/null 2>&1); then
  echo 'non-executable required payload was accepted' >&2
  exit 1
fi

install -d -m 0755 "$tmp/outside"
printf 'outside\n' > "$tmp/outside/world-writable"
chmod 0777 "$tmp/outside/world-writable"
ln -s "$tmp/outside" "$tmp/after/lib"
ci_assert_privileged_payload_security "$tmp/after" usr/bin/fixture-helper
[ "$(stat -c '%a' "$tmp/outside/world-writable")" = 777 ]

python3 - "$SCRIPT_DIR/build-rootfs-image.sh" "$SCRIPT_DIR/system-payload-policy.sh" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
policy = Path(sys.argv[2]).read_text(encoding="utf-8")
assert "for skel_config in kwinrc kwinoutputconfig.json; do" in text
assert "for skel_config in kwinrc plasmakeyboardrc kwinoutputconfig.json; do" not in text
assert 'ci_seed_default_user_keyboard_config "$rootfs_dir" "$DEFAULT_USER_NAME"' in text
assert text.index('ci_seed_default_user_keyboard_config "$rootfs_dir" "$DEFAULT_USER_NAME"') > text.index('applying validated overlay directory')
assert 'ci_snapshot_local_deb_payload' in text
assert 'ci_verify_local_deb_payload_snapshot' in text
assert 'rm -rf -- "$rootfs_dir/var/tmp/ci-debs"' in text
assert 'ci_seed_default_user_keyboard_config()' in policy
assert '[ "$seeded" -eq 1 ]' in policy
assert 'default user keyboard configuration is unsafe' in policy
assert 'local DEB payload changed after overlay' in policy
PY

echo 'SYSTEM_PAYLOAD_POLICY=PASS'
