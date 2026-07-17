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

allowed=' DISTRO ARCH MIRROR DEBOOTSTRAP_VARIANT RESOLV_CONF_CONTENT APT_HTTP_PROXY APT_HTTPS_PROXY APT_SOURCES_LIST ROOTFS_IMAGE_SIZE ROOTFS_UUID ROOTFS_LABEL ROOTFS_PARTLABEL HOSTNAME_NAME DEFAULT_USER_NAME DEFAULT_USER_PASSWORD ROOT_PASSWORD_MODE ROOT_PASSWORD USER_SUDO_MODE SDDM_AUTOLOGIN SDDM_AUTOLOGIN_SESSION TZ_REGION LOCALES LANG_NAME PACKAGE_LIST DESKTOP_ENV OVERLAY_ARCHIVE OVERLAY_ARCHIVE_SHA256 DEB_ARCHIVE DEB_ARCHIVE_SHA256 DEB_DIR SENSOR_DEB_ARCHIVE SENSOR_DEB_ARCHIVE_SHA256 SENSOR_PRODUCER_COMMIT HAPTICS_DEB_ARCHIVE HAPTICS_DEB_ARCHIVE_SHA256 HAPTICS_DEB_DIR HAPTICS_PRODUCER_COMMIT HAPTICS_MODULE_SHA256 HAPTICS_HELPER_BINARY_SHA256 CAMERA_STACK_DEB_DIR BUILD_TB321FU_CAMERA_STACK CAMERA_STACK_ARCHIVE CAMERA_STACK_ARCHIVE_SHA256 CAMERA_STACK_DIR CAMERA_STACK_DEB_VERSION BUILD_TB321FU_GPU_SENSOR TB321FU_GPU_SENSOR_SOURCE_DIR TB321FU_GPU_SENSOR_BUILD_JOBS INSTALL_GNOME_SNAPSHOT INSTALL_FIREFOX INSTALL_FCITX5_CHINESE FCITX5_CHINESE_PACKAGES DISABLE_SNAPD APPLY_Y700_FIRMWARE_FIXES APPLY_Y700_AUDIO_POLICY_FIXES CLEAN_APT_CACHE COMPRESS CHUNK_SIZE KEEP_RAW_IMAGE OUTPUT_DIR OUTPUT_PREFIX BOOT_TEMPLATE_IMAGE BOOT_TEMPLATE_IMAGE_URL BOOT_TEMPLATE_IMAGE_SHA256 BOOT_IMAGE_SIZE BOOT_FAT_BITS BOOT_FAT_LABEL BOOT_SECTOR_SIZE BOOT_CLUSTER_SECTORS KERNEL_ARTIFACT_ARCHIVE KERNEL_ARTIFACT_ARCHIVE_SHA256 BOOTAA64_EFI_URL BOOTAA64_EFI_SHA256 QCOMRAMP_EFI QCOMRAMP_EFI_URL QCOMRAMP_EFI_SHA256 QCOMRAMP_CFG_NAME GRUB_BUILD_ARCHIVE GRUB_BUILD_ARCHIVE_SHA256 DTB_NAME ROOT_SELECTOR ROOT_PARTLABEL ROOT_UUID ROOTARGS ROOTARGS_EXTRA STABLEARGS BOOT_COMPRESS BOOT_CHUNK_SIZE KEEP_BOOT_IMAGE BOOT_PARTLABEL '

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
  case "$key" in
    DEFAULT_USER_PASSWORD|ROOT_PASSWORD|DEFAULT_USER_PASSWORD_HASH|ROOT_PASSWORD_HASH)
      echo "password values/hashes must come from repository secrets, not config files: $key" >&2
      exit 1
      ;;
  esac
  case "$key" in
    APT_HTTP_PROXY|APT_HTTPS_PROXY)
      case "$value" in
        *@*)
          echo "proxy credentials are forbidden in public workflow config: $key" >&2
          exit 1
          ;;
      esac
      ;;
  esac
  case "$key" in
    SENSOR_PRODUCER_COMMIT|HAPTICS_PRODUCER_COMMIT)
      [ -z "$value" ] || [[ $value =~ ^[0-9a-f]{40}$ ]] || {
        echo "$key must be empty or 40 lowercase hex characters" >&2
        exit 1
      }
      ;;
    HAPTICS_MODULE_SHA256|HAPTICS_HELPER_BINARY_SHA256)
      [ -z "$value" ] || [[ $value =~ ^[0-9a-f]{64}$ ]] || {
        echo "$key must be empty or 64 lowercase hex characters" >&2
        exit 1
      }
      ;;
  esac
  case "$allowed" in
    *" $key "*) emit_env "$key" "$value" ;;
    *) echo "unsupported config key: $key" >&2; exit 1 ;;
  esac
done < "$config_file"
