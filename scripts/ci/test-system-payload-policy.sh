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
  local root=$1 package=$2
  install -d -m 0755 "$root/DEBIAN"
  cat > "$root/DEBIAN/control" <<CONTROL
Package: $package
Version: 1
Architecture: arm64
Maintainer: CI <ci@example.invalid>
Description: payload policy fixture
CONTROL
}

daily_root="$tmp/daily-root"
haptics_root="$tmp/haptics-root"
payload="$tmp/payload"
install -d -m 0755 "$payload"
make_control "$daily_root" y700-daily-rootfs-overlay
install -d -m 0777 \
  "$daily_root/etc/systemd/system" \
  "$daily_root/etc/wireplumber/wireplumber.conf.d" \
  "$daily_root/usr/lib/firmware" \
  "$daily_root/usr/lib/aarch64-linux-gnu" \
  "$daily_root/usr/bin" \
  "$daily_root/usr/local/bin" \
  "$daily_root/usr/share/wireplumber/scripts/y700" \
  "$daily_root/opt/libcamera-y700/bin" \
  "$daily_root/opt/libcamera-y700/libexec/libcamera"
printf 'ram-firmware\n' > "$daily_root/usr/lib/firmware/haptic_ram.bin"
printf 'click-firmware\n' > "$daily_root/usr/lib/firmware/haptic_click.bin"
install -m 0644 "$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.conf" \
  "$daily_root/etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf"
install -m 0644 "$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.lua" \
  "$daily_root/usr/share/wireplumber/scripts/y700/headset-cleanup.lua"
printf 'unit\n' > "$daily_root/etc/systemd/system/fixture.service"
printf 'library\n' > "$daily_root/usr/lib/aarch64-linux-gnu/libfixture.so"
printf '#!/bin/sh\nexit 0\n' > "$daily_root/usr/bin/fixture-helper"
for executable in \
  "$daily_root/opt/libcamera-y700/bin/cam" \
  "$daily_root/opt/libcamera-y700/bin/libcamera-bug-report" \
  "$daily_root/opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy" \
  "$daily_root/usr/local/bin/y700-camera-env" \
  "$daily_root/usr/local/bin/y700-camera-cam" \
  "$daily_root/usr/local/bin/y700-camera-preview"; do
  printf '#!/bin/sh\nexit 0\n' > "$executable"
done
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
(cd "$tmp/before" && find . -type f \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf' \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-tb321fu-headset-route-reconcile.conf' \
  ! -path './usr/share/wireplumber/scripts/y700/headset-cleanup.lua' \
  ! -path './usr/share/wireplumber/scripts/tb321fu/headset-route-reconcile.lua' \
  -print0 | sort -z | xargs -0 sha256sum) > "$tmp/before.sha256"

export SOURCE_DATE_EPOCH=0
ci_prepare_y700_daily_payload_deb "$payload" "$tmp/rewrite"

[ "$(ci_deb_member_owners "$payload" usr/lib/firmware/haptic_ram.bin | wc -l)" -eq 1 ]
[ "$(ci_deb_member_owners "$payload" usr/lib/firmware/haptic_click.bin | wc -l)" -eq 1 ]
ci_deb_member_owners "$payload" usr/lib/firmware/haptic_ram.bin | \
  cut -f1 | grep -Fx tb321fu-haptics-common >/dev/null

dpkg-deb -x "$payload/daily.deb" "$tmp/after"
dpkg-deb -x "$payload/haptics.deb" "$tmp/after"
(cd "$tmp/after" && find . -type f \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf' \
  ! -path './etc/wireplumber/wireplumber.conf.d/52-tb321fu-headset-route-reconcile.conf' \
  ! -path './usr/share/wireplumber/scripts/y700/headset-cleanup.lua' \
  ! -path './usr/share/wireplumber/scripts/tb321fu/headset-route-reconcile.lua' \
  -print0 | sort -z | xargs -0 sha256sum) > "$tmp/after.sha256"
cmp "$tmp/before.sha256" "$tmp/after.sha256"
[ ! -e "$tmp/after/etc/wireplumber/wireplumber.conf.d/52-y700-headset-cleanup.conf" ]
[ ! -e "$tmp/after/usr/share/wireplumber/scripts/y700/headset-cleanup.lua" ]
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

grep -F 'systemctl enable tb321fu-haptics.service >/dev/null' \
  "$SCRIPT_DIR/build-tb321fu-haptics-deb.sh" >/dev/null
grep -F 'systemctl is-enabled --quiet tb321fu-haptics.service' \
  "$SCRIPT_DIR/build-tb321fu-haptics-deb.sh" >/dev/null
if grep -F 'systemctl enable tb321fu-haptics.service >/dev/null 2>&1 || true' \
    "$SCRIPT_DIR/build-tb321fu-haptics-deb.sh" >/dev/null; then
  echo 'required haptics enable remains best-effort' >&2
  exit 1
fi

echo 'SYSTEM_PAYLOAD_POLICY=PASS'
