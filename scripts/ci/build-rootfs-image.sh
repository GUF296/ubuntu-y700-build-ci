#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

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
  MIRROR                     default: http://ports.ubuntu.com/ubuntu-ports
  DEBOOTSTRAP_VARIANT        default: minbase; set empty for debootstrap default
  RESOLV_CONF_CONTENT        optional /etc/resolv.conf contents for chroot
  APT_HTTP_PROXY             optional apt proxy used only during provisioning
  APT_HTTPS_PROXY            optional apt https proxy; defaults to APT_HTTP_PROXY
  APT_SOURCES_LIST           optional full sources.list replacement
  ROOTFS_IMAGE_SIZE          default: 14G
  ROOTFS_UUID                optional ext4 UUID
  ROOTFS_LABEL               default: Y700ROOTFS
  ROOTFS_PARTLABEL           metadata only, default: userdata
  HOSTNAME_NAME              default: y700
  DEFAULT_USER_NAME          default: y700
  DEFAULT_USER_PASSWORD      default: 1234
  ROOT_PASSWORD_MODE         locked|set|empty, default: locked
  ROOT_PASSWORD              used when ROOT_PASSWORD_MODE=set
  USER_SUDO_MODE             password|nopasswd|none, default: password
  TZ_REGION                  default: Asia/Shanghai
  LOCALES                    default: en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8
  LANG_NAME                  default: zh_CN.UTF-8
  PACKAGE_LIST               newline/space separated packages
  DESKTOP_ENV                optional package token appended to PACKAGE_LIST
  OVERLAY_ARCHIVE            optional local path or URL; extracted into rootfs
  OVERLAY_DIR                optional directory copied into rootfs
  DEB_ARCHIVE                optional local path or URL containing .deb files
  DEB_DIR                    optional directory containing .deb files
  APPLY_Y700_COMPAT_FIXES    apply verified Y700 compatibility fixes, default: 1
  CLEAN_APT_CACHE            default: 1
  COMPRESS                   none|zstd|xz|7z, default: 7z
  CHUNK_SIZE                 optional 7z volume size, example: 1500m
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
ci_require_cmd chroot
ci_require_cmd e2fsck
ci_require_cmd rsync
ci_require_cmd sha256sum

DISTRO=${DISTRO:-noble}
ARCH=${ARCH:-arm64}
MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
DEBOOTSTRAP_VARIANT=${DEBOOTSTRAP_VARIANT-minbase}
RESOLV_CONF_CONTENT=${RESOLV_CONF_CONTENT:-}
APT_HTTP_PROXY=${APT_HTTP_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}
APT_HTTPS_PROXY=${APT_HTTPS_PROXY:-${https_proxy:-${HTTPS_PROXY:-${APT_HTTP_PROXY:-}}}}
OUTPUT_PREFIX=${OUTPUT_PREFIX:-${DISTRO}-${ARCH}}
OUTPUT_DIR=${OUTPUT_DIR:-out/ci-rootfs}
ROOTFS_IMAGE_SIZE=${ROOTFS_IMAGE_SIZE:-14G}
ROOTFS_LABEL=${ROOTFS_LABEL:-Y700ROOTFS}
ROOTFS_PARTLABEL=${ROOTFS_PARTLABEL:-userdata}
HOSTNAME_NAME=${HOSTNAME_NAME:-y700}
DEFAULT_USER_NAME=${DEFAULT_USER_NAME:-y700}
DEFAULT_USER_PASSWORD=${DEFAULT_USER_PASSWORD:-1234}
ROOT_PASSWORD_MODE=${ROOT_PASSWORD_MODE:-locked}
ROOT_PASSWORD=${ROOT_PASSWORD:-}
USER_SUDO_MODE=${USER_SUDO_MODE:-password}
TZ_REGION=${TZ_REGION:-Asia/Shanghai}
LANG_NAME=${LANG_NAME:-zh_CN.UTF-8}
LOCALES=${LOCALES:-$'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8'}
CLEAN_APT_CACHE=${CLEAN_APT_CACHE:-1}
APPLY_Y700_COMPAT_FIXES=${APPLY_Y700_COMPAT_FIXES:-1}
COMPRESS=${COMPRESS:-7z}
CHUNK_SIZE=${CHUNK_SIZE:-1500m}
KEEP_RAW_IMAGE=${KEEP_RAW_IMAGE:-0}

default_packages="systemd systemd-sysv dbus sudo locales tzdata ca-certificates gnupg curl wget network-manager openssh-server nano vim rsync kmod initramfs-tools"
PACKAGE_LIST=${PACKAGE_LIST:-$default_packages}
if [ -n "${DESKTOP_ENV:-}" ]; then
  PACKAGE_LIST="$PACKAGE_LIST $DESKTOP_ENV"
fi

mkdir -p "$OUTPUT_DIR"
work_dir=$(mktemp -d "$OUTPUT_DIR/.rootfs-build.XXXXXX")
rootfs_dir="$work_dir/rootfs"
rootfs_img="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.img"
manifest="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.manifest"
mounted=0

apply_y700_compat_fixes() {
  local root=$1

  ci_log "applying verified Y700 compatibility fixes"

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

  install -d -m 0755 "$root/etc/systemd/system/multi-user.target.wants"
  if [ -f "$root/etc/systemd/system/y700-sns-init.service" ]; then
    ln -sfn /etc/systemd/system/y700-sns-init.service \
      "$root/etc/systemd/system/multi-user.target.wants/y700-sns-init.service"
  fi
  if [ -f "$root/etc/systemd/system/y700-audio-card-guard.service" ]; then
    ln -sfn ../y700-audio-card-guard.service \
      "$root/etc/systemd/system/multi-user.target.wants/y700-audio-card-guard.service"
  fi

  install -d -m 0755 "$root/usr/local/bin" "$root/etc/xdg/autostart" "$root/etc/sddm.conf.d"
  cat > "$root/usr/local/bin/y700-tablet-session-init" <<'Y700_TABLET_SESSION_INIT'
#!/bin/sh
set -eu

scale=2
dpi=192

if command -v kwriteconfig6 >/dev/null 2>&1; then
  kwriteconfig6 --file kdeglobals --group General --key BrowserApplication firefox.desktop || true
  kwriteconfig6 --file kdeglobals --group General --key TerminalApplication org.kde.konsole.desktop || true
  kwriteconfig6 --file kdeglobals --group General --key TerminalService org.kde.konsole.desktop || true
  kwriteconfig6 --file kdeglobals --group General --key XftDPI "$dpi" || true
  kwriteconfig6 --file kdeglobals --group Locale --key Country "cn" || true
  kwriteconfig6 --file kdeglobals --group Locale --key Language "zh_CN" || true
  kwriteconfig6 --file kdeglobals --group KScreen --key ScaleFactor "$scale" || true
  kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/org.kde.plasma.keyboard.desktop || true
  kwriteconfig6 --file kwinrc --group Wayland --key VirtualKeyboardEnabled true || true
  kwriteconfig6 --file kwinrc --group Xwayland --key Scale "$scale" || true
  kwriteconfig6 --file kded6rc --group Module-kscreen --key autoload true || true
  kwriteconfig6 --file kded6rc --group Module-powerdevil --key autoload true || true
fi

if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default firefox.desktop x-scheme-handler/http || true
  xdg-mime default firefox.desktop x-scheme-handler/https || true
  xdg-mime default org.kde.dolphin.desktop inode/directory || true
  xdg-mime default org.kde.kate.desktop text/plain || true
  xdg-mime default org.kde.ark.desktop application/zip || true
fi
Y700_TABLET_SESSION_INIT
  chmod 0755 "$root/usr/local/bin/y700-tablet-session-init"

  cat > "$root/etc/xdg/autostart/y700-tablet-session-init.desktop" <<'Y700_TABLET_SESSION_DESKTOP'
[Desktop Entry]
Type=Application
Name=Y700 Tablet Session Defaults
Exec=/usr/local/bin/y700-tablet-session-init
OnlyShowIn=KDE;
X-KDE-autostart-phase=1
NoDisplay=true
Y700_TABLET_SESSION_DESKTOP
  chmod 0644 "$root/etc/xdg/autostart/y700-tablet-session-init.desktop"

  cat > "$root/etc/sddm.conf.d/99-y700-autologin.conf" <<'Y700_SDDM_AUTOLOGIN'
[Autologin]
User=y700
Session=plasma.desktop
Relogin=false
Y700_SDDM_AUTOLOGIN
  chmod 0644 "$root/etc/sddm.conf.d/99-y700-autologin.conf"

  local required=(
    lib/firmware/qcom/gen70900_aqe.fw
    lib/firmware/qcom/gen70900_sqe.fw
    lib/firmware/qcom/gen70900_zap.mbn
    lib/firmware/qcom/gmu_gen70900.bin
    lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
    lib/firmware/qcom/vpu/vpu33_p4.mbn
    etc/systemd/system/y700-sns-init.service
    etc/systemd/system/multi-user.target.wants/y700-sns-init.service
    etc/systemd/system/y700-audio-card-guard.service
    etc/systemd/system/multi-user.target.wants/y700-audio-card-guard.service
    usr/local/sbin/y700-sns-init.sh
    usr/local/libexec/y700-iio-sensor-proxy
    usr/local/bin/y700-monitor-sensor
    usr/local/bin/y700-tablet-session-init
    etc/xdg/autostart/y700-tablet-session-init.desktop
    etc/sddm.conf.d/99-y700-autologin.conf
  )
  local rel
  for rel in "${required[@]}"; do
    [ -e "$root/$rel" ] || [ -L "$root/$rel" ] || ci_die "missing Y700 required compatibility file: $rel"
  done
}

cleanup() {
  set +e
  if [ "$mounted" = 1 ]; then
    for p in dev/pts dev proc sys run; do
      mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p"
    done
    mountpoint -q "$rootfs_dir" && umount "$rootfs_dir"
  fi
  rm -rf "$work_dir"
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

apt-get update
apt-get install -y $PACKAGE_LIST

systemctl enable NetworkManager || true
systemctl enable ssh || true

if ! id -u "$DEFAULT_USER_NAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEFAULT_USER_NAME"
fi
printf '%s:%s\n' "$DEFAULT_USER_NAME" "$DEFAULT_USER_PASSWORD" | chpasswd

case "$ROOT_PASSWORD_MODE" in
  locked)
    passwd -l root || true
    ;;
  set)
    [ -n "$ROOT_PASSWORD" ] || { echo 'ROOT_PASSWORD_MODE=set requires ROOT_PASSWORD' >&2; exit 1; }
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
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
  dpkg -i --force-overwrite /var/tmp/ci-debs/*.deb || apt-get -f install -y
fi

for ci_overlay in /var/tmp/ci-debs/*.tar /var/tmp/ci-debs/*.tar.gz /var/tmp/ci-debs/*.tgz /var/tmp/ci-debs/*.tar.xz /var/tmp/ci-debs/*.tar.zst; do
  [ -e "$ci_overlay" ] || continue
  case "$ci_overlay" in
    *.tar) tar -C / -xf "$ci_overlay" ;;
    *.tar.gz|*.tgz) tar -C / -xzf "$ci_overlay" ;;
    *.tar.xz) tar -C / -xJf "$ci_overlay" ;;
    *.tar.zst) tar -C / --zstd -xf "$ci_overlay" ;;
  esac
done

if [ "$CLEAN_APT_CACHE" = 1 ]; then
  apt-get clean
  rm -rf /var/lib/apt/lists/*
fi
rm -f /etc/apt/apt.conf.d/99ci-proxy

rm -f /etc/machine-id
touch /etc/machine-id
rm -f /root/.bash_history "/home/${DEFAULT_USER_NAME}/.bash_history"
rm -rf /tmp/* /var/tmp/ci-debs /root/ci-provision.sh
PROVISION
chmod +x "$rootfs_dir/root/ci-provision.sh"

if [ -n "${DEB_ARCHIVE:-}" ]; then
  tmp_archive="$work_dir/debs.archive"
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  ci_download "$DEB_ARCHIVE" "$tmp_archive"
  ci_extract_archive "$tmp_archive" "$rootfs_dir/var/tmp/ci-debs"
fi
if [ -n "${DEB_DIR:-}" ]; then
  mkdir -p "$rootfs_dir/var/tmp/ci-debs"
  find "$DEB_DIR" -maxdepth 1 -type f -name '*.deb' -exec cp -a {} "$rootfs_dir/var/tmp/ci-debs/" \;
fi

ci_log "provisioning rootfs"
chroot "$rootfs_dir" env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root \
  LANG=C.UTF-8 \
  PACKAGE_LIST="$PACKAGE_LIST" \
  DEFAULT_USER_NAME="$DEFAULT_USER_NAME" \
  DEFAULT_USER_PASSWORD="$DEFAULT_USER_PASSWORD" \
  ROOT_PASSWORD_MODE="$ROOT_PASSWORD_MODE" \
  ROOT_PASSWORD="$ROOT_PASSWORD" \
  USER_SUDO_MODE="$USER_SUDO_MODE" \
  TZ_REGION="$TZ_REGION" \
  LOCALES="$LOCALES" \
  LANG_NAME="$LANG_NAME" \
  APT_HTTP_PROXY="$APT_HTTP_PROXY" \
  APT_HTTPS_PROXY="$APT_HTTPS_PROXY" \
  http_proxy="$APT_HTTP_PROXY" \
  https_proxy="$APT_HTTPS_PROXY" \
  HTTP_PROXY="$APT_HTTP_PROXY" \
  HTTPS_PROXY="$APT_HTTPS_PROXY" \
  CLEAN_APT_CACHE="$CLEAN_APT_CACHE" \
  bash /root/ci-provision.sh

rm -f "$rootfs_dir/etc/resolv.conf"
if [ -f "$original_resolv_link" ]; then
  ln -s "$(cat "$original_resolv_link")" "$rootfs_dir/etc/resolv.conf"
elif [ -f "$original_resolv" ]; then
  cp -a "$original_resolv" "$rootfs_dir/etc/resolv.conf"
else
  ln -s ../run/systemd/resolve/stub-resolv.conf "$rootfs_dir/etc/resolv.conf"
fi

if [ -n "${OVERLAY_ARCHIVE:-}" ]; then
  tmp_overlay="$work_dir/overlay.archive"
  ci_log "applying overlay archive: $OVERLAY_ARCHIVE"
  ci_download "$OVERLAY_ARCHIVE" "$tmp_overlay"
  ci_extract_archive "$tmp_overlay" "$rootfs_dir"
fi
if [ -n "${OVERLAY_DIR:-}" ]; then
  ci_log "applying overlay directory: $OVERLAY_DIR"
  rsync -aH --numeric-ids "$OVERLAY_DIR"/ "$rootfs_dir"/
fi

if ci_bool "$APPLY_Y700_COMPAT_FIXES"; then
  apply_y700_compat_fixes "$rootfs_dir"
fi

cat > "$rootfs_dir/BUILD-INFO.txt" <<INFO
generated=$(date -u -Iseconds)
distro=$DISTRO
arch=$ARCH
debootstrap_variant=$DEBOOTSTRAP_VARIANT
mirror=$MIRROR
hostname=$HOSTNAME_NAME
default_user=$DEFAULT_USER_NAME
root_password_mode=$ROOT_PASSWORD_MODE
user_sudo_mode=$USER_SUDO_MODE
rootfs_label=$ROOTFS_LABEL
rootfs_uuid=${ROOTFS_UUID:-}
rootfs_partlabel=$ROOTFS_PARTLABEL
overlay_archive=${OVERLAY_ARCHIVE:-}
overlay_dir=${OVERLAY_DIR:-}
deb_archive=${DEB_ARCHIVE:-}
deb_dir=${DEB_DIR:-}
apply_y700_compat_fixes=$APPLY_Y700_COMPAT_FIXES
INFO

ci_log "writing manifest"
(cd "$rootfs_dir" && find . -xdev -printf '%y\t%u\t%g\t%m\t%s\t%p\n' | sort) > "$manifest"

for p in dev/pts dev proc sys run; do
  mountpoint -q "$rootfs_dir/$p" && umount -l "$rootfs_dir/$p"
done
umount "$rootfs_dir"
mounted=0
e2fsck -f -y "$rootfs_img"

ci_log "checksumming rootfs image"
raw_sha_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.raw.sha256"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$rootfs_img")" > "$(basename "$raw_sha_file")")

checksum_file="$OUTPUT_DIR/${OUTPUT_PREFIX}-rootfs.SHA256SUMS"
rm -f "$checksum_file"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$manifest")" "$(basename "$raw_sha_file")" > "$(basename "$checksum_file")")

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
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on "-v$CHUNK_SIZE" >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")".* >> "$(basename "$checksum_file")")
    else
      7z a "$sevenz_out" "$rootfs_img" -t7z -m0=lzma2 -mx=9 -mmt=on >/dev/null
      (cd "$OUTPUT_DIR" && sha256sum "$(basename "$sevenz_out")" >> "$(basename "$checksum_file")")
    fi
    ;;
  *) ci_die "unsupported COMPRESS=$COMPRESS" ;;
esac

if [ "$COMPRESS" != none ] && [ "$KEEP_RAW_IMAGE" != 1 ]; then
  rm -f "$rootfs_img"
fi

ci_log "rootfs build complete: $OUTPUT_DIR"
