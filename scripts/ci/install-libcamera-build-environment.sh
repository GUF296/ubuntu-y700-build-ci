#!/usr/bin/env bash
set -euo pipefail

# This is an ephemeral CI provisioning step, never a workstation repair tool.
[ "${1:-}" = --install ] && [ "$#" = 1 ] || {
  echo 'usage: install-libcamera-build-environment.sh --install (CI only)' >&2
  exit 2
}
[ "$EUID" = 0 ] && [ "${GITHUB_ACTIONS:-}" = true ] &&
  [ "${RUNNER_OS:-}" = Linux ] && [ "${RUNNER_ARCH:-}" = X64 ] || {
  echo 'refusing dependency installation outside explicit root Linux X64 Actions runner' >&2
  exit 1
}
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ] &&
  [ "$(dpkg --print-architecture)" = amd64 ] || {
  echo 'camera producer requires an Ubuntu 24.04 amd64 host' >&2
  exit 1
}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
umask 022
work=$(mktemp -d /tmp/tb321fu-camera-apt.XXXXXXXX)
cleanup() {
  case "$work" in /tmp/tb321fu-camera-apt.*) ;; *) return 1 ;; esac
  [ -d "$work" ] && [ ! -L "$work" ] || return 1
  rm -rf -- "$work"
}
trap cleanup EXIT
chmod 0755 "$work"
mkdir -m 0755 "$work/sources" "$work/lists"
python3 -I -B "$script_dir/prepare-libcamera-build-environment.py" >"$work/packages"
mapfile -t packages <"$work/packages"
[ "${#packages[@]}" -gt 0 ]
cat >"$work/sources/camera.sources" <<'SOURCES'
Types: deb
URIs: https://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Architectures: arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture arm64
apt=(apt-get -o Dir::Etc::sourcelist=/dev/null
  -o "Dir::Etc::sourceparts=$work/sources" -o "Dir::State::lists=$work/lists"
  -o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
timeout --signal=KILL 20m "${apt[@]}" update
# Version drift must fail instead of removing packages or silently downgrading.
timeout --signal=KILL 20m "${apt[@]}" install -y --no-remove --no-install-recommends -- "${packages[@]}"
python3 -I -B "$script_dir/verify-libcamera-build-environment.py"
