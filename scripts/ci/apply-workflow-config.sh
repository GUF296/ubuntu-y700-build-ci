#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/../lib/y700-direct-grub.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") CONFIG_FILE [SANITIZED_NOTES_FILE]

Read KEY=value lines from a rootfs.env, boot.env, or source.env CONFIG_FILE and
append keys allowed for that configuration domain to GITHUB_ENV.
Blank lines and lines starting with # are ignored.
Use APT_SOURCES_LIST_B64 or RESOLV_CONF_CONTENT_B64 for multiline rootfs values.
USAGE
}

[ "${1:-}" != "--help" ] || { usage; exit 0; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
[ -n "${GITHUB_ENV:-}" ] || { echo 'GITHUB_ENV is not set' >&2; exit 1; }

config_file=$1
notes_file=${2:-}
[ -f "$config_file" ] && [ ! -L "$config_file" ] || {
  echo "config file must be a regular non-symlink file: $config_file" >&2
  exit 1
}
ci_validate_no_symlink_ancestors "$config_file" CONFIG_FILE
config_size=$(stat -c '%s' -- "$config_file") || {
  echo 'unable to determine workflow config size' >&2
  exit 1
}
[[ $config_size =~ ^[0-9]+$ ]] && (( config_size <= 262144 )) || {
  echo 'workflow config must not exceed 256 KiB' >&2
  exit 1
}
if ! cmp -s "$config_file" <(LC_ALL=C tr -d '\000' < "$config_file"); then
  echo 'workflow config contains a NUL byte' >&2
  exit 1
fi

rootfs_allowed=' DISTRO ARCH MIRROR DEBOOTSTRAP_VARIANT RESOLV_CONF_CONTENT RESOLV_CONF_CONTENT_B64 APT_HTTP_PROXY APT_HTTPS_PROXY APT_SOURCES_LIST APT_SOURCES_LIST_B64 ROOTFS_IMAGE_SIZE ROOTFS_UUID ROOTFS_LABEL ROOTFS_PARTLABEL HOSTNAME_NAME DEFAULT_USER_NAME ROOT_PASSWORD_MODE USER_SUDO_MODE SDDM_AUTOLOGIN SDDM_AUTOLOGIN_SESSION TZ_REGION LOCALES LANG_NAME PACKAGE_LIST DESKTOP_ENV OVERLAY_ARCHIVE OVERLAY_ARCHIVE_SHA256 DEB_ARCHIVE DEB_ARCHIVE_SHA256 DEB_DIR SENSOR_DEB_ARCHIVE SENSOR_DEB_ARCHIVE_SHA256 SENSOR_PRODUCER_COMMIT HAPTICS_DEB_ARCHIVE HAPTICS_DEB_ARCHIVE_SHA256 HAPTICS_DEB_DIR HAPTICS_PRODUCER_COMMIT BUILD_TB321FU_CAMERA_STACK CAMERA_STACK_ARCHIVE CAMERA_STACK_ARCHIVE_SHA256 CAMERA_STACK_DIR CAMERA_STACK_DEB_VERSION BUILD_TB321FU_GPU_SENSOR TB321FU_GPU_SENSOR_SOURCE_DIR TB321FU_GPU_SENSOR_BUILD_JOBS INSTALL_GNOME_SNAPSHOT INSTALL_FIREFOX INSTALL_FCITX5_CHINESE FCITX5_CHINESE_PACKAGES DISABLE_SNAPD APPLY_Y700_FIRMWARE_FIXES APPLY_Y700_AUDIO_POLICY_FIXES CLEAN_APT_CACHE COMPRESS CHUNK_SIZE KEEP_RAW_IMAGE OUTPUT_DIR OUTPUT_PREFIX '
boot_allowed=' BOOT_TEMPLATE_IMAGE BOOT_TEMPLATE_IMAGE_URL BOOT_TEMPLATE_IMAGE_SHA256 BOOT_IMAGE_SIZE BOOT_FAT_BITS BOOT_FAT_LABEL BOOT_FAT_VOLUME_ID BOOT_SECTOR_SIZE BOOT_CLUSTER_SECTORS GRUB_TIMEOUT ROOT_SELECTOR ROOT_PARTLABEL ROOT_UUID ROOTARGS ROOTARGS_EXTRA STABLEARGS BOOT_COMPRESS BOOT_CHUNK_SIZE KEEP_BOOT_IMAGE '
source_allowed=' KERNEL_ARTIFACT_ARCHIVE KERNEL_ARTIFACT_ARCHIVE_SHA256 KERNEL_BUILD_ARCHIVE KERNEL_BUILD_ARCHIVE_SHA256 KERNEL_BOOTSTRAP_PRODUCER_COMMIT KERNEL_BOOTSTRAP_PRODUCER_TREE KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256 BOOTAA64_EFI_URL BOOTAA64_EFI_SHA256 QCOMRAMP_EFI QCOMRAMP_EFI_URL QCOMRAMP_EFI_SHA256 QCOMRAMP_CFG_NAME GRUB_BUILD_ARCHIVE GRUB_BUILD_ARCHIVE_SHA256 HAPTICS_MODULE_SHA256 HAPTICS_HELPER_BINARY_SHA256 DTB_NAME '

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
  local random delim attempt
  delim=''
  for attempt in 1 2 3 4 5 6 7 8; do
    random=$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]') || {
      echo "unable to generate a workflow delimiter for $key" >&2
      return 1
    }
    [[ $random =~ ^[[:xdigit:]]{64}$ ]] || continue
    delim="TB321FU_ENV_${key}_${random}"
    [[ $value != *"$delim"* ]] || { delim=''; continue; }
    break
  done
  [ -n "$delim" ] || {
    echo "workflow value contains every generated delimiter for $key" >&2
    return 1
  }
  {
    printf '%s<<%s\n' "$key" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$env_stage"
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
config_line_count=0

while IFS= read -r line || [ -n "$line" ]; do
  config_line_count=$((config_line_count + 1))
  (( config_line_count <= 1024 )) || {
    echo 'workflow config must not exceed 1024 lines' >&2
    exit 1
  }
  (( ${#line} <= 65536 )) || {
    echo 'workflow config contains a line longer than 64 KiB' >&2
    exit 1
  }
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
    DISTRO)
      ci_validate_distro_name "$value"
      ;;
    ARCH)
      ci_validate_arch_name "$value"
      ;;
    DEBOOTSTRAP_VARIANT)
      ci_validate_debootstrap_variant "$value"
      ;;
    ROOTFS_IMAGE_SIZE)
      ci_validate_rootfs_image_size "$value"
      ;;
    ROOTFS_UUID)
      ci_validate_uuid "$value" ROOTFS_UUID
      ;;
    ROOTFS_LABEL)
      ci_validate_rootfs_label "$value"
      ;;
    ROOTFS_PARTLABEL)
      ci_validate_partlabel "$value" ROOTFS_PARTLABEL
      ;;
    HOSTNAME_NAME)
      ci_validate_hostname "$value"
      ;;
    DEFAULT_USER_NAME)
      ci_validate_account_name "$value"
      ;;
    ROOT_PASSWORD_MODE)
      ci_validate_root_password_mode "$value"
      ;;
    USER_SUDO_MODE)
      ci_validate_user_sudo_mode "$value"
      ;;
    SDDM_AUTOLOGIN)
      ci_validate_bool "$value" SDDM_AUTOLOGIN
      ;;
    SDDM_AUTOLOGIN_SESSION)
      ci_validate_sddm_session "$value"
      ;;
    BUILD_TB321FU_GPU_SENSOR|INSTALL_GNOME_SNAPSHOT|INSTALL_FIREFOX|\
    INSTALL_FCITX5_CHINESE|DISABLE_SNAPD|APPLY_Y700_FIRMWARE_FIXES|\
    APPLY_Y700_AUDIO_POLICY_FIXES|CLEAN_APT_CACHE|KEEP_RAW_IMAGE)
      ci_validate_bool "$value" "$key"
      ;;
    BOOT_FAT_VOLUME_ID)
      [[ $value =~ ^[A-Fa-f0-9]{8}$ ]] || {
        echo 'BOOT_FAT_VOLUME_ID must contain exactly eight hexadecimal characters' >&2
        exit 1
      }
      ;;
    GRUB_TIMEOUT)
      y700_validate_timeout "$value" || exit 1
      ;;
    APT_HTTP_PROXY|APT_HTTPS_PROXY)
      ci_validate_apt_proxy "$value"
      ;;
    LOCALES)
      ci_validate_locales "$value"
      ;;
    LANG_NAME)
      ci_validate_locale_name "$value"
      ;;
    TZ_REGION)
      ci_validate_timezone "$value"
      ;;
    COMPRESS)
      ci_validate_compression "$value"
      ;;
    CHUNK_SIZE|BOOT_CHUNK_SIZE)
      ci_validate_volume_size "$value" "$key"
      ;;
    PACKAGE_LIST|FCITX5_CHINESE_PACKAGES|DESKTOP_ENV)
      ci_normalize_package_list "$value" >/dev/null
      ;;
    RESOLV_CONF_CONTENT)
      ci_validate_resolv_conf_content "$value"
      ;;
    OVERLAY_ARCHIVE|DEB_ARCHIVE|DEB_DIR|SENSOR_DEB_ARCHIVE|SENSOR_DEB_DIR|\
    HAPTICS_DEB_ARCHIVE|HAPTICS_DEB_DIR|CAMERA_STACK_DEB_DIR|\
    TB321FU_GPU_SENSOR_SOURCE_DIR)
      ci_validate_local_path_value "$value" "$key"
      ;;
  esac
  case "$key" in
    SENSOR_PRODUCER_COMMIT|HAPTICS_PRODUCER_COMMIT|KERNEL_BOOTSTRAP_PRODUCER_COMMIT|KERNEL_BOOTSTRAP_PRODUCER_TREE)
      [ -z "$value" ] || [[ $value =~ ^[0-9a-f]{40}$ ]] || {
        echo "$key must be empty or 40 lowercase hex characters" >&2
        exit 1
      }
      ;;
    HAPTICS_MODULE_SHA256|HAPTICS_HELPER_BINARY_SHA256|KERNEL_BUILD_ARCHIVE_SHA256|KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256)
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
      ci_validate_resolv_conf_content "$value"
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

# Cross-field locale validation is performed after duplicate-key precedence has
# been resolved.  The workflow's built-in profile always supplies LANG_NAME;
# standalone configs may omit either value and let the rootfs builder apply its
# documented default.
if [ "$config_domain" = rootfs ]; then
  final_locales=
  final_lang=
  for index in "${!config_keys[@]}"; do
    case "${config_keys[index]}" in
      LOCALES) final_locales=${config_values[index]} ;;
      LANG_NAME) final_lang=${config_values[index]} ;;
    esac
  done
  if [ -n "$final_locales" ] && [ -n "$final_lang" ]; then
    ci_validate_lang_name_in_locales "$final_lang" "$final_locales"
  fi
fi

if [ "$config_domain" = boot ]; then
  final_template=
  final_template_url=
  for index in "${!config_keys[@]}"; do
    case "${config_keys[index]}" in
      BOOT_TEMPLATE_IMAGE) final_template=${config_values[index]} ;;
      BOOT_TEMPLATE_IMAGE_URL) final_template_url=${config_values[index]} ;;
    esac
  done
  if [ -n "$final_template" ] && [ -n "$final_template_url" ]; then
    echo 'boot config accepts only one of BOOT_TEMPLATE_IMAGE and BOOT_TEMPLATE_IMAGE_URL' >&2
    exit 1
  fi
fi

if [ "$config_domain" = source ]; then
  final_qcomramp=
  final_qcomramp_url=
  for index in "${!config_keys[@]}"; do
    case "${config_keys[index]}" in
      QCOMRAMP_EFI) final_qcomramp=${config_values[index]} ;;
      QCOMRAMP_EFI_URL) final_qcomramp_url=${config_values[index]} ;;
    esac
  done
  if [ -n "$final_qcomramp" ] && [ -n "$final_qcomramp_url" ]; then
    echo 'source config accepts only one of QCOMRAMP_EFI and QCOMRAMP_EFI_URL' >&2
    exit 1
  fi
fi

# Validate the complete block before exposing any of it to later workflow steps.
env_stage=$(mktemp "${GITHUB_ENV}.tmp.XXXXXX") || {
  echo 'unable to create private workflow environment staging file' >&2
  exit 1
}
notes_stage=
trap 'rm -f -- "${env_stage:-}" "${notes_stage:-}"' EXIT
for index in "${!config_keys[@]}"; do
  emit_env "${config_keys[index]}" "${config_values[index]}"
done
if [ -n "$notes_file" ]; then
  ci_validate_no_symlink_ancestors "$notes_file" SANITIZED_NOTES_FILE
  ci_require_distinct_paths CONFIG_FILE "$config_file" GITHUB_ENV "$GITHUB_ENV" \
    SANITIZED_NOTES_FILE "$notes_file"
  [ ! -e "$notes_file" ] || [ -f "$notes_file" ] && [ ! -L "$notes_file" ] || {
    echo 'sanitized notes destination must be a regular non-symlink file' >&2
    exit 1
  }
  notes_stage=$(mktemp "${notes_file}.tmp.XXXXXX") || {
    echo 'unable to create private sanitized-notes staging file' >&2
    exit 1
  }
  chmod 0600 "$notes_stage"
  for index in "${!config_keys[@]}"; do
    key=${config_keys[index]}
    value=${config_values[index]}
    case "$key" in
      APT_SOURCES_LIST|RESOLV_CONF_CONTENT)
        if [ -n "$value" ]; then
          encoded=$(printf '%s' "$value" | base64 --wrap=0) || exit 1
          printf '%s_B64=%s\n' "$key" "$encoded" >> "$notes_stage"
        else
          printf '%s=\n' "$key" >> "$notes_stage"
        fi
        ;;
      *)
        ci_validate_single_line "$value" "$key sanitized note"
        [[ "$value" != *$'\t'* && "$value" != *'`'* ]] || {
          echo "$key contains text unsafe for public Markdown notes" >&2
          exit 1
        }
        printf '%s=%s\n' "$key" "$value" >> "$notes_stage"
        ;;
    esac
  done
  mv -f -- "$notes_stage" "$notes_file"
  notes_stage=
fi
cat "$env_stage" >> "$GITHUB_ENV"
rm -f -- "$env_stage"
env_stage=
