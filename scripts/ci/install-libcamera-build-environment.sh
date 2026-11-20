#!/usr/bin/env bash
set -euo pipefail

# Only provision the throwaway camera container, never the Actions host or WSL.
[ "$#" = 1 ] && [ "$1" = --install ] || {
  echo 'usage: install-libcamera-build-environment.sh --install (CI container only)' >&2
  exit 2
}
inputs=/run/tb321fu-camera-inputs
[ "$EUID" = 0 ] && [ -f /.dockerenv ] && [ -r "$inputs/packages" ] &&
  [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_OS:-}" = Linux ] &&
  [ "${RUNNER_ARCH:-}" = X64 ] || {
  echo 'refusing dependency installation outside the dedicated Linux X64 Actions container' >&2
  exit 1
}
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ] && [ "$(dpkg --print-architecture)" = amd64 ]
cd -- "$inputs"
sha256sum --strict -c <<'DIGESTS'
61e29c7504f020539b7d6112302b66e8ea5b6da00eb8b685dace384715fb11eb  base-files.deb
17000967a1fae30c8dbb92b2183ec6e245c6d802aacf2c2945a20ee89298b8e9  libldap2.deb
DIGESTS
mapfile -t packages <packages
[ "${#packages[@]}" -gt 0 ]
historical=0
for i in "${!packages[@]}"; do
  case "${packages[$i]}" in
    base-files:amd64=13ubuntu10.2) packages[$i]="$inputs/base-files.deb"; ((historical+=1)) ;;
    libldap2:amd64=2.6.7+dfsg-1~exp1ubuntu8.2) packages[$i]="$inputs/libldap2.deb"; ((historical+=1)) ;;
  esac
done
[ "$historical" = 2 ]

work=$(mktemp -d /tmp/tb321fu-camera-apt.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
chmod 0755 "$work"
mkdir -m 0755 "$work/sources" "$work/lists"
cat >"$work/sources/camera.sources" <<'SOURCES'
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/20260913T000000Z/
Suites: noble noble-updates noble-security
Components: main universe
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
Check-Valid-Until: no
SOURCES
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture arm64
apt=(apt-get -o Dir::Etc::sourcelist=/dev/null
  -o "Dir::Etc::sourceparts=$work/sources" -o "Dir::State::lists=$work/lists"
  -o Acquire::https::CaInfo=/run/tb321fu-camera-ca.crt -o Acquire::Languages=none
  -o APT::Update::Error-Mode=any -o Acquire::Retries=2 -o Acquire::https::Timeout=30)
timeout --signal=KILL 15m "${apt[@]}" update
# Generic compiler/binutils links, curl for optional HTTPS input, and dpkg-deb
# compression helpers come from the same signed snapshot as the locked payload.
timeout --signal=KILL 25m "${apt[@]}" install -y --no-remove --no-install-recommends -- \
  "${packages[@]}" gcc g++ gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  binutils curl ca-certificates xz-utils zstd
script_dir="$GITHUB_WORKSPACE/scripts/ci"
python3 -I -B "$script_dir/prepare-libcamera-build-environment.py" | cmp - "$inputs/packages"
python3 -I -B "$script_dir/verify-libcamera-build-environment.py"
