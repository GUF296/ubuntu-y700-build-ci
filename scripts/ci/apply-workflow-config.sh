#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") CONFIG_FILE

Read KEY=value lines from CONFIG_FILE and append allowed keys to GITHUB_ENV.
Blank lines and lines starting with # are ignored.
USAGE
}

[ "${1:-}" != "--help" ] || { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
[ -n "${GITHUB_ENV:-}" ] || { echo 'GITHUB_ENV is not set' >&2; exit 1; }

config_file=$1
[ -f "$config_file" ] || { echo "missing config file: $config_file" >&2; exit 1; }

allowed=' DISTRO ARCH MIRROR APT_SOURCES_LIST ROOTFS_IMAGE_SIZE ROOTFS_UUID ROOTFS_LABEL ROOTFS_PARTLABEL HOSTNAME_NAME DEFAULT_USER_NAME DEFAULT_USER_PASSWORD ROOT_PASSWORD_MODE ROOT_PASSWORD USER_SUDO_MODE TZ_REGION LOCALES LANG_NAME PACKAGE_LIST DESKTOP_ENV OVERLAY_ARCHIVE DEB_ARCHIVE CLEAN_APT_CACHE COMPRESS CHUNK_SIZE KEEP_RAW_IMAGE OUTPUT_DIR OUTPUT_PREFIX BOOT_IMAGE_SIZE BOOT_FAT_BITS BOOT_FAT_LABEL BOOT_SECTOR_SIZE BOOT_CLUSTER_SECTORS KERNEL_ARTIFACT_ARCHIVE BOOTAA64_EFI_URL QCOMRAMP_EFI QCOMRAMP_EFI_URL QCOMRAMP_CFG_NAME GRUB_BUILD_ARCHIVE DTB_NAME ROOT_SELECTOR ROOT_PARTLABEL ROOT_UUID ROOTARGS ROOTARGS_EXTRA STABLEARGS BOOT_COMPRESS BOOT_CHUNK_SIZE KEEP_BOOT_IMAGE BOOT_PARTLABEL '

emit_env() {
  local key=$1
  local value=$2
  local delim="EOF_${key}_$$_$(date +%s%N)"
  {
    printf '%s<<%s\n' "$key" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$GITHUB_ENV"
}

while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    ''|'#'*) continue ;;
  esac
  case "$line" in
    *=*) ;;
    *) echo "invalid config line, expected KEY=value: $line" >&2; exit 1 ;;
  esac
  key=${line%%=*}
  value=${line#*=}
  case "$key" in
    *[!A-Z0-9_]*) echo "invalid config key: $key" >&2; exit 1 ;;
  esac
  case "$allowed" in
    *" $key "*) emit_env "$key" "$value" ;;
    *) echo "unsupported config key: $key" >&2; exit 1 ;;
  esac
done < "$config_file"
