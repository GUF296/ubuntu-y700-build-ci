#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
verifier="$SCRIPT_DIR/verify-kernel-bundle.sh"
python3 "$SCRIPT_DIR/verify-sensor-deb-structure.py" --self-test >/dev/null
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-kernel-bundle-verifier.XXXXXX")
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

release=7.1.1-g111111111111
commit=1111111111111111111111111111111111111111
kernel_producer_repository=GUF296/ubuntu-y700-build-ci
kernel_producer_tree=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
kernel_producer_tree_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sensor_commit=2222222222222222222222222222222222222222
epoch=1784073600
haptic_ram_payload='fixture-haptic-ram'
haptic_click_payload='fixture-haptic-click'
haptics_helper_source_payload='fixture-haptics-helper-source'
kernel_root="$tmp/kernel"
device_root="$tmp/device"
sensor_root="$tmp/sensor"
haptics_root="$tmp/haptics"
producer_root="$tmp/haptics-producer"
mkdir -p "$kernel_root" "$device_root" "$sensor_root" "$haptics_root"
haptics_environment_policy_sha=9c1a0bfc44acbcde4833637698aaa59b8c386f3138f79486001ce2003f7095cd
haptics_environment_policy_lines=(
  'schema=tb321fu.haptics-build-environment/v1'
  'policy=isolated-allowlist-v1'
  'path=/usr/sbin:/usr/bin:/sbin:/bin'
  'lang=C'
  'lc-all=C'
  'timezone=UTC'
  'home=/nonexistent'
  'tmpdir=/tmp'
  'producer-environment=env-i-script-allowlist'
  'transport-environment=http_proxy,https_proxy,no_proxy'
  'dynamic-kbuild-environment=discarded'
  'source-date-epoch=explicit'
  'debian-compression=xz,level=6,threads=1,uniform=yes'
  'kbuild-path=private-locked-tool-directory-v1'
  'kbuild-shell=absolute-locked-dash-v1'
  'command-resolution=absolute-recorded-paths'
  'generated-kernel-host-tools=absolute-private-path,sha256,pre-and-post-use-verification'
  'tool-identity=absolute-realpath,sha256,version,post-use-verification'
)
actual_haptics_environment_policy_sha=$(
  printf '%s\n' "${haptics_environment_policy_lines[@]}" | sha256sum | awk '{print $1}'
)
[ "$actual_haptics_environment_policy_sha" = "$haptics_environment_policy_sha" ] || {
  printf 'fixture haptics build-environment policy digest mismatch\n' >&2
  exit 1
}
haptics_build_tool_names=(
  bash dash env readlink realpath basename dirname date mktemp mkdir rm chmod cp mv
  ln cat find install touch stat awk grep sed sort cut cmp tee tr wc git curl
  python3 make gcc as ld ar rsync dpkg dpkg-deb sha256sum
  aarch64-linux-gnu-gcc aarch64-linux-gnu-cpp aarch64-linux-gnu-as
  aarch64-linux-gnu-ld aarch64-linux-gnu-ar aarch64-linux-gnu-nm
  aarch64-linux-gnu-objcopy aarch64-linux-gnu-objdump
  aarch64-linux-gnu-readelf aarch64-linux-gnu-strip kmod tar gzip xz
  sh bc getconf sha1sum uname head expr uniq xargs
)

sha() {
  sha256sum "$1" | awk '{print $1}'
}

write_fixture_aarch64_elf() {
  python3 - "$1" <<'PY_ELF'
import pathlib
import struct
import sys

ident = b"\x7fELF" + bytes((2, 1, 1, 0)) + bytes(8)
header = struct.pack(
    "<16sHHIQQQIHHHHHH",
    ident,
    3,
    183,
    1,
    0,
    64,
    0,
    0,
    64,
    56,
    1,
    0,
    0,
    0,
)
program = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 120, 120, 0x1000)
pathlib.Path(sys.argv[1]).write_bytes(header + program)
PY_ELF
}

setup_haptics_producer() {
  local driver_dir="$producer_root/haptics/daily-current/linux/drivers/input/misc"
  local firmware_dir="$producer_root/haptics/rootfs-reference/usr/lib/firmware"
  local helper_dir="$producer_root/haptics/baseline-20260614-daily-clean/testing-tools"
  local builder_dir="$producer_root/scripts/ci"
  local template_dir="$builder_dir/haptics-control-templates"

  git init -q "$producer_root"
  git -C "$producer_root" config user.name 'TB321FU fixture'
  git -C "$producer_root" config user.email 'fixture@example.invalid'
  mkdir -p "$driver_dir" "$firmware_dir" "$helper_dir" "$builder_dir" "$template_dir"
  cat > "$driver_dir/aw86937-y700.c" <<'EOF_DRIVER'
/* Lenovo Y700 AW86937 input force-feedback haptics driver */
static struct i2c_driver fixture = {
	.name = "aw86937-y700",
};
static const struct i2c_device_id fixture_ids[] = {
	{ "aw86937_y700" },
};
EOF_DRIVER
  printf '%s' "$haptic_ram_payload" > "$firmware_dir/haptic_ram.bin"
  printf '%s' "$haptic_click_payload" > "$firmware_dir/haptic_click.bin"
  printf '%s' "$haptics_helper_source_payload" > "$helper_dir/y700-haptic-test.c"
  cat > "$builder_dir/build-tb321fu-haptics-deb.sh" <<'EOF_BUILDER'
#!/usr/bin/env bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/haptics-maintainer-scripts.sh"
cat > bind-aw86937 <<'EOF_BIND'
#!/bin/sh
set -eu
echo fixture-bind >/dev/null
EOF_BIND
cat > tb321fu-haptics.service <<'EOF_SERVICE'
[Unit]
Description=Fixture TB321FU haptics
EOF_SERVICE
cat > 90-tb321fu-haptics.rules <<'EOF_UDEV'
SUBSYSTEM=="input", TAG+="uaccess"
EOF_UDEV
cat > plasmakeyboardrc <<'EOF_CONF'
[General]
vibrationEnabled=true
EOF_CONF
EOF_BUILDER
  chmod 0755 "$builder_dir/build-tb321fu-haptics-deb.sh"
  cat > "$builder_dir/haptics-maintainer-scripts.sh" <<'EOF_MAINTAINER_HELPER'
#!/usr/bin/env bash
# Fixture provenance marker for the dynamic haptics maintainer-script helper.
haptics_validate_kernel_release() { :; }
haptics_render_maintainer_template() { :; }
haptics_write_maintainer_scripts() { :; }
HAPTICS_MAINTAINER_TEMPLATE_DIR=$(dirname -- "${BASH_SOURCE[0]}")/haptics-control-templates
EOF_MAINTAINER_HELPER
  chmod 0644 "$builder_dir/haptics-maintainer-scripts.sh"
  for script in postinst prerm postrm; do
    cat > "$template_dir/$script.in" <<EOF_MAINTAINER_TEMPLATE
#!/bin/sh
set -eu
KERNEL_RELEASE=@KERNEL_RELEASE@
echo fixture-$script >/dev/null
EOF_MAINTAINER_TEMPLATE
    chmod 0644 "$template_dir/$script.in"
  done
  git -C "$producer_root" add .
  env \
    GIT_AUTHOR_DATE="@$epoch +0000" \
    GIT_COMMITTER_DATE="@$epoch +0000" \
    git -C "$producer_root" commit -q -m fixture
  haptics_commit=$(git -C "$producer_root" rev-parse HEAD)
  git -C "$producer_root" branch -f tb321fu-haptics-producer "$haptics_commit"

  producer_driver="$driver_dir/aw86937-y700.c"
  producer_ram="$firmware_dir/haptic_ram.bin"
  producer_click="$firmware_dir/haptic_click.bin"
  producer_helper="$helper_dir/y700-haptic-test.c"
  producer_builder="$builder_dir/build-tb321fu-haptics-deb.sh"
  producer_maintainer_helper="$builder_dir/haptics-maintainer-scripts.sh"
  producer_build_source="$tmp/producer-aw86937-haptics.c"
  cp "$producer_driver" "$producer_build_source"
  sed -i \
    -e 's/Lenovo Y700 AW86937 input force-feedback haptics driver/Lenovo TB321FU AW86937 input force-feedback haptics driver/g' \
    -e 's/\.name = "aw86937-y700"/.name = "aw86937-haptics"/g' \
    "$producer_build_source"
  sed -i '/{ "aw86937_y700" }/i\	{ "aw86937_haptics" },' "$producer_build_source"

  haptic_ram_sha=$(sha "$producer_ram")
  haptic_click_sha=$(sha "$producer_click")
  haptics_driver_sha=$(sha "$producer_driver")
  haptics_build_source_sha=$(sha "$producer_build_source")
  haptics_helper_source_sha=$(sha "$producer_helper")
  haptics_helper_binary="$tmp/haptics-helper-binary"
  write_fixture_aarch64_elf "$haptics_helper_binary"
  haptics_helper_binary_sha=$(sha "$haptics_helper_binary")
  tampered_haptics_helper_binary="$tmp/haptics-helper-binary-tampered"
  cp "$haptics_helper_binary" "$tampered_haptics_helper_binary"
  printf 'tamper' >> "$tampered_haptics_helper_binary"
  tampered_haptics_helper_binary_sha=$(sha "$tampered_haptics_helper_binary")
  haptics_module_sha=$(printf '%s SMP\n' "$release" | sha256sum | awk '{print $1}')
}

write_haptics_producer_bundle() {
  rm -f -- "$haptics_root/HAPTICS-PRODUCER.bundle"
  git -C "$producer_root" bundle create \
    "$haptics_root/HAPTICS-PRODUCER.bundle" \
    refs/heads/tb321fu-haptics-producer
  chmod 0644 "$haptics_root/HAPTICS-PRODUCER.bundle"
}

extract_fixture_heredoc() {
  python3 "$SCRIPT_DIR/extract-shell-heredoc.py" \
    "$producer_builder" "$1" "$2"
}

render_fixture_haptics_maintainer_template() {
  local template_name=$1 destination=$2 kernel_release=${3:-$release}
  local template="$producer_root/scripts/ci/haptics-control-templates/$template_name"

  sed "s/@KERNEL_RELEASE@/$kernel_release/g" "$template" > "$destination"
}

setup_haptics_producer
expected_haptics_module_sha=$haptics_module_sha
expected_haptics_helper_binary_sha=$haptics_helper_binary_sha

write_bundle() {
  local file=$1 source_epoch=$2 identity bundle_id
  identity="${file}.identity"
  {
    printf 'schema\ttb321fu.kernel-bundle/v2\n'
    printf 'kernel-source-commit\t%s\n' "$commit"
    printf 'kernel-release\t%s\n' "$release"
    printf 'kernel-config-sha256\t%s\n' "$config_sha"
    printf 'kernel-image-sha256\t%s\n' "$(sha "$kernel_root/Image")"
    printf 'kernel-dtb-name\tsm8650-lenovo-tb321fu.dtb\n'
    printf 'kernel-dtb-sha256\t%s\n' "$(sha "$kernel_root/sm8650-lenovo-tb321fu.dtb")"
    printf 'kernel-modules-deb-sha256\t%s\n' "$modules_deb_sha"
    printf 'kernel-modules-manifest-sha256\t%s\n' "$modules_manifest_sha"
    printf 'kernel-sdk-archive-sha256\t%s\n' "$sdk_archive_sha"
    printf 'kernel-sdk-manifest-sha256\t%s\n' "$sdk_manifest_sha"
    printf 'kernel-toolchain-manifest-sha256\t%s\n' "$toolchain_manifest_sha"
    printf 'kbuild-flags-sha256\t%s\n' "$kbuild_flags_manifest_sha"
    printf 'rustc-sha256\t%s\n' "$rustc_sha"
    printf 'rustc\t%s\n' "$rustc_version"
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

write_kernel_metadata_evidence() {
  local modules_deb="$device_root/y700-daily-kernel-modules_20260715.1_arm64.deb"
  local modules_tree="$tmp/modules-manifest"
  local tool label digest version

  config_sha=$(sha "$kernel_root/kernel.config")
  modules_deb_sha=$(sha "$modules_deb")
  rm -rf -- "$modules_tree"
  dpkg-deb --raw-extract "$modules_deb" "$modules_tree" >/dev/null
  (
    cd "$modules_tree"
    find ./usr/lib/modules -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --
  ) > "$tmp/MODULES.sha256"
  modules_manifest_file_count=$(wc -l < "$tmp/MODULES.sha256")
  modules_manifest_sha=$(sha "$tmp/MODULES.sha256")
  module_count=$(find "$modules_tree/usr/lib/modules" -type f -name '*.ko*' | wc -l)
  rm -rf -- "$modules_tree"

  printf 'fixture-sdk-archive\n' > "$tmp/kernel-sdk-fixture.tar.gz"
  sdk_archive_sha=$(sha "$tmp/kernel-sdk-fixture.tar.gz")
  {
    printf 'schema\ttb321fu.kernel-sdk-manifest/v1\n'
    printf 'file\t%s\t644\t./.config\n' "$config_sha"
    printf 'file\t%s\t644\t./Module.symvers\n' "$(printf 'a%.0s' {1..64})"
    printf 'file\t%s\t644\t./include/config/kernel.release\n' "$(printf 'b%.0s' {1..64})"
    printf 'file\t%s\t644\t./include/generated/autoconf.h\n' "$(printf 'c%.0s' {1..64})"
    printf 'file\t%s\t644\t./include/generated/utsrelease.h\n' "$(printf 'd%.0s' {1..64})"
  } > "$tmp/KERNEL-SDK-MANIFEST.tsv"
  sdk_manifest_sha=$(sha "$tmp/KERNEL-SDK-MANIFEST.tsv")

  rustc_sha=$(printf 'a%.0s' {1..64})
  rustc_version='fixture rustc 1.0'
  compiler_sha=$(printf '3%.0s' {1..64})
  compiler_version='fixture gcc 1.0'
  make_sha=$(printf 'b%.0s' {1..64})
  make_version='fixture make 1.0'
  dpkg_deb_sha=$(printf 'c%.0s' {1..64})
  dpkg_deb_version='fixture dpkg-deb 1.0'
  {
    printf 'schema\ttb321fu.kernel-toolchain/v2\n'
    printf 'cross-compile\t/usr/bin/aarch64-linux-gnu-\n'
    printf 'bison-data-directory\t/usr/share/bison\n'
    printf 'bison-data-sha256\t%s\n' "$(printf 'e%.0s' {1..64})"
    for tool in \
      gcc as ld ar nm objcopy objdump readelf strip rustc \
      host-gcc host-gxx host-as host-ld host-ar flex bison m4 \
      awk perl python3 pkg-config pahole git \
      make depmod modinfo tar gzip xz dpkg-deb fdtget bash sh bc getconf \
      sha1sum ln uname sha256sum find sort xargs rsync cp dpkg touch \
      realpath nproc date install stat grep sed readlink wc tr cut findmnt \
      curl flock mv chmod mkdir mktemp rm cat dirname basename env true \
      cmp head expr uniq; do
      case "$tool" in
        gcc) digest=$compiler_sha; version=$compiler_version ;;
        rustc) digest=$rustc_sha; version=$rustc_version ;;
        make) digest=$make_sha; version=$make_version ;;
        dpkg-deb) digest=$dpkg_deb_sha; version=$dpkg_deb_version ;;
        as) digest=$(printf '4%.0s' {1..64}); version='fixture as 1.0' ;;
        ld) digest=$(printf '5%.0s' {1..64}); version='fixture ld 1.0' ;;
        ar) digest=$(printf '6%.0s' {1..64}); version='fixture ar 1.0' ;;
        nm) digest=$(printf '7%.0s' {1..64}); version='fixture nm 1.0' ;;
        objcopy) digest=$(printf '8%.0s' {1..64}); version='fixture objcopy 1.0' ;;
        strip) digest=$(printf '9%.0s' {1..64}); version='fixture strip 1.0' ;;
        pahole) digest=unused; version=unused ;;
        *) digest=$(printf 'd%.0s' {1..64}); version="fixture $tool 1.0" ;;
      esac
      printf '%s-sha256\t%s\n' "$tool" "$digest"
      printf '%s-version\t%s\n' "$tool" "$version"
    done
  } > "$tmp/KERNEL-TOOLCHAIN.tsv"
  toolchain_manifest_sha=$(sha "$tmp/KERNEL-TOOLCHAIN.tsv")
  {
    printf 'schema\ttb321fu.kbuild-flags/v2\n'
    printf 'environment-policy\tisolated-allowlist-v1\n'
    printf 'path\tprivate-locked-tool-directory-v1\n'
    printf 'config-shell\tabsolute-locked-sh-v1\n'
    printf 'build-path-policy\tdeterministic-input-key-v1\n'
    printf 'lc-all\tC\n'
    printf 'lang\tC\n'
    printf 'tz\tUTC\n'
    printf 'arch\tarm64\n'
    printf 'cross-compile\t/usr/bin/aarch64-linux-gnu-\n'
    printf 'kconfig-notimestamp\t1\n'
    printf 'dtb-contract\ttb321fu-aw86937-dual-v1\n'
    printf 'depmod-config\tempty-private-v1\n'
    printf 'kcflags\tdebug-prefix-map-source-and-build-v1\n'
    printf 'kaflags\tdebug-prefix-map-source-and-build-v1\n'
    printf 'kcppflags\tunset\n'
    printf 'krustflags\tunset\n'
    printf 'kbuild-cflags\tunset\n'
    printf 'kbuild-aflags\tunset\n'
    printf 'kbuild-cppflags\tunset\n'
    printf 'kbuild-rustflags\tunset\n'
    printf 'cflags\tunset\n'
    printf 'cxxflags\tunset\n'
    printf 'cppflags\tunset\n'
    printf 'asflags\tunset\n'
    printf 'ldflags\tunset\n'
    printf 'cflags-kernel\tunset\n'
    printf 'cflags-module\tunset\n'
    printf 'aflags-kernel\tunset\n'
    printf 'aflags-module\tunset\n'
    printf 'ldflags-vmlinux\tunset\n'
    printf 'ldflags-module\tunset\n'
    printf 'hostcflags\tunset\n'
    printf 'hostcxxflags\tunset\n'
    printf 'hostldflags\tunset\n'
    printf 'usercflags\tunset\n'
    printf 'userldflags\tunset\n'
    for variable in \
      localversion dtc dtc-flags objcopyflags \
      host-extracflags host-extracxxflags host-extrarustflags hostldlibs \
      procmacroldflags kbuild-extra-warn kbuild-clippy kbuild-checksrc \
      kbuild-extmod-output kbuild-nocmddep kbuild-nsdeps kbuild-preserve \
      kbuild-symtypes kbuild-gendwarfksyms-stable kbuild-kconfig \
      kconfig-autoconfig kconfig-autoheader config-prefix \
      kconfig-defconfig-list kconfig-allconfig kconfig-overwriteconfig \
      kconfig-warn-unknown-symbols kconfig-werror kconfig-nosilentupdate \
      makefiles gnumakeflags makeflags mflags makeoverrides cpath \
      gcc-exec-prefix compiler-path library-path pkg-config-path \
      tar-options gzip-env xz-opt xz-defaults; do
      printf '%s\tunset\n' "$variable"
    done
    printf 'dpkg-deb-threads-max\t1\n'
    printf 'dpkg-deb-compressor-type\txz\n'
    printf 'dpkg-deb-compressor-level\t6\n'
    printf 'source-date-epoch\t%s\n' "$epoch"
    printf 'kbuild-build-timestamp\t2026-07-15 00:00:00 UTC\n'
    printf 'kbuild-build-user\ttb321fu-ci\n'
    printf 'kbuild-build-host\ttb321fu-builder\n'
    printf 'kbuild-build-version\t1\n'
  } > "$tmp/KBUILD-FLAGS.tsv"
  kbuild_flags_manifest_sha=$(sha "$tmp/KBUILD-FLAGS.tsv")

  for label in KERNEL-SDK-MANIFEST.tsv KERNEL-TOOLCHAIN.tsv KBUILD-FLAGS.tsv; do
    cp "$tmp/$label" "$kernel_root/$label"
    cp "$tmp/$label" "$device_root/$label"
    chmod 0644 "$kernel_root/$label" "$device_root/$label"
  done
  cp "$tmp/MODULES.sha256" "$kernel_root/MODULES.sha256"
  chmod 0644 "$kernel_root/MODULES.sha256"
}

write_sensor_fixture_payload() {
  local root=$1 package=$2 path index
  local -a libssc_headers=(
    libssc-sensor-accelerometer.h
    libssc-sensor-compass.h
    libssc-sensor-gyroscope.h
    libssc-sensor-light.h
    libssc-sensor-magnetometer.h
    libssc-sensor-proximity.h
    libssc-sensor.h
    libssc-version-private.h
    libssc.h
    ssc-common.pb-c.h
    ssc-sensor-accelerometer.pb-c.h
    ssc-sensor-gyroscope.pb-c.h
    ssc-sensor-light.pb-c.h
    ssc-sensor-magnetometer.pb-c.h
    ssc-sensor-proximity.pb-c.h
    ssc-sensor-rotationvector.pb-c.h
    ssc-sensor-suid.pb-c.h
  )

  case "$package" in
    qcom-sns-libssc)
      mkdir -p \
        "$root/usr/bin" \
        "$root/usr/include/libssc" \
        "$root/usr/lib/aarch64-linux-gnu/pkgconfig"
      write_fixture_aarch64_elf "$root/usr/bin/ssccli"
      write_fixture_aarch64_elf "$root/usr/lib/aarch64-linux-gnu/libssc.so.2"
      printf 'fixture libssc pc\n' > \
        "$root/usr/lib/aarch64-linux-gnu/pkgconfig/libssc.pc"
      chmod 0755 "$root/usr/bin/ssccli"
      for path in "${libssc_headers[@]}"; do
        printf 'fixture %s\n' "$path" > "$root/usr/include/libssc/$path"
      done
      ln -s libssc.so.2 "$root/usr/lib/aarch64-linux-gnu/libssc.so"
      ;;
    qcom-sns-hexagonrpc)
      mkdir -p "$root/usr/bin" "$root/usr/lib/aarch64-linux-gnu"
      write_fixture_aarch64_elf "$root/usr/bin/hexagonrpcd"
      write_fixture_aarch64_elf \
        "$root/usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4"
      chmod 0755 "$root/usr/bin/hexagonrpcd"
      ln -s libhexagonrpc.so.0.4 \
        "$root/usr/lib/aarch64-linux-gnu/libhexagonrpc.so"
      ;;
    qcom-sns-iio-sensor-proxy)
      mkdir -p "$root/usr/bin" "$root/usr/libexec"
      write_fixture_aarch64_elf "$root/usr/bin/monitor-sensor"
      write_fixture_aarch64_elf "$root/usr/libexec/iio-sensor-proxy"
      chmod 0755 "$root/usr/bin/monitor-sensor" "$root/usr/libexec/iio-sensor-proxy"
      install -D -m 0644 \
        "$SCRIPT_DIR/test-fixtures/sensor-runtime/iio-sensor-proxy.service" \
        "$root/usr/lib/systemd/system/iio-sensor-proxy.service"
      install -D -m 0644 \
        "$SCRIPT_DIR/test-fixtures/sensor-runtime/80-iio-sensor-proxy.rules" \
        "$root/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules"
      install -D -m 0644 \
        "$SCRIPT_DIR/test-fixtures/sensor-runtime/net.hadess.SensorProxy.service" \
        "$root/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service"
      install -D -m 0644 \
        "$SCRIPT_DIR/test-fixtures/sensor-runtime/net.hadess.SensorProxy.conf" \
        "$root/usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf"
      install -D -m 0644 \
        "$SCRIPT_DIR/test-fixtures/sensor-runtime/net.hadess.SensorProxy.policy" \
        "$root/usr/share/polkit-1/actions/net.hadess.SensorProxy.policy"
      ;;
    tb321fu-sensors)
      install -D -m 0644 \
        "$SCRIPT_DIR/payloads/99-qcom-sns.conf" \
        "$root/etc/systemd/system/iio-sensor-proxy.service.d/99-qcom-sns.conf"
      install -D -m 0644 \
        "$SCRIPT_DIR/payloads/qcom-sns-init.service" \
        "$root/usr/lib/systemd/system/qcom-sns-init.service"
      install -D -m 0644 \
        "$SCRIPT_DIR/payloads/80-tb321fu-qcom-sns.rules" \
        "$root/usr/lib/udev/rules.d/80-tb321fu-qcom-sns.rules"
      install -D -m 0644 \
        "$SCRIPT_DIR/test-fixtures/sensor-runtime/tb321fu.yaml" \
        "$root/usr/share/qcom/conf.d/tb321fu.yaml"
      install -D -m 0755 \
        "$SCRIPT_DIR/payloads/qcom-sns-resume" \
        "$root/usr/lib/systemd/system-sleep/qcom-sns-resume"
      install -D -m 0755 \
        "$SCRIPT_DIR/payloads/qcom-sns-init" \
        "$root/usr/libexec/qcom-sns/qcom-sns-init"
      mkdir -p \
        "$root/usr/share/qcom/sm8650/Lenovo/tb321fu/sensors/config" \
        "$root/usr/share/qcom/sm8650/Lenovo/tb321fu/sensors/registry" \
        "$root/usr/share/qcom/sm8650/Lenovo/tb321fu/.tb321fu-manifests"
      for index in {001..300}; do
        printf 'fixture device data %s\n' "$index" > \
          "$root/usr/share/qcom/sm8650/Lenovo/tb321fu/sensors/config/fixture-$index.json"
      done
      for index in {301..541}; do
        printf 'fixture device data %s\n' "$index" > \
          "$root/usr/share/qcom/sm8650/Lenovo/tb321fu/sensors/registry/fixture-$index"
      done
      (cd "$root/usr/share/qcom/sm8650/Lenovo/tb321fu" &&
        LC_ALL=C find sensors/config -type f -print0 |
          LC_ALL=C sort -z |
          xargs -0 -r sha256sum --) > \
        "$root/usr/share/qcom/sm8650/Lenovo/tb321fu/.tb321fu-manifests/config.sha256"
      (cd "$root/usr/share/qcom/sm8650/Lenovo/tb321fu" &&
        LC_ALL=C find sensors/registry -type f -print0 |
          LC_ALL=C sort -z |
          xargs -0 -r sha256sum --) > \
        "$root/usr/share/qcom/sm8650/Lenovo/tb321fu/.tb321fu-manifests/registry.sha256"
      ;;
    *) return 0 ;;
  esac

  case "$package" in
    qcom-sns-libssc|qcom-sns-hexagonrpc)
      cat > "$root/DEBIAN/postinst" <<'EOF_SENSOR_SCRIPT'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
exit 0
EOF_SENSOR_SCRIPT
      cp "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"
      ;;
    qcom-sns-iio-sensor-proxy)
      cat > "$root/DEBIAN/postinst" <<'EOF_SENSOR_SCRIPT'
#!/bin/sh
set -e
rm -f /etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf
rm -f /usr/local/libexec/y700-iio-sensor-proxy
rm -rf /usr/local/lib/y700-sns
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_SENSOR_SCRIPT
      cat > "$root/DEBIAN/postrm" <<'EOF_SENSOR_SCRIPT'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_SENSOR_SCRIPT
      ;;
    tb321fu-sensors)
      cat > "$root/DEBIAN/postinst" <<'EOF_SENSOR_SCRIPT'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop y700-sns-init.service >/dev/null 2>&1 || true
  systemctl disable y700-sns-init.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/iio-sensor-proxy.service.d/10-y700-ssc.conf
  rm -f /etc/systemd/system/y700-sns-init.service
  rm -f /usr/local/libexec/y700-iio-sensor-proxy
  rm -rf /usr/local/lib/y700-sns
  systemctl daemon-reload || true
  systemctl enable qcom-sns-init.service >/dev/null
  systemctl is-enabled --quiet qcom-sns-init.service
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_SENSOR_SCRIPT
      cat > "$root/DEBIAN/postrm" <<'EOF_SENSOR_SCRIPT'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules || true
fi
exit 0
EOF_SENSOR_SCRIPT
      cat > "$root/DEBIAN/prerm" <<'EOF_SENSOR_SCRIPT'
#!/bin/sh
set -e
case "${1:-}" in
  remove|deconfigure)
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop qcom-sns-init.service >/dev/null 2>&1 || true
      systemctl disable qcom-sns-init.service >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/multi-user.target.wants/qcom-sns-init.service
    ;;
esac
exit 0
EOF_SENSOR_SCRIPT
      chmod 0755 "$root/DEBIAN/prerm"
      ;;
  esac
  chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"
}

make_deb() {
  local package=$1 destination=$2 module_path=${3:-} vermagic=${4:-}
  local module_mode=${5:-0644} package_version=${6:-20260715.1}
  local root="$tmp/pkg-$package"
  rm -rf -- "$root"
  mkdir -p "$root/DEBIAN"
  cat > "$root/DEBIAN/control" <<EOF
Package: $package
Version: $package_version
Section: misc
Priority: optional
Architecture: arm64
Maintainer: TB321FU fixture <noreply@localhost>
Description: Small kernel bundle verifier fixture.
EOF
  case "$package" in
    qcom-sns-libssc)
      cat > "$root/DEBIAN/control" <<EOF_SENSOR_CONTROL
Package: qcom-sns-libssc
Version: $package_version
Section: libs
Priority: optional
Architecture: arm64
Maintainer: GUF296 <guf296@users.noreply.github.com>
Provides: libssc
Depends: libc6, libglib2.0-0, libprotobuf-c1, libqmi-glib5
Description: Qualcomm SSC userspace library
 Source-built libssc and ssccli for Qualcomm Sensor Core devices.
EOF_SENSOR_CONTROL
      ;;
    qcom-sns-hexagonrpc)
      cat > "$root/DEBIAN/control" <<EOF_SENSOR_CONTROL
Package: qcom-sns-hexagonrpc
Version: $package_version
Section: libs
Priority: optional
Architecture: arm64
Maintainer: GUF296 <guf296@users.noreply.github.com>
Provides: hexagonrpcd
Depends: libc6
Description: Qualcomm HexagonRPC userspace daemon
 Source-built hexagonrpcd with generic qcom-sns persistent registry mapping.
EOF_SENSOR_CONTROL
      ;;
    qcom-sns-iio-sensor-proxy)
      cat > "$root/DEBIAN/control" <<EOF_SENSOR_CONTROL
Package: qcom-sns-iio-sensor-proxy
Version: $package_version
Section: misc
Priority: optional
Architecture: arm64
Maintainer: GUF296 <guf296@users.noreply.github.com>
Provides: iio-sensor-proxy
Depends: libc6, dbus, libglib2.0-0, libgudev-1.0-0, libpolkit-gobject-1-0, qcom-sns-libssc
Conflicts: iio-sensor-proxy
Replaces: iio-sensor-proxy
Description: IIO Sensor Proxy with Qualcomm SSC support
 Source-built iio-sensor-proxy with Qualcomm SSC drivers enabled.
EOF_SENSOR_CONTROL
      ;;
    tb321fu-sensors)
      cat > "$root/DEBIAN/control" <<EOF_SENSOR_CONTROL
Package: tb321fu-sensors
Version: $package_version
Section: misc
Priority: optional
Architecture: arm64
Maintainer: GUF296 <guf296@users.noreply.github.com>
Conflicts: y700-sensors
Replaces: y700-sensors
Depends: qcom-sns-hexagonrpc, qcom-sns-iio-sensor-proxy, qcom-sns-libssc, systemd, coreutils, findutils, util-linux
Description: Sensor files for Lenovo Legion Y700 TB321FU
 Verified TB321FU Qualcomm SNS device data and cold-boot initialization glue.
EOF_SENSOR_CONTROL
      ;;
  esac
  if [ -n "$module_path" ]; then
    mkdir -p "$root/$(dirname -- "$module_path")"
    printf '%s SMP\n' "$vermagic" > "$root/$module_path"
    chmod "$module_mode" "$root/$module_path"
  fi
  write_sensor_fixture_payload "$root" "$package"
  if [ "$package" = y700-daily-kernel-modules ]; then
    cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
depmod '7.1.1-g111111111111'
EOF
    chmod 0755 "$root/DEBIAN/postinst"
  fi
  if [ "$package" = tb321fu-haptics ]; then
    cat > "$root/DEBIAN/control" <<EOF
Package: tb321fu-haptics
Version: $package_version
Section: misc
Priority: optional
Architecture: arm64
Maintainer: GUF296 <guf296@users.noreply.github.com>
Depends: kmod, systemd, udev, coreutils, findutils, feedbackd, feedbackd-device-themes
Conflicts: y700-haptics
Replaces: y700-haptics
Description: AW86937 haptics support for Lenovo Legion Y700 TB321FU
 Source-built AW86937 force-feedback haptics module, firmware, feedbackd udev
 integration and TB321FU boot-time binding glue.
EOF
    mkdir -p \
      "$root/etc/skel/.config" \
      "$root/usr/lib/firmware" \
      "$root/usr/lib/systemd/system" \
      "$root/usr/lib/udev/rules.d" \
      "$root/usr/libexec/tb321fu-haptics" \
      "$root/usr/bin"
    printf '%s' "$haptic_ram_payload" > "$root/usr/lib/firmware/haptic_ram.bin"
    printf '%s' "$haptic_click_payload" > "$root/usr/lib/firmware/haptic_click.bin"
    cp "$haptics_helper_binary" "$root/usr/bin/tb321fu-haptic-test"
    render_fixture_haptics_maintainer_template postinst.in "$root/DEBIAN/postinst"
    render_fixture_haptics_maintainer_template prerm.in "$root/DEBIAN/prerm"
    render_fixture_haptics_maintainer_template postrm.in "$root/DEBIAN/postrm"
    extract_fixture_heredoc EOF_BIND "$root/usr/libexec/tb321fu-haptics/bind-aw86937"
    extract_fixture_heredoc EOF_SERVICE "$root/usr/lib/systemd/system/tb321fu-haptics.service"
    extract_fixture_heredoc EOF_UDEV "$root/usr/lib/udev/rules.d/90-tb321fu-haptics.rules"
    extract_fixture_heredoc EOF_CONF "$root/etc/skel/.config/plasmakeyboardrc"
    chmod 0644 "$root/usr/lib/firmware/haptic_ram.bin" \
      "$root/usr/lib/firmware/haptic_click.bin" \
      "$root/usr/lib/systemd/system/tb321fu-haptics.service" \
      "$root/usr/lib/udev/rules.d/90-tb321fu-haptics.rules" \
      "$root/etc/skel/.config/plasmakeyboardrc"
    chmod 0755 \
      "$root/DEBIAN/postinst" \
      "$root/DEBIAN/prerm" \
      "$root/DEBIAN/postrm" \
      "$root/usr/bin/tb321fu-haptic-test" \
      "$root/usr/libexec/tb321fu-haptics/bind-aw86937"
  fi
  find "$root" -type d -exec chmod 0755 {} +
  find "$root" -exec touch -h -d "@$epoch" {} +
  SOURCE_DATE_EPOCH=$epoch \
    dpkg-deb --root-owner-group -Zxz -b "$root" "$destination" >/dev/null
}

mutate_haptics_deb() {
  local mutation=$1
  local deb="$haptics_root/tb321fu-haptics_20260715.1_arm64.deb"
  local root="$tmp/haptics-deb-mutation"

  rm -rf -- "$root"
  dpkg-deb --raw-extract "$deb" "$root" >/dev/null
  "$mutation" "$root"
  find "$root" -exec touch -h -d "@$epoch" {} +
  SOURCE_DATE_EPOCH=$epoch \
    dpkg-deb --root-owner-group -Zxz -b "$root" "$deb" >/dev/null
}

mutate_sensor_deb() {
  local package=$1 mutation=$2
  local deb="$sensor_root/${package}_20260715.1_arm64.deb"
  local root="$tmp/sensor-deb-mutation-$package"

  rm -rf -- "$root"
  dpkg-deb --raw-extract "$deb" "$root" >/dev/null
  "$mutation" "$root"
  find "$root" -exec touch -h -d "@$epoch" {} +
  SOURCE_DATE_EPOCH=$epoch \
    dpkg-deb --root-owner-group -Zxz -b "$root" "$deb" >/dev/null
}

remove_sensor_device_file() {
  rm -f -- \
    "$1/usr/share/qcom/sm8650/Lenovo/tb321fu/sensors/config/fixture-001.json"
}

tamper_sensor_device_file() {
  printf 'tampered device data\n' > \
    "$1/usr/share/qcom/sm8650/Lenovo/tb321fu/sensors/config/fixture-001.json"
}

tamper_sensor_runtime_helper() {
  printf '\n# unexpected root action\n' >> \
    "$1/usr/libexec/qcom-sns/qcom-sns-init"
}

tamper_sensor_dbus_policy() {
  printf '\n<!-- unexpected policy -->\n' >> \
    "$1/usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf"
}

remove_sensor_compiled_binary() {
  rm -f -- "$1/usr/bin/ssccli"
}

truncate_sensor_elf() {
  truncate -s 20 "$1/usr/bin/ssccli"
}

remove_sensor_elf_load_segment() {
  printf '\000\000\000\000' | dd of="$1/usr/bin/ssccli" bs=1 seek=64 conv=notrunc status=none
}

remove_sensor_maintainer_script() {
  rm -f -- "$1/DEBIAN/postinst"
}

tamper_sensor_maintainer_script() {
  printf '\n# unexpected maintainer action\n' >> "$1/DEBIAN/postinst"
}

add_sensor_dependency_continuation() {
  sed -i '/^Depends:/a\ , malicious-package' "$1/DEBIAN/control"
}

add_sensor_relationship_field() {
  printf 'Pre-Depends: malicious-package\n' >> "$1/DEBIAN/control"
}

move_haptics_ram() {
  local root=$1
  mkdir -p "$root/usr/share/tb321fu-haptics"
  mv "$root/usr/lib/firmware/haptic_ram.bin" \
    "$root/usr/share/tb321fu-haptics/haptic_ram.bin"
}

mode_haptics_ram() {
  chmod 0600 "$1/usr/lib/firmware/haptic_ram.bin"
}

tamper_haptics_module() {
  printf 'tamper' >> "$1/usr/lib/modules/$release/extra/aw86937-haptics.ko"
}

move_haptics_module() {
  local root=$1
  mkdir -p "$root/usr/lib/modules/$release/updates"
  mv "$root/usr/lib/modules/$release/extra/aw86937-haptics.ko" \
    "$root/usr/lib/modules/$release/updates/aw86937-haptics.ko"
}

mode_haptics_module() {
  chmod 0600 "$1/usr/lib/modules/$release/extra/aw86937-haptics.ko"
}

remove_haptics_helper() {
  rm -f -- "$1/usr/bin/tb321fu-haptic-test"
}

move_haptics_helper() {
  local root=$1
  mkdir -p "$root/usr/libexec/tb321fu-haptics"
  mv "$root/usr/bin/tb321fu-haptic-test" \
    "$root/usr/libexec/tb321fu-haptics/tb321fu-haptic-test"
}

tamper_haptics_helper() {
  printf 'tamper' >> "$1/usr/bin/tb321fu-haptic-test"
  chmod 0755 "$1/usr/bin/tb321fu-haptic-test"
}

truncate_haptics_helper() {
  truncate -s 20 "$1/usr/bin/tb321fu-haptic-test"
}

mode_haptics_helper() {
  chmod 0644 "$1/usr/bin/tb321fu-haptic-test"
}

tamper_haptics_postinst() {
  printf '#!/bin/sh\nset -e\necho malicious-postinst\n' > "$1/DEBIAN/postinst"
  chmod 0755 "$1/DEBIAN/postinst"
}

mismatched_haptics_postinst_release() {
  render_fixture_haptics_maintainer_template \
    postinst.in "$1/DEBIAN/postinst" "${release}-mismatched"
  chmod 0755 "$1/DEBIAN/postinst"
}

mismatched_haptics_prerm_release() {
  render_fixture_haptics_maintainer_template \
    prerm.in "$1/DEBIAN/prerm" "${release}-mismatched"
  chmod 0755 "$1/DEBIAN/prerm"
}

mismatched_haptics_postrm_release() {
  render_fixture_haptics_maintainer_template \
    postrm.in "$1/DEBIAN/postrm" "${release}-mismatched"
  chmod 0755 "$1/DEBIAN/postrm"
}

tamper_haptics_control() {
  sed -i 's/^Depends:.*/Depends: bash/' "$1/DEBIAN/control"
}

tamper_haptics_bind() {
  printf '#!/bin/sh\necho tampered-bind\n' > \
    "$1/usr/libexec/tb321fu-haptics/bind-aw86937"
  chmod 0755 "$1/usr/libexec/tb321fu-haptics/bind-aw86937"
}

tamper_haptics_service() {
  printf '[Service]\nExecStart=/bin/false\n' > \
    "$1/usr/lib/systemd/system/tb321fu-haptics.service"
}

tamper_haptics_udev() {
  printf 'SUBSYSTEM=="input", MODE="0777"\n' > \
    "$1/usr/lib/udev/rules.d/90-tb321fu-haptics.rules"
}

tamper_haptics_config() {
  printf '[General]\nvibrationEnabled=false\n' > \
    "$1/etc/skel/.config/plasmakeyboardrc"
}

add_haptics_extra_file() {
  mkdir -p "$1/usr/share/tb321fu-haptics"
  printf 'unexpected' > "$1/usr/share/tb321fu-haptics/extra"
}

add_haptics_extra_symlink() {
  mkdir -p "$1/usr/share/tb321fu-haptics"
  ln -s ../../bin/tb321fu-haptic-test \
    "$1/usr/share/tb321fu-haptics/helper-link"
}

write_baseline_haptics_deb() {
  make_deb tb321fu-haptics \
    "$haptics_root/tb321fu-haptics_20260715.1_arm64.deb" \
    "usr/lib/modules/$release/extra/aw86937-haptics.ko" "$release"
}

write_haptics_build_tools_manifest() {
  local manifest="$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
  local records="$tmp/HAPTICS-BUILD-TOOLS.records"
  local name digest

  rm -f -- "$manifest" "$records"
  digest=$(printf 'd%.0s' {1..64})
  for name in "${haptics_build_tool_names[@]}"; do
    printf 'tool\t%s\t/usr/bin/%s\t%s\tfixture %s 1.0\n' \
      "$name" "$name" "$digest" "$name" >> "$records"
  done
  haptics_build_toolset_sha=$(sha "$records")
  {
    printf 'schema\ttb321fu.haptics-build-tools/v1\n'
    printf 'environment-policy\tisolated-allowlist-v1\n'
    printf 'environment-policy-sha256\t%s\n' "$haptics_environment_policy_sha"
    printf 'build-toolset-sha256\t%s\n' "$haptics_build_toolset_sha"
    cat "$records"
  } > "$manifest"
  chmod 0644 "$manifest"
  rm -f -- "$records"
}

write_haptics_lock() {
  local bundle_id=$1
  local producer_commit=${2:-$haptics_commit}
  local producer_state=${3:-clean}
  local build_tools_manifest_sha

  build_tools_manifest_sha=$(sha "$haptics_root/HAPTICS-BUILD-TOOLS.tsv")
  {
    printf 'schema\ttb321fu.haptics-source-lock/v3\n'
    printf 'haptics-output-mode\trelease-candidate\n'
    printf 'haptics-producer-commit\t%s\n' "$producer_commit"
    printf 'haptics-producer-state\t%s\n' "$producer_state"
    printf 'environment-policy\tisolated-allowlist-v1\n'
    printf 'environment-policy-sha256\t%s\n' "$haptics_environment_policy_sha"
    printf 'build-toolset-sha256\t%s\n' "$haptics_build_toolset_sha"
    printf 'build-tools-manifest\tHAPTICS-BUILD-TOOLS.tsv\n'
    printf 'build-tools-manifest-sha256\t%s\n' "$build_tools_manifest_sha"
    printf 'aw86937-driver-sha256\t%s\n' "$haptics_driver_sha"
    printf 'aw86937-build-source-sha256\t%s\n' "$haptics_build_source_sha"
    printf 'haptic-ram-firmware-sha256\t%s\n' "$haptic_ram_sha"
    printf 'haptic-click-firmware-sha256\t%s\n' "$haptic_click_sha"
    printf 'haptic-test-helper-sha256\t%s\n' "$haptics_helper_source_sha"
    printf 'aw86937-module-sha256\t%s\n' "$haptics_module_sha"
    printf 'haptic-test-helper-binary-sha256\t%s\n' "$haptics_helper_binary_sha"
    printf 'kernel-bundle-id\t%s\n' "$bundle_id"
    printf 'kernel-release\t%s\n' "$release"
    printf 'kernel-source-commit\t%s\n' "$commit"
    printf 'kernel-config-sha256\t%s\n' "$config_sha"
    printf 'kernel-build-input\tkernel-sdk-archive\n'
    printf 'kernel-build-archive-sha256\t%s\n' "$sdk_archive_sha"
    printf 'source-date-epoch\t%s\n' "$epoch"
  } > "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
}

write_haptics_snapshot() {
  local snapshot="$haptics_root/HAPTICS-SOURCE-SNAPSHOT"

  rm -rf -- "$snapshot"
  mkdir -p \
    "$snapshot/source/haptics/daily-current/linux/drivers/input/misc" \
    "$snapshot/build" \
    "$snapshot/source/haptics/rootfs-reference/usr/lib/firmware" \
    "$snapshot/source/haptics/baseline-20260614-daily-clean/testing-tools"
  cp "$producer_driver" \
    "$snapshot/source/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c"
  cp "$producer_build_source" "$snapshot/build/aw86937-haptics.c"
  cp "$producer_ram" \
    "$snapshot/source/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin"
  cp "$producer_click" \
    "$snapshot/source/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin"
  cp "$producer_helper" \
    "$snapshot/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c"
  find "$snapshot" -type d -exec chmod 0755 {} +
  find "$snapshot" -type f -exec chmod 0644 {} +
}

write_haptics_checksum_manifest() {
  local deb="$haptics_root/tb321fu-haptics_20260715.1_arm64.deb"

  (cd "$haptics_root" && sha256sum \
    ./"$(basename -- "$deb")" \
    ./HAPTICS-SOURCE-LOCK.tsv \
    ./HAPTICS-BUILD-TOOLS.tsv \
    ./HAPTICS-PRODUCER.bundle \
    ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c \
    ./HAPTICS-SOURCE-SNAPSHOT/build/aw86937-haptics.c \
    ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin \
    ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/rootfs-reference/usr/lib/firmware/haptic_click.bin \
    ./HAPTICS-SOURCE-SNAPSHOT/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c \
    > SHA256SUMS-tb321fu-haptics-debs.txt)
}

write_kernel_source_lock() {
  write_kernel_metadata_evidence
  write_bundle "$kernel_root/KERNEL-BUNDLE.tsv" "$epoch"
  kernel_bundle_id=$written_bundle_id
  write_bundle "$device_root/KERNEL-BUNDLE.tsv" "$epoch"
  [ "$kernel_bundle_id" = "$written_bundle_id" ] ||
    { printf 'fixture kernel bundle IDs diverged\n' >&2; exit 1; }
  {
    printf 'schema\ttb321fu.kernel-bootstrap/v3\n'
    printf 'kernel_bundle_id\t%s\n' "$kernel_bundle_id"
    printf 'kernel_commit\t%s\n' "$commit"
    printf 'kernel_release\t%s\n' "$release"
    printf 'source_date_epoch\t%s\n' "$epoch"
    printf 'config_sha256\t%s\n' "$config_sha"
    printf 'image_sha256\t%s\n' "$(sha "$kernel_root/Image")"
    printf 'dtb_name\tsm8650-lenovo-tb321fu.dtb\n'
    printf 'dtb_sha256\t%s\n' "$(sha "$kernel_root/sm8650-lenovo-tb321fu.dtb")"
    printf 'modules_deb_sha256\t%s\n' "$modules_deb_sha"
    printf 'modules_manifest_sha256\t%s\n' "$modules_manifest_sha"
    printf 'modules_manifest_file_count\t%s\n' "$modules_manifest_file_count"
    printf 'kernel_sdk_archive_sha256\t%s\n' "$sdk_archive_sha"
    printf 'kernel_sdk_manifest_sha256\t%s\n' "$sdk_manifest_sha"
    printf 'kernel_toolchain_manifest_sha256\t%s\n' "$toolchain_manifest_sha"
    printf 'kbuild_flags_sha256\t%s\n' "$kbuild_flags_manifest_sha"
    printf 'baseline_archive_sha256\t%s\n' "$(printf 'd%.0s' {1..64})"
    printf 'baseline_rootfs_sha256\t%s\n' "$(sha "$device_root/y700-daily-rootfs-overlay_20260715.1_arm64.deb")"
    printf 'baseline_compat_sha256\t%s\n' "$(sha "$device_root/y700-compat1-extra-rootfs-overlay.tar.gz")"
    printf 'producer_repository\t%s\n' "$kernel_producer_repository"
    printf 'producer_commit\t%s\n' "$commit"
    printf 'producer_tree\t%s\n' "$kernel_producer_tree"
    printf 'producer_tree_sha256\t%s\n' "$kernel_producer_tree_sha256"
    printf 'producer_state\tclean\n'
    printf 'packager_sha256\t%s\n' "$(printf 'e%.0s' {1..64})"
    printf 'common_sh_sha256\t%s\n' "$(printf 'f%.0s' {1..64})"
    printf 'compiler_sha256\t%s\n' "$compiler_sha"
    printf 'compiler\t%s\n' "$compiler_version"
    printf 'rustc_sha256\t%s\n' "$rustc_sha"
    printf 'rustc\t%s\n' "$rustc_version"
    printf 'kbuild_build_timestamp\t2026-07-15 00:00:00 UTC\n'
    printf 'kbuild_build_user\ttb321fu-ci\n'
    printf 'kbuild_build_host\ttb321fu-builder\n'
    printf 'kbuild_build_version\t1\n'
    printf 'make_sha256\t%s\n' "$make_sha"
    printf 'make\t%s\n' "$make_version"
    printf 'dpkg_deb_sha256\t%s\n' "$dpkg_deb_sha"
    printf 'dpkg_deb\t%s\n' "$dpkg_deb_version"
    printf 'module_count\t%s\n' "$module_count"
  } > "$kernel_root/SOURCE-LOCK.tsv"
  cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
  chmod 0644 "$kernel_root/KERNEL-BUNDLE.tsv" "$device_root/KERNEL-BUNDLE.tsv" \
    "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
}

write_sensor_metadata() {
  local fixture_device_root="$tmp/pkg-tb321fu-sensors/usr/share/qcom/sm8650/Lenovo/tb321fu"

  (cd "$fixture_device_root" &&
    LC_ALL=C find . -type f ! -path './.tb321fu-manifests/*' -print0 |
      LC_ALL=C sort -z |
      xargs -0 -r sha256sum --) > "$sensor_root/DEVICE-DATA.sha256"
  {
    printf 'component\trepository\tcommit\n'
    printf 'sensor-producer\thttps://github.com/GUF296/tb321fu-sensor-debs\t%s\n' "$sensor_commit"
    printf 'libssc\thttps://github.com/GUF296/libssc.git\tb7719402d5d45f64d8ac533ff02698fdd84e1edc\n'
    printf 'iio-sensor-proxy\thttps://github.com/GUF296/iio-sensor-proxy.git\t4054d61222b473c1b172a04faf0677845201ec7f\n'
    printf 'hexagonrpc\thttps://github.com/GUF296/hexagonrpc.git\t86d7a139ef35bb2e62ea13bd7b166a1ec08a4b97\n'
    printf 'device-data-manifest\tlocal-tree\t%s\n' "$(sha "$sensor_root/DEVICE-DATA.sha256")"
    printf 'producer-state\tgit-status\tclean\n'
  } > "$sensor_root/SOURCE-LOCK.tsv"
  (cd "$sensor_root" && sha256sum ./*.deb > SHA256SUMS-y700-sensor-debs.txt)
}

refresh_sensor_device_data_lock() {
  sed -i \
    "s/^device-data-manifest\tlocal-tree\t[0-9a-f]\{64\}$/device-data-manifest\tlocal-tree\t$(sha "$sensor_root/DEVICE-DATA.sha256")/" \
    "$sensor_root/SOURCE-LOCK.tsv"
}

pack_archives_raw() {
  tar -C "$kernel_root" -czf "$tmp/kernel.tar.gz" .
  tar -C "$device_root" -czf "$tmp/device.tar.gz" .
  tar -C "$sensor_root" -czf "$tmp/sensor.tar.gz" .
  tar -C "$haptics_root" -czf "$tmp/haptics.tar.gz" .
}

pack_archives() {
  write_haptics_checksum_manifest
  pack_archives_raw
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
    EXPECTED_SENSOR_PRODUCER_COMMIT="$sensor_commit" \
    HAPTICS_DEB_ARCHIVE="$tmp/haptics.tar.gz" \
    HAPTICS_DEB_ARCHIVE_SHA256="$(sha "$tmp/haptics.tar.gz")" \
    EXPECTED_HAPTICS_PRODUCER_COMMIT="$haptics_commit" \
    EXPECTED_HAPTICS_MODULE_SHA256="$expected_haptics_module_sha" \
    EXPECTED_HAPTICS_HELPER_BINARY_SHA256="$expected_haptics_helper_binary_sha" \
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
make_deb y700-daily-rootfs-overlay \
  "$device_root/y700-daily-rootfs-overlay_20260715.1_arm64.deb"
printf 'fixture compat overlay\n' > "$device_root/y700-compat1-extra-rootfs-overlay.tar.gz"
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
write_haptics_snapshot
write_haptics_build_tools_manifest
write_haptics_lock "$kernel_bundle_id"
write_haptics_producer_bundle
pack_archives

run_verifier success >/dev/null
success_dir="$tmp/tb321fu-verified-kernel-bundle-success"
grep -Fq "SENSOR_DEB_ARCHIVE=$success_dir/sensor-debs.archive" \
  "$success_dir/verified.env"
cmp -s "$tmp/sensor.tar.gz" "$success_dir/sensor-debs.archive"
grep -Fxq $'schema\ttb321fu.verified-inputs/v1' "$success_dir/VERIFIED-INPUTS.tsv"
grep -Fxq $'sensor-producer-commit\t'"$sensor_commit" \
  "$success_dir/VERIFIED-INPUTS.tsv"
grep -Fxq $'haptics-producer-commit\t'"$haptics_commit" \
  "$success_dir/VERIFIED-INPUTS.tsv"
grep -Fxq $'haptics-module-sha256\t'"$expected_haptics_module_sha" \
  "$success_dir/VERIFIED-INPUTS.tsv"
grep -Fxq $'haptics-helper-binary-sha256\t'"$expected_haptics_helper_binary_sha" \
  "$success_dir/VERIFIED-INPUTS.tsv"
cmp -s "$haptics_root/HAPTICS-BUILD-TOOLS.tsv" \
  "$success_dir/HAPTICS-BUILD-TOOLS.tsv"
grep -Fxq $'schema\ttb321fu.haptics-build-tools/v1' \
  "$success_dir/HAPTICS-BUILD-TOOLS.tsv"
grep -Fxq $'producer_repository\t'"$kernel_producer_repository" \
  "$success_dir/KERNEL-SOURCE-LOCK.tsv"
grep -Fxq $'producer_tree\t'"$kernel_producer_tree" \
  "$success_dir/KERNEL-SOURCE-LOCK.tsv"
grep -Fxq $'producer_tree_sha256\t'"$kernel_producer_tree_sha256" \
  "$success_dir/KERNEL-SOURCE-LOCK.tsv"

make_deb tb321fu-sensors \
  "$device_root/tb321fu-sensors_injected_arm64.deb"
pack_archives
require_failure device-reserved-sensor-package \
  'device archive contains reserved component package: tb321fu-sensors'
rm -f -- "$device_root/tb321fu-sensors_injected_arm64.deb"
pack_archives

make_deb tb321fu-sensors "$device_root/reserved-sensor-payload.bin"
ln -s reserved-sensor-payload.bin "$device_root/reserved-sensor-link.deb"
pack_archives
require_failure device-symlinked-reserved-package \
  'device archive contains a non-regular DEB path'
rm -f -- \
  "$device_root/reserved-sensor-link.deb" \
  "$device_root/reserved-sensor-payload.bin"
pack_archives

for package in \
  qcom-sns-libssc qcom-sns-hexagonrpc qcom-sns-iio-sensor-proxy tb321fu-sensors; do
  rm -f -- "$sensor_root/${package}_20260715.1_arm64.deb"
  make_deb "$package" "$sensor_root/${package}_20260715.1~rc1_arm64.deb" \
    '' '' 0644 '20260715.1~rc1'
done
write_sensor_metadata
pack_archives
run_verifier sensor-tilde-version >/dev/null
grep -Fxq $'sensor-package-version\t20260715.1~rc1' \
  "$tmp/tb321fu-verified-kernel-bundle-sensor-tilde-version/VERIFIED-BUNDLE.tsv"
for package in \
  qcom-sns-libssc qcom-sns-hexagonrpc qcom-sns-iio-sensor-proxy tb321fu-sensors; do
  rm -f -- "$sensor_root/${package}_20260715.1~rc1_arm64.deb"
  make_deb "$package" "$sensor_root/${package}_20260715.1_arm64.deb"
done
write_sensor_metadata
pack_archives

export GIT_DIR="$tmp/hostile-git-dir"
export GIT_OBJECT_DIRECTORY="$tmp/hostile-git-objects"
export GIT_NAMESPACE=hostile
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0="$tmp/hostile-hooks"
run_verifier hostile-git-environment >/dev/null
unset GIT_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE GIT_CONFIG_COUNT \
  GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

sed -i "s/^sensor-producer\t\([^\t]*\)\t$sensor_commit$/sensor-producer\t\1\t9999999999999999999999999999999999999999/" \
  "$sensor_root/SOURCE-LOCK.tsv"
pack_archives
require_failure sensor-producer-mismatch 'sensor producer commit mismatch'
write_sensor_metadata
pack_archives

printf '\0' >> "$sensor_root/SOURCE-LOCK.tsv"
pack_archives
require_failure sensor-lock-nul 'sensor source lock contains NUL'
write_sensor_metadata

printf '\0' >> "$sensor_root/DEVICE-DATA.sha256"
refresh_sensor_device_data_lock
pack_archives
require_failure sensor-device-data-nul 'device-data manifest contains NUL'
write_sensor_metadata

printf '\0' >> "$sensor_root/SHA256SUMS-y700-sensor-debs.txt"
pack_archives
require_failure sensor-checksum-nul 'sensor checksum manifest contains NUL'
write_sensor_metadata
pack_archives

mutate_sensor_deb tb321fu-sensors remove_sensor_device_file
write_sensor_metadata
pack_archives
require_failure sensor-device-file-missing \
  'tb321fu-sensors data tar member set mismatch'
make_deb tb321fu-sensors "$sensor_root/tb321fu-sensors_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb tb321fu-sensors tamper_sensor_device_file
write_sensor_metadata
pack_archives
require_failure sensor-device-file-tampered 'device-data checksum mismatch'
make_deb tb321fu-sensors "$sensor_root/tb321fu-sensors_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb tb321fu-sensors tamper_sensor_runtime_helper
write_sensor_metadata
pack_archives
require_failure sensor-runtime-helper-tampered \
  'tb321fu-sensors runtime payload digest mismatch: usr/libexec/qcom-sns/qcom-sns-init'
make_deb tb321fu-sensors "$sensor_root/tb321fu-sensors_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb qcom-sns-iio-sensor-proxy tamper_sensor_dbus_policy
write_sensor_metadata
pack_archives
require_failure sensor-dbus-policy-tampered \
  'qcom-sns-iio-sensor-proxy runtime payload digest mismatch: usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf'
make_deb qcom-sns-iio-sensor-proxy \
  "$sensor_root/qcom-sns-iio-sensor-proxy_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb qcom-sns-libssc remove_sensor_compiled_binary
write_sensor_metadata
pack_archives
require_failure sensor-compiled-binary-missing \
  'qcom-sns-libssc data tar member set mismatch'
make_deb qcom-sns-libssc "$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb qcom-sns-libssc truncate_sensor_elf
write_sensor_metadata
pack_archives
require_failure sensor-elf-truncated \
  'qcom-sns-libssc payload is not AArch64 ELF: usr/bin/ssccli'
make_deb qcom-sns-libssc "$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb qcom-sns-libssc remove_sensor_elf_load_segment
write_sensor_metadata
pack_archives
require_failure sensor-elf-no-load-segment \
  'qcom-sns-libssc payload has no ELF load segment: usr/bin/ssccli'
make_deb qcom-sns-libssc "$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb qcom-sns-libssc remove_sensor_maintainer_script
write_sensor_metadata
pack_archives
require_failure sensor-maintainer-missing \
  'qcom-sns-libssc control tar member set mismatch'
make_deb qcom-sns-libssc "$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
write_sensor_metadata
pack_archives

mutate_sensor_deb qcom-sns-libssc tamper_sensor_maintainer_script
write_sensor_metadata
pack_archives
require_failure sensor-maintainer-tampered \
  'qcom-sns-libssc maintainer script digest mismatch: postinst'
make_deb qcom-sns-libssc "$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb qcom-sns-libssc add_sensor_dependency_continuation
write_sensor_metadata
pack_archives
require_failure sensor-dependency-continuation \
  'qcom-sns-libssc control has an unexpected continuation: Depends'
make_deb qcom-sns-libssc "$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
write_sensor_metadata

mutate_sensor_deb qcom-sns-libssc add_sensor_relationship_field
write_sensor_metadata
pack_archives
require_failure sensor-extra-relationship \
  'qcom-sns-libssc control field set mismatch'
make_deb qcom-sns-libssc "$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
write_sensor_metadata
pack_archives

printf 'unexpected\n' > "$sensor_root/EXTRA"
pack_archives
require_failure sensor-extra-member 'sensor archive must contain exactly seven root members'
rm -f -- "$sensor_root/EXTRA"

chmod 0600 "$sensor_root/DEVICE-DATA.sha256"
pack_archives
require_failure sensor-wrong-root-mode 'sensor archive member is not mode 0644'
chmod 0644 "$sensor_root/DEVICE-DATA.sha256"

sensor_deb="$sensor_root/qcom-sns-libssc_20260715.1_arm64.deb"
mv "$sensor_deb" "$sensor_root/renamed-sensor.deb"
pack_archives
require_failure sensor-wrong-deb-filename \
  'qcom-sns-libssc sensor DEB must occur exactly once'
mv "$sensor_root/renamed-sensor.deb" "$sensor_deb"

make_deb qcom-sns-libssc "$sensor_deb" '' '' 0644 '1:20260715.1'
pack_archives
require_failure sensor-unsafe-version 'qcom-sns-libssc control version is unsafe'
make_deb qcom-sns-libssc "$sensor_deb"
write_sensor_metadata

printf 'tampered\n' >> "$sensor_root/DEVICE-DATA.sha256"
pack_archives
require_failure sensor-device-data-mismatch 'device-data manifest has a malformed record'
write_sensor_metadata

printf '%s  ./../escape\n' "$(printf '0%.0s' {1..64})" > "$sensor_root/DEVICE-DATA.sha256"
refresh_sensor_device_data_lock
pack_archives
require_failure sensor-device-data-path 'device-data manifest has an unsafe path'
write_sensor_metadata

printf '%s  .//sensors/noncanonical.json\n' "$(printf '0%.0s' {1..64})" > \
  "$sensor_root/DEVICE-DATA.sha256"
refresh_sensor_device_data_lock
pack_archives
require_failure sensor-device-data-noncanonical 'device-data manifest has an unsafe path'
write_sensor_metadata

printf '%s  ./sensors/config/\n' "$(printf '0%.0s' {1..64})" > \
  "$sensor_root/DEVICE-DATA.sha256"
refresh_sensor_device_data_lock
pack_archives
require_failure sensor-device-data-trailing-slash 'device-data manifest has an unsafe path'
write_sensor_metadata

{
  printf '%s  ./sensors/z.json\n' "$(printf '0%.0s' {1..64})"
  printf '%s  ./sensors/a.json\n' "$(printf '1%.0s' {1..64})"
} > "$sensor_root/DEVICE-DATA.sha256"
refresh_sensor_device_data_lock
pack_archives
require_failure sensor-device-data-order 'device-data manifest paths are not strictly ordered'
write_sensor_metadata

mapfile -t sensor_lock_lines < "$sensor_root/SOURCE-LOCK.tsv"
{
  printf '%s\n' "${sensor_lock_lines[0]}" "${sensor_lock_lines[2]}" "${sensor_lock_lines[1]}"
  printf '%s\n' "${sensor_lock_lines[@]:3}"
} > "$sensor_root/SOURCE-LOCK.tsv"
pack_archives
require_failure sensor-lock-order 'sensor source lock has unexpected record order'
write_sensor_metadata

sed -i '$d' "$sensor_root/SHA256SUMS-y700-sensor-debs.txt"
pack_archives
require_failure sensor-checksum-coverage 'sensor checksum manifest must contain exactly four records'
write_sensor_metadata

mapfile -t sensor_checksum_lines < "$sensor_root/SHA256SUMS-y700-sensor-debs.txt"
{
  printf '%s\n' "${sensor_checksum_lines[1]}" "${sensor_checksum_lines[0]}"
  printf '%s\n' "${sensor_checksum_lines[@]:2}"
} > "$sensor_root/SHA256SUMS-y700-sensor-debs.txt"
pack_archives
require_failure sensor-checksum-order 'sensor checksum manifest has unexpected DEB order or name'
write_sensor_metadata
pack_archives

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

printf '\0' >> "$kernel_root/SOURCE-LOCK.tsv"
printf '\0' >> "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-nul 'kernel bundle metadata contains NUL'
write_kernel_source_lock

mapfile -t kernel_lock_lines < "$kernel_root/SOURCE-LOCK.tsv"
{
  printf '%s\n' "${kernel_lock_lines[0]}" "${kernel_lock_lines[2]}" "${kernel_lock_lines[1]}"
  printf '%s\n' "${kernel_lock_lines[@]:3}"
} > "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-order 'unexpected TSV field order'
write_kernel_source_lock

printf 'unexpected_field\tvalue\n' >> "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-extra 'unexpected TSV field count'
write_kernel_source_lock

mapfile -t kernel_lock_lines < "$kernel_root/SOURCE-LOCK.tsv"
printf '%s\n' "${kernel_lock_lines[@]:0:${#kernel_lock_lines[@]}-1}" > "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-missing 'unexpected TSV field count'
write_kernel_source_lock

sed -i 's/^producer_state\tclean$/producer_state\tdirty/' "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-producer-state 'kernel source-lock producer state is not clean'
write_kernel_source_lock

sed -i 's|^producer_repository\t.*|producer_repository\tGUF296/untrusted-producer|' \
  "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-producer-repository 'invalid kernel source-lock producer repository'
write_kernel_source_lock

sed -i 's/^producer_tree\t.*/producer_tree\tAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' \
  "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-producer-tree 'invalid kernel source-lock producer tree'
write_kernel_source_lock

sed -i 's/^producer_tree_sha256\t.*/producer_tree_sha256\tCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/' \
  "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-producer-tree-sha256 'invalid kernel source-lock producer tree SHA-256'
write_kernel_source_lock

sed -i 's/^modules_manifest_file_count\t.*/modules_manifest_file_count\t0/' \
  "$kernel_root/SOURCE-LOCK.tsv"
cp "$kernel_root/SOURCE-LOCK.tsv" "$device_root/SOURCE-LOCK.tsv"
pack_archives
require_failure kernel-source-lock-manifest-count 'invalid kernel source-lock modules manifest file count'
write_kernel_source_lock

printf 'tampered manifest\n' >> "$kernel_root/MODULES.sha256"
pack_archives
require_failure kernel-modules-manifest-bytes 'kernel MODULES.sha256 SHA-256 mismatch'
write_kernel_source_lock

printf 'kcflags\t-hostile\n' >> "$kernel_root/KBUILD-FLAGS.tsv"
pack_archives
require_failure kernel-kbuild-flags-tamper 'kernel and device Kbuild flags differ'
write_kernel_source_lock

kernel_module_mutation="$tmp/kernel-module-vermagic-mutation"
dpkg-deb --raw-extract \
  "$device_root/y700-daily-kernel-modules_20260715.1_arm64.deb" \
  "$kernel_module_mutation" >/dev/null
printf '%s preempt SMP\n' "$release" > \
  "$kernel_module_mutation/usr/lib/modules/$release/kernel/fixture-extra.ko"
chmod 0644 \
  "$kernel_module_mutation/usr/lib/modules/$release/kernel/fixture-extra.ko"
find "$kernel_module_mutation" -exec touch -h -d "@$epoch" {} +
SOURCE_DATE_EPOCH=$epoch dpkg-deb --root-owner-group -Zxz -b \
  "$kernel_module_mutation" \
  "$device_root/y700-daily-kernel-modules_20260715.1_arm64.deb" >/dev/null
write_kernel_source_lock
pack_archives
require_failure kernel-module-vermagic-flags \
  'kernel module vermagic flags mismatch'
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

sed -i 's/^haptics-output-mode\trelease-candidate$/haptics-output-mode\tlocal/' \
  "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
pack_archives
require_failure haptics-local-output-mode 'haptics source lock is not a release candidate'
write_haptics_lock "$kernel_bundle_id"

sed -i 's/^kernel-build-input\tkernel-sdk-archive$/kernel-build-input\tlocal-directory/' \
  "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
pack_archives
require_failure haptics-local-kernel-input \
  'haptics kernel build input is not the verified SDK archive'
write_haptics_lock "$kernel_bundle_id"

sed -i "s/^kernel-build-archive-sha256.*/kernel-build-archive-sha256\\t$(printf '0%.0s' {1..64})/" \
  "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
pack_archives
require_failure haptics-sdk-archive-mismatch 'haptics kernel build archive SHA-256 mismatch'
write_haptics_lock "$kernel_bundle_id"

write_haptics_lock "$kernel_bundle_id" 3333333333333333333333333333333333333333
pack_archives
require_failure haptics-producer-mismatch 'haptics producer commit mismatch'
write_haptics_lock "$kernel_bundle_id" "$haptics_commit" dirty
pack_archives
require_failure haptics-producer-dirty 'haptics producer source lock is not clean'
write_haptics_lock "$kernel_bundle_id"

printf '\0' >> "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
pack_archives
require_failure haptics-lock-nul 'haptics source lock contains NUL'
write_haptics_lock "$kernel_bundle_id"

haptics_lock="$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
mapfile -t lock_lines < "$haptics_lock"
{
  printf '%s\n' "${lock_lines[1]}" "${lock_lines[0]}"
  printf '%s\n' "${lock_lines[@]:2}"
} > "$haptics_lock"
pack_archives
require_failure haptics-lock-reordered 'unexpected TSV field order'
write_haptics_lock "$kernel_bundle_id"

printf 'unexpected-field\tvalue\n' >> "$haptics_lock"
pack_archives
require_failure haptics-lock-extra 'unexpected TSV field count'
write_haptics_lock "$kernel_bundle_id"

mapfile -t lock_lines < "$haptics_lock"
printf '%s\n' "${lock_lines[@]:0:${#lock_lines[@]}-1}" > "$haptics_lock"
pack_archives
require_failure haptics-lock-missing 'unexpected TSV field count'
write_haptics_lock "$kernel_bundle_id"

sed -i "s/^source-date-epoch.*/source-date-epoch\t$((epoch + 1))/" "$haptics_lock"
pack_archives
require_failure haptics-source-date-mismatch 'haptics source-date-epoch mismatch'
write_haptics_lock "$kernel_bundle_id"

mv "$haptics_root/HAPTICS-BUILD-TOOLS.tsv" "$tmp/HAPTICS-BUILD-TOOLS.saved.tsv"
pack_archives_raw
require_failure haptics-build-tools-missing \
  'HAPTICS-BUILD-TOOLS.tsv must occur exactly once'
mv "$tmp/HAPTICS-BUILD-TOOLS.saved.tsv" "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"

chmod 0600 "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
pack_archives
require_failure haptics-build-tools-mode \
  'HAPTICS-BUILD-TOOLS.tsv must have mode 0644'
chmod 0644 "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"

mapfile -t haptics_build_tool_lines < "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
printf '%s\n' "${haptics_build_tool_lines[@]:0:${#haptics_build_tool_lines[@]}-1}" > \
  "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
pack_archives
require_failure haptics-build-tools-record-missing \
  'haptics build-tools manifest must contain exactly four headers and 64 tool records'
write_haptics_build_tools_manifest
write_haptics_lock "$kernel_bundle_id"

sed -i 's/fixture bash 1\.0/fixture bash 1.1/' \
  "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
forged_toolset_sha=$(tail -n +5 "$haptics_root/HAPTICS-BUILD-TOOLS.tsv" | sha256sum | awk '{print $1}')
sed -i \
  "s/^build-toolset-sha256.*/build-toolset-sha256\\t$forged_toolset_sha/" \
  "$haptics_root/HAPTICS-BUILD-TOOLS.tsv" \
  "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
pack_archives
require_failure haptics-build-tools-tamper \
  'haptics build-tools manifest SHA-256 mismatch'
write_haptics_build_tools_manifest
write_haptics_lock "$kernel_bundle_id"

sed -i $'s#tool\tbash\t/usr/bin/bash\t#tool\tbash\trelative/bash\t#' \
  "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
pack_archives
require_failure haptics-build-tools-path \
  'haptics build-tool path is outside the canonical producer PATH: bash'
write_haptics_build_tools_manifest
write_haptics_lock "$kernel_bundle_id"

invalid_haptics_tool_sha=$(printf 'z%.0s' {1..64})
valid_haptics_tool_sha=$(printf 'd%.0s' {1..64})
sed -i "5s/$valid_haptics_tool_sha/$invalid_haptics_tool_sha/" \
  "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
pack_archives
require_failure haptics-build-tools-sha \
  'invalid haptics build-tool SHA-256: bash'
write_haptics_build_tools_manifest
write_haptics_lock "$kernel_bundle_id"

long_haptics_tool_version=$(printf 'v%.0s' {1..241})
sed -i "5s/fixture bash 1\.0/$long_haptics_tool_version/" \
  "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
pack_archives
require_failure haptics-build-tools-version \
  'invalid haptics build-tool version: bash'
write_haptics_build_tools_manifest
write_haptics_lock "$kernel_bundle_id"

mapfile -t haptics_build_tool_lines < "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
{
  printf '%s\n' "${haptics_build_tool_lines[@]:0:4}"
  printf '%s\n' "${haptics_build_tool_lines[5]}" "${haptics_build_tool_lines[4]}"
  printf '%s\n' "${haptics_build_tool_lines[@]:6}"
} > "$haptics_root/HAPTICS-BUILD-TOOLS.tsv"
pack_archives
require_failure haptics-build-tools-order \
  'unexpected haptics build-tool order at line 5'
write_haptics_build_tools_manifest
write_haptics_lock "$kernel_bundle_id"

sed -i \
  's/^environment-policy\tisolated-allowlist-v1$/environment-policy\thostile-policy/' \
  "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
pack_archives
require_failure haptics-build-environment-policy \
  'haptics source lock has an unexpected build-environment policy'
write_haptics_lock "$kernel_bundle_id"

sed -i \
  "s/^environment-policy-sha256.*/environment-policy-sha256\\t$(printf '0%.0s' {1..64})/" \
  "$haptics_root/HAPTICS-SOURCE-LOCK.tsv"
pack_archives
require_failure haptics-build-environment-policy-sha \
  'haptics source lock environment-policy SHA-256 mismatch'
write_haptics_lock "$kernel_bundle_id"

printf 'tampered-driver-source' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c"
pack_archives
require_failure haptics-driver-source-bytes 'AW86937 original driver source SHA-256 mismatch'
write_haptics_snapshot

printf 'tampered-build-source' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/build/aw86937-haptics.c"
pack_archives
require_failure haptics-build-source-bytes 'AW86937 patched build source SHA-256 mismatch'
write_haptics_snapshot

printf 'tampered-helper-source' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c"
pack_archives
require_failure haptics-helper-source-bytes 'haptics test helper source SHA-256 mismatch'
write_haptics_snapshot

printf 'tampered-firmware-source' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin"
pack_archives
require_failure haptics-firmware-source-bytes 'haptic_ram.bin source snapshot SHA-256 mismatch'
write_haptics_snapshot

chmod 0600 \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/build/aw86937-haptics.c"
pack_archives
require_failure haptics-source-mode 'haptics source snapshot file must have mode 0644'
write_haptics_snapshot

mv \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c" \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/baseline-20260614-daily-clean/testing-tools/wrong-name.c"
pack_archives_raw
require_failure haptics-source-path 'haptics source snapshot file must be a regular file'
write_haptics_snapshot

printf 'extra' > "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/extra"
pack_archives
require_failure haptics-source-extra 'HAPTICS-SOURCE-SNAPSHOT must contain exactly five files'
write_haptics_snapshot

mkdir "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/unexpected-empty-directory"
pack_archives
require_failure haptics-source-extra-directory \
  'HAPTICS-SOURCE-SNAPSHOT contains an unexpected empty directory'
write_haptics_snapshot

printf 'self-consistent-forged-driver' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c"
haptics_driver_sha=$(sha \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c")
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure haptics-self-consistent-driver \
  'AW86937 source snapshot does not match the producer commit'
haptics_driver_sha=$(sha "$producer_driver")
write_haptics_snapshot
write_haptics_lock "$kernel_bundle_id"

printf 'self-consistent-forged-build-source' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/build/aw86937-haptics.c"
haptics_build_source_sha=$(sha \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/build/aw86937-haptics.c")
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure haptics-self-consistent-build-source \
  'AW86937 patched build source is not the deterministic producer transform'
haptics_build_source_sha=$(sha "$producer_build_source")
write_haptics_snapshot
write_haptics_lock "$kernel_bundle_id"

printf 'self-consistent-forged-firmware' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin"
haptic_ram_sha=$(sha \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/rootfs-reference/usr/lib/firmware/haptic_ram.bin")
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure haptics-self-consistent-firmware \
  'haptic_ram.bin snapshot does not match the producer commit'
haptic_ram_sha=$(sha "$producer_ram")
write_haptics_snapshot
write_haptics_lock "$kernel_bundle_id"

printf 'self-consistent-forged-helper' > \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c"
haptics_helper_source_sha=$(sha \
  "$haptics_root/HAPTICS-SOURCE-SNAPSHOT/source/haptics/baseline-20260614-daily-clean/testing-tools/y700-haptic-test.c")
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure haptics-self-consistent-helper \
  'haptics helper source snapshot does not match the producer commit'
haptics_helper_source_sha=$(sha "$producer_helper")
write_haptics_snapshot
write_haptics_lock "$kernel_bundle_id"

wrong_haptics_commit=$(env \
  GIT_AUTHOR_DATE="@$epoch +0000" \
  GIT_COMMITTER_DATE="@$epoch +0000" \
  git -C "$producer_root" commit-tree "$haptics_commit^{tree}" \
  -p "$haptics_commit" -m wrong-bundle-tip)
git -C "$producer_root" branch -f tb321fu-haptics-producer "$wrong_haptics_commit"
write_haptics_producer_bundle
pack_archives
require_failure haptics-bundle-tip 'haptics producer Git bundle commit mismatch'
git -C "$producer_root" branch -f tb321fu-haptics-producer "$haptics_commit"
write_haptics_producer_bundle

original_haptics_commit=$haptics_commit
sed -i \
  's|^HAPTICS_MAINTAINER_TEMPLATE_DIR=.*|HAPTICS_MAINTAINER_TEMPLATE_DIR=${HAPTICS_MAINTAINER_TEMPLATE_DIR:-/tmp/hostile-templates}|' \
  "$producer_maintainer_helper"
git -C "$producer_root" add scripts/ci/haptics-maintainer-scripts.sh
hostile_helper_tree=$(git -C "$producer_root" write-tree)
hostile_helper_commit=$(env \
  GIT_AUTHOR_DATE="@$epoch +0000" \
  GIT_COMMITTER_DATE="@$epoch +0000" \
  git -C "$producer_root" commit-tree "$hostile_helper_tree" \
    -p "$original_haptics_commit" -m hostile-template-override)
git -C "$producer_root" reset --hard -q "$original_haptics_commit"
git -C "$producer_root" branch -f tb321fu-haptics-producer "$hostile_helper_commit"
haptics_commit=$hostile_helper_commit
write_haptics_lock "$kernel_bundle_id"
write_haptics_producer_bundle
pack_archives
require_failure haptics-helper-environment-override \
  'haptics producer maintainer helper must not allow an environment template override'
haptics_commit=$original_haptics_commit
git -C "$producer_root" branch -f tb321fu-haptics-producer "$haptics_commit"
write_haptics_lock "$kernel_bundle_id"
write_haptics_producer_bundle

sed -i \
  's|^HAPTICS_MAINTAINER_TEMPLATE_DIR=.*|HAPTICS_MAINTAINER_TEMPLATE_DIR=/tmp/hostile-templates|' \
  "$producer_maintainer_helper"
git -C "$producer_root" add scripts/ci/haptics-maintainer-scripts.sh
hostile_helper_tree=$(git -C "$producer_root" write-tree)
hostile_helper_commit=$(env \
  GIT_AUTHOR_DATE="@$epoch +0000" \
  GIT_COMMITTER_DATE="@$epoch +0000" \
  git -C "$producer_root" commit-tree "$hostile_helper_tree" \
    -p "$original_haptics_commit" -m hostile-template-location)
git -C "$producer_root" reset --hard -q "$original_haptics_commit"
git -C "$producer_root" branch -f tb321fu-haptics-producer "$hostile_helper_commit"
haptics_commit=$hostile_helper_commit
write_haptics_lock "$kernel_bundle_id"
write_haptics_producer_bundle
pack_archives
require_failure haptics-helper-untracked-template-location \
  'haptics producer maintainer helper must derive templates from its committed location'
haptics_commit=$original_haptics_commit
git -C "$producer_root" branch -f tb321fu-haptics-producer "$haptics_commit"
write_haptics_lock "$kernel_bundle_id"
write_haptics_producer_bundle

GIT_NO_REPLACE_OBJECTS=1 git -C "$producer_root" update-ref \
  "refs/replace/$haptics_commit" "$haptics_commit"
rm -f -- "$haptics_root/HAPTICS-PRODUCER.bundle"
GIT_NO_REPLACE_OBJECTS=1 git -C "$producer_root" bundle create \
  "$haptics_root/HAPTICS-PRODUCER.bundle" \
  refs/heads/tb321fu-haptics-producer "refs/replace/$haptics_commit"
GIT_NO_REPLACE_OBJECTS=1 git -C "$producer_root" update-ref -d \
  "refs/replace/$haptics_commit"
pack_archives
require_failure haptics-bundle-replace-ref \
  'haptics producer Git bundle must advertise exactly one ref'
write_haptics_producer_bundle

write_haptics_checksum_manifest
rm -f -- "$haptics_root/SHA256SUMS-tb321fu-haptics-debs.txt"
pack_archives_raw
require_failure haptics-manifest-missing 'haptics checksum manifest must occur exactly once'
write_haptics_checksum_manifest

printf '%064d  ./unexpected\n' 0 >> \
  "$haptics_root/SHA256SUMS-tb321fu-haptics-debs.txt"
pack_archives_raw
require_failure haptics-manifest-extra \
  'haptics checksum manifest has an unexpected entry count'
write_haptics_checksum_manifest

mapfile -t haptics_manifest_lines < \
  "$haptics_root/SHA256SUMS-tb321fu-haptics-debs.txt"
{
  printf '%s\n' "${haptics_manifest_lines[1]}" "${haptics_manifest_lines[0]}"
  printf '%s\n' "${haptics_manifest_lines[@]:2}"
} > "$haptics_root/SHA256SUMS-tb321fu-haptics-debs.txt"
pack_archives_raw
require_failure haptics-manifest-reordered \
  'unexpected haptics checksum path/order at line 1'
write_haptics_checksum_manifest

mapfile -t haptics_manifest_lines < \
  "$haptics_root/SHA256SUMS-tb321fu-haptics-debs.txt"
{
  printf '%s\n' "${haptics_manifest_lines[0]}"
  printf '%s\n' "${haptics_manifest_lines[2]}" "${haptics_manifest_lines[1]}"
  printf '%s\n' "${haptics_manifest_lines[@]:3}"
} > "$haptics_root/SHA256SUMS-tb321fu-haptics-debs.txt"
pack_archives_raw
require_failure haptics-build-tools-checksum-order \
  'unexpected haptics checksum path/order at line 2'
write_haptics_checksum_manifest

cp "$haptics_root/tb321fu-haptics_20260715.1_arm64.deb" \
  "$haptics_root/unexpected-package.deb"
pack_archives
require_failure haptics-extra-deb \
  'haptics archive root contains an unexpected member: unexpected-package.deb'
rm -f -- "$haptics_root/unexpected-package.deb"

printf 'wrong-kernel-config\n' > "$kernel_root/kernel.config"
pack_archives
require_failure wrong-config 'kernel config SHA-256 mismatch'
printf 'fixture-kernel-config\n' > "$kernel_root/kernel.config"

make_deb tb321fu-haptics "$haptics_root/tb321fu-haptics_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/extra/aw86937-haptics.ko" wrong-release
haptics_module_sha=$(printf 'wrong-release SMP\n' | sha256sum | awk '{print $1}')
expected_haptics_module_sha=$haptics_module_sha
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure wrong-haptics-vermagic \
  'haptics module vermagic differs from kernel modules'
haptics_module_sha=$(printf '%s preempt SMP\n' "$release" | sha256sum | awk '{print $1}')
expected_haptics_module_sha=$haptics_module_sha
write_haptics_lock "$kernel_bundle_id"
make_deb tb321fu-haptics "$haptics_root/tb321fu-haptics_20260715.1_arm64.deb" \
  "usr/lib/modules/$release/extra/aw86937-haptics.ko" "$release preempt"
pack_archives
require_failure wrong-haptics-vermagic-flags \
  'haptics module vermagic differs from kernel modules'
haptics_module_sha=$(printf '%s SMP\n' "$release" | sha256sum | awk '{print $1}')
expected_haptics_module_sha=$haptics_module_sha
write_haptics_lock "$kernel_bundle_id"
write_baseline_haptics_deb

mutate_haptics_deb move_haptics_ram
pack_archives
require_failure wrong-haptics-firmware-path \
  'haptic_ram.bin is not installed at usr/lib/firmware/haptic_ram.bin'
write_baseline_haptics_deb

mutate_haptics_deb mode_haptics_ram
pack_archives
require_failure wrong-haptics-firmware-mode 'haptic_ram.bin must have mode 0644'
write_baseline_haptics_deb

haptic_ram_payload='tampered-haptic-ram'
write_baseline_haptics_deb
pack_archives
require_failure wrong-haptics-firmware 'haptic_ram.bin SHA-256 mismatch'
haptic_ram_payload='fixture-haptic-ram'
write_baseline_haptics_deb

mutate_haptics_deb move_haptics_module
pack_archives
require_failure wrong-haptics-module-path 'haptics module path release mismatch'
write_baseline_haptics_deb

mutate_haptics_deb mode_haptics_module
pack_archives
require_failure wrong-haptics-module-mode 'aw86937-haptics.ko must have mode 0644'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_module
pack_archives
require_failure wrong-haptics-module-bytes 'aw86937-haptics.ko SHA-256 mismatch'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_module
haptics_module_sha=$(printf '%s SMP\ntamper' "$release" | sha256sum | awk '{print $1}')
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure haptics-self-consistent-module-forgery \
  'haptics module SHA-256 differs from the external expected digest'
haptics_module_sha=$expected_haptics_module_sha
write_haptics_lock "$kernel_bundle_id"
write_baseline_haptics_deb

mutate_haptics_deb remove_haptics_helper
pack_archives
require_failure missing-haptics-helper 'tb321fu-haptic-test must occur exactly once'
write_baseline_haptics_deb

mutate_haptics_deb move_haptics_helper
pack_archives
require_failure wrong-haptics-helper-path \
  'tb321fu-haptic-test is not installed at usr/bin/tb321fu-haptic-test'
write_baseline_haptics_deb

mutate_haptics_deb mode_haptics_helper
pack_archives
require_failure wrong-haptics-helper-mode 'tb321fu-haptic-test must have mode 0755'
write_baseline_haptics_deb

mutate_haptics_deb truncate_haptics_helper
haptics_helper_binary_sha=$(head -c 20 "$haptics_helper_binary" | sha256sum | awk '{print $1}')
approved_haptics_helper_binary_sha=$expected_haptics_helper_binary_sha
expected_haptics_helper_binary_sha=$haptics_helper_binary_sha
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure invalid-haptics-helper-elf 'haptics helper is not AArch64 ELF'
haptics_helper_binary_sha=$approved_haptics_helper_binary_sha
expected_haptics_helper_binary_sha=$approved_haptics_helper_binary_sha
write_haptics_lock "$kernel_bundle_id"
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_helper
pack_archives
require_failure wrong-haptics-helper-bytes 'tb321fu-haptic-test SHA-256 mismatch'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_helper
haptics_helper_binary_sha=$tampered_haptics_helper_binary_sha
write_haptics_lock "$kernel_bundle_id"
pack_archives
require_failure haptics-self-consistent-helper-binary-forgery \
  'haptics helper binary SHA-256 differs from the external expected digest'
haptics_helper_binary_sha=$expected_haptics_helper_binary_sha
write_haptics_lock "$kernel_bundle_id"
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_postinst
pack_archives
require_failure malicious-haptics-postinst \
  'haptics DEB postinst differs from the producer template'
write_baseline_haptics_deb

mutate_haptics_deb mismatched_haptics_postinst_release
pack_archives
require_failure haptics-postinst-dynamic-release-mismatch \
  'haptics DEB postinst differs from the producer template'
write_baseline_haptics_deb

mutate_haptics_deb mismatched_haptics_prerm_release
pack_archives
require_failure haptics-prerm-dynamic-release-mismatch \
  'haptics DEB prerm differs from the producer template'
write_baseline_haptics_deb

mutate_haptics_deb mismatched_haptics_postrm_release
pack_archives
require_failure haptics-postrm-dynamic-release-mismatch \
  'haptics DEB postrm differs from the producer template'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_control
pack_archives
require_failure tampered-haptics-control \
  'haptics DEB control metadata differs from the producer contract'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_bind
pack_archives
require_failure tampered-haptics-bind \
  'haptics DEB payload differs from committed template: EOF_BIND'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_service
pack_archives
require_failure tampered-haptics-service \
  'haptics DEB payload differs from committed template: EOF_SERVICE'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_udev
pack_archives
require_failure tampered-haptics-udev \
  'haptics DEB payload differs from committed template: EOF_UDEV'
write_baseline_haptics_deb

mutate_haptics_deb tamper_haptics_config
pack_archives
require_failure tampered-haptics-config \
  'haptics DEB payload differs from committed template: EOF_CONF'
write_baseline_haptics_deb

mutate_haptics_deb add_haptics_extra_file
pack_archives
require_failure extra-haptics-data-file 'haptics data tar member set mismatch'
write_baseline_haptics_deb

mutate_haptics_deb add_haptics_extra_symlink
pack_archives
require_failure extra-haptics-data-symlink 'haptics data tar member set mismatch'
write_baseline_haptics_deb

rm -f -- "$sensor_root/tb321fu-sensors_20260715.1_arm64.deb"
write_sensor_metadata
pack_archives
require_failure missing-sensor-package 'sensor archive must contain exactly four DEBs'

printf 'KERNEL_BUNDLE_VERIFIER=PASS\n'
