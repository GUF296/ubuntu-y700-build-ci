#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") CONFIG_FILE

Read KEY=value lines from a rootfs.env, boot.env, or source.env CONFIG_FILE and
append keys allowed for that configuration domain to GITHUB_ENV.
Blank lines and lines starting with # are ignored.
Use APT_SOURCES_LIST_B64 or RESOLV_CONF_CONTENT_B64 for multiline rootfs values.
USAGE
}

[ "${1:-}" != "--help" ] || { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
[ -n "${GITHUB_ENV:-}" ] || { echo 'GITHUB_ENV is not set' >&2; exit 1; }

config_file=$1
[ -f "$config_file" ] || { echo "missing config file: $config_file" >&2; exit 1; }

rootfs_allowed=' DISTRO ARCH MIRROR DEBOOTSTRAP_VARIANT RESOLV_CONF_CONTENT RESOLV_CONF_CONTENT_B64 APT_HTTP_PROXY APT_HTTPS_PROXY APT_SOURCES_LIST APT_SOURCES_LIST_B64 ROOTFS_IMAGE_SIZE ROOTFS_UUID ROOTFS_LABEL ROOTFS_PARTLABEL HOSTNAME_NAME DEFAULT_USER_NAME ROOT_PASSWORD_MODE USER_SUDO_MODE SDDM_AUTOLOGIN SDDM_AUTOLOGIN_SESSION TZ_REGION LOCALES LANG_NAME PACKAGE_LIST DESKTOP_ENV OVERLAY_ARCHIVE OVERLAY_ARCHIVE_SHA256 DEB_ARCHIVE DEB_ARCHIVE_SHA256 DEB_DIR SENSOR_DEB_ARCHIVE SENSOR_DEB_ARCHIVE_SHA256 SENSOR_PRODUCER_COMMIT HAPTICS_DEB_ARCHIVE HAPTICS_DEB_ARCHIVE_SHA256 HAPTICS_DEB_DIR HAPTICS_PRODUCER_COMMIT BUILD_TB321FU_CAMERA_STACK CAMERA_STACK_ARCHIVE CAMERA_STACK_ARCHIVE_SHA256 CAMERA_STACK_DIR CAMERA_STACK_DEB_VERSION BUILD_TB321FU_GPU_SENSOR TB321FU_GPU_SENSOR_SOURCE_DIR TB321FU_GPU_SENSOR_BUILD_JOBS INSTALL_GNOME_SNAPSHOT INSTALL_FIREFOX INSTALL_FCITX5_CHINESE FCITX5_CHINESE_PACKAGES DISABLE_SNAPD APPLY_Y700_FIRMWARE_FIXES APPLY_Y700_AUDIO_POLICY_FIXES CLEAN_APT_CACHE COMPRESS CHUNK_SIZE KEEP_RAW_IMAGE OUTPUT_DIR OUTPUT_PREFIX '
boot_allowed=' BOOT_TEMPLATE_IMAGE BOOT_TEMPLATE_IMAGE_URL BOOT_TEMPLATE_IMAGE_SHA256 BOOT_IMAGE_SIZE BOOT_FAT_BITS BOOT_FAT_LABEL BOOT_SECTOR_SIZE BOOT_CLUSTER_SECTORS ROOT_SELECTOR ROOT_PARTLABEL ROOT_UUID ROOTARGS ROOTARGS_EXTRA STABLEARGS BOOT_COMPRESS BOOT_CHUNK_SIZE KEEP_BOOT_IMAGE '
source_allowed=' KERNEL_ARTIFACT_ARCHIVE KERNEL_ARTIFACT_ARCHIVE_SHA256 BOOTAA64_EFI_URL BOOTAA64_EFI_SHA256 QCOMRAMP_EFI QCOMRAMP_EFI_URL QCOMRAMP_EFI_SHA256 QCOMRAMP_CFG_NAME GRUB_BUILD_ARCHIVE GRUB_BUILD_ARCHIVE_SHA256 HAPTICS_MODULE_SHA256 HAPTICS_HELPER_BINARY_SHA256 DTB_NAME '

case "${config_file##*/}" in
  rootfs.env)
    config_domain=rootfs
    allowed=$rootfs_allowed
    ;;
  boot.env)
    config_domain=boot
    allowed=$boot_allowed
    ;;
  source.env)
    config_domain=source
    allowed=$source_allowed
    ;;
  *)
    echo "cannot determine config domain from file name: $config_file (expected rootfs.env, boot.env, or source.env)" >&2
    exit 1
    ;;
esac

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

decode_ascii_base64() {
  local key=$1 value=$2 decoded_file decoded

  [[ ${#value} -ge 4 && ${#value} -le 16384 &&
     $value =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || {
    echo "$key must be canonical base64 text up to 16 KiB" >&2
    return 1
  }
  command -v base64 >/dev/null 2>&1 || {
    echo 'base64 is required to decode workflow configuration' >&2
    return 1
  }
  decoded_file=$(mktemp "${TMPDIR:-/tmp}/tb321fu-config.XXXXXX") || return 1
  if ! printf '%s' "$value" | base64 --decode > "$decoded_file"; then
    rm -f -- "$decoded_file"
    echo "$key is not valid base64" >&2
    return 1
  fi
  if [ "$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$decoded_file" | wc -c)" -ne 0 ]; then
    rm -f -- "$decoded_file"
    echo "$key must decode to printable ASCII text" >&2
    return 1
  fi
  decoded=$(<"$decoded_file")
  rm -f -- "$decoded_file"
  printf '%s' "$decoded"
}

config_keys=()
config_values=()
declare -A config_key_indexes=()

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
    *" $key "*) ;;
    *)
      echo "config key is not allowed in $config_domain config: $key" >&2
      exit 1
      ;;
  esac
  case "$key" in
    APT_SOURCES_LIST_B64)
      value=$(decode_ascii_base64 "$key" "$value") || exit 1
      key=APT_SOURCES_LIST
      ci_validate_https_apt_sources_list "$value"
      ;;
    RESOLV_CONF_CONTENT_B64)
      value=$(decode_ascii_base64 "$key" "$value") || exit 1
      key=RESOLV_CONF_CONTENT
      ;;
    APT_SOURCES_LIST)
      ci_validate_https_apt_sources_list "$value"
      ;;
  esac
  # Workflow defaults, advanced overrides, and the dedicated UI controls are
  # deliberately concatenated into one domain file. Validate every entry,
  # then export the final declaration once so precedence is deterministic
  # without relying on duplicate GITHUB_ENV assignments.
  if [ -n "${config_key_indexes[$key]+x}" ]; then
    config_values["${config_key_indexes[$key]}"]=$value
  else
    config_key_indexes[$key]=${#config_keys[@]}
    config_keys+=("$key")
    config_values+=("$value")
  fi
done < "$config_file"

# Validate the complete block before exposing any of it to later workflow steps.
for index in "${!config_keys[@]}"; do
  emit_env "${config_keys[index]}" "${config_values[index]}"
done
