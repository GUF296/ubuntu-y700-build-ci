#!/usr/bin/env bash
# Check installed desktop userspace after every package transaction. Never load policy here.
set -euo pipefail
[[ $# == 3 ]] || exit 2
inventory=$1 arch=$2 root=$3
[[ -f $inventory && -d $root && $root == /* && $root != / && $(realpath -e -- "$root") == "$root" ]] || exit 2
LC_ALL=C awk -F '\t' -v arch="$arch" '
  $1 == "apparmor" || $1 ~ /^apparmor:/ {
    if (NF != 3 || ($1 != "apparmor" && $1 != "apparmor:" arch) || $2 == "" || $3 != arch) bad=1
    ++n
  }
  END { exit bad || n != 1 }
' "$inventory" || { echo 'selected desktop lacks exactly one target AppArmor package' >&2; exit 1; }
chroot "$root" /bin/sh -ec '
  test -f /usr/sbin/apparmor_parser && test -x /usr/sbin/apparmor_parser && test -s /usr/sbin/apparmor_parser &&
  test -f /usr/bin/aa-enabled && test -x /usr/bin/aa-enabled && test -s /usr/bin/aa-enabled &&
  test -f /lib/systemd/system/apparmor.service && test -s /lib/systemd/system/apparmor.service &&
  test -L /etc/systemd/system/sysinit.target.wants/apparmor.service &&
  test /etc/systemd/system/sysinit.target.wants/apparmor.service -ef /lib/systemd/system/apparmor.service
' || { echo 'desktop AppArmor executable or enabled distribution service missing' >&2; exit 1; }
