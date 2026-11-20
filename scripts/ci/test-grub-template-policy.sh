#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
builder="$SCRIPT_DIR/build-grub-image.sh"

fail() {
  printf 'GRUB_TEMPLATE_POLICY=FAIL %s\n' "$*" >&2
  exit 1
}

[ -x "$builder" ] || fail 'builder is not executable'
bash -n "$builder"
for command in mkfs.vfat fsck.fat mcopy mdir mtype cmp sha256sum dd; do
  command -v "$command" >/dev/null 2>&1 || fail "missing fixture command: $command"
done

for token in \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_SELECTOR' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_PARTLABEL' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOT_UUID' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS_EXTRA' \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for non-template STABLEARGS' \
  'direct_boot_config_mode=template-preserved' \
  'direct_boot_config_mode=external-replaced' \
  'requested_rootargs=$generated_rootargs' \
  'fsck.fat -n "$boot_img"' \
  'verify_fat_file "$boot_img"' \
  'verify_fresh_fat_tree "$boot_img" "$payload_dir"' \
  'verify_template_fat_closure' \
  'boot_template_origin=$boot_template_origin' \
  'kernel_image_sha256=$kernel_image_digest'; do
  grep -Fq -- "$token" "$builder" || fail "missing template policy token: $token"
done
grep -Fq 'require_regular_file QCOMRAMP_EFI "$QCOMRAMP_EFI"' "$builder" ||
  fail 'local QCOMRAMP EFI regular-file validation is missing'

scratch=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-grub-template-policy.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

template_seed="$scratch/template-seed"
mkdir -p "$template_seed/EFI/BOOT" \
  "$template_seed/boot/grub/arm64-efi" \
  "$template_seed/dtb" \
  "$template_seed/template-dir"
printf 'template BOOTAA64 bytes\n' > "$template_seed/EFI/BOOT/BOOTAA64.EFI"
printf 'template QCOMRAMP bytes\n' > "$template_seed/EFI/BOOT/QCOMRAMP.EFI"
printf 'template direct config\n' > "$template_seed/EFI/BOOT/qcomramp.cfg"
printf 'template outer config\n' > "$template_seed/boot/grub/arm64-efi/grub.cfg"
printf 'template DTB\n' > "$template_seed/dtb/template.dtb"
printf 'template preserved payload\n' > "$template_seed/template-only.txt"
printf 'nested preserved payload\n' > "$template_seed/template-dir/nested.txt"

template="$scratch/template.img"
truncate -s 16M "$template"
mkfs.vfat --invariant -F 16 -S 512 -n Y700TPL -i 1234ABCD "$template" >/dev/null
mcopy -s -m -i "$template" \
  "$template_seed/EFI" "$template_seed/boot" "$template_seed/dtb" \
  "$template_seed/template-only.txt" "$template_seed/template-dir" ::/
fsck.fat -n "$template" >/dev/null || fail 'fixture template FAT is inconsistent'
template_sha=$(sha256sum "$template" | awk '{print $1}')

printf 'fixture kernel Image\n' > "$scratch/Image"
printf 'fixture TB321FU DTB\n' > "$scratch/sm8650-lenovo-tb321fu.dtb"
printf 'fixture QCOMRAMP\n' > "$scratch/local-QCOMRAMP.EFI"
ln -s "$scratch/local-QCOMRAMP.EFI" "$scratch/QCOMRAMP-link.EFI"

logging_bin="$scratch/logging-bin"
mkdir -p "$logging_bin"
real_mcopy=$(command -v mcopy)
cat > "$logging_bin/mcopy" <<'MCOPY_LOGGER'
#!/usr/bin/env bash
set -euo pipefail
: "${REAL_MCOPY:?}"
: "${MCOPY_LOG:?}"
printf '%s\n' "$*" >> "$MCOPY_LOG"
exec "$REAL_MCOPY" "$@"
MCOPY_LOGGER
chmod 0755 "$logging_bin/mcopy"

run_template() {
  local output_dir=$1 path_prefix=$2
  shift 2
  (
    cd "$scratch"
    env \
      OUTPUT_DIR="$output_dir" \
      OUTPUT_PREFIX=test \
      BOOT_IMAGE_SIZE=16M \
      BOOT_FAT_BITS=16 \
      BOOT_FAT_LABEL=Y700TPL \
      BOOT_FAT_VOLUME_ID=1234ABCD \
      BOOT_TEMPLATE_IMAGE="$template" \
      BOOT_TEMPLATE_IMAGE_SHA256="$template_sha" \
      KERNEL_IMAGE="$scratch/Image" \
      DTB_FILE="$scratch/sm8650-lenovo-tb321fu.dtb" \
      BOOT_COMPRESS=none \
      KEEP_BOOT_IMAGE=1 \
      SOURCE_DATE_EPOCH=0 \
      PATH="${path_prefix:+$path_prefix:}$PATH" \
      REAL_MCOPY="$real_mcopy" \
      MCOPY_LOG="${MCOPY_LOG:-$scratch/default-mcopy.log}" \
      "$@" bash "$builder"
  )
}

expect_rejection() {
  local label=$1 expected=$2
  shift 2
  local output status
  set +e
  output=$(run_template "reject-$label" '' "$@" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$label override was accepted"
  grep -Fq -- "$expected" <<<"$output" ||
    fail "$label failed at the wrong boundary"
}

expect_rejection selector \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for a non-template ROOT_PARTLABEL' \
  ROOT_PARTLABEL=alternate
expect_rejection uuid \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOT_UUID' \
  ROOT_UUID=00112233
expect_rejection rootargs \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS' \
  ROOTARGS='root=PARTLABEL=userdata rw rootwait'
expect_rejection extra \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for ROOTARGS_EXTRA' \
  ROOTARGS_EXTRA=debug
expect_rejection stableargs \
  'BOOT_TEMPLATE_IMAGE requires QCOMRAMP_EFI for non-template STABLEARGS' \
  STABLEARGS=consoleblank=1

base_log="$scratch/base.log"
MCOPY_LOG="$base_log.mcopy" run_template base-out "$logging_bin" >"$base_log" 2>&1
base_image="$scratch/base-out/test-grub-fat.img"
[ -f "$base_image" ] || fail 'template fixture image was not retained'
fsck.fat -n "$base_image" >/dev/null || fail 'template fixture FAT is inconsistent'

extract_template_file() {
  local image=$1 path=$2 output=$3
  mcopy -i "$image" "::$path" "$output" ||
    fail "cannot extract $path from fixture image"
}

extract_template_file "$base_image" /BOOT-INFO.txt "$scratch/base-BOOT-INFO.txt"
boot_info="$scratch/base-BOOT-INFO.txt"
grep -Fq 'boot_template_origin=local' "$boot_info" || fail 'template origin is missing'
grep -Fq 'boot_template_name=template.img' "$boot_info" || fail 'template name is not portable'
grep -Eq '^boot_template_sha256=[0-9a-f]{64}$' "$boot_info" || fail 'template digest is missing'
grep -Eq '^kernel_image_sha256=[0-9a-f]{64}$' "$boot_info" || fail 'kernel digest is missing'
grep -Eq '^dtb_sha256=[0-9a-f]{64}$' "$boot_info" || fail 'DTB digest is missing'
grep -Eq '^bootaa64_sha256=[0-9a-f]{64}$' "$boot_info" || fail 'BOOTAA64 digest is missing'
grep -Eq '^qcomramp_sha256=[0-9a-f]{64}$' "$boot_info" || fail 'QCOMRAMP digest is missing'
for forbidden_metadata in \
  'boot_template_image=' 'kernel_image_source=' 'dtb_source=' \
  'bootaa64_source=' 'qcomramp_source=' "$scratch"; do
  if grep -Fq -- "$forbidden_metadata" "$boot_info"; then
    fail "BOOT-INFO.txt leaked legacy/path metadata: $forbidden_metadata"
  fi
done
grep -Fq 'direct_boot_config_mode=template-preserved' "$boot_info" ||
  fail 'template mode is missing from BOOT-INFO.txt'

for preserved in \
  'EFI/BOOT/BOOTAA64.EFI' \
  'EFI/BOOT/QCOMRAMP.EFI' \
  'EFI/BOOT/qcomramp.cfg' \
  'boot/grub/arm64-efi/grub.cfg' \
  'dtb/template.dtb' \
  'template-only.txt' \
  'template-dir/nested.txt'; do
  extracted="$scratch/base-${preserved//\//_}"
  extract_template_file "$base_image" "/$preserved" "$extracted"
  cmp -s -- "$template_seed/$preserved" "$extracted" ||
    fail "template-preserved file changed: /$preserved"
done
grep -Fq -- '::/Image ' "$base_log.mcopy" || fail 'Image was not read back from FAT'
grep -Fq -- '::/dtb/platform.dtb ' "$base_log.mcopy" || fail 'platform DTB was not read back from FAT'
grep -Fq -- '::/BOOT-INFO.txt ' "$base_log.mcopy" || fail 'BOOT-INFO was not read back from FAT'
grep -Fq -- '::/SHA256SUMS.txt ' "$base_log.mcopy" || fail 'payload checksums were not read back from FAT'

external_log="$scratch/external.log"
MCOPY_LOG="$external_log.mcopy" run_template external-out "$logging_bin" \
  QCOMRAMP_EFI="$scratch/local-QCOMRAMP.EFI" ROOT_PARTLABEL=alternate \
  >"$external_log" 2>&1
grep -Fq '::/EFI/BOOT/qcomramp.cfg' "$external_log.mcopy" ||
  fail 'external QCOMRAMP EFI did not stage its matching config'
grep -Fq '::/boot/grub/arm64-efi/grub.cfg' "$external_log.mcopy" ||
  fail 'external QCOMRAMP EFI did not stage the matching outer GRUB config'

set +e
symlink_output=$(run_template symlink-out '' QCOMRAMP_EFI="$scratch/QCOMRAMP-link.EFI" 2>&1)
symlink_status=$?
set -e
[ "$symlink_status" -ne 0 ] || fail 'local QCOMRAMP EFI symlink was accepted'
grep -Fq 'QCOMRAMP_EFI must be an existing regular non-symlink file' <<<"$symlink_output" ||
  fail 'QCOMRAMP EFI symlink failed at the wrong boundary'

real_fsck=$(command -v fsck.fat)
hostile_bin="$scratch/hostile-bin"
mkdir -p "$hostile_bin"
cat > "$hostile_bin/fsck.fat" <<'FSCK_HOSTILE'
#!/usr/bin/env bash
set -euo pipefail
: "${REAL_FSCK:?}"
: "${MUTATION:?}"
: "${MUTATION_MARK:?}"
: "${REAL_MCOPY:?}"
image=${@: -1}
if [[ "$image" == */test-grub-fat.img && ! -e "$MUTATION_MARK" ]]; then
  : > "$MUTATION_MARK"
  case "$MUTATION" in
    preserved)
      printf 'hostile replacement\n' > "${MUTATION_FILE:?}"
      "$REAL_MCOPY" -o -m -i "$image" "$MUTATION_FILE" ::/template-only.txt
      ;;
    namespace)
      printf 'unexpected member\n' > "${MUTATION_FILE:?}"
      "$REAL_MCOPY" -o -m -i "$image" "$MUTATION_FILE" ::/unexpected.bin
      ;;
    profile)
      printf '\xEF\xBE\xAD\xDE' | dd of="$image" bs=1 seek=39 conv=notrunc status=none
      ;;
    *)
      printf 'unknown mutation: %s\n' "$MUTATION" >&2
      exit 2
      ;;
  esac
fi
exec "$REAL_FSCK" "$@"
FSCK_HOSTILE
chmod 0755 "$hostile_bin/fsck.fat"

expect_hostile() {
  local mutation=$1 expected=$2 output status
  local output_dir="hostile-$mutation"
  local marker="$scratch/$mutation.marker" mutation_file="$scratch/$mutation.payload"
  rm -f -- "$marker" "$mutation_file"
  set +e
  output=$(run_template "$output_dir" "$hostile_bin" \
    MUTATION="$mutation" \
    MUTATION_MARK="$marker" \
    MUTATION_FILE="$mutation_file" \
    REAL_FSCK="$real_fsck" \
    MCOPY_LOG="$scratch/$mutation.mcopy" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$mutation hostile fixture was accepted"
  grep -Fq -- "$expected" <<<"$output" ||
    fail "$mutation hostile fixture failed outside its intended boundary"
}

expect_hostile preserved 'template-preserved FAT file changed: /template-only.txt'
expect_hostile namespace 'final FAT namespace differs from template plus staged overlay'
expect_hostile profile 'FAT image size or boot-sector/BPB profile changed'

printf 'GRUB_TEMPLATE_POLICY=PASS\n'
