#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

ci_die() {
  printf 'test failure: %s\n' "$*" >&2
  exit 1
}

. "$SCRIPT_DIR/tb321fu-gpu-deb-package.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root="$tmp/root"
package_root="$tmp/package"
fake_bin="$tmp/bin"
state="$tmp/diversion-state"
stock=/usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
disabled=$stock.disabled-tb321fu-adreno
plugin=/usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
checksum=/usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256

mkdir -p "$fake_bin" "$root$(dirname "$stock")" "$package_root$(dirname "$plugin")" \
  "$package_root$(dirname "$checksum")"
printf 'stock-provider-v1\n' > "$root$stock"
printf 'tb321fu-provider-v1\n' > "$package_root$plugin"
(
  cd "$package_root"
  sha256sum ".${plugin}" > ".${checksum}"
)
checksum_line=$(cat "$package_root$checksum")
[[ $checksum_line == *"  .${plugin}" ]] || ci_die "GPU checksum is not package-relative"
[[ $checksum_line != *"$tmp"* ]] || ci_die "GPU checksum leaked its host build path"

cat > "$fake_bin/dpkg-divert" <<'MOCK_DIVERT'
#!/bin/sh
set -eu
state=${TB321FU_GPU_TEST_STATE:?}
root=${TB321FU_GPU_TEST_ROOT:?}
owner_file=$state.owner
target_file=$state.target

case "${1:-}" in
  --listpackage)
    [ -f "$owner_file" ] && cat "$owner_file"
    ;;
  --truename)
    if [ -f "$target_file" ]; then cat "$target_file"; else printf '%s\n' "$2"; fi
    ;;
  --package)
    package=$2
    shift 2
    action=
    divert=
    stock=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --add|--remove) action=$1 ;;
        --rename) ;;
        --divert) shift; divert=$1 ;;
        *) stock=$1 ;;
      esac
      shift
    done
    [ -n "$action" ] && [ -n "$divert" ] && [ -n "$stock" ]
    case "$action" in
      --add)
        [ ! -f "$owner_file" ]
        mv -- "$root$stock" "$root$divert"
        printf '%s\n' "$package" > "$owner_file"
        printf '%s\n' "$divert" > "$target_file"
        ;;
      --remove)
        [ "$(cat "$owner_file")" = "$package" ]
        mv -- "$root$divert" "$root$stock"
        rm -f "$owner_file" "$target_file"
        ;;
    esac
    ;;
  *) exit 2 ;;
esac
MOCK_DIVERT

cat > "$fake_bin/dpkg-query" <<'MOCK_QUERY'
#!/bin/sh
set -eu
[ "${1:-}" = -L ]
[ "${2:-}" = tb321fu-ksystemstats-gpu ]
printf '%s\n' \
  /usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so \
  /usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256
MOCK_QUERY
chmod 0755 "$fake_bin/dpkg-divert" "$fake_bin/dpkg-query"

tb321fu_write_gpu_deb_metadata "$package_root" 1.20260715 arm64 \
  'libc6 (>= 2.38), libqt6core6t64 (>= 6.6)' 1
(
  cd "$package_root"
  find usr -type f -print0 | sort -z | xargs -0 -r md5sum > DEBIAN/md5sums
)
chmod 0644 "$package_root/DEBIAN/md5sums"
dpkg-deb --root-owner-group --build "$package_root" "$tmp/gpu.deb" >/dev/null
[ "$(dpkg-deb -f "$tmp/gpu.deb" Package)" = tb321fu-ksystemstats-gpu ]
[ "$(dpkg-deb -f "$tmp/gpu.deb" Version)" = 1.20260715 ]
[ "$(dpkg-deb -f "$tmp/gpu.deb" Architecture)" = arm64 ]
[ "$(dpkg-deb -f "$tmp/gpu.deb" Provides)" = tb321fu-adreno-frequency-provider ]
[ "$(dpkg-deb -f "$tmp/gpu.deb" Conflicts)" = y700-ksystemstats-gpu ]
[ "$(dpkg-deb -f "$tmp/gpu.deb" Replaces)" = y700-ksystemstats-gpu ]

run_script() {
  local script=$1
  shift
  env PATH="$fake_bin:/usr/bin:/bin" \
    TB321FU_GPU_TEST_ROOT="$root" \
    TB321FU_GPU_TEST_STATE="$state" \
    "$package_root/DEBIAN/$script" "$@"
}

install_payload() {
  install -D -m 0644 "$package_root$plugin" "$root$plugin"
  install -D -m 0644 "$package_root$checksum" "$root$checksum"
}

# Fresh installation owns the diversion, validates the package payload, and
# retains the exact stock provider under the deterministic diverted name.
run_script preinst install
[ ! -e "$root$stock" ]
cmp -s "$root$disabled" <(printf 'stock-provider-v1\n')
install_payload
run_script postinst configure
[ ! -e "$root/var/lib/tb321fu-ksystemstats-gpu/diversion-added-by-preinst" ]

# Upgrade preserves the existing diversion and accepts only the new payload
# after its checksum has been updated.
run_script prerm upgrade
run_script preinst upgrade
printf 'tb321fu-provider-v2\n' > "$root$plugin"
(
  cd "$root"
  sha256sum ".${plugin}" > ".${checksum}"
)
run_script postrm upgrade
run_script postinst configure

# Removal restores the exact original stock provider.
run_script prerm remove
rm -f "$root$plugin" "$root$checksum"
run_script postrm remove
cmp -s "$root$stock" <(printf 'stock-provider-v1\n')
[ ! -e "$root$disabled" ]

# A failed fresh install is rolled back by postrm abort-install.
run_script preinst install
run_script postrm abort-install
cmp -s "$root$stock" <(printf 'stock-provider-v1\n')
[ ! -e "$root$disabled" ]

# Never take over a diversion owned by another package.
printf 'foreign-package\n' > "$state.owner"
printf '%s\n' "$disabled" > "$state.target"
if run_script preinst install >/dev/null 2>&1; then
  ci_die "foreign diversion was accepted"
fi
rm -f "$state.owner" "$state.target"

for maintainer_script in preinst postinst prerm postrm; do
  [ "$(stat -c '%a' "$package_root/DEBIAN/$maintainer_script")" = 755 ] || \
    ci_die "$maintainer_script is not executable"
done

# Test indirection is generated only for this fixture; production maintainer
# scripts always operate on the dpkg root and ignore ambient test variables.
production_root="$tmp/production-package"
tb321fu_write_gpu_deb_metadata "$production_root" 1.20260715 arm64 \
  'libc6 (>= 2.38), libqt6core6t64 (>= 6.6)'
if grep -R -Fq TB321FU_GPU_TEST_ROOT "$production_root/DEBIAN"; then
  ci_die "production maintainer script retained test-root indirection"
fi
for maintainer_script in preinst postinst prerm postrm; do
  grep -Fxq 'root=' "$production_root/DEBIAN/$maintainer_script" || \
    ci_die "production $maintainer_script does not pin the dpkg root"
done

printf 'GPU_DEB_LIFECYCLE=PASS\n'
