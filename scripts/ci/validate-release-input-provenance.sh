#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

readonly APPROVED_KERNEL_BOOTSTRAP_PRODUCER_COMMIT=cbc1b36c37c140271bb688c5b1a79b10e669ba2c
readonly APPROVED_KERNEL_BOOTSTRAP_PRODUCER_TREE=0d84ed4c3d8cd13b70624e47800ae932cb80acac
readonly APPROVED_KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256=f554dc63a60a8a5c31f7acac67ca654596d7ff006cdb6845be940e03ac0c3e90
readonly APPROVED_KERNEL_ARTIFACT_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/tb321fu-kernel-artifacts-7.1.1-00011-g11bbf0262857.tar.gz
readonly APPROVED_KERNEL_ARTIFACT_ARCHIVE_SHA256=ab71b3335e8a535a3e7f50dfc2c97f8932c1cddd91ec79a16188be8f08c6ce3b
readonly APPROVED_KERNEL_BUILD_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/tb321fu-kernel-build-sdk-7.1.1-00011-g11bbf0262857.tar.gz
readonly APPROVED_KERNEL_BUILD_ARCHIVE_SHA256=0b84cd9bec6c41d7c55c143cd7e945820971e4267aed66728126e6b96f753e87
readonly APPROVED_DEVICE_DEB_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/tb321fu-device-debs-7.1.1-00011-g11bbf0262857.tar.gz
readonly APPROVED_DEVICE_DEB_ARCHIVE_SHA256=16f905295d9c5644f3621e7c864da0e4653d724a4a8fe189aaaf5d302ce54490
readonly APPROVED_SENSOR_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-remediation-20260829.1/tb321fu-sensor-debs_20260829.1_arm64.tar.gz
readonly APPROVED_SENSOR_DEB_ARCHIVE_SHA256=3829d252d3e15e359cdcbe47fa99e7aa2975b29a98f132c5e04c5dfd936cc5bf
readonly APPROVED_SENSOR_PRODUCER_COMMIT=7c93f418a2e828fc156e99ac605a9b70bdcbb477
readonly APPROVED_HAPTICS_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20261120.1/tb321fu-haptics-debs_20261120.1_arm64.tar.gz
readonly APPROVED_HAPTICS_DEB_ARCHIVE_SHA256=86f9529ca06b7cee6f803c1eded3d8f2f64f749f5db825d3ab5b563a8f219210
readonly APPROVED_HAPTICS_PRODUCER_COMMIT=79ac73d521064fd5192d68e5b0cd778ce385cbe1
APPROVED_CAMERA_STACK_DEB_VERSION=$(python3 -I -B "$SCRIPT_DIR/camera-package-policy.py" version)
readonly APPROVED_CAMERA_STACK_DEB_VERSION

usage() {
  cat <<'EOF'
Usage: validate-release-input-provenance.sh

For a tagged prerelease, reject local, unpinned or unapproved producer inputs.
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

require_approved_profile_value() {
  local label=$1 value=$2 approved=$3

  [ "$value" = "$approved" ] ||
    ci_die "tagged release requires the approved $label from the committed source profile"
}

require_https_sha256 KERNEL_ARTIFACT_ARCHIVE \
  "${KERNEL_ARTIFACT_ARCHIVE:-}" "${KERNEL_ARTIFACT_ARCHIVE_SHA256:-}"
require_https_sha256 KERNEL_BUILD_ARCHIVE \
  "${KERNEL_BUILD_ARCHIVE:-}" "${KERNEL_BUILD_ARCHIVE_SHA256:-}"
require_https_sha256 DEB_ARCHIVE \
  "${DEB_ARCHIVE:-}" "${DEB_ARCHIVE_SHA256:-}"
require_https_sha256 SENSOR_DEB_ARCHIVE \
  "${SENSOR_DEB_ARCHIVE:-}" "${SENSOR_DEB_ARCHIVE_SHA256:-}"
require_https_sha256 HAPTICS_DEB_ARCHIVE \
  "${HAPTICS_DEB_ARCHIVE:-}" "${HAPTICS_DEB_ARCHIVE_SHA256:-}"

require_approved_profile_value KERNEL_ARTIFACT_ARCHIVE \
  "${KERNEL_ARTIFACT_ARCHIVE:-}" "$APPROVED_KERNEL_ARTIFACT_ARCHIVE"
require_approved_profile_value KERNEL_ARTIFACT_ARCHIVE_SHA256 \
  "${KERNEL_ARTIFACT_ARCHIVE_SHA256:-}" "$APPROVED_KERNEL_ARTIFACT_ARCHIVE_SHA256"
require_approved_profile_value KERNEL_BUILD_ARCHIVE \
  "${KERNEL_BUILD_ARCHIVE:-}" "$APPROVED_KERNEL_BUILD_ARCHIVE"
require_approved_profile_value KERNEL_BUILD_ARCHIVE_SHA256 \
  "${KERNEL_BUILD_ARCHIVE_SHA256:-}" "$APPROVED_KERNEL_BUILD_ARCHIVE_SHA256"
require_approved_profile_value DEB_ARCHIVE \
  "${DEB_ARCHIVE:-}" "$APPROVED_DEVICE_DEB_ARCHIVE"
require_approved_profile_value DEB_ARCHIVE_SHA256 \
  "${DEB_ARCHIVE_SHA256:-}" "$APPROVED_DEVICE_DEB_ARCHIVE_SHA256"
require_approved_profile_value SENSOR_DEB_ARCHIVE \
  "${SENSOR_DEB_ARCHIVE:-}" "$APPROVED_SENSOR_DEB_ARCHIVE"
require_approved_profile_value SENSOR_DEB_ARCHIVE_SHA256 \
  "${SENSOR_DEB_ARCHIVE_SHA256:-}" "$APPROVED_SENSOR_DEB_ARCHIVE_SHA256"
require_approved_profile_value SENSOR_PRODUCER_COMMIT \
  "${SENSOR_PRODUCER_COMMIT:-}" "$APPROVED_SENSOR_PRODUCER_COMMIT"
require_approved_profile_value HAPTICS_DEB_ARCHIVE \
  "${HAPTICS_DEB_ARCHIVE:-}" "$APPROVED_HAPTICS_DEB_ARCHIVE"
require_approved_profile_value HAPTICS_DEB_ARCHIVE_SHA256 \
  "${HAPTICS_DEB_ARCHIVE_SHA256:-}" "$APPROVED_HAPTICS_DEB_ARCHIVE_SHA256"
require_approved_profile_value HAPTICS_PRODUCER_COMMIT \
  "${HAPTICS_PRODUCER_COMMIT:-}" "$APPROVED_HAPTICS_PRODUCER_COMMIT"
require_approved_profile_value BUILD_TB321FU_CAMERA_STACK \
  "${BUILD_TB321FU_CAMERA_STACK:-}" 1
require_approved_profile_value CAMERA_STACK_DEB_VERSION \
  "${CAMERA_STACK_DEB_VERSION:-}" "$APPROVED_CAMERA_STACK_DEB_VERSION"
require_approved_profile_value KERNEL_BOOTSTRAP_PRODUCER_COMMIT \
  "${KERNEL_BOOTSTRAP_PRODUCER_COMMIT:-}" \
  "$APPROVED_KERNEL_BOOTSTRAP_PRODUCER_COMMIT"
require_approved_profile_value KERNEL_BOOTSTRAP_PRODUCER_TREE \
  "${KERNEL_BOOTSTRAP_PRODUCER_TREE:-}" \
  "$APPROVED_KERNEL_BOOTSTRAP_PRODUCER_TREE"
require_approved_profile_value KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256 \
  "${KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256:-}" \
  "$APPROVED_KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256"

require_empty HAPTICS_DEB_DIR "${HAPTICS_DEB_DIR:-}"
require_empty SENSOR_DEB_DIR "${SENSOR_DEB_DIR:-}"
require_empty DEB_DIR "${DEB_DIR:-}"
require_empty CAMERA_STACK_DIR "${CAMERA_STACK_DIR:-}"
[ -z "${CAMERA_STACK_ARCHIVE:-}" ] &&
  [ -z "${CAMERA_STACK_ARCHIVE_SHA256:-}" ] ||
  ci_die 'tagged release requires the committed camera source and rejects CAMERA_STACK_ARCHIVE overrides'
require_empty TB321FU_GPU_SENSOR_SOURCE_DIR "${TB321FU_GPU_SENSOR_SOURCE_DIR:-}"
require_empty BOOTAA64_EFI "${BOOTAA64_EFI:-}"
require_empty QCOMRAMP_EFI "${QCOMRAMP_EFI:-}"

if [ -n "${OVERLAY_ARCHIVE:-}" ] || [ -n "${OVERLAY_ARCHIVE_SHA256:-}" ]; then
  require_https_sha256 OVERLAY_ARCHIVE \
    "${OVERLAY_ARCHIVE:-}" "${OVERLAY_ARCHIVE_SHA256:-}"
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
if [ -n "${QCOMRAMP_EFI:-}" ] && [ -n "${QCOMRAMP_EFI_URL:-}" ]; then
  ci_die 'tagged release accepts only one QCOMRAMP EFI input'
fi
boot_template=${BOOT_TEMPLATE_IMAGE:-${BOOT_TEMPLATE_IMAGE_URL:-}}
if [ -n "${GRUB_BUILD_ARCHIVE:-}" ] && {
  [ -n "$boot_template" ] ||
  [ -n "${QCOMRAMP_EFI:-}" ] ||
  [ -n "${QCOMRAMP_EFI_URL:-}" ];
}; then
  ci_die 'tagged release cannot combine GRUB_BUILD_ARCHIVE with a template or QCOMRAMP EFI'
fi
if [ -n "$boot_template" ]; then
  require_https_sha256 BOOT_TEMPLATE_IMAGE "$boot_template" \
    "${BOOT_TEMPLATE_IMAGE_SHA256:-}"
elif [ -n "${QCOMRAMP_EFI_URL:-}" ]; then
  require_https_sha256 QCOMRAMP_EFI_URL \
    "${QCOMRAMP_EFI_URL:-}" "${QCOMRAMP_EFI_SHA256:-}"
elif [ -n "${GRUB_BUILD_ARCHIVE:-}" ]; then
  require_https_sha256 BOOTAA64_EFI_URL \
    "${BOOTAA64_EFI_URL:-}" "${BOOTAA64_EFI_SHA256:-}"
else
  ci_die 'tagged release requires a pinned boot template, QCOMRAMP EFI, or GRUB build archive'
fi

printf 'RELEASE_INPUT_PROVENANCE=PASS\n'
