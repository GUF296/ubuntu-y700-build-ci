#!/usr/bin/env bash
# The fixture executes the same membership and file tests as the real target,
# in a disposable root with its own native shell. No LSM/service operations.
set -euo pipefail
d=$(cd -- "$(dirname -- "$0")" && pwd -P)
t=$(mktemp -d)
trap 'rm -rf -- "$t"' EXIT
root=$t/root inv=$t/inventory
mkdir -p "$root"
test_reject() {
  if "$@" >/dev/null 2>&1; then echo 'incorrect desktop AppArmor state accepted' >&2; exit 1; fi
}
verify=(bash "$d/verify-desktop-apparmor.sh" "$inv" arm64 "$root")
for bad in 'libapparmor1:arm64\t5\tarm64' 'apparmor\t5\tamd64' 'apparmor:amd64\t5\tarm64' \
    'apparmor\t\tarm64' 'apparmor\t5\tarm64\napparmor:arm64\t5\tarm64'; do
  printf '%b\n' "$bad" >"$inv"
  if "${verify[@]}" 2>"$t/err"; then exit 1; fi
  grep -Fxq 'selected desktop lacks exactly one target AppArmor package' "$t/err"
done
python3 -IB - "$d/build-rootfs-image.sh" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
guard='if [ -n "${DESKTOP_ENV:-}" ]; then'
select=s.index('PACKAGE_LIST="$PACKAGE_LIST $DESKTOP_ENV apparmor"')
check=s.index('bash "$SCRIPT_DIR/verify-desktop-apparmor.sh" "$package_inventory" "$ARCH" "$rootfs_dir"')
assert s.rfind(guard,0,select)>s.rfind('\nfi',0,select)
assert s.index('apt_secure install -y --no-install-recommends')>select
assert s.index('dpkg-query -W \\')<s.index('[ -s "$package_inventory" ]')<s.rfind(guard,0,check)<check<s.index('ci_log "writing manifest"')
PY
runner=()
if [ "$(id -u)" != 0 ]; then
  if unshare -Ur true 2>/dev/null; then runner=(unshare -Ur)
  else echo 'SKIP native AppArmor chroot fixture: unprivileged namespaces unavailable (inventory assertions passed)'; exit 0; fi
fi
mkdir -p "$root"/{bin,usr/bin,usr/sbin,usr/lib/systemd/system,etc/systemd/system/sysinit.target.wants}
cp -L /bin/sh "$root/bin/sh"
# Only the running distro shell's loader and its direct linked libraries.
while read -r lib; do
  mkdir -p "$root$(dirname "$lib")"
  cp -L "$lib" "$root$lib"
done < <(LC_ALL=C ldd /bin/sh | awk '$2=="=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}')
if [ ! -e "$root/lib/systemd" ]; then mkdir -p "$root/lib"; ln -s /usr/lib/systemd "$root/lib/systemd"; fi
for f in usr/sbin/apparmor_parser usr/bin/aa-enabled usr/lib/systemd/system/apparmor.service; do
  printf 'fixture\n' >"$root/$f"
done
chmod 755 "$root/usr/sbin/apparmor_parser" "$root/usr/bin/aa-enabled"
service=/usr/lib/systemd/system/apparmor.service
link=$root/etc/systemd/system/sysinit.target.wants/apparmor.service
ln -s "$service" "$link"
printf 'apparmor:arm64\t5\tarm64\n' >"$inv"
"${runner[@]}" "${verify[@]}"
printf 'apparmor\t5\tarm64\n' >"$inv"
"${runner[@]}" "${verify[@]}"
chmod 644 "$root/usr/sbin/apparmor_parser"
test_reject "${runner[@]}" "${verify[@]}"
chmod 755 "$root/usr/sbin/apparmor_parser"
rm "$link"
test_reject "${runner[@]}" "${verify[@]}"
ln -s /usr/bin/aa-enabled "$link"
test_reject "${runner[@]}" "${verify[@]}"
echo 'PASS desktop AppArmor package, parser, distro unit and enable link (not kernel enforcement)'
