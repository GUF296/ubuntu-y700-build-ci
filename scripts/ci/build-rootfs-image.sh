#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/system-payload-policy.sh"
. "$SCRIPT_DIR/tb321fu-gpu-deb-package.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Build a standard ARM64 rootfs disk image from declared inputs.

Required host tools: debootstrap, mount, chroot, mkfs.ext4, e2fsck, tar.

Environment inputs:
  OUTPUT_DIR                 default: out/ci-rootfs
  OUTPUT_PREFIX              default: <DISTRO>-<ARCH>
  DISTRO                     default: noble
  ARCH                       default: arm64
  MIRROR                     default: https://ports.ubuntu.com/ubuntu-ports
  DEBOOTSTRAP_VARIANT        default: minbase; set empty for debootstrap default
  RESOLV_CONF_CONTENT        optional /etc/resolv.conf contents for chroot
  APT_HTTP_PROXY             optional apt proxy used only during provisioning
  APT_HTTPS_PROXY            optional apt https proxy; defaults to APT_HTTP_PROXY
  APT_SOURCES_LIST           optional full sources.list replacement
  ROOTFS_IMAGE_SIZE          default: 14G
  ROOTFS_UUID                optional ext4 UUID
  ROOTFS_LABEL               default: Ubuntu
  ROOTFS_PARTLABEL           metadata only, default: userdata
  HOSTNAME_NAME              default: y700
  DEFAULT_USER_NAME          default: y700
  DEFAULT_USER_PASSWORD_HASH crypt(3) hash supplied via secret; default: locked
  DEFAULT_USER_AUTHORIZED_KEYS newline-separated OpenSSH public keys supplied via secret
  ROOT_PASSWORD_MODE         locked|set|empty, default: locked
  ROOT_PASSWORD_HASH         crypt(3) hash used when ROOT_PASSWORD_MODE=set
  USER_SUDO_MODE             password|nopasswd|none, default: password
  SDDM_AUTOLOGIN             enable SDDM autologin for DEFAULT_USER_NAME, default: 0
  SDDM_AUTOLOGIN_SESSION     SDDM session desktop name, default: plasma
  TZ_REGION                  default: Asia/Shanghai
  LOCALES                    default: en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8
  LANG_NAME                  default: zh_CN.UTF-8
  PACKAGE_LIST               newline/space separated packages
  DESKTOP_ENV                optional package token appended to PACKAGE_LIST
  OVERLAY_ARCHIVE            optional local path or URL; extracted into rootfs
  OVERLAY_DIR                optional directory copied into rootfs
  DEB_ARCHIVE                optional local path or URL containing .deb files
  DEB_DIR                    optional directory containing .deb files
  SENSOR_DEB_ARCHIVE         optional local path or URL containing sensor .deb files
  SENSOR_DEB_DIR             optional directory containing source-built sensor .deb files
  HAPTICS_DEB_ARCHIVE        optional local path or URL containing haptics .deb files
  HAPTICS_DEB_DIR            optional directory containing source-built haptics .deb files
  CAMERA_STACK_DEB_DIR       optional directory containing source-built camera stack .deb files
  BUILD_TB321FU_GPU_SENSOR   build/install TB321FU KSystemStats Adreno frequency plugin, default: 1
  TB321FU_GPU_SENSOR_SOURCE_DIR
                              optional source directory for the plugin; defaults to repo source/
  INSTALL_GNOME_SNAPSHOT     install GNOME Snapshot camera app, default: 1
  INSTALL_FIREFOX            install Firefox browser, default: 1
  INSTALL_FCITX5_CHINESE     install and configure Fcitx 5 Chinese input, default: 1
  FCITX5_CHINESE_PACKAGES    optional package list for Fcitx 5 Chinese input
  DISABLE_SNAPD              purge snapd and snap integration from rootfs, default: 1
  APPLY_Y700_FIRMWARE_FIXES  copy/verify required Y700 firmware paths only, default: 1
  APPLY_Y700_AUDIO_POLICY_FIXES
                              install Y700 WirePlumber ALSA policy for headset mic, default: 1
  CLEAN_APT_CACHE            default: 1
  COMPRESS                   none|zstd|xz|7z, default: 7z
  CHUNK_SIZE                 optional 7z volume size; empty disables volumes
  KEEP_RAW_IMAGE             keep uncompressed rootfs image after packaging, default: 0
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ci_require_cmd debootstrap
ci_require_cmd mkfs.ext4
ci_require_cmd mount
ci_require_cmd umount
ci_require_cmd findmnt
ci_require_cmd realpath
ci_require_cmd chroot
ci_require_cmd cmp
ci_require_cmd dpkg-deb
ci_require_cmd e2fsck
ci_require_cmd rsync
ci_require_cmd sha256sum
ci_require_cmd dpkg-query

DISTRO=${DISTRO:-noble}
ARCH=${ARCH:-arm64}
MIRROR=${MIRROR:-https://ports.ubuntu.com/ubuntu-ports}
DEBOOTSTRAP_VARIANT=${DEBOOTSTRAP_VARIANT-minbase}
RESOLV_CONF_CONTENT=${RESOLV_CONF_CONTENT:-}
APT_HTTP_PROXY=${APT_HTTP_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}
APT_HTTPS_PROXY=${APT_HTTPS_PROXY:-${https_proxy:-${HTTPS_PROXY:-${APT_HTTP_PROXY:-}}}}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-${DISTRO}-${ARCH}}
ci_validate_output_prefix "$OUTPUT_PREFIX"
OUTPUT_DIR=${OUTPUT_DIR:-out/ci-rootfs}
ROOTFS_IMAGE_SIZE=${ROOTFS_IMAGE_SIZE:-14G}
ROOTFS_LABEL=${ROOTFS_LABEL:-Ubuntu}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}
HOSTNAME_NAME=${HOSTNAME_NAME:-y700}
DEFAULT_USER_NAME=${DEFAULT_USER_NAME:-y700}
DEFAULT_USER_PASSWORD_HASH=${DEFAULT_USER_PASSWORD_HASH:-!}
DEFAULT_USER_AUTHORIZED_KEYS=${DEFAULT_USER_AUTHORIZED_KEYS:-}
ROOT_PASSWORD_MODE=${ROOT_PASSWORD_MODE:-locked}
ROOT_PASSWORD_HASH=${ROOT_PASSWORD_HASH:-}
USER_SUDO_MODE=${USER_SUDO_MODE:-password}
SDDM_AUTOLOGIN=${SDDM_AUTOLOGIN:-0}
SDDM_AUTOLOGIN_SESSION=${SDDM_AUTOLOGIN_SESSION:-plasma}
TZ_REGION=${TZ_REGION:-Asia/Shanghai}
LANG_NAME=${LANG_NAME:-zh_CN.UTF-8}
LOCALES=${LOCALES:-$'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8'}
CLEAN_APT_CACHE=${CLEAN_APT_CACHE:-1}
APPLY_Y700_FIRMWARE_FIXES=${APPLY_Y700_FIRMWARE_FIXES:-1}
APPLY_Y700_AUDIO_POLICY_FIXES=${APPLY_Y700_AUDIO_POLICY_FIXES:-1}
BUILD_TB321FU_GPU_SENSOR=${BUILD_TB321FU_GPU_SENSOR:-1}
TB321FU_GPU_SENSOR_SOURCE_DIR=${TB321FU_GPU_SENSOR_SOURCE_DIR:-}
INSTALL_GNOME_SNAPSHOT=${INSTALL_GNOME_SNAPSHOT:-1}
INSTALL_FIREFOX=${INSTALL_FIREFOX:-1}
INSTALL_FCITX5_CHINESE=${INSTALL_FCITX5_CHINESE:-1}
FCITX5_CHINESE_PACKAGES=${FCITX5_CHINESE_PACKAGES:-"fonts-noto-cjk im-config fcitx5 fcitx5-chinese-addons fcitx5-pinyin fcitx5-config-qt kde-config-fcitx5 fcitx5-frontend-gtk2 fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 fcitx5-frontend-qt6 fcitx5-module-wayland fcitx5-module-xorg fcitx5-module-kimpanel fcitx5-module-emoji fcitx5-material-color"}
DISABLE_SNAPD=${DISABLE_SNAPD:-1}
COMPRESS=${COMPRESS:-7z}
CHUNK_SIZE=${CHUNK_SIZE:-}
KEEP_RAW_IMAGE=${KEEP_RAW_IMAGE:-0}
MOZILLA_APT_KEY_FINGERPRINT=${MOZILLA_APT_KEY_FINGERPRINT:-35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3}
DEB_ARCHIVE_SHA256=${DEB_ARCHIVE_SHA256:-}
SENSOR_DEB_ARCHIVE_SHA256=${SENSOR_DEB_ARCHIVE_SHA256:-}
HAPTICS_DEB_ARCHIVE_SHA256=${HAPTICS_DEB_ARCHIVE_SHA256:-}
OVERLAY_ARCHIVE_SHA256=${OVERLAY_ARCHIVE_SHA256:-}
ci_require_sudo_password_hash "$USER_SUDO_MODE" "$DEFAULT_USER_PASSWORD_HASH"
ci_validate_https_apt_uri "$MIRROR"
if [ -n "${APT_SOURCES_LIST:-}" ]; then
  ci_validate_https_apt_sources_list "$APT_SOURCES_LIST"
fi
[ -z "${SENSOR_DEB_ARCHIVE:-}" ] || [ -z "${SENSOR_DEB_DIR:-}" ] ||
  ci_die "set only one of SENSOR_DEB_ARCHIVE and SENSOR_DEB_DIR"
[ -z "${HAPTICS_DEB_ARCHIVE:-}" ] || [ -z "${HAPTICS_DEB_DIR:-}" ] ||
  ci_die "set only one of HAPTICS_DEB_ARCHIVE and HAPTICS_DEB_DIR"
SOURCE_DATE_EPOCH=$(ci_source_date_epoch)
export SOURCE_DATE_EPOCH
TB321FU_COMPAT_ARCHIVE_NAME=${TB321FU_COMPAT_ARCHIVE_NAME:-y700-compat1-extra-rootfs-overlay.tar.gz}
TB321FU_COMPAT_ARCHIVE_SHA256=${TB321FU_COMPAT_ARCHIVE_SHA256:-a3f55ddee04aac465465c2ff8fcddebc1b65b7e7d3af82e5e5c8ce0a4766c414}
TB321FU_COMPAT_PACKAGE_VERSION=${TB321FU_COMPAT_PACKAGE_VERSION:-20260624.1}

default_packages="systemd systemd-sysv dbus sudo locales tzdata ca-certificates gnupg curl wget network-manager openssh-server nano vim rsync kmod initramfs-tools"
PACKAGE_LIST=${PACKAGE_LIST:-$default_packages}
if [ -n "${DESKTOP_ENV:-}" ]; then
  PACKAGE_LIST="$PACKAGE_LIST $DESKTOP_ENV"
fi
if ci_bool "$INSTALL_GNOME_SNAPSHOT"; then
  PACKAGE_LIST="$PACKAGE_LIST gnome-snapshot"
fi
if ci_bool "$INSTALL_FIREFOX"; then
  PACKAGE_LIST="$PACKAGE_LIST firefox"
fi
if ci_bool "$INSTALL_FCITX5_CHINESE"; then
  PACKAGE_LIST="$PACKAGE_LIST $FCITX5_CHINESE_PACKAGES"
fi
PACKAGE_LIST=$(ci_normalize_package_list "$PACKAGE_LIST")
ci_require_user_access_path "$DEFAULT_USER_PASSWORD_HASH" "$DEFAULT_USER_AUTHORIZED_KEYS" "$SDDM_AUTOLOGIN"

configure_mozilla_firefox_repo() {
  local root=$1
  local keyring_dir="$root/etc/apt/keyrings"
  local source_dir="$root/etc/apt/sources.list.d"
  local pref_dir="$root/etc/apt/preferences.d"
  local keyring="$keyring_dir/packages.mozilla.org.asc"
  local key_tmp="$work_dir/packages.mozilla.org.asc"

  ci_log "configuring Mozilla APT repository for non-snap Firefox"
  install -d -m 0755 "$keyring_dir" "$source_dir" "$pref_dir"
  ci_download "https://packages.mozilla.org/apt/repo-signing-key.gpg" "$key_tmp" \
    "openpgp-fpr:$MOZILLA_APT_KEY_FINGERPRINT"
  install -m 0644 "$key_tmp" "$keyring"

  cat > "$source_dir/mozilla.list" <<'MOZILLA_APT'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
MOZILLA_APT
  chmod 0644 "$source_dir/mozilla.list"

  cat > "$pref_dir/mozilla-firefox" <<'MOZILLA_PREF'
Package: firefox firefox-*
Pin: origin packages.mozilla.org
Pin-Priority: 1001

Package: firefox
Pin: version 1:*snap*
Pin-Priority: -1
MOZILLA_PREF
  chmod 0644 "$pref_dir/mozilla-firefox"
}

include_deb_archive() {
  local label=$1 src=$2 expected_sha=$3
  local archive extract copied deb

  [ -n "$src" ] || return 0

  archive="$work_dir/${label}.archive"
  extract="$work_dir/${label}-debs"
  rm -rf "$extract"
  mkdir -p "$rootfs_dir/var/tmp/ci-debs" "$extract"

  ci_log "including $label deb archive: $src"
  ci_download "$src" "$archive" "$expected_sha"
  ci_extract_archive "$archive" "$extract"

  copied=0
  while IFS= read -r -d '' deb; do
    ci_copy_deb_unique "$deb" "$rootfs_dir/var/tmp/ci-debs" "$label archive member"
    copied=$((copied + 1))
  done < <(find "$extract" -type f -name '*.deb' -print0 | sort -z)

  [ "$copied" -gt 0 ] || ci_die "$label deb archive did not contain any .deb files: $src"
}

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.rootfs-build.XXXXXX")
rootfs_dir="$work_dir/rootfs"
rootfs_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.img"
build_info="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.BUILD-INFO.txt"
manifest="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.manifest"
package_inventory="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.packages.tsv"
apt_provenance="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.apt-provenance.tsv"
apt_sources="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.apt-sources.txt"
apt_bootstrap="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.apt-bootstrap.tsv"
mounted=0

unmount_chroot_runtime() {
  local relative target
  for relative in run sys proc dev/pts dev; do
    target="$rootfs_dir/$relative"
    if findmnt -rn --mountpoint "$target" >/dev/null; then
      umount -- "$target" || ci_die "failed to unmount chroot runtime path: $target"
    fi
  done
  for relative in run sys proc dev/pts dev; do
    target="$rootfs_dir/$relative"
    ! findmnt -rn --mountpoint "$target" >/dev/null ||
      ci_die "chroot runtime path remains mounted: $target"
  done
}

apply_y700_firmware_fixes() {
  local root=$1

  ci_log "applying Y700 firmware path fixes"

  install -d -m 0755 "$root/lib/firmware/qcom" "$root/lib/firmware/qcom/sm8650" "$root/lib/firmware/qcom/vpu"

  copy_firmware_if_missing() {
    local source_rel=$1
    local dest_rel=$2
    [ -f "$root/$source_rel" ] || return 1
    if [ -e "$root/$dest_rel" ]; then
      return 0
    fi
    install -d -m 0755 "$(dirname "$root/$dest_rel")"
    install -m 0644 "$root/$source_rel" "$root/$dest_rel"
  }

  # The device overlay stores some firmware under /usr/lib/firmware or vendor-specific
  # subdirectories, while the kernel requests the canonical /lib/firmware/qcom paths.
  local src dst
  for src in \
    usr/lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn \
    lib/firmware/qcom/sm8650/lenovo/tb321fu/gen70900_zap.mbn; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/gen70900_zap.mbn; then
      break
    fi
  done
  for src in \
    usr/lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin \
    lib/firmware/qcom-tb321fu/Lenovo-Y700-TB321FU-tplg.bin; do
    if copy_firmware_if_missing "$src" lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin; then
      break
    fi
  done

  for src in \
    usr/lib/firmware/qcom/gen70900_aqe.fw \
    usr/lib/firmware/qcom/gen70900_sqe.fw \
    usr/lib/firmware/qcom/gmu_gen70900.bin \
    usr/lib/firmware/qcom/vpu/vpu33_p4.mbn; do
    dst=${src#usr/}
    copy_firmware_if_missing "$src" "$dst" || true
  done

  local required=(
    lib/firmware/qcom/gen70900_aqe.fw
    lib/firmware/qcom/gen70900_sqe.fw
    lib/firmware/qcom/gen70900_zap.mbn
    lib/firmware/qcom/gmu_gen70900.bin
    lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
    lib/firmware/qcom/vpu/vpu33_p4.mbn
  )
  local rel
  for rel in "${required[@]}"; do
    [ -e "$root/$rel" ] || [ -L "$root/$rel" ] || ci_die "missing Y700 required compatibility file: $rel"
  done
}


apply_y700_audio_policy_fixes() {
  local root=$1
  local conf_dir="$root/etc/wireplumber/wireplumber.conf.d"
  local conf="$conf_dir/51-y700-alsa-auto.conf"
  local route_conf="$conf_dir/52-tb321fu-headset-route-reconcile.conf"
  local route_script="$root/usr/share/wireplumber/scripts/tb321fu/headset-route-reconcile.lua"

  ci_log "installing Y700 WirePlumber ALSA policy fix"

  install -d -m 0755 "$conf_dir"
  cat > "$conf" <<'CONF'
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "alsa_card.platform-sound"
      }
    ]
    actions = {
      update-props = {
        api.alsa.use-acp = true
        api.alsa.use-ucm = true
        api.acp.auto-profile = true
        api.acp.auto-port = true
        api.alsa.split-enable = false
      }
    }
  }
]
CONF
  chmod 0644 "$conf"
  chown 0:0 "$conf" 2>/dev/null || true

  grep -q 'api.acp.auto-profile = true' "$conf" || ci_die "Y700 ALSA policy missing auto-profile=true"
  grep -q 'api.acp.auto-port = true' "$conf" || ci_die "Y700 ALSA policy missing auto-port=true"
  grep -q 'api.alsa.split-enable = false' "$conf" || ci_die "Y700 ALSA policy missing split-enable=false"

  [ ! -e "$conf_dir/52-y700-headset-cleanup.conf" ] ||
    ci_die "legacy node-presence WirePlumber cleanup config remains in the rootfs"
  [ ! -e "$root/usr/share/wireplumber/scripts/y700/headset-cleanup.lua" ] ||
    ci_die "legacy node-presence WirePlumber cleanup script remains in the rootfs"
  cmp -s "$SCRIPT_DIR/payloads/52-tb321fu-headset-route-reconcile.conf" "$route_conf" ||
    ci_die "TB321FU WirePlumber route reconcile config is missing or changed"
  cmp -s "$SCRIPT_DIR/payloads/tb321fu-headset-route-reconcile.lua" "$route_script" ||
    ci_die "TB321FU WirePlumber route reconcile script is missing or changed"
}

apply_sddm_autologin() {
  local root=$1
  local conf_dir="$root/etc/sddm.conf.d"
  local conf="$conf_dir/zz-tb321fu-autologin.conf"
  local session=${SDDM_AUTOLOGIN_SESSION%.desktop}

  rm -f "$conf" "$conf_dir/30-autologin.conf" "$conf_dir/10-y700-autologin.conf"

  if ! ci_bool "$SDDM_AUTOLOGIN"; then
    ci_log "SDDM autologin disabled"
    return 0
  fi

  ci_log "enabling SDDM autologin for $DEFAULT_USER_NAME"
  install -d -m 0755 "$conf_dir"
  cat > "$conf" <<CONF
[Autologin]
User=$DEFAULT_USER_NAME
Session=$session
Relogin=false
CONF
  chmod 0644 "$conf"
  chown 0:0 "$conf" 2>/dev/null || true

  grep -q "^User=$DEFAULT_USER_NAME$" "$conf" || ci_die "SDDM autologin user was not written"
  grep -q "^Session=$session$" "$conf" || ci_die "SDDM autologin session was not written"
}

prepare_tb321fu_compat_firmware_deb() {
  local payload_dir=$1
  local archive archive_sha actual_files expected_files member mode leftover
  local stage="$work_dir/tb321fu-compat-firmware-stage"
  local package_root="$work_dir/tb321fu-compat-firmware-package"
  local expected="$work_dir/tb321fu-compat-firmware.sha256"
  local output="$payload_dir/tb321fu-compat-firmware_${TB321FU_COMPAT_PACKAGE_VERSION}_${ARCH}.deb"
  local -a archives=()

  [ -d "$payload_dir" ] || return 0
  while IFS= read -r -d '' archive; do
    archives+=("$archive")
  done < <(find "$payload_dir" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar.xz' -o -name '*.tar.zst' \) -print0 | sort -z)

  [ "${#archives[@]}" -gt 0 ] || return 0
  [ "${#archives[@]}" -eq 1 ] || ci_die "expected one TB321FU compat overlay, found ${#archives[@]}"
  archive=${archives[0]}
  [ "$(basename "$archive")" = "$TB321FU_COMPAT_ARCHIVE_NAME" ] || \
    ci_die "unexpected nested device overlay: $(basename "$archive")"
  archive_sha=$(sha256sum "$archive" | awk '{print $1}')
  [ "$archive_sha" = "$TB321FU_COMPAT_ARCHIVE_SHA256" ] || \
    ci_die "TB321FU compat overlay checksum mismatch: $archive_sha"

  rm -rf -- "$stage" "$package_root"
  ci_extract_archive "$archive" "$stage"
  cat > "$expected" <<'COMPAT_SHA256'
25237c161d727b8ea92b4beb837a31651b44ea78bfc34d95672af8f346a45825  ./usr/lib/firmware/qcom/gen70900_aqe.fw
a739a1ef14e4418c5a1f1e1da444deb71aeeb4a31370ab41a4dddf378ab5683d  ./usr/lib/firmware/qcom/gen70900_sqe.fw
9685f62c42543befcaee68d25355e16bf55cdb0d573bddcc9f6633f59eec3f72  ./usr/lib/firmware/qcom/gmu_gen70900.bin
8166b1fde9725547bd07eba4add22f442dc938f17274fbf358dbdcfc88ec5f31  ./usr/lib/firmware/qcom/vpu/vpu33_p4.mbn
COMPAT_SHA256

  leftover=$(find "$stage" -mindepth 1 ! -type d ! -type f -print -quit)
  [ -z "$leftover" ] || ci_die "unsupported special member in TB321FU compat overlay: $leftover"
  actual_files=$(cd "$stage" && find . -type f -print | LC_ALL=C sort)
  expected_files=$(awk '{print $2}' "$expected" | LC_ALL=C sort)
  [ "$actual_files" = "$expected_files" ] || ci_die "TB321FU compat overlay member list mismatch"
  (cd "$stage" && sha256sum -c "$expected") || ci_die "TB321FU compat firmware content mismatch"
  while IFS= read -r member; do
    mode=$(stat -c '%a' "$stage/${member#./}")
    [ "$mode" = 644 ] || ci_die "unsafe TB321FU compat firmware mode $mode: $member"
  done <<< "$expected_files"

  install -d -m 0755 "$package_root/DEBIAN" \
    "$package_root/usr/share/doc/tb321fu-compat-firmware"
  cp -a "$stage/usr" "$package_root/"
  cp -a "$expected" "$package_root/usr/share/doc/tb321fu-compat-firmware/files.sha256"
  cat > "$package_root/usr/share/doc/tb321fu-compat-firmware/provenance" <<PROVENANCE
source_archive=$TB321FU_COMPAT_ARCHIVE_NAME
source_archive_sha256=$archive_sha
release_lock=device-compat1-files.sha256
PROVENANCE
  cat > "$package_root/DEBIAN/control" <<CONTROL
Package: tb321fu-compat-firmware
Version: $TB321FU_COMPAT_PACKAGE_VERSION
Section: misc
Priority: optional
Architecture: $ARCH
Maintainer: TB321FU reconstruction <noreply@localhost>
Description: Verified TB321FU compatibility firmware from the tested Ubuntu release
CONTROL
  chmod 0644 "$package_root/DEBIAN/control" \
    "$package_root/usr/share/doc/tb321fu-compat-firmware/files.sha256" \
    "$package_root/usr/share/doc/tb321fu-compat-firmware/provenance"
  ci_normalize_package_tree "$package_root"
  dpkg-deb --build --root-owner-group "$package_root" "$output" >/dev/null
  rm -f -- "$archive"
  rm -rf -- "$stage" "$package_root"
  rm -f -- "$expected"

  leftover=$(find "$payload_dir" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar.xz' -o -name '*.tar.zst' \) -print -quit)
  [ -z "$leftover" ] || ci_die "unconverted nested device overlay remains: $leftover"
  ci_log "converted verified TB321FU compat overlay to managed package: $(basename "$output")"
}

apply_tb321fu_legacy_cleanup() {
  local root=$1

  ci_log "verifying migrated legacy y700 sensor and haptics glue is absent"
  ci_assert_no_tb321fu_legacy_payload "$root"
  rm -f \
    "$root/etc/systemd/system/smartmontools.service" \
    "$root/etc/systemd/system/sddm.service.d/10-y700-audio-card-guard.conf"

  if [ -f "$root/usr/lib/systemd/system/qcom-sns-init.service" ]; then
    install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/qcom-sns-init.service \
      "$root/etc/systemd/system/multi-user.target.wants/qcom-sns-init.service"
  fi
  if [ -f "$root/usr/lib/systemd/system/tb321fu-haptics.service" ]; then
    install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/tb321fu-haptics.service \
      "$root/etc/systemd/system/multi-user.target.wants/tb321fu-haptics.service"
  fi
  if [ -f "$root/etc/systemd/system/y700-audio-card-guard.service" ]; then
    grep -q '^Restart=on-failure$' "$root/etc/systemd/system/y700-audio-card-guard.service" || \
      ci_die "audio card guard does not retry asynchronously"
    install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn /etc/systemd/system/y700-audio-card-guard.service \
      "$root/etc/systemd/system/multi-user.target.wants/y700-audio-card-guard.service"
  fi

  if [ -x "$root/usr/libexec/iio-sensor-proxy" ]; then
    install -d -m 0755 "$root/usr/share/dbus-1/system-services"
    cat > "$root/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service" <<'DBUS_SERVICE'
[D-BUS Service]
Name=net.hadess.SensorProxy
Exec=/usr/libexec/iio-sensor-proxy
User=root
SystemdService=iio-sensor-proxy.service
DBUS_SERVICE
    chmod 0644 "$root/usr/share/dbus-1/system-services/net.hadess.SensorProxy.service"
  fi
}

apply_tb321fu_gpu_sensor() {
  local root=$1
  local source_dir=${TB321FU_GPU_SENSOR_SOURCE_DIR:-"$SCRIPT_DIR/../../source/tb321fu-ksystemstats-adreno-freq"}
  local rootfs_src=/tmp/tb321fu-ksystemstats-adreno-freq-src
  local rootfs_build=/tmp/tb321fu-ksystemstats-adreno-freq-build
  local package_stage=/tmp/tb321fu-ksystemstats-gpu-package
  local package_deb=/tmp/tb321fu-ksystemstats-gpu.deb
  local runtime_deps_file=/tmp/tb321fu-ksystemstats-gpu.runtime-depends
  local new_build_deps_file=/tmp/tb321fu-ksystemstats-gpu.new-build-deps
  local apt_transaction_dir=/var/lib/tb321fu-build-provenance/apt-transactions
  local plugin_rel=usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
  local stock_plugin_rel=usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
  local disabled_stock_plugin_rel=$stock_plugin_rel.disabled-tb321fu-adreno
  local package_hash package_version package_arch runtime_deps package_output
  local apt_recorder_sha256 apt_common_sha256

  ci_log "building TB321FU KSystemStats Adreno GPU frequency plugin"

  [ -f "$source_dir/CMakeLists.txt" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/CMakeLists.txt"
  [ -f "$source_dir/tb321fu_gpu.cpp" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/tb321fu_gpu.cpp"
  [ -f "$source_dir/metadata.json" ] || ci_die "missing TB321FU GPU sensor source: $source_dir/metadata.json"

  rm -rf "$root$rootfs_src" "$root$rootfs_build" "$root$package_stage"
  rm -f "$root$package_deb" "$root$runtime_deps_file" "$root$new_build_deps_file"
  install -d -m 0755 "$root$rootfs_src"
  rsync -a --delete "$source_dir"/ "$root$rootfs_src"/

cat > "$root/root/ci-build-tb321fu-gpu-sensor.sh" <<'GPU_SENSOR_BUILD'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt_secure()
{
  assert_apt_recorder_integrity
  /root/ci-apt-transaction.sh "$APT_PROVENANCE_DIR" "$APT_PROVENANCE_PHASE" "$@"
}

assert_apt_recorder_integrity()
{
  local actual
  [[ ${CI_APT_RECORDER_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || {
    echo 'missing trusted APT recorder digest' >&2
    exit 1
  }
  [[ ${CI_APT_COMMON_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || {
    echo 'missing trusted APT validation helper digest' >&2
    exit 1
  }
  actual=$(sha256sum /root/ci-apt-transaction.sh | awk '{print $1}')
  [ "$actual" = "$CI_APT_RECORDER_SHA256" ] || {
    echo 'trusted APT recorder integrity check failed' >&2
    exit 1
  }
  actual=$(sha256sum /root/ci-apt-common.sh | awk '{print $1}')
  [ "$actual" = "$CI_APT_COMMON_SHA256" ] || {
    echo 'trusted APT validation helper integrity check failed' >&2
    exit 1
  }
}

ci_bool_chroot()
{
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "${APT_HTTP_PROXY:-}" ] || [ -n "${APT_HTTPS_PROXY:-}" ]; then
  mkdir -p /etc/apt/apt.conf.d
  : > /etc/apt/apt.conf.d/99ci-proxy
  if [ -n "${APT_HTTP_PROXY:-}" ]; then
    printf 'Acquire::http::Proxy "%s";\n' "$APT_HTTP_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
  if [ -n "${APT_HTTPS_PROXY:-}" ]; then
    printf 'Acquire::https::Proxy "%s";\n' "$APT_HTTPS_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
fi

src=/tmp/tb321fu-ksystemstats-adreno-freq-src
build=/tmp/tb321fu-ksystemstats-adreno-freq-build
stage=/tmp/tb321fu-ksystemstats-gpu-package
plugin_rel=usr/lib/aarch64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_tb321fu_gpu.so
plugin=$stage/$plugin_rel
runtime_deps_file=/tmp/tb321fu-ksystemstats-gpu.runtime-depends
new_build_deps_file=/tmp/tb321fu-ksystemstats-gpu.new-build-deps
build_deps="cmake extra-cmake-modules g++ make dpkg-dev libksysguard-dev libkf6coreaddons-dev libsensors-dev"

new_build_deps=""
for pkg in $build_deps; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    :
  else
    new_build_deps="$new_build_deps $pkg"
  fi
done

apt_secure update
apt_secure install -y --no-install-recommends $build_deps

cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$build" -j"${TB321FU_GPU_SENSOR_BUILD_JOBS:-2}"
rm -rf "$stage"
DESTDIR="$stage" cmake --install "$build"

test -f "$plugin"
install -d -m 0755 "$stage/usr/share/tb321fu-ksystemstats-gpu"
(cd "$stage" && sha256sum "./$plugin_rel" > \
  ./usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256)

install -d -m 0755 "$src/debian"
cat > "$src/debian/control" <<'SHLIBS_CONTROL'
Source: tb321fu-ksystemstats-gpu
Section: utils
Priority: optional
Maintainer: TB321FU Linux maintainers <noreply@example.invalid>
Standards-Version: 4.7.0

Package: tb321fu-ksystemstats-gpu
Architecture: any
Depends: ${shlibs:Depends}
Description: TB321FU Adreno frequency provider for KSystemStats
SHLIBS_CONTROL
(cd "$src" && dpkg-shlibdeps -O -e"$plugin") | \
  sed -n 's/^shlibs:Depends=//p' > "$runtime_deps_file"
test -s "$runtime_deps_file"
printf '%s\n' "$new_build_deps" > "$new_build_deps_file"
GPU_SENSOR_BUILD
  chmod +x "$root/root/ci-build-tb321fu-gpu-sensor.sh"

  local gpu_resolv_backup="$work_dir/gpu-sensor-resolv.conf.original"
  local gpu_resolv_link="$work_dir/gpu-sensor-resolv.conf.link"
  rm -f "$gpu_resolv_backup" "$gpu_resolv_link"
  if [ -L "$root/etc/resolv.conf" ]; then
    readlink "$root/etc/resolv.conf" > "$gpu_resolv_link"
  elif [ -e "$root/etc/resolv.conf" ]; then
    cp -a "$root/etc/resolv.conf" "$gpu_resolv_backup"
  fi
  rm -f "$root/etc/resolv.conf"
  if [ -n "$RESOLV_CONF_CONTENT" ]; then
    printf '%s\n' "$RESOLV_CONF_CONTENT" > "$root/etc/resolv.conf"
  elif [ -f /run/systemd/resolve/resolv.conf ]; then
    cp /run/systemd/resolve/resolv.conf "$root/etc/resolv.conf"
  else
    cp /etc/resolv.conf "$root/etc/resolv.conf"
  fi

  apt_recorder_sha256=$(sha256sum "$root/root/ci-apt-transaction.sh" | awk '{print $1}')
  apt_common_sha256=$(sha256sum "$root/root/ci-apt-common.sh" | awk '{print $1}')

  chroot "$root" env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    LANG=C.UTF-8 \
    APT_HTTP_PROXY="$APT_HTTP_PROXY" \
    APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
    http_proxy="$APT_HTTP_PROXY" \
    https_proxy="$APT_HTTPS_PROXY" \
    HTTP_PROXY="$APT_HTTP_PROXY" \
    HTTPS_PROXY="$APT_HTTPS_PROXY" \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    CI_APT_COMMON_SH=/root/ci-apt-common.sh \
    CI_APT_RECORDER_SHA256="$apt_recorder_sha256" \
    CI_APT_COMMON_SHA256="$apt_common_sha256" \
    APT_PROVENANCE_DIR="$apt_transaction_dir" \
    APT_PROVENANCE_PHASE=gpu-build \
    TB321FU_GPU_SENSOR_BUILD_JOBS="${TB321FU_GPU_SENSOR_BUILD_JOBS:-2}" \
    bash /root/ci-build-tb321fu-gpu-sensor.sh

  [ "$(wc -l < "$root$runtime_deps_file")" -eq 1 ] || \
    ci_die "TB321FU GPU package runtime dependency output is not exactly one line"
  runtime_deps=$(tr -d '\r\n' < "$root$runtime_deps_file")
  [ -n "$runtime_deps" ] || ci_die "TB321FU GPU package runtime dependencies are empty"
  package_arch=$(chroot "$root" dpkg --print-architecture)
  package_hash=$(
    {
      sha256sum "$root$package_stage/$plugin_rel" | awk '{print $1}'
      sha256sum "$SCRIPT_DIR/tb321fu-gpu-deb-package.sh" | awk '{print $1}'
      printf 'architecture=%s\nruntime-depends=%s\n' "$package_arch" "$runtime_deps"
    } | sha256sum | awk '{print $1}'
  )
  package_version="1.${package_hash:0:16}"
  tb321fu_write_gpu_deb_metadata \
    "$root$package_stage" "$package_version" "$package_arch" "$runtime_deps"
  (
    cd "$root$package_stage"
    find usr -type f -print0 | \
      sort -z | xargs -0 -r md5sum > DEBIAN/md5sums
  )
  chmod 0644 "$root$package_stage/DEBIAN/control" "$root$package_stage/DEBIAN/md5sums"
  dpkg-deb --root-owner-group --build "$root$package_stage" "$root$package_deb"
  package_output="$OUTPUT_DIR/${OUTPUT_PREFIX}-tb321fu-ksystemstats-gpu_${package_version}_${package_arch}.deb"
  # Install through the same attested apt wrapper as every other package
  # transaction so the locally built GPU DEB and its SHA-256 enter the final
  # provenance record.
  chroot "$root" env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    LANG=C.UTF-8 \
    APT_HTTP_PROXY="$APT_HTTP_PROXY" \
    APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
    http_proxy="$APT_HTTP_PROXY" \
    https_proxy="$APT_HTTPS_PROXY" \
    HTTP_PROXY="$APT_HTTP_PROXY" \
    HTTPS_PROXY="$APT_HTTPS_PROXY" \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    CI_APT_COMMON_SH=/root/ci-apt-common.sh \
    CI_APT_RECORDER_SHA256="$apt_recorder_sha256" \
    CI_APT_COMMON_SHA256="$apt_common_sha256" \
    APT_PROVENANCE_DIR="$apt_transaction_dir" \
    /root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build install -y -- "$package_deb"

  chroot "$root" dpkg-query -W -f='${Status}\n' tb321fu-ksystemstats-gpu | \
    grep -Fx 'install ok installed' >/dev/null || ci_die "TB321FU GPU package is not installed"
  chroot "$root" dpkg-query -S "/$plugin_rel" | \
    grep -Fx "tb321fu-ksystemstats-gpu: /$plugin_rel" >/dev/null || \
    ci_die "TB321FU GPU plugin is not owned by its native package"
  chroot "$root" dpkg-divert --listpackage "/$stock_plugin_rel" | \
    grep -Fx tb321fu-ksystemstats-gpu >/dev/null || \
    ci_die "TB321FU GPU stock-plugin diversion has the wrong owner"
  chroot "$root" sh -eu -c \
    'cd / && sha256sum -c /usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256'
  find "$OUTPUT_DIR" -maxdepth 1 -type f \
    -name "${OUTPUT_PREFIX}-tb321fu-ksystemstats-gpu_*.deb" -delete
  install -m 0644 "$root$package_deb" "$package_output"

  local -a new_build_deps=()
  read -r -a new_build_deps < "$root$new_build_deps_file" || true
  if [ "${#new_build_deps[@]}" -gt 0 ]; then
    local dependency
    for dependency in "${new_build_deps[@]}"; do
      [[ $dependency =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || ci_die "unsafe GPU build dependency: $dependency"
    done
    install -m 0755 "$SCRIPT_DIR/apt-transaction-provenance.sh" \
      "$root/root/ci-apt-transaction.sh"
    install -m 0644 "$SCRIPT_DIR/common.sh" "$root/root/ci-apt-common.sh"
    apt_recorder_sha256=$(sha256sum "$root/root/ci-apt-transaction.sh" | awk '{print $1}')
    apt_common_sha256=$(sha256sum "$root/root/ci-apt-common.sh" | awk '{print $1}')
    chroot "$root" env -i \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/root \
      LANG=C.UTF-8 \
      APT_HTTP_PROXY="$APT_HTTP_PROXY" \
      APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
      http_proxy="$APT_HTTP_PROXY" \
      https_proxy="$APT_HTTPS_PROXY" \
      HTTP_PROXY="$APT_HTTP_PROXY" \
      HTTPS_PROXY="$APT_HTTPS_PROXY" \
      SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
      CI_APT_COMMON_SH=/root/ci-apt-common.sh \
      CI_APT_RECORDER_SHA256="$apt_recorder_sha256" \
      CI_APT_COMMON_SHA256="$apt_common_sha256" \
      /root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build mark-auto "${new_build_deps[@]}"
    chroot "$root" env -i \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/root \
      LANG=C.UTF-8 \
      APT_HTTP_PROXY="$APT_HTTP_PROXY" \
      APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
      http_proxy="$APT_HTTP_PROXY" \
      https_proxy="$APT_HTTPS_PROXY" \
      HTTP_PROXY="$APT_HTTP_PROXY" \
      HTTPS_PROXY="$APT_HTTPS_PROXY" \
      SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
      CI_APT_COMMON_SH=/root/ci-apt-common.sh \
      CI_APT_RECORDER_SHA256="$apt_recorder_sha256" \
      CI_APT_COMMON_SHA256="$apt_common_sha256" \
      /root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build autoremove -y --purge
  fi
  chroot "$root" apt-get clean
  rm -rf "$root$rootfs_src" "$root$rootfs_build" "$root$package_stage"
  rm -f "$root$package_deb" "$root$runtime_deps_file" "$root$new_build_deps_file" \
    "$root/etc/apt/apt.conf.d/99ci-proxy"

  rm -f "$root/etc/resolv.conf"
  if [ -f "$gpu_resolv_link" ]; then
    ln -s "$(cat "$gpu_resolv_link")" "$root/etc/resolv.conf"
  elif [ -f "$gpu_resolv_backup" ]; then
    cp -a "$gpu_resolv_backup" "$root/etc/resolv.conf"
  else
    ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
  fi

  rm -f "$root/root/ci-build-tb321fu-gpu-sensor.sh"
  [ -f "$root/$plugin_rel" ] || ci_die "TB321FU GPU sensor plugin missing after build: /$plugin_rel"
  [ ! -e "$root/$stock_plugin_rel" ] || ci_die "stock KSystemStats GPU plugin still enabled: /$stock_plugin_rel"
  [ -f "$root/$disabled_stock_plugin_rel" ] || ci_die "disabled stock KSystemStats GPU plugin missing: /$disabled_stock_plugin_rel"
  [ -s "$root/usr/share/tb321fu-ksystemstats-gpu/ksystemstats_plugin_tb321fu_gpu.so.sha256" ] || \
    ci_die "TB321FU GPU package checksum is missing"
}

cleanup() {
  set +e
  if [ "$mounted" = 1 ]; then
    ci_unmount_tree "$rootfs_dir" ||
      ci_log "cleanup preserved mounted work tree for manual recovery: $work_dir"
  fi
  if ! ci_safe_rmtree "$work_dir" "$OUTPUT_DIR" .rootfs-build.; then
    ci_log "cleanup refused to remove work tree: $work_dir"
  fi
}
trap cleanup EXIT

ci_log "creating ext4 image: $rootfs_img"
rm -f "$rootfs_img"
truncate -s "$ROOTFS_IMAGE_SIZE" "$rootfs_img"
mkfs_args=(-F -L "$ROOTFS_LABEL")
if [ -n "${ROOTFS_UUID:-}" ]; then
  mkfs_args+=(-U "$ROOTFS_UUID")
fi
mkfs.ext4 "${mkfs_args[@]}" "$rootfs_img"

mkdir -p "$rootfs_dir"
mount -o loop "$rootfs_img" "$rootfs_dir"
mounted=1

ci_log "debootstrap $DISTRO/$ARCH from $MIRROR"
debootstrap_args=(--arch="$ARCH")
if [ -n "$DEBOOTSTRAP_VARIANT" ]; then
  debootstrap_args+=(--variant="$DEBOOTSTRAP_VARIANT")
fi
debootstrap "${debootstrap_args[@]}" "$DISTRO" "$rootfs_dir" "$MIRROR"

# Record the seed rootfs before replacing its APT sources or installing the
# transaction recorder. This captures bootstrap provenance without claiming a
# rolling mirror is an immutable package snapshot.
bootstrap_provenance="$work_dir/apt-bootstrap.tsv"
debootstrap_binary=$(realpath -e -- "$(command -v debootstrap)")
[ -f "$debootstrap_binary" ] && [ -x "$debootstrap_binary" ] ||
  ci_die 'debootstrap binary is not a regular executable'
debootstrap_version=$(dpkg-query -W -f='${Version}' debootstrap) ||
  ci_die 'cannot determine the installed debootstrap package version'
bootstrap_variant=${DEBOOTSTRAP_VARIANT:-default}
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  bash "$SCRIPT_DIR/write-apt-provenance.sh" capture-bootstrap \
    "$rootfs_dir" "$bootstrap_provenance" "$debootstrap_version" \
    "$(sha256sum "$debootstrap_binary" | awk '{print $1}')" \
    "$DISTRO" "$ARCH" "$bootstrap_variant" "$MIRROR"

if [ -n "${APT_SOURCES_LIST:-}" ]; then
  printf '%s\n' "$APT_SOURCES_LIST" > "$rootfs_dir/etc/apt/sources.list"
else
  cat > "$rootfs_dir/etc/apt/sources.list" <<APT
deb $MIRROR $DISTRO main restricted universe multiverse
deb $MIRROR $DISTRO-updates main restricted universe multiverse
deb $MIRROR $DISTRO-backports main restricted universe multiverse
deb $MIRROR $DISTRO-security main restricted universe multiverse
APT
fi

printf '%s\n' "$HOSTNAME_NAME" > "$rootfs_dir/etc/hostname"
touch "$rootfs_dir/etc/hosts"
sed -i '/^127\.0\.1\.1\b/d' "$rootfs_dir/etc/hosts"
printf '127.0.1.1 %s\n' "$HOSTNAME_NAME" >> "$rootfs_dir/etc/hosts"
original_resolv="$work_dir/resolv.conf.original"
original_resolv_link="$work_dir/resolv.conf.link"
if [ -L "$rootfs_dir/etc/resolv.conf" ]; then
  readlink "$rootfs_dir/etc/resolv.conf" > "$original_resolv_link"
elif [ -e "$rootfs_dir/etc/resolv.conf" ]; then
  cp -a "$rootfs_dir/etc/resolv.conf" "$original_resolv"
fi
rm -f "$rootfs_dir/etc/resolv.conf"
if [ -n "$RESOLV_CONF_CONTENT" ]; then
  printf '%s\n' "$RESOLV_CONF_CONTENT" > "$rootfs_dir/etc/resolv.conf"
elif [ -f /run/systemd/resolve/resolv.conf ]; then
  cp /run/systemd/resolve/resolv.conf "$rootfs_dir/etc/resolv.conf"
else
  cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"
fi
if ! awk '
  /^[[:space:]]*nameserver[[:space:]]+/ {
    ns=$2
    if (ns !~ /^(127\.|::1$|0\.0\.0\.0$)/) good=1
  }
  END { exit good ? 0 : 1 }
' "$rootfs_dir/etc/resolv.conf"; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$rootfs_dir/etc/resolv.conf"
fi

mount --bind /dev "$rootfs_dir/dev"
mount --bind /dev/pts "$rootfs_dir/dev/pts"
mount -t proc proc "$rootfs_dir/proc"
mount -t sysfs sysfs "$rootfs_dir/sys"
mount -t tmpfs tmpfs "$rootfs_dir/run"

cat > "$rootfs_dir/root/ci-provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt_secure()
{
  assert_apt_recorder_integrity
  /root/ci-apt-transaction.sh "$APT_PROVENANCE_DIR" "$APT_PROVENANCE_PHASE" "$@"
}

assert_apt_recorder_integrity()
{
  local actual
  [[ ${CI_APT_RECORDER_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || {
    echo 'missing trusted APT recorder digest' >&2
    exit 1
  }
  [[ ${CI_APT_COMMON_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || {
    echo 'missing trusted APT validation helper digest' >&2
    exit 1
  }
  actual=$(sha256sum /root/ci-apt-transaction.sh | awk '{print $1}')
  [ "$actual" = "$CI_APT_RECORDER_SHA256" ] || {
    echo 'trusted APT recorder integrity check failed' >&2
    exit 1
  }
  actual=$(sha256sum /root/ci-apt-common.sh | awk '{print $1}')
  [ "$actual" = "$CI_APT_COMMON_SHA256" ] || {
    echo 'trusted APT validation helper integrity check failed' >&2
    exit 1
  }
}

ci_bool_chroot()
{
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "${APT_HTTP_PROXY:-}" ] || [ -n "${APT_HTTPS_PROXY:-}" ]; then
  mkdir -p /etc/apt/apt.conf.d
  : > /etc/apt/apt.conf.d/99ci-proxy
  if [ -n "${APT_HTTP_PROXY:-}" ]; then
    printf 'Acquire::http::Proxy "%s";\n' "$APT_HTTP_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
  if [ -n "${APT_HTTPS_PROXY:-}" ]; then
    printf 'Acquire::https::Proxy "%s";\n' "$APT_HTTPS_PROXY" >> /etc/apt/apt.conf.d/99ci-proxy
  fi
fi

apt_secure update
mapfile -t requested_packages <<< "$PACKAGE_LIST"
apt_secure install -y -- "${requested_packages[@]}"

if ci_bool_chroot "$INSTALL_FIREFOX"; then
  firefox_version=$(dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)
  [ -n "$firefox_version" ] || { echo 'firefox package was not installed' >&2; exit 1; }
  case "$firefox_version" in
    *snap*) echo "refusing snap transition Firefox package version: $firefox_version" >&2; exit 1 ;;
  esac
fi

if ci_bool_chroot "$INSTALL_FCITX5_CHINESE"; then
  for pkg in fcitx5 fcitx5-chinese-addons fcitx5-pinyin im-config fonts-noto-cjk; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || {
      echo "required Fcitx 5 Chinese input package missing: $pkg" >&2
      exit 1
    }
  done

  install -d -m 0755 \
    /etc/environment.d \
    /etc/skel/.config/environment.d \
    /etc/skel/.config/autostart \
    /etc/skel/.config/fcitx5 \
    /etc/skel/.config/plasma-workspace/env

  cat > /etc/environment.d/90-fcitx5.conf <<'FCITX5_ENV'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
INPUT_METHOD=fcitx
FCITX5_ENV
  chmod 0644 /etc/environment.d/90-fcitx5.conf
  cp -a /etc/environment.d/90-fcitx5.conf /etc/skel/.config/environment.d/90-fcitx5.conf

  cat > /etc/skel/.config/plasma-workspace/env/fcitx5.sh <<'FCITX5_PLASMA_ENV'
#!/bin/sh
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export INPUT_METHOD=fcitx
FCITX5_PLASMA_ENV
  chmod 0755 /etc/skel/.config/plasma-workspace/env/fcitx5.sh

  cat > /etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop <<'FCITX5_AUTOSTART'
[Desktop Entry]
Name=Fcitx 5
GenericName=Input Method
Comment=Start Fcitx 5 input method
Exec=fcitx5 -d --replace
Icon=org.fcitx.Fcitx5
Terminal=false
Type=Application
Categories=System;Utility;
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
FCITX5_AUTOSTART
  chmod 0644 /etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop

  cat > /etc/skel/.config/fcitx5/profile <<'FCITX5_PROFILE'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=pinyin

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=pinyin
# Layout
Layout=

[GroupOrder]
0=Default
FCITX5_PROFILE
  chmod 0644 /etc/skel/.config/fcitx5/profile
fi

install -d -m 0755 /etc/xdg /etc/skel/.config

cat > /etc/xdg/kwinrc <<'KWINRC'
[Wayland]
InputMethod=/usr/share/applications/org.kde.plasma.keyboard.desktop
VirtualKeyboardEnabled=true
KWINRC
chmod 0644 /etc/xdg/kwinrc
cp -a /etc/xdg/kwinrc /etc/skel/.config/kwinrc

cat > /etc/skel/.config/kwinoutputconfig.json <<'KWINOUTPUTCONFIG'
[
    {
        "data": [
            {
                "allowDdcCi": true,
                "allowSdrSoftwareBrightness": false,
                "autoBrightnessCurve": [
                    0,
                    200,
                    2500,
                    12000,
                    40000,
                    100000
                ],
                "autoRotation": "InTabletMode",
                "automaticBrightness": true,
                "brightness": 0.35,
                "colorPowerTradeoff": "PreferEfficiency",
                "colorProfileSource": "sRGB",
                "connectorName": "DSI-1",
                "detectedDdcCi": false,
                "edrPolicy": "always",
                "highDynamicRange": false,
                "iccProfilePath": "",
                "maxBitsPerColor": 0,
                "mode": {
                    "height": 2560,
                    "refreshRate": 120000,
                    "width": 1600
                },
                "overscan": 0,
                "rgbRange": "Automatic",
                "scale": 2.3,
                "sdrBrightness": 200,
                "sdrGamutWideness": 0,
                "sharpness": 0,
                "transform": "Rotated180",
                "vrrPolicy": "Never",
                "wideColorGamut": false
            }
        ],
        "name": "outputs"
    }
]
KWINOUTPUTCONFIG
chmod 0644 /etc/skel/.config/kwinoutputconfig.json

systemctl enable NetworkManager.service ssh.service
for required_unit in NetworkManager.service ssh.service; do
  systemctl is-enabled --quiet "$required_unit" || {
    echo "required system service was not enabled: $required_unit" >&2
    exit 1
  }
done

if ! id -u "$DEFAULT_USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEFAULT_USER_NAME"
fi
if [ -n "$DEFAULT_USER_PASSWORD_HASH" ] && [ "$DEFAULT_USER_PASSWORD_HASH" != '!' ]; then
  printf '%s:%s\n' "$DEFAULT_USER_NAME" "$DEFAULT_USER_PASSWORD_HASH" | chpasswd -e
else
  passwd -l "$DEFAULT_USER_NAME" || true
fi
default_user_group=$(id -gn "$DEFAULT_USER_NAME")
if [ -n "$DEFAULT_USER_AUTHORIZED_KEYS" ]; then
  install -d -m 0700 -o "$DEFAULT_USER_NAME" -g "$default_user_group" "/home/$DEFAULT_USER_NAME/.ssh"
  printf '%s\n' "$DEFAULT_USER_AUTHORIZED_KEYS" > "/home/$DEFAULT_USER_NAME/.ssh/authorized_keys"
  chown "$DEFAULT_USER_NAME:$default_user_group" "/home/$DEFAULT_USER_NAME/.ssh/authorized_keys"
  chmod 0600 "/home/$DEFAULT_USER_NAME/.ssh/authorized_keys"
fi
if [ -d "/home/$DEFAULT_USER_NAME" ]; then
  install -d -m 0755 "/home/$DEFAULT_USER_NAME/.config"
  for skel_config in kwinrc kwinoutputconfig.json; do
    cp -a "/etc/skel/.config/$skel_config" "/home/$DEFAULT_USER_NAME/.config/$skel_config"
    chown "$DEFAULT_USER_NAME:$default_user_group" "/home/$DEFAULT_USER_NAME/.config/$skel_config"
  done
fi

if ci_bool_chroot "$INSTALL_FCITX5_CHINESE" && [ -d "/home/$DEFAULT_USER_NAME" ]; then
  install -d -m 0755 \
    "/home/$DEFAULT_USER_NAME/.config" \
    "/home/$DEFAULT_USER_NAME/.config/environment.d" \
    "/home/$DEFAULT_USER_NAME/.config/autostart" \
    "/home/$DEFAULT_USER_NAME/.config/fcitx5" \
    "/home/$DEFAULT_USER_NAME/.config/plasma-workspace" \
    "/home/$DEFAULT_USER_NAME/.config/plasma-workspace/env"
  cp -a /etc/skel/.config/environment.d/90-fcitx5.conf "/home/$DEFAULT_USER_NAME/.config/environment.d/90-fcitx5.conf"
  cp -a /etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop "/home/$DEFAULT_USER_NAME/.config/autostart/org.fcitx.Fcitx5.desktop"
  cp -a /etc/skel/.config/fcitx5/profile "/home/$DEFAULT_USER_NAME/.config/fcitx5/profile"
  cp -a /etc/skel/.config/plasma-workspace/env/fcitx5.sh "/home/$DEFAULT_USER_NAME/.config/plasma-workspace/env/fcitx5.sh"
  chown -R "$DEFAULT_USER_NAME:$default_user_group" \
    "/home/$DEFAULT_USER_NAME/.config/environment.d" \
    "/home/$DEFAULT_USER_NAME/.config/autostart" \
    "/home/$DEFAULT_USER_NAME/.config/fcitx5" \
    "/home/$DEFAULT_USER_NAME/.config/plasma-workspace"
fi

case "$ROOT_PASSWORD_MODE" in
  locked)
    passwd -l root || true
    ;;
  set)
    [ -n "$ROOT_PASSWORD_HASH" ] || { echo 'ROOT_PASSWORD_MODE=set requires ROOT_PASSWORD_HASH' >&2; exit 1; }
    printf 'root:%s\n' "$ROOT_PASSWORD_HASH" | chpasswd -e
    ;;
  empty)
    passwd -d root || true
    ;;
  *)
    echo "unsupported ROOT_PASSWORD_MODE=$ROOT_PASSWORD_MODE" >&2
    exit 1
    ;;
esac

case "$USER_SUDO_MODE" in
  password)
    usermod -aG sudo "$DEFAULT_USER_NAME"
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  nopasswd)
    usermod -aG sudo "$DEFAULT_USER_NAME"
    mkdir -p /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEFAULT_USER_NAME" > "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    chmod 0440 "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    visudo -cf "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  none)
    gpasswd -d "$DEFAULT_USER_NAME" sudo >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/010_${DEFAULT_USER_NAME}-nopasswd"
    ;;
  *)
    echo "unsupported USER_SUDO_MODE=$USER_SUDO_MODE" >&2
    exit 1
    ;;
esac

if [ -n "$TZ_REGION" ] && [ -f "/usr/share/zoneinfo/$TZ_REGION" ]; then
  ln -sf "/usr/share/zoneinfo/$TZ_REGION" /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata || true
fi

while IFS= read -r locale_line; do
  [ -n "$locale_line" ] || continue
  sed -i "s/^# *\($locale_line\)/\1/" /etc/locale.gen || true
done <<LOCALES_EOF
$LOCALES
LOCALES_EOF
locale-gen || true
update-locale LANG="$LANG_NAME" || true

if compgen -G "/var/tmp/ci-debs/*.deb" >/dev/null; then
  apt_secure install -y --no-install-recommends /var/tmp/ci-debs/*.deb
fi

if compgen -G "/var/tmp/ci-debs/*.tar*" >/dev/null; then
  echo 'unconverted nested device overlay reached the chroot' >&2
  exit 1
fi

if ci_bool_chroot "$DISABLE_SNAPD"; then
  purge_candidates=()
  for purge_candidate in snapd plasma-discover-backend-snap; do
    if dpkg-query -W -f='${db:Status-Status}' "$purge_candidate" 2>/dev/null | grep -Fxq installed; then
      purge_candidates+=("$purge_candidate")
    fi
  done
  if [ "${#purge_candidates[@]}" -gt 0 ]; then
    apt_secure purge -y "${purge_candidates[@]}"
  fi
  apt_secure autoremove -y --purge
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd
  if dpkg-query -W -f='${Status}' snapd 2>/dev/null | grep -q 'install ok installed'; then
    echo 'snapd is still installed despite DISABLE_SNAPD=1' >&2
    exit 1
  fi
fi

if [ "$CLEAN_APT_CACHE" = 1 ]; then
  apt-get clean
fi
rm -f /etc/apt/apt.conf.d/99ci-proxy

rm -f /etc/machine-id
touch /etc/machine-id
rm -f /root/.bash_history "/home/${DEFAULT_USER_NAME}/.bash_history"
rm -rf /tmp/* /root/ci-provision.sh
PROVISION
chmod +x "$rootfs_dir/root/ci-provision.sh"

if [ -n "${DEB_ARCHIVE:-}" ]; then
  tmp_archive="$work_dir/debs.archive"
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_download "$DEB_ARCHIVE" "$tmp_archive" "$DEB_ARCHIVE_SHA256"
  ci_extract_archive "$tmp_archive" "$rootfs_dir/var/tmp/ci-debs"
fi
if [ -n "${DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  while IFS= read -r -d '' deb; do
    ci_copy_deb_unique "$deb" "$rootfs_dir/var/tmp/ci-debs" 'device DEB directory member'
  done < <(find "$DEB_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
fi
if [ -n "${SENSOR_DEB_ARCHIVE:-}" ]; then
  include_deb_archive sensor "$SENSOR_DEB_ARCHIVE" "$SENSOR_DEB_ARCHIVE_SHA256"
fi
if [ -n "${SENSOR_DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_log "including source-built sensor debs from: $SENSOR_DEB_DIR"
  while IFS= read -r -d '' deb; do
    ci_copy_deb_unique "$deb" "$rootfs_dir/var/tmp/ci-debs" 'sensor DEB directory member'
  done < <(find "$SENSOR_DEB_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
fi
if [ -n "${HAPTICS_DEB_ARCHIVE:-}" ]; then
  include_deb_archive haptics "$HAPTICS_DEB_ARCHIVE" "$HAPTICS_DEB_ARCHIVE_SHA256"
fi
if [ -n "${HAPTICS_DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_log "including source-built haptics debs from: $HAPTICS_DEB_DIR"
  while IFS= read -r -d '' deb; do
    ci_copy_deb_unique "$deb" "$rootfs_dir/var/tmp/ci-debs" 'haptics DEB directory member'
  done < <(find "$HAPTICS_DEB_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
fi
if [ -n "${CAMERA_STACK_DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_log "including source-built camera stack debs from: $CAMERA_STACK_DEB_DIR"
  while IFS= read -r -d '' deb; do
    ci_copy_deb_unique "$deb" "$rootfs_dir/var/tmp/ci-debs" 'camera DEB directory member'
  done < <(find "$CAMERA_STACK_DEB_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
fi

ci_prepare_y700_daily_payload_deb \
  "$rootfs_dir/var/tmp/ci-debs" "$work_dir/device-deb-policy"
prepare_tb321fu_compat_firmware_deb "$rootfs_dir/var/tmp/ci-debs"
ci_assert_unique_deb_packages "$rootfs_dir/var/tmp/ci-debs"

if ci_bool "$INSTALL_FIREFOX"; then
  configure_mozilla_firefox_repo "$rootfs_dir"
fi

apt_transaction_dir=/var/lib/tb321fu-build-provenance/apt-transactions
install -d -m 0700 "$rootfs_dir$apt_transaction_dir"
install -m 0755 "$SCRIPT_DIR/apt-transaction-provenance.sh" \
  "$rootfs_dir/root/ci-apt-transaction.sh"
install -m 0644 "$SCRIPT_DIR/common.sh" "$rootfs_dir/root/ci-apt-common.sh"
apt_recorder_sha256=$(sha256sum "$rootfs_dir/root/ci-apt-transaction.sh" | awk '{print $1}')
apt_common_sha256=$(sha256sum "$rootfs_dir/root/ci-apt-common.sh" | awk '{print $1}')

ci_log "provisioning rootfs"
chroot "$rootfs_dir" env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root \
  LANG=C.UTF-8 \
  PACKAGE_LIST="$PACKAGE_LIST" \
  INSTALL_FCITX5_CHINESE="$INSTALL_FCITX5_CHINESE" \
  DEFAULT_USER_NAME="$DEFAULT_USER_NAME" \
  DEFAULT_USER_PASSWORD_HASH="$DEFAULT_USER_PASSWORD_HASH" \
  DEFAULT_USER_AUTHORIZED_KEYS="$DEFAULT_USER_AUTHORIZED_KEYS" \
  ROOT_PASSWORD_MODE="$ROOT_PASSWORD_MODE" \
  ROOT_PASSWORD_HASH="$ROOT_PASSWORD_HASH" \
  USER_SUDO_MODE="$USER_SUDO_MODE" \
  INSTALL_FIREFOX="$INSTALL_FIREFOX" \
  DISABLE_SNAPD="$DISABLE_SNAPD" \
  TZ_REGION="$TZ_REGION" \
  LOCALES="$LOCALES" \
  LANG_NAME="$LANG_NAME" \
  APT_HTTP_PROXY="$APT_HTTP_PROXY" \
  APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
  http_proxy="$APT_HTTP_PROXY" \
  https_proxy="$APT_HTTPS_PROXY" \
  HTTP_PROXY="$APT_HTTP_PROXY" \
  HTTPS_PROXY="$APT_HTTPS_PROXY" \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  CI_APT_COMMON_SH=/root/ci-apt-common.sh \
  CI_APT_RECORDER_SHA256="$apt_recorder_sha256" \
  CI_APT_COMMON_SHA256="$apt_common_sha256" \
  APT_PROVENANCE_DIR="$apt_transaction_dir" \
  APT_PROVENANCE_PHASE=rootfs-provision \
  CLEAN_APT_CACHE="$CLEAN_APT_CACHE" \
  bash /root/ci-provision.sh

device_payload_snapshot="$work_dir/local-device-payload-before-overlay.tsv"
ci_snapshot_local_deb_payload \
  "$rootfs_dir" "$rootfs_dir/var/tmp/ci-debs" \
  "$work_dir/local-device-payload-before-overlay-stage" "$device_payload_snapshot"

rm -f "$rootfs_dir/etc/resolv.conf"
if [ -f "$original_resolv_link" ]; then
  ln -s "$(cat "$original_resolv_link")" "$rootfs_dir/etc/resolv.conf"
elif [ -f "$original_resolv" ]; then
  cp -a "$original_resolv" "$rootfs_dir/etc/resolv.conf"
else
  ln -s ../run/systemd/resolve/stub-resolv.conf "$rootfs_dir/etc/resolv.conf"
fi

overlay_stage=
if [ -n "${OVERLAY_ARCHIVE:-}" ]; then
  tmp_overlay="$work_dir/overlay.archive"
  overlay_stage="$work_dir/final-overlay"
  mkdir -p "$overlay_stage"
  ci_log "staging overlay archive: $OVERLAY_ARCHIVE"
  ci_download "$OVERLAY_ARCHIVE" "$tmp_overlay" "$OVERLAY_ARCHIVE_SHA256"
  ci_extract_archive "$tmp_overlay" "$overlay_stage"
  ci_validate_rootfs_overlay_tree "$overlay_stage"
fi
if [ -n "${OVERLAY_DIR:-}" ]; then
  ci_validate_rootfs_overlay_tree "$OVERLAY_DIR"
fi

unmount_chroot_runtime

if [ -n "$overlay_stage" ]; then
  ci_log "applying staged overlay archive: $OVERLAY_ARCHIVE"
  rsync -aH --numeric-ids "$overlay_stage"/ "$rootfs_dir"/
fi
if [ -n "${OVERLAY_DIR:-}" ]; then
  ci_log "applying validated overlay directory: $OVERLAY_DIR"
  rsync -aH --numeric-ids "$OVERLAY_DIR"/ "$rootfs_dir"/
fi
if [ -f "$device_payload_snapshot" ]; then
  ci_verify_local_deb_payload_snapshot "$rootfs_dir" "$device_payload_snapshot"
fi
rm -rf -- "$rootfs_dir/var/tmp/ci-debs"

apply_sddm_autologin "$rootfs_dir"
apply_tb321fu_legacy_cleanup "$rootfs_dir"

if ci_bool "$APPLY_Y700_FIRMWARE_FIXES"; then
  apply_y700_firmware_fixes "$rootfs_dir"
fi
if ci_bool "$APPLY_Y700_AUDIO_POLICY_FIXES"; then
  apply_y700_audio_policy_fixes "$rootfs_dir"
fi
if ci_bool "$BUILD_TB321FU_GPU_SENSOR"; then
  # An optional overlay is not allowed to replace the trusted recorder used
  # for the later GPU-build APT transactions.
  install -m 0755 "$SCRIPT_DIR/apt-transaction-provenance.sh" \
    "$rootfs_dir/root/ci-apt-transaction.sh"
  install -m 0644 "$SCRIPT_DIR/common.sh" "$rootfs_dir/root/ci-apt-common.sh"
  apply_tb321fu_gpu_sensor "$rootfs_dir"
fi

# Run this after all optional overlay content has been applied. Existing user
# settings are retained; only an absent file receives the package-owned
# default from /etc/skel.
ci_seed_default_user_keyboard_config "$rootfs_dir" "$DEFAULT_USER_NAME"

ci_log "writing transaction-scoped APT provenance"
bash "$SCRIPT_DIR/write-apt-provenance.sh" finalize \
  "$rootfs_dir" "$bootstrap_provenance" "$apt_provenance" "$apt_sources"
install -m 0644 "$bootstrap_provenance" "$apt_bootstrap"
rm -rf "$rootfs_dir/var/lib/tb321fu-build-provenance"
rm -f "$rootfs_dir/root/ci-apt-transaction.sh" "$rootfs_dir/root/ci-apt-common.sh"
if [ "$CLEAN_APT_CACHE" = 1 ]; then
  rm -rf "$rootfs_dir/var/lib/apt/lists"/*
fi

ci_assert_privileged_payload_security "$rootfs_dir" \
  usr/libexec/tb321fu-haptics/bind-aw86937 \
  opt/libcamera-y700/bin/cam \
  opt/libcamera-y700/bin/libcamera-bug-report \
  opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy \
  usr/local/bin/y700-camera-env \
  usr/local/bin/y700-camera-cam \
  usr/local/bin/y700-camera-preview

cat > "$build_info" <<INFO
generated=$(ci_iso8601_timestamp)
distro=$DISTRO
arch=$ARCH
debootstrap_variant=$DEBOOTSTRAP_VARIANT
mirror=$MIRROR
hostname=$HOSTNAME_NAME
default_user=$DEFAULT_USER_NAME
root_password_mode=$ROOT_PASSWORD_MODE
user_sudo_mode=$USER_SUDO_MODE
sddm_autologin=$SDDM_AUTOLOGIN
sddm_autologin_session=$SDDM_AUTOLOGIN_SESSION
rootfs_label=$ROOTFS_LABEL
rootfs_uuid=${ROOTFS_UUID:-}
rootfs_partlabel=$ROOTFS_PARTLABEL
overlay_archive=${OVERLAY_ARCHIVE:-}
overlay_dir=${OVERLAY_DIR:-}
deb_archive=${DEB_ARCHIVE:-}
deb_dir=${DEB_DIR:-}
sensor_deb_archive=${SENSOR_DEB_ARCHIVE:-}
sensor_deb_dir=${SENSOR_DEB_DIR:-}
haptics_deb_archive=${HAPTICS_DEB_ARCHIVE:-}
haptics_deb_dir=${HAPTICS_DEB_DIR:-}
camera_stack_deb_dir=${CAMERA_STACK_DEB_DIR:-}
apt_provenance_sha256=$(sha256sum "$apt_provenance" | awk '{print $1}')
apt_sources_sha256=$(sha256sum "$apt_sources" | awk '{print $1}')
apt_bootstrap_sha256=$(sha256sum "$apt_bootstrap" | awk '{print $1}')
build_tb321fu_gpu_sensor=$BUILD_TB321FU_GPU_SENSOR
tb321fu_gpu_sensor_source_dir=${TB321FU_GPU_SENSOR_SOURCE_DIR:-repo-default}
install_gnome_snapshot=$INSTALL_GNOME_SNAPSHOT
install_firefox=$INSTALL_FIREFOX
install_fcitx5_chinese=$INSTALL_FCITX5_CHINESE
disable_snapd=$DISABLE_SNAPD
apply_y700_firmware_fixes=$APPLY_Y700_FIRMWARE_FIXES
apply_y700_audio_policy_fixes=$APPLY_Y700_AUDIO_POLICY_FIXES
INFO

rm -f \
  "$rootfs_dir/BUILD-INFO.txt" \
  "$rootfs_dir/SHA256SUMS" \
  "$rootfs_dir/SHA256SUMS.txt" \
  "$rootfs_dir/Y700-ROOTFS-OVERLAY-MANIFEST.tsv"

ci_log "writing installed-package inventory"
LC_ALL=C chroot "$rootfs_dir" dpkg-query -W \
  -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Architecture}\n' |
  LC_ALL=C awk -F '\t' '$1 == "ii " { print $2 "\t" $3 "\t" $4 }' |
  LC_ALL=C sort > "$package_inventory"
[ -s "$package_inventory" ] || ci_die "installed-package inventory is empty"

ci_log "writing manifest"
(cd "$rootfs_dir" && find . -xdev -printf '%y\t%u\t%g\t%m\t%s\t%p\n' | sort) > "$manifest"

ci_unmount_tree "$rootfs_dir"
mounted=0
ci_e2fsck_repair "$rootfs_img" 0

ci_log "checksumming rootfs image"
raw_sha_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.raw.sha256"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" > "$(basename "$raw_sha_file")")

checksum_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.SHA256SUMS"
rm -f "$checksum_file"
(cd "$OUTPUT_DIR" && sha256sum \
  "$(basename "$build_info")" \
  "$(basename "$manifest")" \
  "$(basename "$package_inventory")" \
  "$(basename "$apt_provenance")" \
  "$(basename "$apt_sources")" \
  "$(basename "$apt_bootstrap")" \
  "$(basename "$raw_sha_file")" > "$(basename "$checksum_file")")

case "$COMPRESS" in
  none)
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" >> "$(basename "$checksum_file")")
    ;;
  zstd)
    ci_require_cmd zstd
    zstd -T0 -19 -f "$rootfs_img" -o "$rootfs_img.zst"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").zst" >> "$(basename "$checksum_file")")
    ;;
  xz)
    xz -T0 -k -f "$rootfs_img"
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img").xz" >> "$(basename "$checksum_file")")
    ;;
  7z)
    ci_require_cmd 7z
    sevenz_out="$rootfs_img.7z"
    rm -f "$sevenz_out" "$sevenz_out".*
    if [ -n "${CHUNK_SIZE:-}" ]; then
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on -mtm=off -mta=off -mtc=off "-v$CHUNK_SIZE" >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")")
    else
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on -mtm=off -mta=off -mtc=off >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")")
    fi
    ;;
  *) ci_die "unsupported COMPRESS=$COMPRESS" ;;
esac

if [ "$COMPRESS" != none ] && [ "$KEEP_RAW_IMAGE" != 1 ]; then
  rm -f "$rootfs_img"
fi

ci_log "rootfs build complete: $OUTPUT_DIR"
