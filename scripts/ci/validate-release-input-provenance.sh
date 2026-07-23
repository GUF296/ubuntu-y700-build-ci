#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: validate-release-input-provenance.sh

For a tagged prerelease, reject local or unpinned external producer inputs.
Untagged artifact builds intentionally retain local-path support for development.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

RELEASE_TAG=${RELEASE_TAG:-}
[ -n "$RELEASE_TAG" ] || exit 0

require_https_sha256() {
  local label=$1 uri=$2 digest=$3

  [ -n "$uri" ] || ci_die "tagged release requires $label"
  [[ ${#uri} -le 2048 &&
     $uri =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~:/@%+,-]*)?$ ]] ||
    ci_die "tagged release requires a safe HTTPS URL for $label"
  [[ $digest =~ ^[0-9a-f]{64}$ ]] ||
    ci_die "tagged release requires a lowercase SHA-256 for $label"
}

require_empty() {
  local name=$1 value=$2

  [ -z "$value" ] || ci_die "tagged release does not accept local $name"
}

require_https_sha256 KERNEL_ARTIFACT_ARCHIVE \
  "${KERNEL_ARTIFACT_ARCHIVE:-}" "${KERNEL_ARTIFACT_ARCHIVE_SHA256:-}"
require_https_sha256 DEB_ARCHIVE \
  "${DEB_ARCHIVE:-}" "${DEB_ARCHIVE_SHA256:-}"
require_https_sha256 SENSOR_DEB_ARCHIVE \
  "${SENSOR_DEB_ARCHIVE:-}" "${SENSOR_DEB_ARCHIVE_SHA256:-}"
require_https_sha256 HAPTICS_DEB_ARCHIVE \
  "${HAPTICS_DEB_ARCHIVE:-}" "${HAPTICS_DEB_ARCHIVE_SHA256:-}"

require_empty HAPTICS_DEB_DIR "${HAPTICS_DEB_DIR:-}"
require_empty SENSOR_DEB_DIR "${SENSOR_DEB_DIR:-}"
require_empty CAMERA_STACK_DIR "${CAMERA_STACK_DIR:-}"
require_empty TB321FU_GPU_SENSOR_SOURCE_DIR "${TB321FU_GPU_SENSOR_SOURCE_DIR:-}"
require_empty QCOMRAMP_EFI "${QCOMRAMP_EFI:-}"

if [ -n "${OVERLAY_ARCHIVE:-}" ] || [ -n "${OVERLAY_ARCHIVE_SHA256:-}" ]; then
  require_https_sha256 OVERLAY_ARCHIVE \
    "${OVERLAY_ARCHIVE:-}" "${OVERLAY_ARCHIVE_SHA256:-}"
fi
if [ -n "${CAMERA_STACK_ARCHIVE:-}" ] || [ -n "${CAMERA_STACK_ARCHIVE_SHA256:-}" ]; then
  require_https_sha256 CAMERA_STACK_ARCHIVE \
    "${CAMERA_STACK_ARCHIVE:-}" "${CAMERA_STACK_ARCHIVE_SHA256:-}"
fi
if [ -n "${GRUB_BUILD_ARCHIVE:-}" ] || [ -n "${GRUB_BUILD_ARCHIVE_SHA256:-}" ]; then
  require_https_sha256 GRUB_BUILD_ARCHIVE \
    "${GRUB_BUILD_ARCHIVE:-}" "${GRUB_BUILD_ARCHIVE_SHA256:-}"
fi
if [ -n "${BOOTAA64_EFI_URL:-}" ] || [ -n "${BOOTAA64_EFI_SHA256:-}" ]; then
  require_https_sha256 BOOTAA64_EFI_URL \
    "${BOOTAA64_EFI_URL:-}" "${BOOTAA64_EFI_SHA256:-}"
fi
if [ -n "${QCOMRAMP_EFI_URL:-}" ] || [ -n "${QCOMRAMP_EFI_SHA256:-}" ]; then
  require_https_sha256 QCOMRAMP_EFI_URL \
    "${QCOMRAMP_EFI_URL:-}" "${QCOMRAMP_EFI_SHA256:-}"
fi

if [ -n "${BOOT_TEMPLATE_IMAGE:-}" ] && [ -n "${BOOT_TEMPLATE_IMAGE_URL:-}" ]; then
  ci_die 'tagged release accepts only one boot template input'
fi
boot_template=${BOOT_TEMPLATE_IMAGE:-${BOOT_TEMPLATE_IMAGE_URL:-}}
if [ -n "$boot_template" ]; then
  require_https_sha256 BOOT_TEMPLATE_IMAGE "$boot_template" \
    "${BOOT_TEMPLATE_IMAGE_SHA256:-}"
elif [ -n "${QCOMRAMP_EFI_URL:-}" ]; then
  require_https_sha256 BOOTAA64_EFI_URL \
    "${BOOTAA64_EFI_URL:-}" "${BOOTAA64_EFI_SHA256:-}"
elif [ -n "${GRUB_BUILD_ARCHIVE:-}" ]; then
  require_https_sha256 BOOTAA64_EFI_URL \
    "${BOOTAA64_EFI_URL:-}" "${BOOTAA64_EFI_SHA256:-}"
else
  ci_die 'tagged release requires a pinned boot template, QCOMRAMP EFI, or GRUB build archive'
fi

printf 'RELEASE_INPUT_PROVENANCE=PASS\n'
