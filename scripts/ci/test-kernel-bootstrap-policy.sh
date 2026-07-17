#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
packager="$SCRIPT_DIR/package-kernel-bootstrap.sh"
workflow="$SCRIPT_DIR/../../.github/workflows/build-rootfs-and-grub.yml"

fail() {
  printf 'KERNEL_BOOTSTRAP_POLICY=FAIL %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local token=$1

  grep -Fq -- "$token" "$packager" || fail "missing policy token: $token"
}

require_workflow_literal() {
  local token=$1

  grep -Fq -- "$token" "$workflow" || fail "missing workflow policy token: $token"
}

[ -x "$packager" ] || fail "packager is not executable"
bash -n "$packager"
python3 "$SCRIPT_DIR/test-kernel-bundle-metadata.py"
bash "$SCRIPT_DIR/test-kernel-bundle-verifier.sh"

for token in \
  'kernel worktree must be clean $phase' \
  'kernel worktree contains ignored files $phase' \
  'kernel config SHA-256 mismatch $phase' \
  'make -C "$kernel_source" O="$kernel_build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" clean' \
  'Image modules "qcom/$DTB_NAME"' \
  'UTS_RELEASE does not match built kernel release' \
  'module vermagic mismatch' \
  'rootfs baseline changed' \
  'compat baseline changed' \
  'KBUILD_BUILD_TIMESTAMP' \
  'KBUILD_BUILD_USER' \
  'KBUILD_BUILD_HOST' \
  'KBUILD_BUILD_VERSION' \
  'KCONFIG_NOTIMESTAMP=1' \
  'find "$package_root" -type d -exec chmod 0755' \
  'kernel-bundle-id' \
  'tb321fu.kernel-bootstrap/v2' \
  'packager_sha256' \
  'common_sh_sha256' \
  'module_count'; do
  require_literal "$token"
done

for token in \
  'bash scripts/ci/test-kernel-bootstrap-policy.sh' \
  'bash scripts/ci/verify-kernel-bundle.sh' \
  'SENSOR_DEB_ARCHIVE="$SENSOR_DEB_ARCHIVE"' \
  'SENSOR_DEB_ARCHIVE_SHA256="$SENSOR_DEB_ARCHIVE_SHA256"' \
  'EXPECTED_SENSOR_PRODUCER_COMMIT="$SENSOR_PRODUCER_COMMIT"' \
  'HAPTICS_DEB_ARCHIVE="$HAPTICS_DEB_ARCHIVE"' \
  'EXPECTED_HAPTICS_PRODUCER_COMMIT="$HAPTICS_PRODUCER_COMMIT"' \
  'EXPECTED_HAPTICS_MODULE_SHA256="$HAPTICS_MODULE_SHA256"' \
  'EXPECTED_HAPTICS_HELPER_BINARY_SHA256="$HAPTICS_HELPER_BINARY_SHA256"' \
  'cat "$verified_dir/verified.env" >> "$GITHUB_ENV"' \
  'Remediation releases must set prerelease=true.' \
  'VERIFIED-INPUTS.tsv'; do
  require_workflow_literal "$token"
done

sudo_preserve_env=$(grep -F 'sudo --preserve-env=' "$workflow") ||
  fail "workflow rootfs sudo environment boundary is missing"
case "$sudo_preserve_env" in
  *HAPTICS_MODULE_SHA256*|*HAPTICS_HELPER_BINARY_SHA256*)
    fail "trusted haptics digests leak into the rootfs sudo environment"
    ;;
esac

postinst=$(awk '
  /cat > "\$package_root\/DEBIAN\/postinst" <<EOF/ { capture = 1; next }
  capture && /^EOF$/ { exit }
  capture { print }
' "$packager")
[ -n "$postinst" ] || fail "unable to extract generated postinst"
grep -Fq 'depmod "\$current_release"' <<<"$postinst" || fail "postinst does not run release-local depmod"
if grep -Eq 'rm[[:space:]]+-rf|/usr/lib/modules.*/lib/modules|for base in .*modules' <<<"$postinst"; then
  fail "postinst contains cross-release module cleanup"
fi

common_env=(
  KERNEL_SOURCE_DIR=/
  KERNEL_GIT_DIR=/
  KERNEL_BUILD_DIR=/
  EXPECTED_KERNEL_CONFIG_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  KERNEL_PACKAGE_VERSION=1
  BASE_DEVICE_DEB_ARCHIVE=/nonexistent
  BASE_DEVICE_DEB_ARCHIVE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
)

set +e
invalid_commit_output=$(env "${common_env[@]}" EXPECTED_KERNEL_COMMIT=bad bash "$packager" 2>&1)
invalid_commit_status=$?
set -e
[ "$invalid_commit_status" -ne 0 ] || fail "invalid commit was accepted"
grep -Fq 'EXPECTED_KERNEL_COMMIT must be 40 lowercase hex characters' <<<"$invalid_commit_output" ||
  fail "invalid commit failed at the wrong boundary"

set +e
invalid_jobs_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  KERNEL_BUILD_JOBS=0 bash "$packager" 2>&1)
invalid_jobs_status=$?
set -e
[ "$invalid_jobs_status" -ne 0 ] || fail "invalid build parallelism was accepted"
grep -Fq 'invalid KERNEL_BUILD_JOBS' <<<"$invalid_jobs_output" ||
  fail "invalid build parallelism failed at the wrong boundary"

set +e
invalid_dtb_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  DTB_NAME=../escape.dtb bash "$packager" 2>&1)
invalid_dtb_status=$?
set -e
[ "$invalid_dtb_status" -ne 0 ] || fail "unsafe DTB name was accepted"
grep -Fq 'unsafe DTB_NAME' <<<"$invalid_dtb_output" ||
  fail "unsafe DTB name failed at the wrong boundary"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-kernel-bootstrap-policy.XXXXXX")
cleanup() {
  rm -rf -- "$fixture"
}
trap cleanup EXIT
source_dir="$fixture/source"
build_dir="$fixture/build"
mkdir -p "$source_dir" "$build_dir"
git -C "$source_dir" init -q
git -C "$source_dir" config user.name 'TB321FU policy fixture'
git -C "$source_dir" config user.email noreply@localhost
printf 'ignored-residue\n' > "$source_dir/.gitignore"
printf 'tracked\n' > "$source_dir/tracked.txt"
git -C "$source_dir" add .gitignore tracked.txt
git -C "$source_dir" commit -qm 'fixture baseline'
printf 'CONFIG_TB321FU_FIXTURE=y\n' > "$build_dir/.config"
fixture_commit=$(git -C "$source_dir" rev-parse HEAD)
fixture_config_sha=$(sha256sum "$build_dir/.config" | awk '{print $1}')
preflight_env=(
  KERNEL_SOURCE_DIR="$source_dir"
  KERNEL_GIT_DIR="$source_dir/.git"
  KERNEL_BUILD_DIR="$build_dir"
  EXPECTED_KERNEL_COMMIT="$fixture_commit"
  EXPECTED_KERNEL_CONFIG_SHA256="$fixture_config_sha"
  KERNEL_PACKAGE_VERSION=1
  BASE_DEVICE_DEB_ARCHIVE=/nonexistent
  BASE_DEVICE_DEB_ARCHIVE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
)

preflight_output=$(env "${preflight_env[@]}" bash "$packager" --preflight)
grep -Fq 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS' <<<"$preflight_output" ||
  fail "clean preflight did not pass"

set +e
config_output=$(env "${preflight_env[@]}" \
  EXPECTED_KERNEL_CONFIG_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  bash "$packager" --preflight 2>&1)
config_status=$?
set -e
[ "$config_status" -ne 0 ] || fail "config mismatch was accepted"
grep -Fq 'kernel config SHA-256 mismatch before release packaging' <<<"$config_output" ||
  fail "config mismatch failed at the wrong boundary"

printf 'dirty\n' >> "$source_dir/tracked.txt"
set +e
dirty_output=$(env "${preflight_env[@]}" bash "$packager" --preflight 2>&1)
dirty_status=$?
set -e
[ "$dirty_status" -ne 0 ] || fail "tracked dirty source was accepted"
grep -Fq 'kernel worktree must be clean before release packaging' <<<"$dirty_output" ||
  fail "tracked dirty source failed at the wrong boundary"
printf 'tracked\n' > "$source_dir/tracked.txt"

touch "$source_dir/ignored-residue"
set +e
ignored_output=$(env "${preflight_env[@]}" bash "$packager" --preflight 2>&1)
ignored_status=$?
set -e
[ "$ignored_status" -ne 0 ] || fail "ignored source residue was accepted"
grep -Fq 'kernel worktree contains ignored files before release packaging' <<<"$ignored_output" ||
  fail "ignored source residue failed at the wrong boundary"

sensor_commit=1111111111111111111111111111111111111111
haptics_commit=2222222222222222222222222222222222222222
haptics_module_sha=$(printf '3%.0s' {1..64})
haptics_helper_binary_sha=$(printf '4%.0s' {1..64})
config_fixture="$fixture/rootfs.env"
github_env_fixture="$fixture/github.env"
{
  printf 'SENSOR_PRODUCER_COMMIT=%s\n' "$sensor_commit"
  printf 'HAPTICS_PRODUCER_COMMIT=%s\n' "$haptics_commit"
  printf 'HAPTICS_MODULE_SHA256=%s\n' "$haptics_module_sha"
  printf 'HAPTICS_HELPER_BINARY_SHA256=%s\n' "$haptics_helper_binary_sha"
} > "$config_fixture"
GITHUB_ENV="$github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$config_fixture"
read_exported_config() {
  local key=$1 file=$2
  awk -v key="$key" '
  index($0, key "<<") == 1 {
    delimiter = $0
    sub("^" key "<<", "", delimiter)
    if ((getline value) <= 0 || (getline terminator) <= 0 || terminator != delimiter)
      exit 2
    print value
    found = 1
  }
  END { if (!found) exit 3 }
  ' "$file"
}
propagated_sensor_commit=$(read_exported_config SENSOR_PRODUCER_COMMIT \
  "$github_env_fixture") || fail "SENSOR_PRODUCER_COMMIT was not exported through workflow config"
[ "$propagated_sensor_commit" = "$sensor_commit" ] ||
  fail "SENSOR_PRODUCER_COMMIT changed during workflow config propagation"
propagated_haptics_commit=$(read_exported_config HAPTICS_PRODUCER_COMMIT \
  "$github_env_fixture") || fail "HAPTICS_PRODUCER_COMMIT was not exported through workflow config"
[ "$propagated_haptics_commit" = "$haptics_commit" ] ||
  fail "HAPTICS_PRODUCER_COMMIT changed during workflow config propagation"
propagated_haptics_module_sha=$(read_exported_config HAPTICS_MODULE_SHA256 \
  "$github_env_fixture") || fail "HAPTICS_MODULE_SHA256 was not exported through workflow config"
[ "$propagated_haptics_module_sha" = "$haptics_module_sha" ] ||
  fail "HAPTICS_MODULE_SHA256 changed during workflow config propagation"
propagated_haptics_helper_binary_sha=$(read_exported_config \
  HAPTICS_HELPER_BINARY_SHA256 "$github_env_fixture") ||
  fail "HAPTICS_HELPER_BINARY_SHA256 was not exported through workflow config"
[ "$propagated_haptics_helper_binary_sha" = "$haptics_helper_binary_sha" ] ||
  fail "HAPTICS_HELPER_BINARY_SHA256 changed during workflow config propagation"

printf 'HAPTICS_MODULE_SHA256=%s\n' "$(printf 'A%.0s' {1..64})" > "$config_fixture"
set +e
invalid_haptics_digest_output=$(GITHUB_ENV="$github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$config_fixture" 2>&1)
invalid_haptics_digest_status=$?
set -e
[ "$invalid_haptics_digest_status" -ne 0 ] ||
  fail "uppercase haptics digest was accepted"
grep -Fq 'HAPTICS_MODULE_SHA256 must be empty or 64 lowercase hex characters' \
  <<<"$invalid_haptics_digest_output" ||
  fail "invalid haptics digest failed at the wrong boundary"

printf 'SENSOR_PRODUCER_COMMIT=%s\n' ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD > "$config_fixture"
set +e
invalid_sensor_commit_output=$(GITHUB_ENV="$github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$config_fixture" 2>&1)
invalid_sensor_commit_status=$?
set -e
[ "$invalid_sensor_commit_status" -ne 0 ] ||
  fail "uppercase sensor producer commit was accepted"
grep -Fq 'SENSOR_PRODUCER_COMMIT must be empty or 40 lowercase hex characters' \
  <<<"$invalid_sensor_commit_output" ||
  fail "invalid sensor producer commit failed at the wrong boundary"

printf 'KERNEL_BOOTSTRAP_POLICY=PASS\n'
