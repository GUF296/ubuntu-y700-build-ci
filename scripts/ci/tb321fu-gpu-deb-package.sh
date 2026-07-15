#!/usr/bin/env bash

tb321fu_write_gpu_deb_metadata() {
  local package_root=$1
  local version=$2
  local architecture=$3
  local dependencies=$4
  local allow_test_root=${5:-0}
  local control_dir="$package_root/DEBIAN"
  local script

  [[ $version =~ ^[A-Za-z0-9.+:~]+$ ]] || ci_die "unsafe GPU package version: $version"
  [[ $architecture =~ ^[a-z0-9][a-z0-9-]*$ ]] || ci_die "unsafe GPU package architecture: $architecture"
  [ -n "$dependencies" ] || ci_die "GPU package runtime dependency list is empty"
  [[ $dependencies != *$'\n'* && $dependencies != *$'\r'* ]] || \
    ci_die "GPU package runtime dependency list contains a newline"
  case "$allow_test_root" in
    0|1) ;;
    *) ci_die "invalid GPU package test-root mode: $allow_test_root" ;;
  esac

  install -d -m 0755 "$control_dir"
  cat > "$control_dir/control" <<CONTROL
Package: tb321fu-ksystemstats-gpu
Version: $version
Section: utils
Priority: optional
Architecture: $architecture
Maintainer: TB321FU Linux maintainers <noreply@example.invalid>
Depends: $dependencies
Provides: tb321fu-adreno-frequency-provider
Conflicts: y700-ksystemstats-gpu
Replaces: y700-ksystemstats-gpu
Description: TB321FU Adreno frequency provider for KSystemStats
 Package-managed KSystemStats provider for the Lenovo TB321FU. The package
 diverts the generic GPU provider while installed and restores it on removal.
CONTROL

  for script in preinst postinst prerm postrm; do
    cat > "$control_dir/$script" <<'MAINTAINER_PREAMBLE_START'
#!/bin/sh
set -eu

package=tb321fu-ksystemstats-gpu
stock=/usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
divert=$stock.disabled-tb321fu-adreno
plugin=/usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
checksum=/usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256
MAINTAINER_PREAMBLE_START
    if [ "$allow_test_root" = 1 ]; then
      cat >> "$control_dir/$script" <<'MAINTAINER_TEST_ROOT'
root=${TB321FU_GPU_TEST_ROOT:-}
case "$root" in
  ""|/*) ;;
  *) echo "TB321FU_GPU_TEST_ROOT must be empty or absolute" >&2; exit 2 ;;
esac
MAINTAINER_TEST_ROOT
    else
      printf 'root=\n' >> "$control_dir/$script"
    fi
    cat >> "$control_dir/$script" <<'MAINTAINER_PREAMBLE_END'
state_dir=$root/var/lib/tb321fu-ksystemstats-gpu
added_marker=$state_dir/diversion-added-by-preinst

diversion_owner() {
  LC_ALL=C dpkg-divert --listpackage "$stock" 2>/dev/null || true
}

validate_owned_diversion() {
  owner=$(diversion_owner)
  [ "$owner" = "$package" ] || {
    echo "GPU diversion is owned by ${owner:-no package}, expected $package" >&2
    return 1
  }
  true_name=$(LC_ALL=C dpkg-divert --truename "$stock")
  [ "$true_name" = "$divert" ] || {
    echo "GPU diversion target is $true_name, expected $divert" >&2
    return 1
  }
}
MAINTAINER_PREAMBLE_END
  done

  cat >> "$control_dir/preinst" <<'PREINST'

case "${1:-}" in
  install|upgrade)
    owner=$(diversion_owner)
    if [ -z "$owner" ]; then
      if [ -e "$root$divert" ] || [ -L "$root$divert" ]; then
        echo "unmanaged GPU diversion target already exists: $divert" >&2
        exit 1
      fi
      install -d -m 0755 "$state_dir"
      : > "$added_marker"
      if ! dpkg-divert --package "$package" --add --rename --divert "$divert" "$stock"; then
        rm -f "$added_marker"
        exit 1
      fi
    elif [ "$owner" = "$package" ]; then
      validate_owned_diversion
      rm -f "$added_marker"
    else
      echo "refusing foreign GPU diversion owned by $owner" >&2
      exit 1
    fi
    ;;
  abort-upgrade)
    owner=$(diversion_owner)
    [ -z "$owner" ] || validate_owned_diversion
    ;;
  *) echo "unsupported preinst action: ${1:-missing}" >&2; exit 1 ;;
esac
exit 0
PREINST

  cat >> "$control_dir/postinst" <<'POSTINST'

case "${1:-}" in
  configure)
    validate_owned_diversion
    [ ! -e "$root$stock" ] && [ ! -L "$root$stock" ] || {
      echo "stock GPU provider remains active after diversion" >&2
      exit 1
    }
    [ -f "$root$divert" ] || { echo "diverted stock GPU provider is missing" >&2; exit 1; }
    dpkg-query -L "$package" | grep -Fx "$plugin" >/dev/null
    dpkg-query -L "$package" | grep -Fx "$checksum" >/dev/null
    [ -f "$root$plugin" ] || { echo "packaged GPU provider is missing" >&2; exit 1; }
    [ -f "$root$checksum" ] || { echo "packaged GPU checksum is missing" >&2; exit 1; }
    (cd "${root:-/}" && sha256sum -c "$root$checksum")
    rm -f "$added_marker"
    ;;
  abort-upgrade|abort-remove|abort-deconfigure) validate_owned_diversion ;;
  *) echo "unsupported postinst action: ${1:-missing}" >&2; exit 1 ;;
esac
exit 0
POSTINST

  cat >> "$control_dir/prerm" <<'PRERM'

case "${1:-}" in
  remove|upgrade|deconfigure|failed-upgrade) validate_owned_diversion ;;
  *) echo "unsupported prerm action: ${1:-missing}" >&2; exit 1 ;;
esac
exit 0
PRERM

  cat >> "$control_dir/postrm" <<'POSTRM'

remove_owned_diversion() {
  validate_owned_diversion
  dpkg-divert --package "$package" --remove --rename --divert "$divert" "$stock"
}

case "${1:-}" in
  remove|disappear)
    remove_owned_diversion
    rm -f "$added_marker"
    ;;
  abort-install)
    if [ -f "$added_marker" ]; then
      remove_owned_diversion
      rm -f "$added_marker"
    fi
    ;;
  upgrade|failed-upgrade|abort-upgrade)
    validate_owned_diversion
    [ ! -f "$added_marker" ] || {
      echo "unexpected fresh-install diversion marker during upgrade rollback" >&2
      exit 1
    }
    ;;
  purge)
    owner=$(diversion_owner)
    [ -z "$owner" ] || { echo "GPU diversion still exists during purge: $owner" >&2; exit 1; }
    rm -rf "$state_dir"
    ;;
  *) echo "unsupported postrm action: ${1:-missing}" >&2; exit 1 ;;
esac
exit 0
POSTRM

  chmod 0755 "$control_dir/preinst" "$control_dir/postinst" \
    "$control_dir/prerm" "$control_dir/postrm"
}
