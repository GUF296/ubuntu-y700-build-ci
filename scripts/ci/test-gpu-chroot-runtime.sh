#!/usr/bin/env bash
# No network, target image, device firmware, credentials or real APT operation.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
if (( EUID != 0 )); then
  exec unshare --user --map-root-user -- /bin/bash "$0" "$@"
fi
export LC_ALL=C
. "$here/common.sh"
parent=$(realpath -e -- "${TMPDIR:-/tmp}")
tmp=$(mktemp -d "$parent/tb321fu-gpu-runtime.XXXXXXXX")
trap 'ci_safe_rmtree "$tmp" "$parent" tb321fu-gpu-runtime.' EXIT
root="$tmp/root"
mkdir -p "$root"/{bin,dev,proc,run,sys,tmp,etc/apt/sources.list.d}
ln -s /proc/self/fd "$root/dev/fd"
# Use native distro binaries with only their dynamic-loader dependencies.
for cmd in bash awk basename find head sha256sum sort stat tr wc; do
  exe=$(command -v "$cmd")
  cp -L -- "$exe" "$root/bin/$cmd"
  libs=$(ldd "$exe")
  while read -r lib; do
    [[ -n $lib ]] && install -D -- "$lib" "$root$lib"
  done < <(awk '/ => \// {print $3} /^[[:space:]]*\// {print $1}' <<< "$libs")
done
cp -- "$here/common.sh" "$root/common.sh"
# Take the actual recorder source collection functions, stopping before any
# top-level transaction or APT command. Verify both lists, not just return code.
awk '/^readonly MAX_APT_TEXT_FILE_BYTES=/ {copy=1} /^collect_indexes\(\)/ {exit} copy' \
  "$here/apt-transaction-provenance.sh" > "$root/recorder-functions.sh"
cat > "$root/probe.sh" <<'PROBE'
set -euo pipefail
. /common.sh
. /recorder-functions.sh
die() { echo "$1" >&2; exit 1; }
apt_root=/
collect_sources /tmp/record
PROBE
printf '%s\n' 'deb https://ports.ubuntu.com/ubuntu-ports resolute main' > "$root/etc/apt/sources.list"
printf '%s\n' 'deb https://ports.ubuntu.com/ubuntu-ports resolute-updates main' > "$root/etc/apt/sources.list.d/updates.list"
if env -i PATH=/bin LC_ALL=C "$(command -v chroot)" "$root" /bin/bash /probe.sh 2>"$tmp/err"; then
  echo 'recorder unexpectedly worked without procfs' >&2; exit 1
fi
grep -Eq '/dev/fd/[0-9]+: No such file or directory' "$tmp/err"
run() { bash "$here/chroot-gpu-build.sh" "$root" /bin/bash -euc "$1"; }
run 'export PATH=/bin; . /probe.sh; [[ $(wc -l </tmp/record) == 2 && $(</tmp/record) == *"etc/apt/sources.list.d/updates.list"* ]]
  [[ -c /dev/null && -c /dev/zero && -c /dev/random && -c /dev/urandom ]]
  head -c 1 /dev/zero >/dev/null; head -c 1 /dev/urandom >/dev/null
  exec {pty}<>/dev/ptmx; exec {pty}>&-
  [[ -d /proc/1/fd && ! -e /sys/class && ! -e /run/systemd ]]'
rc=0; run 'exit 17' || rc=$?
[[ $rc == 17 ]]
for sub in proc dev; do
  rc=0; mountpoint -q -- "$root/$sub" || rc=$?
  [[ $rc == 32 ]]
done
[[ ! -e $root/proc/1 && ! -e $root/dev/null && ! -e $root/dev/pts && -L $root/dev/fd ]]
printf 'GPU_PRIVATE_RUNTIME=PASS collector=2-real-sources private-pty=opened child-exit=17 parent-mounts=unchanged\n'
