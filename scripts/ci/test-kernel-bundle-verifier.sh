#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
verifier="$SCRIPT_DIR/verify-kernel-bundle.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-kernel-bundle-verifier.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

release=7.1.1-g111111111111
commit=1111111111111111111111111111111111111111
epoch=1784073600
kernel_root="$tmp/kernel"
device_root="$tmp/device"
sensor_root="$tmp/sensor"
haptics_root="$tmp/haptics"
mkdir -p "$kernel_root" "$device_root" "$sensor_root" "$haptics_root"

sha() {
  sha256sum "$1" | awk '{print $1}'
}

write_bundle() {
  local file=$1 source_epoch=$2 identity bundle_id
  identity="${file}.identity"
  {
    printf 'schema\ttb321fu.kernel-bundle/v1\n'
    printf 'kernel-source-commit\t%s\n' "$commit"
    printf 'kernel-release\t%s\n' "$release"
    printf 'kernel-config-sha256\t%s\n' "$config_sha"
    printf 'source-date-epoch\t%s\n' "$source_epoch"
    printf 'kbuild-build-timestamp\t2026-07-15 00:00:00 UTC\n'
    printf 'kbuild-build-user\ttb321fu-ci\n'
    printf 'kbuild-build-host\ttb321fu-builder\n'
    printf 'kbuild-build-version\t1\n'
  } > "$identity"
  bundle_id=$(sha "$identity")
  cat "$identity" > "$file"
  printf 'kernel-bundle-id\t%s\n' "$bundle_id" >> "$file"
  rm -f -- "$identity"
  written_bundle_id=$bundle_id
}

make_deb() {
  local package=$1 destination=$2 module_path=${3:-} vermagic=${4:-}
  local module_mode=${5:-0644}
  local root="$tmp/pkg-$package"
  rm -rf -- "$root"
  mkdir -p "$root/DEBIAN"
  cat > "$root/DEBIAN/control" <<EOF
Package: $package
Version: 20260715.1
Section: misc
Priority: optional
Architecture: arm64
Maintainer: TB321FU fixture <noreply@localhost>
Description: Small kernel bundle verifier fixture.
EOF
  if [ -n "$module_path" ]; then
    mkdir -p "$root/$(dirname -- "$module_path")"
    printf '%s SMP\n' "$vermagic" > "$root/$module_path"
    chmod "$module_mode" "$root/$module_path"
  fi
  if [ "$package" = y700-daily-kernel-modules ]; then
    cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
depmod '7.1.1-g111111111111'
EOF
    chmod 0755 "$root/DEBIAN/postinst"
  fi
  dpkg-deb --root-owner-group -Zxz -b "$root" "$destination" >/dev/null
}

write_haptics_lock() {
  local bundle_id=$1
  {
    printf 'kernel-bundle-id\t%s\n' "$bundle_id"
    printf 'kernel-release\t%s\n' "$release"
    printf 'kernel-source-commit\t%s\n' "$commit"
    printf 'kernel-config-sha256\t%s\n' "$config_sha"
  } > "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
}

write_kernel_source_lock() {
  modules_deb_sha=$(sha "$device_root/y700-daily-kernel-modules_20260715.1_arm64.deb")
  {
    printf 'schema\ttb321fu.kernel-bootstrap/v2\n'
    printf 'kernel_bundle_id\t%s\n' "$kernel_bundle_id"
    printf 'kernel_commit\t%s\n' "$commit"
    printf 'kernel_release\t%s\n' "$release"
    printf 'config_sha256\t%s\n' "$config_sha"
    printf 'image_sha256\t%s\n' "$(sha "$kernel_root/Image")"
    printf 'dtb_sha256\t%s\n' "$(sha "$kernel_root/sm8650-lenovo-tb321fu.dtb")"
    printf 'modules_deb_sha256\t%s\n' "$modules_deb_sha"
  } > "$kernel_root/SOURCE-LOCK.tsv"
  cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
}

write_sensor_metadata() {
  {
    printf 'component\trepository\tcommit\n'
    printf 'sensor-producer\thttps://example.invalid/sensor\t%s\n' "$commit"
    printf 'libssc\thttps://example.invalid/libssc\t%s\n' "$commit"
    printf 'iio-sensor-proxy\thttps://example.invalid/iio\t%s\n' "$commit"
    printf 'hexagonrpc\thttps://example.invalid/hexagonrpc\t%s\n' "$commit"
    printf 'producer-state\tgit-status\tclean\n'
  } > "$sensor_root/SOURCE-LOCK.tsv"
  (cd "$sensor_root" && sha256sum ./*.deb > SHA256SUMS-y700-sensor-debs.txt)
}

pack_archives() {
  tar -C "$kernel_root" -czf "$tmp/kernel.tar.gz" .
  tar -C "$device_root" -czf "$tmp/device.tar.gz" .
  tar -C "$sensor_root" -czf "$tmp/sensor.tar.gz" .
  tar -C "$haptics_root" -czf "$tmp/haptics.tar.gz" .
}

run_verifier() {
  local output_name=$1
  env \
    OUTPUT_DIR="$tmp/tb321fu-verified-kernel-bundle-$output_name" \
    KERNEL_ARTIFACT_ARCHIVE="$tmp/kernel.tar.gz" \
    KERNEL_ARTIFACT_ARCHIVE_SHA256="$(sha "$tmp/kernel.tar.gz")" \
    DEB_ARCHIVE="$tmp/device.tar.gz" \
    DEB_ARCHIVE_SHA256="$(sha "$tmp/device.tar.gz")" \
    SENSOR_DEB_ARCHIVE="$tmp/sensor.tar.gz" \
    SENSOR_DEB_ARCHIVE_SHA256="$(sha "$tmp/sensor.tar.gz")" \
    HAPTICS_DEB_ARCHIVE="$tmp/haptics.tar.gz" \
    HAPTICS_DEB_ARCHIVE_SHA256="$(sha "$tmp/haptics.tar.gz")" \
    MODINFO="$tmp/modinfo" \
    bash "$verifier"
}

require_failure() {
  local name=$1 expected=$2 output status
  set +e
  output=$(run_verifier "$name" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || {
    printf 'fixture %s unexpectedly passed\n' "$name" >&2
    exit 1
  }
  grep -Fq -- "$expected" <<<"$output" || {
    printf 'fixture %s failed at the wrong boundary; expected %s\n%s\n' \
      "$name" "$expected" "$output" >&2
    exit 1
  }
}

cat > "$tmp/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = -F ] && [ "$2" = vermagic ]
cat -- "$3"
EOF
chmod 0755 "$tmp/modinfo"

printf 'fixture-kernel-config\n' > "$kernel_root/kernel.config"
printf 'fixture-image\n' > "$kernel_root/Image"
printf 'fixture-dtb\n' > "$kernel_root/sm8650-lenovo-tb321fu.dtb"
config_sha=$(sha "$kernel_root/kernel.config")
write_bundle "$kernel_root/KERNEL-BUNDLE.tsv" "$epoch"
kernel_bundle_id=$written_bundle_id
cp "$kernel_root/KERNEL-BUNDLE.tsv" "$device_root/KERNEL-BUNDLE.tsv"

make_deb y700-daily-kernel-modules \
  "$device_root/y700-daily-kernel-modules_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/kernel/fixture.ko" "$release"
write_kernel_source_lock

for package in \
  qcom-sns-libssc qcom-sns-hexagonrpc qcom-sns-iio-sensor-proxy tb321fu-sensors; do
  make_deb "$package" "$sensor_root/${package}_20260715.1_arm64.deb"
done
write_sensor_metadata

make_deb tb321fu-haptics "$haptics_root/tb321fu-haptics_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/extra/aw86937-haptics.ko" "$release"
write_haptics_lock "$kernel_bundle_id"
pack_archives

run_verifier success >/dev/null
success_dir="$tmp/tb321fu-verified-kernel-bundle-success"
grep -Fq "SENSOR_DEB_ARCHIVE=$success_dir/sensor-debs.archive" \
  "$success_dir/verified.env"
cmp -s "$tmp/sensor.tar.gz" "$success_dir/sensor-debs.archive"
grep -Fxq $'schema\ttb321fu.verified-inputs/v1' "$success_dir/VERIFIED-INPUTS.tsv"

make_deb y700-daily-kernel-modules \
  "$device_root/y700-daily-kernel-modules_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/kernel/fixture.ko" "$release" 0600
write_kernel_source_lock
pack_archives
require_failure wrong-module-mode 'kernel modules DEB contains a non-0644 data file'
make_deb y700-daily-kernel-modules \
  "$device_root/y700-daily-kernel-modules_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/kernel/fixture.ko" "$release"
write_kernel_source_lock

write_bundle "$device_root/KERNEL-BUNDLE.tsv" "$((epoch + 1))"
pack_archives
require_failure device-bundle-mismatch 'bundle metadata is not byte-identical'
cp "$kernel_root/KERNEL-BUNDLE.tsv" "$device_root/KERNEL-BUNDLE.tsv"

write_haptics_lock "$(printf '0%.0s' {1..64})"
pack_archives
require_failure haptics-bundle-mismatch 'haptics kernel-bundle-id mismatch'
write_haptics_lock "$kernel_bundle_id"

printf 'wrong-kernel-config\n' > "$kernel_root/kernel.config"
pack_archives
require_failure wrong-config 'kernel config SHA-256 mismatch'
printf 'fixture-kernel-config\n' > "$kernel_root/kernel.config"

make_deb tb321fu-haptics "$haptics_root/tb321fu-haptics_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/extra/aw86937-haptics.ko" wrong-release
pack_archives
require_failure wrong-haptics-vermagic 'haptics module vermagic mismatch'
make_deb tb321fu-haptics "$haptics_root/tb321fu-haptics_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/extra/aw86937-haptics.ko" "$release"

rm -f -- "$sensor_root/tb321fu-sensors_20260715.1_arm64.deb"
write_sensor_metadata
pack_archives
require_failure missing-sensor-package 'sensor archive must contain exactly four DEBs'

printf 'KERNEL_BUNDLE_VERIFIER=PASS\n'
