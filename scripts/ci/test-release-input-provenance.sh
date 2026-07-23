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

release_env=(
  RELEASE_TAG=tb321fu-test-20260723
  KERNEL_ARTIFACT_ARCHIVE=https://example.invalid/kernel.tar.gz
  KERNEL_ARTIFACT_ARCHIVE_SHA256="$sha_a"
  DEB_ARCHIVE=https://example.invalid/device.tar.gz
  DEB_ARCHIVE_SHA256="$sha_b"
  SENSOR_DEB_ARCHIVE=https://example.invalid/sensor.tar.gz
  SENSOR_DEB_ARCHIVE_SHA256="$sha_c"
  HAPTICS_DEB_ARCHIVE=https://example.invalid/haptics.tar.gz
  HAPTICS_DEB_ARCHIVE_SHA256="$sha_d"
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
require_failure 'lowercase SHA-256 for HAPTICS_DEB_ARCHIVE' \
  HAPTICS_DEB_ARCHIVE_SHA256="${sha_d^^}"
require_failure 'does not accept local CAMERA_STACK_DIR' \
  CAMERA_STACK_DIR=/tmp/camera
require_failure 'does not accept local QCOMRAMP_EFI' \
  QCOMRAMP_EFI=/tmp/QCOMRAMP.EFI
require_failure 'only one boot template input' \
  BOOT_TEMPLATE_IMAGE_URL=https://example.invalid/other-template.img

env \
  RELEASE_TAG= \
  KERNEL_ARTIFACT_ARCHIVE=/tmp/kernel.tar.gz \
  DEB_ARCHIVE=/tmp/device.tar.gz \
  SENSOR_DEB_ARCHIVE=/tmp/sensor.tar.gz \
  HAPTICS_DEB_ARCHIVE=/tmp/haptics.tar.gz \
  BOOT_TEMPLATE_IMAGE=/tmp/template.img \
  bash "$validator" >/dev/null ||
  fail 'untagged local artifact workflow was rejected'

printf 'RELEASE_INPUT_PROVENANCE=PASS tagged releases require HTTPS+SHA inputs while untagged builds retain local support\n'
