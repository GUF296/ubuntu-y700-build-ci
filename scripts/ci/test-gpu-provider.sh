#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
g++ -std=c++17 -Wall -Wextra -Werror "$here/test-gpu-frequency-range.cpp" -o "$work/frequency"
"$work/frequency"

# ELF dependency discovery cannot infer the package whose stock provider we divert.
# Exercise the actual metadata writer, and inspect the result without running its maintainer scripts.
# shellcheck source=tb321fu-gpu-deb-package.sh
. "$here/tb321fu-gpu-deb-package.sh"
ci_die() { echo "$*" >&2; exit 1; }
shlibs='libksysguardsystemstats2 (>= 4:6.6.4~), libqt6core6t64 (>= 6.10.0~)'
tb321fu_write_gpu_deb_metadata "$work/package" 1.1234567890abcdef arm64 "$shlibs"
dpkg-deb --root-owner-group --build "$work/package" "$work/package.deb" >/dev/null
[[ $(dpkg-deb -f "$work/package.deb" Package) == tb321fu-ksystemstats-gpu ]]
[[ $(dpkg-deb -f "$work/package.deb" Architecture) == arm64 ]]
[[ $(dpkg-deb -f "$work/package.deb" Depends) == "ksystemstats, $shlibs" ]]
echo 'GPU_PACKAGE_STOCK_OWNER_AND_SHLIBS=PASS'
