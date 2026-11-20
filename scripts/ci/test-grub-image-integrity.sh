#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
builder="$SCRIPT_DIR/build-grub-image.sh"

fail() {
  printf 'GRUB_IMAGE_INTEGRITY=FAIL %s\n' "$*" >&2
  exit 1
}

for command in mkfs.vfat fsck.fat mcopy mtype cmp sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "missing fixture command: $command"
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-grub-integrity.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

printf 'fixture kernel Image\n' > "$scratch/Image"
printf 'fixture TB321FU DTB\n' > "$scratch/sm8650-lenovo-tb321fu.dtb"
printf 'fixture BOOTAA64\n' > "$scratch/BOOTAA64.EFI"
printf 'fixture QCOMRAMP\n' > "$scratch/QCOMRAMP.EFI"

run_builder() {
  local output_dir=$1
  shift
  (
    cd "$scratch"
    OUTPUT_DIR="$output_dir" \
      OUTPUT_PREFIX=fixture \
      BOOT_IMAGE_SIZE=16M \
      BOOT_FAT_BITS=16 \
      BOOT_FAT_LABEL=Y700TEST \
      BOOT_FAT_VOLUME_ID=1234ABCD \
      KERNEL_IMAGE="$scratch/Image" \
      DTB_FILE="$scratch/sm8650-lenovo-tb321fu.dtb" \
      BOOTAA64_EFI="$scratch/BOOTAA64.EFI" \
      QCOMRAMP_EFI="$scratch/QCOMRAMP.EFI" \
      BOOT_COMPRESS=none \
      KEEP_BOOT_IMAGE=1 \
      SOURCE_DATE_EPOCH=0 \
      env "$@" bash "$builder"
  )
}

mkdir -p "$scratch/fresh-grub-build/grub-core"
cat > "$scratch/fresh-grub-build/grub-mkstandalone" <<'GRUB_FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 2
printf 'fixture generated direct GRUB EFI\n' > "$output"
GRUB_FIXTURE
chmod 0755 "$scratch/fresh-grub-build/grub-mkstandalone"

run_fresh_builder() {
  local output_dir=$1
  shift
  (
    cd "$scratch"
    OUTPUT_DIR="$output_dir" \
      OUTPUT_PREFIX=fresh \
      BOOT_IMAGE_SIZE=16M \
      BOOT_FAT_BITS=16 \
      BOOT_FAT_LABEL=Y700TEST \
      BOOT_FAT_VOLUME_ID=1234ABCD \
      KERNEL_IMAGE="$scratch/Image" \
      DTB_FILE="$scratch/sm8650-lenovo-tb321fu.dtb" \
      BOOTAA64_EFI="$scratch/BOOTAA64.EFI" \
      QCOMRAMP_EFI= \
      Y700_GRUB_BUILD_DIR="$scratch/fresh-grub-build" \
      BOOT_COMPRESS=none \
      KEEP_BOOT_IMAGE=1 \
      SOURCE_DATE_EPOCH=0 \
      env "$@" bash "$builder"
  )
}

run_builder good-out
good_image="$scratch/good-out/fixture-grub-fat.img"
[ -f "$good_image" ] || fail 'fresh fixture image was not retained'
fsck.fat -n "$good_image" >/dev/null || fail 'fresh fixture FAT is inconsistent'
mcopy -i "$good_image" ::/BOOT-INFO.txt "$scratch/BOOT-INFO.txt"
for forbidden in \
  "$scratch" 'boot_template_image=' 'kernel_image_source=' 'dtb_source=' \
  'bootaa64_source=' 'qcomramp_source='; do
  if grep -Fq -- "$forbidden" "$scratch/BOOT-INFO.txt"; then
    fail "portable metadata contains forbidden source text: $forbidden"
  fi
done
for required in \
  'boot_template_origin=none' \
  'kernel_image_origin=local' \
  'bootaa64_origin=local' \
  'qcomramp_origin=local'; do
  grep -Fq -- "$required" "$scratch/BOOT-INFO.txt" ||
    fail "portable metadata omits $required"
done

real_mcopy=$(command -v mcopy)
mkdir -p "$scratch/corrupt-bin"
cat > "$scratch/corrupt-bin/mcopy" <<'MCOPY_CORRUPTOR'
#!/usr/bin/env bash
set -euo pipefail
: "${REAL_MCOPY:?}"
"$REAL_MCOPY" "$@"
for argument in "$@"; do
  if [ "$argument" = '::/Image' ]; then
    destination=${!#}
    printf 'corrupt readback\n' >> "$destination"
    break
  fi
done
MCOPY_CORRUPTOR
chmod 0755 "$scratch/corrupt-bin/mcopy"

set +e
corrupt_output=$(PATH="$scratch/corrupt-bin:$PATH" REAL_MCOPY="$real_mcopy" \
  run_builder corrupt-out 2>&1)
corrupt_status=$?
set -e
[ "$corrupt_status" -ne 0 ] ||
  fail 'fresh-image verification accepted corrupted readback bytes'
grep -Fq 'FAT readback differs for /Image' <<< "$corrupt_output" ||
  fail 'corrupted readback failed outside the byte-comparison boundary'

run_fresh_builder fresh-out
fresh_image="$scratch/fresh-out/fresh-grub-fat.img"
[ -f "$fresh_image" ] || fail 'fresh generated EFI fixture image was not retained'
fsck.fat -n "$fresh_image" >/dev/null || fail 'fresh generated EFI FAT is inconsistent'
mcopy -i "$fresh_image" ::/EFI/BOOT/QCOMRAMP.EFI "$scratch/fresh-qcomramp.efi"
grep -Fq 'fixture generated direct GRUB EFI' "$scratch/fresh-qcomramp.efi" ||
  fail 'fresh generated direct EFI was not copied into the image'

printf 'GRUB_IMAGE_INTEGRITY=PASS\n'
