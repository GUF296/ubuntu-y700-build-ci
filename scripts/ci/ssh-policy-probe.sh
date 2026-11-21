#!/usr/bin/env bash
# Inspect the selected target's global host keys and per-account auth policy.
# The rootfs has already been sealed and its previous runtime mounts removed.
set -euo pipefail
export LC_ALL=C
umask 077
[ "$#" -eq 2 ] || { echo 'usage: ssh-policy-probe.sh ROOT USER' >&2; exit 2; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(realpath -e -- "$1")
user=$2
[ "$root" != / ] && [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] && [ "$user" != root ] || exit 2
[ -d "$root/run" ] && [ ! -L "$root/run" ] && [ -d "$root/etc/ssh" ] && [ ! -L "$root/etc/ssh" ] || {
  echo 'invalid target SSH runtime paths' >&2; exit 1;
}
# Global (no Match context) -G is keyless. -C is legal only with -T;
# -T loads a real key. Use a new private anonymous tmpfs, never the ext4
# image. Call a single mount-namespace process: even on failure/death its
# key, public half, mount and directories disappear with the namespace.
unshare --mount --propagation private --fork --kill-child \
  bash -eu -o pipefail -s -- "$root" "$user" "$script_dir/ssh-host-identity.py" <<'PRIVATE_PROBE'
  root=$1 user=$2 helper=$3
  mount -t tmpfs -o mode=0755,nosuid,nodev,noexec,size=2m tmpfs "$root/run"
  trap 'umount -- "$root/run"' EXIT
  [ "$(findmnt -rn --mountpoint "$root/run" -o FSTYPE)" = tmpfs ] || exit 1
  mkdir -m 0755 "$root/run/sshd"
  mkdir -m 0700 "$root/run/tb321fu-policy"
  # Canonical host-key validation must use the unmodified target config:
  # the later explicit -h changes the effective key list for that probe.
  chroot "$root" /usr/sbin/sshd -G | python3 -IB "$helper" config
  key=/run/tb321fu-policy/identity
  ssh-keygen -q -t ed25519 -N "" -C "" -f "$root$key"
  for account in "$user" root; do
    context="user=$account,host=client.invalid,addr=192.0.2.2,laddr=192.0.2.1,lport=22"
    chroot "$root" /usr/sbin/sshd -T -h "$key" -C "$context" |
      awk -v user="$account" '
        $1 ~ /^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|authenticationmethods)$/ {
          if (++seen[$1] != 1) exit 1
          print "ssh_policy[" user "]." $1 "=" substr($0, index($0, " ") + 1)
        }
        END { if (length(seen) != 5) exit 1 }
      '
  done
PRIVATE_PROBE
