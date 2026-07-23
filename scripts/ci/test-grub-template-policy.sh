#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
builder="$SCRIPT_DIR/build-grub-image.sh"

fail() {
  printf 'GRUB_TEMPLATE_POLICY=FAIL %s\n' "$*" >&2
  exit 1
}

[ -x "$builder" ] || fail "builder is not executable"
bash -n "$builder"

for token in \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_SELECTOR' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_PARTLABEL' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOT_UUID' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS_EXTRA' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for non-template STABLEARGS' \
  'direct_boot_config_mode=template-preserved' \
  'direct_boot_config_mode=external-replaced' \
  'requested_rootargs=$generated_rootargs'; do
  grep -Fq -- "$token" "$builder" || fail "missing template policy token: $token"
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-grub-template-policy.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

fake_bin="$scratch/bin"
mkdir -p "$fake_bin" "$scratch/out"
for command in mkfs.vfat mdir; do
  printf '#!/bin/sh\nexit 0\n' > "$fake_bin/$command"
  chmod 0755 "$fake_bin/$command"
done
printf '%s\n' \
  '#!/bin/sh' \
  'printf '\''%s\n'\'' "$*" >> "$MCOPY_LOG"' \
  'exit 0' > "$fake_bin/mcopy"
chmod 0755 "$fake_bin/mcopy"

template="$scratch/template.img"
image="$scratch/Image"
dtb="$scratch/sm8650-lenovo-tb321fu.dtb"
qcomramp="$scratch/QCOMRAMP.EFI"
: > "$template"
: > "$image"
: > "$dtb"
: > "$qcomramp"
template_sha=$(sha256sum "$template" | awk '{print $1}')

run_template() {
  local log=$1
  shift
  MCOPY_LOG="$log" PATH="$fake_bin:$PATH" \
    OUTPUT_DIR="$scratch/out" \
    OUTPUT_PREFIX=test \
    BOOT_TEMPLATE_IMAGE="$template" \
    BOOT_TEMPLATE_IMAGE_SHA256="$template_sha" \
    KERNEL_IMAGE="$image" \
    DTB_FILE="$dtb" \
    BOOT_COMPRESS=none \
    KEEP_BOOT_IMAGE=1 \
    env "$@" bash "$builder"
}

set +e
selector_output=$(run_template "$scratch/selector.log" ROOT_PARTLABEL=alternate 2>&1)
selector_status=$?
set -e
[ "$selector_status" -ne 0 ] || fail "template accepted an unpaired ROOT_PARTLABEL override"
grep -Fq 'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_PARTLABEL' \
  <<<"$selector_output" || fail "ROOT_PARTLABEL override failed at the wrong boundary"

set +e
stableargs_output=$(run_template "$scratch/stableargs.log" STABLEARGS=consoleblank=1 2>&1)
stableargs_status=$?
set -e
[ "$stableargs_status" -ne 0 ] || fail "template accepted an unpaired STABLEARGS override"
grep -Fq 'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for non-template STABLEARGS' \
  <<<"$stableargs_output" || fail "STABLEARGS override failed at the wrong boundary"

base_log="$scratch/base.log"
run_template "$base_log"
if grep -Eq '::/EFI/BOOT/qcomramp\.cfg|::/boot/grub/arm64-efi/grub\.cfg' "$base_log"; then
  fail "template-preserved mode overwrote a direct or outer GRUB configuration"
fi

external_log="$scratch/external.log"
run_template "$external_log" QCOMRAMP_EFI="$qcomramp" ROOT_PARTLABEL=alternate
grep -Fq '::/EFI/BOOT/qcomramp.cfg' "$external_log" ||
  fail "external QCOMRAMP EFI did not stage its matching config"
grep -Fq '::/boot/grub/arm64-efi/grub.cfg' "$external_log" ||
  fail "external QCOMRAMP EFI did not stage the matching outer GRUB config"

printf 'GRUB_TEMPLATE_POLICY=PASS\n'
