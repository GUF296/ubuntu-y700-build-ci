#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
validator=$SCRIPT_DIR/validate-release-input-provenance.sh

fail() {
  printf 'RELEASE_INPUT_PROVENANCE=FAIL %s\n' "$*" >&2
  exit 1
}

[ -f "$validator" ] || fail 'validator is missing'
bash -n "$validator"

sha_a=$(printf 'a%.0s' {1..64})
sha_b=$(printf 'b%.0s' {1..64})
sha_c=$(printf 'c%.0s' {1..64})
sha_d=$(printf 'd%.0s' {1..64})
sha_e=$(printf 'e%.0s' {1..64})
sha_f=$(printf 'f%.0s' {1..64})
approved_kernel_archive=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/tb321fu-kernel-artifacts-7.1.1-00011-g11bbf0262857.tar.gz
approved_kernel_archive_sha=ab71b3335e8a535a3e7f50dfc2c97f8932c1cddd91ec79a16188be8f08c6ce3b
approved_sdk_archive=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/tb321fu-kernel-build-sdk-7.1.1-00011-g11bbf0262857.tar.gz
approved_sdk_archive_sha=0b84cd9bec6c41d7c55c143cd7e945820971e4267aed66728126e6b96f753e87
approved_device_archive=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/tb321fu-device-debs-7.1.1-00011-g11bbf0262857.tar.gz
approved_device_archive_sha=16f905295d9c5644f3621e7c864da0e4653d724a4a8fe189aaaf5d302ce54490
approved_producer_commit=cbc1b36c37c140271bb688c5b1a79b10e669ba2c
approved_producer_tree=0d84ed4c3d8cd13b70624e47800ae932cb80acac
approved_producer_tree_sha=f554dc63a60a8a5c31f7acac67ca654596d7ff006cdb6845be940e03ac0c3e90
approved_sensor_archive=https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-remediation-20260829.1/tb321fu-sensor-debs_20260829.1_arm64.tar.gz
approved_sensor_archive_sha=3829d252d3e15e359cdcbe47fa99e7aa2975b29a98f132c5e04c5dfd936cc5bf
approved_sensor_producer_commit=7c93f418a2e828fc156e99ac605a9b70bdcbb477
approved_haptics_archive=https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20261120.1/tb321fu-haptics-debs_20261120.1_arm64.tar.gz
approved_haptics_archive_sha=dd6815d0384823dbe58015aa6c77d71b29065af3b9a49682ed5904ff76db41f9
approved_haptics_producer_commit=d293ea86308e2427225385373466e2f9f1157309
approved_camera_version=$(python3 -I -B "$SCRIPT_DIR/camera-package-policy.py" version)
wrong_producer_tree_sha=$(printf '3%.0s' {1..64})

release_env=(
  RELEASE_TAG=tb321fu-test-20260723
  KERNEL_ARTIFACT_ARCHIVE="$approved_kernel_archive"
  KERNEL_ARTIFACT_ARCHIVE_SHA256="$approved_kernel_archive_sha"
  KERNEL_BUILD_ARCHIVE="$approved_sdk_archive"
  KERNEL_BUILD_ARCHIVE_SHA256="$approved_sdk_archive_sha"
  KERNEL_BOOTSTRAP_PRODUCER_COMMIT="$approved_producer_commit"
  KERNEL_BOOTSTRAP_PRODUCER_TREE="$approved_producer_tree"
  KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256="$approved_producer_tree_sha"
  DEB_ARCHIVE="$approved_device_archive"
  DEB_ARCHIVE_SHA256="$approved_device_archive_sha"
  DEB_DIR=
  SENSOR_DEB_ARCHIVE="$approved_sensor_archive"
  SENSOR_DEB_ARCHIVE_SHA256="$approved_sensor_archive_sha"
  SENSOR_PRODUCER_COMMIT="$approved_sensor_producer_commit"
  HAPTICS_DEB_ARCHIVE="$approved_haptics_archive"
  HAPTICS_DEB_ARCHIVE_SHA256="$approved_haptics_archive_sha"
  HAPTICS_PRODUCER_COMMIT="$approved_haptics_producer_commit"
  BUILD_TB321FU_CAMERA_STACK=1
  CAMERA_STACK_DEB_VERSION="$approved_camera_version"
  BOOT_TEMPLATE_IMAGE=https://example.invalid/template.img
  BOOT_TEMPLATE_IMAGE_URL=
  BOOT_TEMPLATE_IMAGE_SHA256="$sha_e"
  BOOTAA64_EFI_URL=
  BOOTAA64_EFI_SHA256=
  QCOMRAMP_EFI=
  QCOMRAMP_EFI_URL=
  QCOMRAMP_EFI_SHA256=
  GRUB_BUILD_ARCHIVE=
  GRUB_BUILD_ARCHIVE_SHA256=
  HAPTICS_DEB_DIR=
  SENSOR_DEB_DIR=
  CAMERA_STACK_DIR=
  CAMERA_STACK_ARCHIVE=
  CAMERA_STACK_ARCHIVE_SHA256=
  TB321FU_GPU_SENSOR_SOURCE_DIR=
  OVERLAY_ARCHIVE=
  OVERLAY_ARCHIVE_SHA256=
)

env "${release_env[@]}" bash "$validator" >/dev/null ||
  fail 'valid tagged-release provenance fixture was rejected'

require_failure() {
  local expected=$1
  shift
  local output status

  set +e
  output=$(env "${release_env[@]}" "$@" bash "$validator" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "accepted invalid release input: $*"
  grep -Fq -- "$expected" <<<"$output" ||
    fail "invalid release input failed at the wrong boundary: $output"
}

require_failure 'safe HTTPS URL for KERNEL_ARTIFACT_ARCHIVE' \
  KERNEL_ARTIFACT_ARCHIVE=/tmp/kernel.tar.gz
require_failure 'safe HTTPS URL for KERNEL_BUILD_ARCHIVE' \
  KERNEL_BUILD_ARCHIVE=/tmp/kernel-sdk.tar.gz
require_failure 'lowercase SHA-256 for KERNEL_BUILD_ARCHIVE' \
  KERNEL_BUILD_ARCHIVE_SHA256="${sha_f^^}"
require_failure 'approved KERNEL_ARTIFACT_ARCHIVE' \
  KERNEL_ARTIFACT_ARCHIVE=https://example.invalid/kernel.tar.gz
require_failure 'approved KERNEL_ARTIFACT_ARCHIVE_SHA256' \
  KERNEL_ARTIFACT_ARCHIVE_SHA256="$sha_a"
require_failure 'approved KERNEL_BUILD_ARCHIVE' \
  KERNEL_BUILD_ARCHIVE=https://example.invalid/kernel-sdk.tar.gz
require_failure 'approved KERNEL_BUILD_ARCHIVE_SHA256' \
  KERNEL_BUILD_ARCHIVE_SHA256="$sha_f"
require_failure 'approved DEB_ARCHIVE' \
  DEB_ARCHIVE=https://example.invalid/device.tar.gz
require_failure 'approved DEB_ARCHIVE_SHA256' \
  DEB_ARCHIVE_SHA256="$sha_b"
require_failure 'does not accept local DEB_DIR' \
  DEB_DIR=/tmp/device-debs
require_failure 'approved KERNEL_BOOTSTRAP_PRODUCER_COMMIT' \
  KERNEL_BOOTSTRAP_PRODUCER_COMMIT=1111111111111111111111111111111111111111
require_failure 'approved KERNEL_BOOTSTRAP_PRODUCER_TREE' \
  KERNEL_BOOTSTRAP_PRODUCER_TREE=2222222222222222222222222222222222222222
require_failure 'approved KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256' \
  KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256="$wrong_producer_tree_sha"
require_failure 'lowercase SHA-256 for HAPTICS_DEB_ARCHIVE' \
  HAPTICS_DEB_ARCHIVE_SHA256="${sha_d^^}"
require_failure 'approved SENSOR_DEB_ARCHIVE' \
  SENSOR_DEB_ARCHIVE=https://example.invalid/sensor.tar.gz
require_failure 'approved SENSOR_DEB_ARCHIVE_SHA256' \
  SENSOR_DEB_ARCHIVE_SHA256="$sha_a"
require_failure 'approved SENSOR_PRODUCER_COMMIT' \
  SENSOR_PRODUCER_COMMIT=1111111111111111111111111111111111111111
require_failure 'approved HAPTICS_DEB_ARCHIVE' \
  HAPTICS_DEB_ARCHIVE=https://example.invalid/haptics.tar.gz
require_failure 'approved HAPTICS_DEB_ARCHIVE_SHA256' \
  HAPTICS_DEB_ARCHIVE_SHA256="$sha_b"
require_failure 'approved HAPTICS_PRODUCER_COMMIT' \
  HAPTICS_PRODUCER_COMMIT=2222222222222222222222222222222222222222
require_failure 'does not accept local CAMERA_STACK_DIR' \
  CAMERA_STACK_DIR=/tmp/camera
require_failure 'approved BUILD_TB321FU_CAMERA_STACK' \
  BUILD_TB321FU_CAMERA_STACK=0
require_failure 'approved CAMERA_STACK_DEB_VERSION' \
  CAMERA_STACK_DEB_VERSION=20260831.1
require_failure 'requires the committed camera source' \
  CAMERA_STACK_ARCHIVE=https://example.invalid/camera.tar.gz \
  CAMERA_STACK_ARCHIVE_SHA256="$sha_a"
require_failure 'does not accept local QCOMRAMP_EFI' \
  QCOMRAMP_EFI=/tmp/QCOMRAMP.EFI
require_failure 'does not accept local BOOTAA64_EFI' \
  BOOTAA64_EFI=/tmp/BOOTAA64.EFI
require_failure 'only one boot template input' \
  BOOT_TEMPLATE_IMAGE_URL=https://example.invalid/other-template.img
require_failure 'cannot combine GRUB_BUILD_ARCHIVE' \
  GRUB_BUILD_ARCHIVE=https://example.invalid/grub.tar.gz \
  GRUB_BUILD_ARCHIVE_SHA256="$sha_f"

template_and_qcomramp_archive_env=(
  BOOT_TEMPLATE_IMAGE=
  BOOT_TEMPLATE_IMAGE_URL=https://example.invalid/template.img
  BOOT_TEMPLATE_IMAGE_SHA256="$sha_e"
  QCOMRAMP_EFI_URL=https://example.invalid/QCOMRAMP.EFI
  QCOMRAMP_EFI_SHA256="$sha_f"
)
env "${release_env[@]}" "${template_and_qcomramp_archive_env[@]}" \
  GRUB_BUILD_ARCHIVE=https://example.invalid/grub.tar.gz \
  GRUB_BUILD_ARCHIVE_SHA256="$sha_a" \
  bash "$validator" >/tmp/tb321fu-release-provenance-conflict.$$ 2>&1 &&
  fail 'accepted GRUB_BUILD_ARCHIVE with template and QCOMRAMP EFI'
grep -Fq 'cannot combine GRUB_BUILD_ARCHIVE' /tmp/tb321fu-release-provenance-conflict.$$ ||
  fail 'GRUB/template conflict failed at the wrong boundary'
rm -f /tmp/tb321fu-release-provenance-conflict.$$

# A pinned remote QCOMRAMP EFI is a valid alternative to a boot template.  The
# branch must validate the QCOMRAMP URL/digest itself and must not accidentally
# require BOOTAA64_EFI_URL.
env "${release_env[@]}" \
  BOOT_TEMPLATE_IMAGE= \
  BOOT_TEMPLATE_IMAGE_URL= \
  BOOT_TEMPLATE_IMAGE_SHA256= \
  QCOMRAMP_EFI_URL=https://example.invalid/QCOMRAMP.EFI \
  QCOMRAMP_EFI_SHA256="$sha_f" \
  BOOTAA64_EFI_URL= \
  BOOTAA64_EFI_SHA256= \
  bash "$validator" >/dev/null ||
  fail 'valid pinned QCOMRAMP EFI URL was rejected'

env \
  RELEASE_TAG= \
  KERNEL_ARTIFACT_ARCHIVE=/tmp/kernel.tar.gz \
  KERNEL_BUILD_ARCHIVE=/tmp/kernel-sdk.tar.gz \
  KERNEL_BOOTSTRAP_PRODUCER_COMMIT=1111111111111111111111111111111111111111 \
  DEB_ARCHIVE=/tmp/device.tar.gz \
  SENSOR_DEB_ARCHIVE=/tmp/sensor.tar.gz \
  HAPTICS_DEB_ARCHIVE=/tmp/haptics.tar.gz \
  BOOT_TEMPLATE_IMAGE=/tmp/template.img \
  bash "$validator" >/dev/null ||
  fail 'untagged local artifact workflow was rejected'

printf 'RELEASE_INPUT_PROVENANCE=PASS tagged releases require approved HTTPS+SHA inputs while untagged builds retain local support\n'
