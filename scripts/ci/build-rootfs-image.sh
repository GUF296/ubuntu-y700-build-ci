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
