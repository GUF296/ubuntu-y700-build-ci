#!/usr/bin/env bash
# Run one post-overlay GPU build/packaging command. The normal chroot runtime
# is already detached. Bash process substitution in the APT recorder needs
# the target's /dev/fd -> /proc/self/fd, including inside APT subprocesses.
set -euo pipefail
[[ $# -ge 2 ]] || { echo 'usage: chroot-gpu-build.sh ROOT COMMAND [ARGS...]' >&2; exit 2; }
root=$1
shift
[[ $root != / && $root == /* && $(realpath -e -- "$root") == "$root" &&
   -d $root/proc && ! -L $root/proc && -d $root/dev && ! -L $root/dev ]] || {
  echo 'GPU chroot requires a physical target and real proc/dev directories' >&2
  exit 1
}
# A fresh PID namespace keeps unrelated processes out of procfs. Do not
# bind the host's /dev directory, /dev/pts, /sys, /run or proc. PID 1 exiting also ends
# the namespace's children, releasing the mount on success, error or death.
exec unshare --mount --pid --fork --kill-child --propagation private -- \
  /bin/bash -eu -o pipefail -c '
    root=$1
    shift
    for sub in proc dev; do
      if mountpoint -q -- "$root/$sub"; then
        echo "GPU chroot target $sub was already mounted" >&2
        exit 1
      else
        rc=$?
        [[ $rc == 32 ]] || { echo "cannot inspect GPU chroot $sub mount" >&2; exit 1; }
      fi
    done
    mount -t proc -o ro,nosuid,nodev,noexec proc "$root/proc"
    # Some debootstrap variants leave only an empty /dev after bootstrap.
    # Build a small ephemeral target; these four memory devices expose no disks.
    mount -t tmpfs -o mode=0755,size=1m,nosuid,nodev,noexec tmpfs "$root/dev"
    for device in null zero random urandom; do
      [[ -c /dev/$device && ! -L /dev/$device ]]
      touch "$root/dev/$device"
      mount --bind "/dev/$device" "$root/dev/$device"
    done
    ln -s /proc/self/fd "$root/dev/fd"
    for pair in stdin:0 stdout:1 stderr:2; do
      ln -s "/proc/self/fd/${pair#*:}" "$root/dev/${pair%:*}"
    done
    mkdir -m 0755 "$root/dev/pts"
    mount -t devpts -o newinstance,nosuid,noexec,ptmxmode=0666,mode=0600 devpts "$root/dev/pts"
    ln -s pts/ptmx "$root/dev/ptmx"
    exec chroot "$root" "$@"
  ' gpu-chroot "$root" "$@"
