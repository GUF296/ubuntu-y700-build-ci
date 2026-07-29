#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
packager="$SCRIPT_DIR/package-kernel-bootstrap.sh"
common="$SCRIPT_DIR/common.sh"
workflow="$SCRIPT_DIR/../../.github/workflows/build-rootfs-and-grub.yml"
repo_root=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
packager_relative=${packager#"$repo_root"/}

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
IFS= read -r packager_shebang < "$packager" || fail "cannot read packager shebang"
case "$packager_shebang" in
  '#!/bin/sh'|'#!/usr/bin/sh') ;;
  *) fail "packager must use a fixed absolute POSIX bootstrap interpreter" ;;
esac
packager_index_mode=$(git -C "$repo_root" ls-files --stage -- "$packager_relative" |
  awk 'NR == 1 { print $1 } END { if (NR != 1) exit 1 }') ||
  fail "unable to read the packager Git index mode"
[ "$packager_index_mode" = 100755 ] ||
  fail "packager Git index mode is $packager_index_mode, expected 100755"
[ "$(cat "$repo_root/.gitignore")" = /out/ ] ||
  fail "producer root .gitignore must contain only the canonical /out/ rule"
[ "$(git -C "$repo_root" ls-files --stage -- .gitignore | awk '{print $1}')" = 100644 ] ||
  fail "producer root .gitignore must be tracked with mode 100644"
bash -n "$packager"
python3 "$SCRIPT_DIR/test-kernel-bundle-metadata.py"
bash "$SCRIPT_DIR/test-kernel-bundle-verifier.sh"

for token in \
  'kernel worktree must be clean $phase' \
  'kernel worktree contains ignored files $phase' \
  'kernel worktree has unsafe assume-unchanged/skip-worktree index flags $phase' \
  'kernel config SHA-256 mismatch $phase' \
  'ci_sanitized_git_env "$GIT_BIN" --no-replace-objects' \
  'ci_sanitized_kernel_env' \
  'Build from a fresh private O= directory.' \
  'kernel build input changed while bootstrap packaging ran' \
  'private olddefconfig changed the approved kernel config' \
  'kernel build changed the approved kernel config' \
  ': "${EXPECTED_KERNEL_RELEASE:?set EXPECTED_KERNEL_RELEASE}"' \
  'unsafe EXPECTED_KERNEL_RELEASE' \
  '[ "$KERNEL_PACKAGE_VERSION" = "$EXPECTED_KERNEL_RELEASE" ]' \
  'KERNEL_PACKAGE_VERSION must equal EXPECTED_KERNEL_RELEASE' \
  'EXPECTED_KERNEL_RELEASE does not bind EXPECTED_KERNEL_COMMIT' \
  'verify_kernel_release_identity "$kernel_release"' \
  'kernel release mismatch: expected $EXPECTED_KERNEL_RELEASE, got $actual_release' \
  'canonical CROSS_COMPILE is not representable by the evidence schema' \
  'kernel_make -j"$KERNEL_BUILD_JOBS" Image modules "qcom/$DTB_NAME"' \
  'SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"' \
  'UTS_RELEASE does not match built kernel release' \
  'module vermagic mismatch' \
  'rootfs baseline changed' \
  'compat baseline changed' \
  'KBUILD_BUILD_TIMESTAMP' \
  'KBUILD_BUILD_USER' \
  'KBUILD_BUILD_HOST' \
  'KBUILD_BUILD_VERSION' \
  'KCONFIG_NOTIMESTAMP=1' \
  'CONFIG_RUSTC_VERSION' \
  'KERNEL_RUSTC' \
  'RUSTC="$kernel_rustc"' \
  'M4="$M4_BIN"' \
  'BISON_PKGDATADIR="$BISON_DATA_DIR"' \
  'capture_bison_data_identity' \
  'verify_bison_data_identity "$phase"' \
  'bison-data-directory' \
  'bison-data-sha256' \
  'rustc_sha256' \
  'kernel-sdk-archive-sha256' \
  'KERNEL-SDK-MANIFEST.tsv' \
  'KERNEL-TOOLCHAIN.tsv' \
  'KBUILD-FLAGS.tsv' \
  'tb321fu.kbuild-flags/v2' \
  'private-locked-tool-directory-v1' \
  'absolute-locked-sh-v1' \
  'deterministic-input-key-v1' \
  'debug-prefix-map-source-and-build-v1' \
  'prepare_kernel_locked_path "$kernel_locked_path"' \
  'build_identity_key="$actual_commit-$expected_config_sha"' \
  'kernel_build_candidate="$output_parent_candidate/.tb321fu-kernel-build-$build_identity_key"' \
  'kernel_locked_path_candidate="$output_parent_candidate/.tb321fu-kernel-tools-$build_identity_key"' \
  'deterministic private Kbuild paths changed during validation' \
  '-fdebug-prefix-map=$kernel_source=/usr/src/tb321fu-linux-source' \
  '-fdebug-prefix-map=$kernel_build=/usr/src/tb321fu-linux-build' \
  'MODULES.sha256' \
  'eight-member baseline archive must contain the complete replaceable metadata set' \
  'baseline_sdk_metadata' \
  'verify_bootstrap_producer_state' \
  'verify_kernel_bootstrap_metadata_snapshot' \
  '"$PYTHON3_BIN" -I "$runtime_bundle_verifier"' \
  'generated kernel bootstrap metadata failed canonical parser verification' \
  'CANONICAL_KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY' \
  'KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY' \
  'GITHUB_REPOSITORY' \
  'cat-file tree "$producer_tree"' \
  'kernel bootstrap producer worktree must be clean' \
  'kernel bootstrap producer repository must be GUF296/ubuntu-y700-build-ci' \
  'kernel bootstrap producer commit changed while packaging ran' \
  'kernel bootstrap producer tree changed while packaging ran' \
  'producer_repository' \
  'producer_tree_sha256' \
  'find "$package_root" -type d -exec chmod 0755' \
  'kernel-bundle-id' \
  'tb321fu.kernel-bootstrap/v3' \
  'packager_sha256' \
  'common_sh_sha256' \
  'module_count'; do
  require_literal "$token"
done

for token in \
  'readonly CI_CANONICAL_BUILD_PATH=/usr/sbin:/usr/bin:/sbin:/bin' \
  'env -i' \
  'HOME=/nonexistent' \
  'LANG=C' \
  'LC_ALL=C' \
  'TZ=UTC'; do
  grep -Fq -- "$token" "$common" ||
    fail "missing exact kernel-environment policy token: $token"
done

expected_producer_inputs=$(cat <<'EOF'
KERNEL_SOURCE_DIR
KERNEL_GIT_DIR
KERNEL_BUILD_DIR
EXPECTED_KERNEL_COMMIT
EXPECTED_KERNEL_CONFIG_SHA256
EXPECTED_KERNEL_RELEASE
KERNEL_PACKAGE_VERSION
BASE_DEVICE_DEB_ARCHIVE
BASE_DEVICE_DEB_ARCHIVE_SHA256
OUTPUT_DIR
SOURCE_DATE_EPOCH
KERNEL_BUILD_JOBS
ARCH
CROSS_COMPILE
DTB_NAME
KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_USER
KBUILD_BUILD_HOST
KBUILD_BUILD_VERSION
KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY
GITHUB_REPOSITORY
KERNEL_RUSTC
HTTPS_PROXY
HTTP_PROXY
NO_PROXY
https_proxy
http_proxy
no_proxy
EOF
)
actual_producer_inputs=$(awk '
  /^readonly -a PRODUCER_INPUT_ENV=\(/ { capture = 1; next }
  capture && /^\)/ { exit }
  capture {
    sub(/[[:space:]]*#.*/, "")
    gsub(/[[:space:]\047\042]/, "")
    if (length) print
  }
' "$packager")
[ "$actual_producer_inputs" = "$expected_producer_inputs" ] ||
  fail "whole-producer input environment is not the exact approved allowlist"

actual_bootstrap_inputs=$(awk '
  /exec \/usr\/bin\/env -i/ { capture = 1; next }
  capture && /\/usr\/bin\/bash --noprofile --norc/ { exit }
  capture {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
    sub(/=.*/, "", line)
    if (line == "PATH" || line == "HOME" || line == "LANG" ||
        line == "LC_ALL" || line == "TZ" ||
        line == "TB321FU_KERNEL_PRODUCER_ENV_POLICY") next
    print line
  }
' "$packager")
[ "$actual_bootstrap_inputs" = "$expected_producer_inputs" ] ||
  fail "POSIX producer bootstrap and Bash producer input allowlists differ"
while IFS= read -r producer_input_name; do
  printf -v producer_input_assignment '%s="${%s-}"' \
    "$producer_input_name" "$producer_input_name"
  [ "$(grep -Fc -- "$producer_input_assignment" "$packager")" -eq 1 ] ||
    fail "POSIX producer bootstrap does not copy $producer_input_name literally once"
done <<<"$expected_producer_inputs"

for token in \
  'PRODUCER_CANONICAL_PATH=/usr/sbin:/usr/bin:/sbin:/bin' \
  'PRODUCER_ENV_POLICY=isolated-allowlist-v1' \
  'readonly PRODUCER_CANONICAL_PATH' \
  'readonly PRODUCER_ENV_POLICY' \
  'exec /usr/bin/env -i' \
  '/usr/bin/bash --noprofile --norc'; do
  require_literal "$token"
done

for token in \
  'bash scripts/ci/test-kernel-bootstrap-policy.sh' \
  'bash scripts/ci/verify-kernel-bundle.sh' \
  'kmod bc' \
  'device-tree-compiler flex bison m4 build-essential' \
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
  EXPECTED_KERNEL_RELEASE=1-g000000000000
  KERNEL_PACKAGE_VERSION=1-g000000000000
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
missing_release_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  EXPECTED_KERNEL_RELEASE= bash "$packager" 2>&1)
missing_release_status=$?
set -e
[ "$missing_release_status" -ne 0 ] || fail "missing expected kernel release was accepted"
grep -Fq 'set EXPECTED_KERNEL_RELEASE' <<<"$missing_release_output" ||
  fail "missing expected kernel release failed at the wrong boundary"

set +e
invalid_release_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  EXPECTED_KERNEL_RELEASE='bad/release' KERNEL_PACKAGE_VERSION='bad/release' \
  bash "$packager" 2>&1)
invalid_release_status=$?
set -e
[ "$invalid_release_status" -ne 0 ] || fail "unsafe expected kernel release was accepted"
grep -Fq 'unsafe EXPECTED_KERNEL_RELEASE' <<<"$invalid_release_output" ||
  fail "unsafe expected kernel release failed at the wrong boundary"

set +e
unbound_release_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  EXPECTED_KERNEL_RELEASE=1-g111111111111 KERNEL_PACKAGE_VERSION=1-g111111111111 \
  bash "$packager" 2>&1)
unbound_release_status=$?
set -e
[ "$unbound_release_status" -ne 0 ] || fail "commit-unbound expected kernel release was accepted"
grep -Fq 'EXPECTED_KERNEL_RELEASE does not bind EXPECTED_KERNEL_COMMIT' \
  <<<"$unbound_release_output" ||
  fail "commit-unbound expected kernel release failed at the wrong boundary"

set +e
package_release_mismatch_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  KERNEL_PACKAGE_VERSION=2-g000000000000 bash "$packager" 2>&1)
package_release_mismatch_status=$?
set -e
[ "$package_release_mismatch_status" -ne 0 ] ||
  fail "kernel package version differing from expected release was accepted"
grep -Fq 'KERNEL_PACKAGE_VERSION must equal EXPECTED_KERNEL_RELEASE' \
  <<<"$package_release_mismatch_output" ||
  fail "kernel package version mismatch failed at the wrong boundary"

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
invalid_arch_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  ARCH=x86_64 bash "$packager" 2>&1)
invalid_arch_status=$?
set -e
[ "$invalid_arch_status" -ne 0 ] || fail "non-arm64 kernel architecture was accepted"
grep -Fq 'ARCH must be arm64' <<<"$invalid_arch_output" ||
  fail "non-arm64 kernel architecture failed at the wrong boundary"

set +e
invalid_dtb_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  DTB_NAME=../escape.dtb bash "$packager" 2>&1)
invalid_dtb_status=$?
set -e
[ "$invalid_dtb_status" -ne 0 ] || fail "unsafe DTB name was accepted"
grep -Fq 'unsafe DTB_NAME' <<<"$invalid_dtb_output" ||
  fail "unsafe DTB name failed at the wrong boundary"

set +e
invalid_cross_compile_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  CROSS_COMPILE='../hostile-' bash "$packager" 2>&1)
invalid_cross_compile_status=$?
set -e
[ "$invalid_cross_compile_status" -ne 0 ] || fail "unsafe cross compiler prefix was accepted"
grep -Fq 'unsafe CROSS_COMPILE' <<<"$invalid_cross_compile_output" ||
  fail "unsafe cross compiler prefix failed at the wrong boundary"

set +e
relative_slash_cross_compile_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  CROSS_COMPILE='toolchains/aarch64-linux-gnu-' bash "$packager" 2>&1)
relative_slash_cross_compile_status=$?
set -e
[ "$relative_slash_cross_compile_status" -ne 0 ] ||
  fail "relative slash-containing cross compiler prefix was accepted"
grep -Eq 'unsafe CROSS_COMPILE|CROSS_COMPILE containing a slash must be absolute' \
  <<<"$relative_slash_cross_compile_output" ||
  fail "relative slash-containing cross compiler prefix failed at the wrong boundary"

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
release_make_marker="$fixture/kernel-make-targets.log"
printf 'ignored-residue\n' > "$source_dir/.gitignore"
printf 'tracked\n' > "$source_dir/tracked.txt"
cat > "$source_dir/Makefile" <<'EOF'
.PHONY: olddefconfig kernelrelease Image modules modules_install qcom/sm8650-lenovo-tb321fu.dtb

olddefconfig:
	@printf '%s\n' '$@' >> '@RELEASE_MAKE_MARKER@'

kernelrelease:
	@printf '%s\n' '$@' >> '@RELEASE_MAKE_MARKER@'
	@printf '1-derived-g%s\n' "$$(git rev-parse --short=12 HEAD)"

Image modules modules_install qcom/sm8650-lenovo-tb321fu.dtb:
	@printf '%s\n' '$@' >> '@RELEASE_MAKE_MARKER@'
	@exit 99
EOF
sed -i "s|@RELEASE_MAKE_MARKER@|$release_make_marker|g" "$source_dir/Makefile"
git -C "$source_dir" add .gitignore Makefile tracked.txt
git -C "$source_dir" commit -qm 'fixture baseline'
printf 'CONFIG_TB321FU_FIXTURE=y\nCONFIG_RUSTC_VERSION=0\n' > "$build_dir/.config"
fixture_commit=$(git -C "$source_dir" rev-parse HEAD)
fixture_config_sha=$(sha256sum "$build_dir/.config" | awk '{print $1}')
producer_root="$fixture/bootstrap-producer"
producer_scripts="$producer_root/scripts/ci"
producer_packager="$producer_scripts/package-kernel-bootstrap.sh"
producer_safe_extract="$producer_scripts/safe-extract-archive.py"
producer_bundle_verifier="$producer_scripts/verify-kernel-bundle.py"
mkdir -p "$producer_scripts"
cp "$repo_root/.gitignore" "$producer_root/.gitignore"
cp "$packager" "$producer_packager"
cp "$SCRIPT_DIR/common.sh" "$producer_scripts/common.sh"
cp "$SCRIPT_DIR/safe-extract-archive.py" "$producer_safe_extract"
cp "$SCRIPT_DIR/verify-kernel-bundle.py" "$producer_bundle_verifier"
chmod 0755 "$producer_packager"
chmod 0755 "$producer_scripts/common.sh"
chmod 0644 "$producer_safe_extract"
chmod 0644 "$producer_bundle_verifier"
chmod 0644 "$producer_root/.gitignore"
git -C "$producer_root" init -q
git -C "$producer_root" config user.name 'TB321FU producer fixture'
git -C "$producer_root" config user.email noreply@localhost
git -C "$producer_root" add \
  .gitignore \
  scripts/ci/package-kernel-bootstrap.sh \
  scripts/ci/common.sh \
  scripts/ci/safe-extract-archive.py \
  scripts/ci/verify-kernel-bundle.py
git -C "$producer_root" commit -qm 'bootstrap producer fixture'
producer_repository=GUF296/ubuntu-y700-build-ci
producer_commit=$(git -C "$producer_root" rev-parse HEAD)
producer_tree=$(git -C "$producer_root" rev-parse HEAD^{tree})
producer_tree_sha256=$(git -C "$producer_root" cat-file tree "$producer_tree" | sha256sum | awk '{print $1}')
fixture_expected_release="1-expected-g${fixture_commit:0:12}"
preflight_env=(
  KERNEL_SOURCE_DIR="$source_dir"
  KERNEL_GIT_DIR="$source_dir/.git"
  KERNEL_BUILD_DIR="$build_dir"
  EXPECTED_KERNEL_COMMIT="$fixture_commit"
  EXPECTED_KERNEL_CONFIG_SHA256="$fixture_config_sha"
  EXPECTED_KERNEL_RELEASE="$fixture_expected_release"
  KERNEL_PACKAGE_VERSION="$fixture_expected_release"
  BASE_DEVICE_DEB_ARCHIVE=/nonexistent
  BASE_DEVICE_DEB_ARCHIVE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
)

preflight_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" bash "$producer_packager" --preflight)
grep -Fq 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS' <<<"$preflight_output" ||
  fail "clean preflight did not pass"
grep -Fq 'rustc=disabled' <<<"$preflight_output" ||
  fail "Rust-disabled kernel config did not use the inert Rust toolchain record"
for producer_field in \
  "producer-repository=$producer_repository" \
  "producer-commit=$producer_commit" \
  "producer-tree=$producer_tree" \
  "producer-tree-sha256=$producer_tree_sha256"; do
  grep -Fq -- "$producer_field" <<<"$preflight_output" ||
    fail "clean preflight omitted producer provenance: $producer_field"
done

kernel_release_contract=$(sed -n \
  '/^verify_kernel_release_identity() {$/,/^}$/p' "$producer_packager")
[ -n "$kernel_release_contract" ] || fail "unable to extract kernel release contract"
exact_fixture_release="1-g${fixture_commit:0:12}"
EXPECTED_KERNEL_RELEASE="$exact_fixture_release" bash --noprofile --norc -c '
  set -euo pipefail
  ci_die() { printf "error: %s\n" "$*" >&2; exit 1; }
  eval "$1"
  verify_kernel_release_identity "$2"
' bash "$kernel_release_contract" "$exact_fixture_release" ||
  fail "exact expected kernel release was rejected"
set +e
wrong_actual_release_output=$(EXPECTED_KERNEL_RELEASE="$exact_fixture_release" \
  bash --noprofile --norc -c '
    set -euo pipefail
    ci_die() { printf "error: %s\n" "$*" >&2; exit 1; }
    eval "$1"
    verify_kernel_release_identity "$2"
  ' bash "$kernel_release_contract" "2-g${fixture_commit:0:12}" 2>&1)
wrong_actual_release_status=$?
set -e
[ "$wrong_actual_release_status" -ne 0 ] ||
  fail "wrong but grammar-valid actual kernel release was accepted"
grep -Fq "kernel release mismatch: expected $exact_fixture_release, got 2-g${fixture_commit:0:12}" \
  <<<"$wrong_actual_release_output" ||
  fail "wrong actual kernel release failed at the wrong boundary"

release_probe_line=$(grep -nF 'kernel_release=$(kernel_make -s kernelrelease)' "$producer_packager" |
  cut -d: -f1)
release_verify_line=$(grep -nF 'verify_kernel_release_identity "$kernel_release"' "$producer_packager" |
  cut -d: -f1)
baseline_download_line=$(grep -nF 'ci_download "$BASE_DEVICE_DEB_ARCHIVE" "$baseline_archive"' \
  "$producer_packager" | cut -d: -f1)
full_build_line=$(grep -nF 'kernel_make -j"$KERNEL_BUILD_JOBS" Image modules "qcom/$DTB_NAME"' \
  "$producer_packager" | cut -d: -f1)
modules_install_line=$(grep -nF 'kernel_make INSTALL_MOD_PATH="$modules_root" DEPMOD="$TRUE_BIN" modules_install' \
  "$producer_packager" | cut -d: -f1)
package_build_line=$(grep -nF '"$DPKG_DEB_BIN" --root-owner-group --threads-max=1 -Zxz -z6' \
  "$producer_packager" | cut -d: -f1)
sdk_archive_line=$(grep -nF 'write_kernel_sdk_archive "$kernel_build" "$sdk_archive"' \
  "$producer_packager" | cut -d: -f1)
mapfile -t output_archive_lines < <(
  grep -nF '"$TAR_BIN" --format=gnu --sort=name --mtime="@$SOURCE_DATE_EPOCH"' \
    "$producer_packager" | cut -d: -f1
)
[[ $release_probe_line =~ ^[0-9]+$ && $release_verify_line =~ ^[0-9]+$ &&
   $baseline_download_line =~ ^[0-9]+$ && $full_build_line =~ ^[0-9]+$ &&
   $modules_install_line =~ ^[0-9]+$ && $package_build_line =~ ^[0-9]+$ &&
   $sdk_archive_line =~ ^[0-9]+$ && ${#output_archive_lines[@]} -eq 2 &&
   ${output_archive_lines[0]} =~ ^[0-9]+$ && ${output_archive_lines[1]} =~ ^[0-9]+$ &&
   $release_probe_line -lt $release_verify_line &&
   $release_verify_line -lt $baseline_download_line &&
   $release_verify_line -lt $full_build_line &&
   $release_verify_line -lt $modules_install_line &&
   $release_verify_line -lt $package_build_line &&
   $release_verify_line -lt $sdk_archive_line &&
   $release_verify_line -lt ${output_archive_lines[0]} &&
   $release_verify_line -lt ${output_archive_lines[1]} ]] ||
  fail "exact kernel release check is not ordered before baseline acquisition or production"

[ ! -e "$release_make_marker" ] ||
  fail "kernel Makefile fixture ran during preflight"
derived_mismatch_output_dir="$fixture/tb321fu-kernel-bootstrap-derived-release-mismatch"
set +e
derived_mismatch_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$derived_mismatch_output_dir" \
  "$producer_packager" 2>&1)
derived_mismatch_status=$?
set -e
[ "$derived_mismatch_status" -ne 0 ] ||
  fail "derived kernel release differing from the approved release was accepted"
derived_fixture_release="1-derived-g${fixture_commit:0:12}"
grep -Fq \
  "kernel release mismatch: expected $fixture_expected_release, got $derived_fixture_release" \
  <<<"$derived_mismatch_output" ||
  fail "derived kernel release mismatch failed at the wrong boundary"
[ -f "$release_make_marker" ] ||
  fail "derived kernel release fixture did not invoke Kbuild"
[ "$(cat "$release_make_marker")" = $'olddefconfig\nkernelrelease' ] ||
  fail "derived kernel release mismatch reached a full build target"
[ ! -e "$derived_mismatch_output_dir" ] && [ ! -L "$derived_mismatch_output_dir" ] ||
  fail "derived kernel release mismatch published an output target"
grep -Fq '/nonexistent' <<<"$derived_mismatch_output" &&
  fail "derived kernel release mismatch reached baseline acquisition"

producer_safe_extract_clean="$fixture/safe-extract-archive.clean.py"
cp "$producer_safe_extract" "$producer_safe_extract_clean"
printf '\n# hostile fixture mutation\n' >> "$producer_safe_extract"
set +e
dirty_helper_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  "$producer_packager" --preflight 2>&1)
dirty_helper_status=$?
set -e
[ "$dirty_helper_status" -ne 0 ] ||
  fail "modified safe extractor in the producer worktree was accepted"
grep -Fq 'kernel bootstrap producer worktree must be clean' <<<"$dirty_helper_output" ||
  fail "modified safe extractor failed at the wrong producer boundary"
cp "$producer_safe_extract_clean" "$producer_safe_extract"
chmod 0644 "$producer_safe_extract"

git -C "$producer_root" update-index --assume-unchanged \
  scripts/ci/safe-extract-archive.py
set +e
assume_helper_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  "$producer_packager" --preflight 2>&1)
assume_helper_status=$?
set -e
[ "$assume_helper_status" -ne 0 ] ||
  fail "assume-unchanged safe extractor entry was accepted"
grep -Fq 'kernel bootstrap producer has unsafe assume-unchanged/skip-worktree index flags' \
  <<<"$assume_helper_output" ||
  fail "assume-unchanged safe extractor failed at the wrong producer boundary"
git -C "$producer_root" update-index --no-assume-unchanged \
  scripts/ci/safe-extract-archive.py

git -C "$producer_root" update-index --skip-worktree \
  scripts/ci/safe-extract-archive.py
set +e
skip_helper_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  "$producer_packager" --preflight 2>&1)
skip_helper_status=$?
set -e
[ "$skip_helper_status" -ne 0 ] ||
  fail "skip-worktree safe extractor entry was accepted"
grep -Fq 'kernel bootstrap producer has unsafe assume-unchanged/skip-worktree index flags' \
  <<<"$skip_helper_output" ||
  fail "skip-worktree safe extractor failed at the wrong producer boundary"
git -C "$producer_root" update-index --no-skip-worktree \
  scripts/ci/safe-extract-archive.py

shadow_bin="$fixture/path-shadow"
shadow_marker="$fixture/path-shadow-executed"
mkdir -p "$shadow_bin"
cat > "$shadow_bin/hostile-tool" <<EOF
#!/bin/sh
printf '%s\n' "\${0##*/}" >> '$shadow_marker'
exit 97
EOF
chmod 0755 "$shadow_bin/hostile-tool"
for shadow_name in \
  bash git make sha256sum find sort xargs rsync cp dpkg dpkg-deb depmod \
  modinfo tar gzip touch realpath nproc date install awk stat grep sed \
  readlink wc tr findmnt cut cmp head expr uniq; do
  ln -s hostile-tool "$shadow_bin/$shadow_name"
done
hostile_producer_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  PATH="$shadow_bin" \
  BASH_ENV="$shadow_bin/hostile-tool" \
  ENV="$shadow_bin/hostile-tool" \
  DTC=/tmp/hostile-dtc \
  DTC_FLAGS='--hostile-dtc-flags' \
  LOCALVERSION=-hostile \
  HOSTCC=/tmp/hostile-hostcc \
  HOSTCFLAGS='-DHOSTILE_HOSTCFLAGS' \
  DEPMOD=/tmp/hostile-depmod \
  MAKEFILES=/tmp/hostile.mk \
  GNUMAKEFLAGS='-e --eval=hostile' \
  KBUILD_KCONFIG=/tmp/hostile-kconfig \
  CPATH=/tmp/hostile-cpath \
  COMPILER_PATH=/tmp/hostile-compiler-path \
  TAR_OPTIONS=--hostile-tar-options \
  GZIP=--hostile-gzip-options \
  XZ_OPT=--hostile-xz-options \
  DPKG_ROOT=/tmp/hostile-dpkg-root \
  DPKG_ADMINDIR=/tmp/hostile-dpkg-admin \
  'CFLAGS_tb321fu-hostile.o=-DHOSTILE_DYNAMIC_CFLAGS' \
  'DTC_FLAGS_tb321fu-hostile.dtb=--hostile-dynamic-dtc-flags' \
  "$producer_packager" --preflight)
grep -Fq 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS' <<<"$hostile_producer_output" ||
  fail "whole-producer hostile environment changed bootstrap preflight"
[ ! -e "$shadow_marker" ] ||
  fail "whole-producer PATH/BASH_ENV/ENV payload executed across environment isolation"

explicit_producer_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY=GUF296/not-the-producer \
  KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY="$producer_repository" \
  bash "$producer_packager" --preflight)
grep -Fq "producer-repository=$producer_repository" <<<"$explicit_producer_output" ||
  fail "explicit canonical producer repository was not accepted"

set +e
invalid_producer_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY='https://token@example.invalid/GUF296/ubuntu-y700-build-ci' \
  bash "$producer_packager" --preflight 2>&1)
invalid_producer_status=$?
set -e
[ "$invalid_producer_status" -ne 0 ] ||
  fail "noncanonical explicit producer repository was accepted"
grep -Fq 'kernel bootstrap producer repository must be GUF296/ubuntu-y700-build-ci' \
  <<<"$invalid_producer_output" ||
  fail "noncanonical explicit producer repository failed at the wrong boundary"
if grep -Fq 'token@example.invalid' <<<"$invalid_producer_output"; then
  fail "producer repository rejection echoed a raw credential-bearing URL"
fi

set +e
missing_producer_output=$(env -u GITHUB_REPOSITORY -u KERNEL_BOOTSTRAP_PRODUCER_REPOSITORY \
  "${preflight_env[@]}" bash "$producer_packager" --preflight 2>&1)
missing_producer_status=$?
set -e
[ "$missing_producer_status" -ne 0 ] || fail "missing producer repository was accepted"
grep -Fq 'kernel bootstrap producer repository must be GUF296/ubuntu-y700-build-ci' \
  <<<"$missing_producer_output" || fail "missing producer repository failed at the wrong boundary"

absolute_cross_compile="$(dirname -- "$(command -v aarch64-linux-gnu-gcc)")/aarch64-linux-gnu-"
absolute_cross_compile_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  CROSS_COMPILE="$absolute_cross_compile" bash "$producer_packager" --preflight)
grep -Fq 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS' <<<"$absolute_cross_compile_output" ||
  fail "absolute cross compiler prefix was rejected"

space_cross_target="$fixture/cross tool target"
space_cross_link="$fixture/cross-tool-link"
mkdir "$space_cross_target"
ln -s "$space_cross_target" "$space_cross_link"
set +e
space_cross_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  CROSS_COMPILE="$space_cross_link/aarch64-linux-gnu-" \
  bash "$producer_packager" --preflight 2>&1)
space_cross_status=$?
set -e
[ "$space_cross_status" -ne 0 ] ||
  fail "cross compiler prefix resolving through a space-containing path was accepted"
grep -Fq 'canonical CROSS_COMPILE is not representable by the evidence schema' \
  <<<"$space_cross_output" ||
  fail "space-containing canonical cross compiler path failed at the wrong boundary"

output_fixture="$fixture/output"
mkdir -p "$output_fixture"

producer_unignored_parent="$producer_root/nonignored-output"
producer_unignored_output="$producer_unignored_parent/tb321fu-kernel-bootstrap-unignored"
set +e
producer_unignored_output_log=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$producer_unignored_output" \
  bash "$producer_packager" 2>&1)
producer_unignored_output_status=$?
set -e
[ "$producer_unignored_output_status" -ne 0 ] ||
  fail "nonignored producer-local OUTPUT_DIR was accepted"
grep -Fq 'producer-local OUTPUT_DIR, lock and temporary paths must be Git-ignored' \
  <<<"$producer_unignored_output_log" ||
  fail "nonignored producer-local OUTPUT_DIR failed at the wrong boundary"
[ ! -e "$producer_unignored_parent" ] && [ ! -L "$producer_unignored_parent" ] ||
  fail "nonignored producer-local OUTPUT_DIR validation left a directory behind"
[ ! -e "$producer_unignored_output.lock" ] && [ ! -L "$producer_unignored_output.lock" ] ||
  fail "nonignored producer-local OUTPUT_DIR validation left a lock behind"

producer_default_out="$producer_root/out"
producer_default_lock="$producer_default_out/tb321fu-kernel-bootstrap.lock"
mkdir -p "$producer_default_out"
exec {producer_default_lock_fd}>>"$producer_default_lock"
flock -n "$producer_default_lock_fd" || fail "unable to hold ignored default output lock"
set +e
producer_default_output_log=$(
  cd "$producer_root"
  env -u OUTPUT_DIR "${preflight_env[@]}" \
    GITHUB_REPOSITORY="$producer_repository" \
    "$producer_packager" 2>&1
)
producer_default_output_status=$?
set -e
[ "$producer_default_output_status" -ne 0 ] ||
  fail "ignored default producer OUTPUT_DIR did not honor its held lock"
grep -Fq 'kernel bootstrap target is already locked' <<<"$producer_default_output_log" ||
  fail "ignored default producer OUTPUT_DIR did not pass location policy"
[ -z "$(find "$producer_default_out" -maxdepth 1 -type d \
  -name '.tb321fu-kernel-bootstrap.*' -print -quit)" ] ||
  fail "ignored default producer OUTPUT_DIR validation left a temporary tree"
exec {producer_default_lock_fd}>&-

set +e
unsafe_output_dir_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$output_fixture/not-a-bootstrap-output" \
  bash "$producer_packager" 2>&1)
unsafe_output_dir_status=$?
set -e
[ "$unsafe_output_dir_status" -ne 0 ] || fail "unsafe OUTPUT_DIR basename was accepted"
grep -Eq 'unsafe OUTPUT_DIR|OUTPUT_DIR basename must be a bounded' \
  <<<"$unsafe_output_dir_output" ||
  fail "unsafe OUTPUT_DIR failed at the wrong boundary"

set +e
traversal_output_dir_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$output_fixture/../tb321fu-kernel-bootstrap-traversal" \
  bash "$producer_packager" 2>&1)
traversal_output_dir_status=$?
set -e
[ "$traversal_output_dir_status" -ne 0 ] ||
  fail "parent-traversing OUTPUT_DIR was accepted"
grep -Fq 'unsafe OUTPUT_DIR' <<<"$traversal_output_dir_output" ||
  fail "parent-traversing OUTPUT_DIR failed at the wrong boundary"

prefix_map_output_dir="$fixture/output parent/tb321fu-kernel-bootstrap-prefix-map"
set +e
prefix_map_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$prefix_map_output_dir" \
  bash "$producer_packager" 2>&1)
prefix_map_output_status=$?
set -e
[ "$prefix_map_output_status" -ne 0 ] ||
  fail "private Kbuild path unsuitable for deterministic debug mapping was accepted"
grep -Fq 'private kernel build path cannot be represented safely in deterministic compiler flags' \
  <<<"$prefix_map_output" ||
  fail "unsafe deterministic debug-map path failed at the wrong boundary"

existing_output_dir="$output_fixture/tb321fu-kernel-bootstrap-existing"
mkdir "$existing_output_dir"
printf 'must-survive\n' > "$existing_output_dir/user-sentinel"
set +e
existing_output_dir_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$existing_output_dir" \
  bash "$producer_packager" 2>&1)
existing_output_dir_status=$?
set -e
[ "$existing_output_dir_status" -ne 0 ] || fail "existing OUTPUT_DIR target was accepted"
grep -Eq 'OUTPUT_DIR.*(already exists|existing target)|refusing.*OUTPUT_DIR|kernel bootstrap target already exists' \
  <<<"$existing_output_dir_output" ||
  fail "existing OUTPUT_DIR failed at the wrong boundary"
grep -Fxq 'must-survive' "$existing_output_dir/user-sentinel" ||
  fail "existing OUTPUT_DIR content was modified or removed"

dangling_output_dir="$output_fixture/tb321fu-kernel-bootstrap-dangling"
ln -s missing-user-target "$dangling_output_dir"
set +e
dangling_output_dir_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$dangling_output_dir" \
  bash "$producer_packager" 2>&1)
dangling_output_dir_status=$?
set -e
[ "$dangling_output_dir_status" -ne 0 ] || fail "dangling OUTPUT_DIR target was accepted"
grep -Eq 'OUTPUT_DIR.*(already exists|existing target)|refusing.*OUTPUT_DIR|kernel bootstrap target already exists' \
  <<<"$dangling_output_dir_output" ||
  fail "dangling OUTPUT_DIR target failed at the wrong boundary"
[ -L "$dangling_output_dir" ] &&
  [ "$(readlink -- "$dangling_output_dir")" = missing-user-target ] ||
  fail "dangling OUTPUT_DIR target was modified or removed"

locked_output_dir="$output_fixture/tb321fu-kernel-bootstrap-locked"
locked_output_lock="$locked_output_dir.lock"
exec {held_output_lock_fd}>>"$locked_output_lock"
flock -n "$held_output_lock_fd" || fail "unable to hold fixture OUTPUT_DIR lock"
set +e
locked_output_dir_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$locked_output_dir" \
  bash "$producer_packager" 2>&1)
locked_output_dir_status=$?
set -e
[ "$locked_output_dir_status" -ne 0 ] || fail "concurrent same-target producer was accepted"
grep -Fq 'kernel bootstrap target is already locked' <<<"$locked_output_dir_output" ||
  fail "concurrent same-target producer failed at the wrong boundary"
[ ! -e "$locked_output_dir" ] && [ ! -L "$locked_output_dir" ] ||
  fail "lock rejection created or replaced the OUTPUT_DIR target"
exec {held_output_lock_fd}>&-

symlink_lock_output_dir="$output_fixture/tb321fu-kernel-bootstrap-symlink-lock"
symlink_lock_path="$symlink_lock_output_dir.lock"
symlink_lock_target="$fixture/user-owned-lock-target"
printf 'must-survive\n' > "$symlink_lock_target"
ln -s "$symlink_lock_target" "$symlink_lock_path"
set +e
symlink_lock_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$symlink_lock_output_dir" \
  bash "$producer_packager" 2>&1)
symlink_lock_status=$?
set -e
[ "$symlink_lock_status" -ne 0 ] || fail "symlink OUTPUT_DIR lock was accepted"
grep -Fq 'kernel bootstrap target lock must be a regular file' \
  <<<"$symlink_lock_output" ||
  fail "symlink OUTPUT_DIR lock failed at the wrong boundary"
grep -Fxq 'must-survive' "$symlink_lock_target" ||
  fail "symlink OUTPUT_DIR lock target was modified"
[ -L "$symlink_lock_path" ] || fail "symlink OUTPUT_DIR lock was replaced"

for overlap_record in \
  "source:$source_dir/tb321fu-kernel-bootstrap-source-overlap:$source_dir/.git" \
  "build:$build_dir/tb321fu-kernel-bootstrap-build-overlap:$source_dir/.git"; do
  overlap_label=${overlap_record%%:*}
  overlap_tail=${overlap_record#*:}
  overlap_output_dir=${overlap_tail%%:*}
  overlap_git_dir=${overlap_tail#*:}
  set +e
  overlap_output=$(env "${preflight_env[@]}" \
    KERNEL_GIT_DIR="$overlap_git_dir" \
    GITHUB_REPOSITORY="$producer_repository" \
    OUTPUT_DIR="$overlap_output_dir" \
    bash "$producer_packager" 2>&1)
  overlap_status=$?
  set -e
  [ "$overlap_status" -ne 0 ] ||
    fail "OUTPUT_DIR overlapping the authoritative kernel $overlap_label was accepted"
  grep -Fq 'OUTPUT_DIR must not overlap authoritative kernel inputs' \
    <<<"$overlap_output" ||
    fail "kernel $overlap_label OUTPUT_DIR overlap failed at the wrong boundary"
done

external_kernel_git="$fixture/external-kernel-git"
cp -a "$source_dir/.git" "$external_kernel_git"
set +e
git_overlap_output=$(env "${preflight_env[@]}" \
  KERNEL_GIT_DIR="$external_kernel_git" \
  GITHUB_REPOSITORY="$producer_repository" \
  OUTPUT_DIR="$external_kernel_git/tb321fu-kernel-bootstrap-git-overlap" \
  bash "$producer_packager" 2>&1)
git_overlap_status=$?
set -e
[ "$git_overlap_status" -ne 0 ] ||
  fail "OUTPUT_DIR overlapping the authoritative kernel Git database was accepted"
grep -Fq 'OUTPUT_DIR must not overlap authoritative kernel inputs' \
  <<<"$git_overlap_output" ||
  fail "kernel Git database OUTPUT_DIR overlap failed at the wrong boundary"

require_literal 'kernel bootstrap target appeared before promotion'
promotion_block=$(sed -n \
  '/^"\$MV_BIN" --no-clobber -T/,/kernel bootstrap no-clobber promotion failed/p' \
  "$packager")
[ -n "$promotion_block" ] || fail "unable to extract no-clobber promotion block"
promotion_function_file="$fixture/no-clobber-promotion-function.sh"
{
  printf '%s\n' 'ci_die() { printf "promotion fixture: %s\\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'promote_fixture() {'
  printf '%s\n' "$promotion_block"
  printf '%s\n' '}'
} > "$promotion_function_file"
promotion_stage="$fixture/promotion-stage"
promotion_target="$fixture/promotion-target"
mkdir "$promotion_stage"
printf 'promoted\n' > "$promotion_stage/sentinel"
(
  # shellcheck source=/dev/null
  . "$promotion_function_file"
  MV_BIN=/usr/bin/mv
  stage="$promotion_stage"
  output_path="$promotion_target"
  promote_fixture
)
[ ! -e "$promotion_stage" ] && [ ! -L "$promotion_stage" ] ||
  fail "successful no-clobber promotion retained its stage"
grep -Fxq 'promoted' "$promotion_target/sentinel" ||
  fail "successful no-clobber promotion lost staged content"

collision_stage="$fixture/collision-stage"
collision_target="$fixture/collision-target"
mkdir "$collision_stage" "$collision_target"
printf 'staged\n' > "$collision_stage/staged-sentinel"
printf 'user-owned\n' > "$collision_target/user-sentinel"
set +e
collision_output=$(
  (
    # shellcheck source=/dev/null
    . "$promotion_function_file"
    MV_BIN=/usr/bin/mv
    stage="$collision_stage"
    output_path="$collision_target"
    promote_fixture
  ) 2>&1
)
collision_status=$?
set -e
[ "$collision_status" -ne 0 ] ||
  fail "no-clobber promotion accepted an appeared target"
grep -Fq 'kernel bootstrap no-clobber promotion failed' <<<"$collision_output" ||
  fail "appeared-target promotion failed at the wrong boundary"
grep -Fxq 'staged' "$collision_stage/staged-sentinel" ||
  fail "appeared-target promotion removed the unpromoted stage"
grep -Fxq 'user-owned' "$collision_target/user-sentinel" ||
  fail "appeared-target promotion clobbered user content"

set +e
config_output=$(env "${preflight_env[@]}" \
  EXPECTED_KERNEL_CONFIG_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  GITHUB_REPOSITORY="$producer_repository" \
  bash "$producer_packager" --preflight 2>&1)
config_status=$?
set -e
[ "$config_status" -ne 0 ] || fail "config mismatch was accepted"
grep -Fq 'kernel config SHA-256 mismatch before release packaging' <<<"$config_output" ||
  fail "config mismatch failed at the wrong boundary"

printf 'dirty\n' >> "$source_dir/tracked.txt"
set +e
dirty_output=$(env "${preflight_env[@]}" GITHUB_REPOSITORY="$producer_repository" \
  bash "$producer_packager" --preflight 2>&1)
dirty_status=$?
set -e
[ "$dirty_status" -ne 0 ] || fail "tracked dirty source was accepted"
grep -Fq 'kernel worktree must be clean before release packaging' <<<"$dirty_output" ||
  fail "tracked dirty source failed at the wrong boundary"
printf 'tracked\n' > "$source_dir/tracked.txt"

touch "$source_dir/ignored-residue"
set +e
ignored_output=$(env "${preflight_env[@]}" GITHUB_REPOSITORY="$producer_repository" \
  bash "$producer_packager" --preflight 2>&1)
ignored_status=$?
set -e
[ "$ignored_status" -ne 0 ] || fail "ignored source residue was accepted"
grep -Fq 'kernel worktree contains ignored files before release packaging' <<<"$ignored_output" ||
  fail "ignored source residue failed at the wrong boundary"
rm -f -- "$source_dir/ignored-residue"

hostile_git_output=$(env "${preflight_env[@]}" \
  GITHUB_REPOSITORY="$producer_repository" \
  GIT_DIR=/nonexistent \
  GIT_WORK_TREE=/nonexistent \
  GIT_INDEX_FILE=/nonexistent \
  GIT_OBJECT_DIRECTORY=/nonexistent \
  GIT_ALTERNATE_OBJECT_DIRECTORIES=/nonexistent \
  GIT_REPLACE_REF_BASE=refs/replace \
  GIT_CONFIG_NOSYSTEM=0 \
  GIT_CONFIG_GLOBAL=/nonexistent \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=core.excludesFile \
  GIT_CONFIG_VALUE_0=/nonexistent \
  GIT_NO_REPLACE_OBJECTS=0 \
  bash "$producer_packager" --preflight)
grep -Fq 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS' <<<"$hostile_git_output" ||
  fail "hostile inherited Git environment changed bootstrap preflight"

hostile_kernel_env=$(env \
  EXPECTED_KERNEL_RELEASE=9-hostile-gffffffffffff \
  KERNEL_PACKAGE_VERSION=9-hostile-gffffffffffff \
  DTC=/tmp/hostile-dtc \
  DTC_FLAGS='--hostile-dtc-flags' \
  LOCALVERSION=-hostile \
  LOCALVERSION_AUTO=1 \
  HOSTCC=/tmp/hostile-hostcc \
  HOSTCXX=/tmp/hostile-hostcxx \
  HOSTLD=/tmp/hostile-hostld \
  HOSTCFLAGS='-DHOSTILE_HOSTCFLAGS' \
  HOSTCXXFLAGS='-DHOSTILE_HOSTCXXFLAGS' \
  HOSTLDFLAGS='-Wl,--hostile-host' \
  DEPMOD=/tmp/hostile-depmod \
  MAKEFILES=/tmp/hostile.mk \
  MAKEFLAGS='-e --eval=hostile' \
  GNUMAKEFLAGS='-e --eval=hostile_gnu' \
  KBUILD_KCONFIG=/tmp/hostile-kconfig \
  KCFLAGS='-include /tmp/hostile-kcflags' \
  KAFLAGS='-include /tmp/hostile-kaflags' \
  KCPPFLAGS='-include /tmp/hostile-kcppflags' \
  KRUSTFLAGS='--cfg hostile_krustflags' \
  KBUILD_CFLAGS='-DHOSTILE_KBUILD_CFLAGS' \
  KBUILD_AFLAGS='-DHOSTILE_KBUILD_AFLAGS' \
  KBUILD_CPPFLAGS='-DHOSTILE_KBUILD_CPPFLAGS' \
  KBUILD_RUSTFLAGS='--cfg hostile_kbuild_rustflags' \
  CFLAGS='-DHOSTILE_CFLAGS' \
  CXXFLAGS='-DHOSTILE_CXXFLAGS' \
  CPPFLAGS='-DHOSTILE_CPPFLAGS' \
  LDFLAGS='-Wl,--hostile' \
  LDFLAGS_vmlinux='-Wl,--hostile-vmlinux' \
  CPATH=/tmp/hostile-cpath \
  CPLUS_INCLUDE_PATH=/tmp/hostile-cplus-include \
  C_INCLUDE_PATH=/tmp/hostile-c-include \
  COMPILER_PATH=/tmp/hostile-compiler-path \
  LIBRARY_PATH=/tmp/hostile-library-path \
  GCC_EXEC_PREFIX=/tmp/hostile-gcc-prefix/ \
  TAR_OPTIONS=--hostile-tar-options \
  GZIP=--hostile-gzip-options \
  XZ_OPT=--hostile-xz-options \
  XZ_DEFAULTS=--hostile-xz-defaults \
  DPKG_ROOT=/tmp/hostile-dpkg-root \
  DPKG_ADMINDIR=/tmp/hostile-dpkg-admin \
  DPKG_COLORS=always \
  DPKG_DEB_THREADS_MAX=999 \
  'CFLAGS_tb321fu-hostile.o=-DHOSTILE_DYNAMIC_CFLAGS' \
  'DTC_FLAGS_tb321fu-hostile.dtb=--hostile-dynamic-dtc-flags' \
  bash -c '. "$1"; ci_sanitized_kernel_env \
    GIT_DIR=/fixture/git \
    GIT_WORK_TREE=/fixture/source \
    ARCH=arm64 \
    CROSS_COMPILE=/opt/tb321fu-toolchain/aarch64-linux-gnu- \
    SOURCE_DATE_EPOCH=1700000000 \
    KBUILD_BUILD_TIMESTAMP="2023-11-14 22:13:20 UTC" \
    KBUILD_BUILD_USER=tb321fu-ci \
    KBUILD_BUILD_HOST=tb321fu-builder \
    KBUILD_BUILD_VERSION=1 \
    KCONFIG_NOTIMESTAMP=1 \
    RUSTC=/bin/false \
    /usr/bin/env' \
  bash "$SCRIPT_DIR/common.sh")
expected_kernel_env=$(cat <<'EOF'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
HOME=/nonexistent
LANG=C
LC_ALL=C
TZ=UTC
GIT_CONFIG_NOSYSTEM=1
GIT_CONFIG_GLOBAL=/dev/null
GIT_ATTR_NOSYSTEM=1
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
GIT_NO_REPLACE_OBJECTS=1
GIT_CONFIG_COUNT=3
GIT_CONFIG_KEY_0=core.fsmonitor
GIT_CONFIG_VALUE_0=false
GIT_CONFIG_KEY_1=core.untrackedCache
GIT_CONFIG_VALUE_1=false
GIT_CONFIG_KEY_2=core.excludesFile
GIT_CONFIG_VALUE_2=/dev/null
GIT_DIR=/fixture/git
GIT_WORK_TREE=/fixture/source
ARCH=arm64
CROSS_COMPILE=/opt/tb321fu-toolchain/aarch64-linux-gnu-
SOURCE_DATE_EPOCH=1700000000
KBUILD_BUILD_TIMESTAMP=2023-11-14 22:13:20 UTC
KBUILD_BUILD_USER=tb321fu-ci
KBUILD_BUILD_HOST=tb321fu-builder
KBUILD_BUILD_VERSION=1
KCONFIG_NOTIMESTAMP=1
RUSTC=/bin/false
EOF
)
hostile_kernel_env_sorted=$(LC_ALL=C sort <<<"$hostile_kernel_env")
expected_kernel_env_sorted=$(LC_ALL=C sort <<<"$expected_kernel_env")
[ "$hostile_kernel_env_sorted" = "$expected_kernel_env_sorted" ] ||
  fail "inner Kbuild environment differs from the exact approved allowlist"

kernel_make_function=$(sed -n '/^kernel_make() {$/,/^}$/p' "$packager")
[ -n "$kernel_make_function" ] || fail "unable to extract kernel_make"
[ "$(grep -Fc 'SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must pass SOURCE_DATE_EPOCH in both the clean environment and make command line"
[ "$(grep -Fc 'CONFIG_SHELL="$SH_BIN"' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must fix CONFIG_SHELL in both the clean environment and make command line"
[ "$(grep -Ec '^[[:space:]]+SHELL="\$SH_BIN"' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must fix SHELL in both the clean environment and make command line"
[ "$(grep -Fc 'KCFLAGS="$kernel_kcflags"' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must fix debug-prefix KCFLAGS in both the clean environment and make command line"
[ "$(grep -Fc 'KAFLAGS="$kernel_kaflags"' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must fix debug-prefix KAFLAGS in both the clean environment and make command line"
[ "$(grep -Fc 'M4="$M4_BIN"' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must fix M4 in both the clean environment and make command line"
[ "$(grep -Fc 'BISON_PKGDATADIR="$BISON_DATA_DIR"' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must fix the Bison data tree in both the clean environment and make command line"
for host_tool_assignment in \
  'HOSTAS="$HOST_AS_BIN"' 'HOSTLD="$HOST_LD_BIN"' 'HOSTAR="$HOST_AR_BIN"'; do
  [ "$(grep -Fc "$host_tool_assignment" <<<"$kernel_make_function")" -eq 2 ] ||
    fail "kernel_make must fix $host_tool_assignment in both boundaries"
done
[ "$(grep -Fc 'verify_locked_tools ' <<<"$kernel_make_function")" -eq 2 ] ||
  fail "kernel_make must verify locked tool and data bytes before and after every invocation"
kernel_make_function_file="$fixture/kernel-make-function.sh"
printf '%s\n' "$kernel_make_function" > "$kernel_make_function_file"
mkdir -p "$fixture/kernel-make-source" "$fixture/kernel-make-build"
actual_kernel_make_env=$(
  (
    # shellcheck source=common.sh
    . "$common"
    # shellcheck source=/dev/null
    . "$kernel_make_function_file"
    verify_kernel_locked_path() { :; }
    verify_locked_tools() { :; }
    declare -A LOCKED_TOOL_PATH=()
    LOCKED_TOOL_PATH[pahole]=unused
    LOCKED_TOOL_PATH[gcc]=/fixture/cross-gcc
    LOCKED_TOOL_PATH[as]=/fixture/cross-as
    LOCKED_TOOL_PATH[ld]=/fixture/cross-ld
    LOCKED_TOOL_PATH[ar]=/fixture/cross-ar
    LOCKED_TOOL_PATH[nm]=/fixture/cross-nm
    LOCKED_TOOL_PATH[objcopy]=/fixture/cross-objcopy
    LOCKED_TOOL_PATH[objdump]=/fixture/cross-objdump
    LOCKED_TOOL_PATH[readelf]=/fixture/cross-readelf
    LOCKED_TOOL_PATH[strip]=/fixture/cross-strip
    kernel_git=/fixture/git
    kernel_source="$fixture/kernel-make-source"
    kernel_build="$fixture/kernel-make-build"
    kernel_locked_path=/fixture/kbuild-tools
    kernel_rustc=/bin/false
    SOURCE_DATE_EPOCH=1700000000
    ARCH=arm64
    CROSS_COMPILE=/opt/tb321fu-toolchain/aarch64-linux-gnu-
    KBUILD_BUILD_TIMESTAMP='2023-11-14 22:13:20 UTC'
    KBUILD_BUILD_USER=tb321fu-ci
    KBUILD_BUILD_HOST=tb321fu-builder
    KBUILD_BUILD_VERSION=1
    HOST_GCC_BIN=/fixture/host-gcc
    HOST_GXX_BIN=/fixture/host-gxx
    HOST_AS_BIN=/fixture/host-as
    HOST_LD_BIN=/fixture/host-ld
    HOST_AR_BIN=/fixture/host-ar
    FLEX_BIN=/fixture/flex
    BISON_BIN=/fixture/bison
    M4_BIN=/fixture/m4
    BISON_DATA_DIR=/fixture/bison-data
    AWK_BIN=/fixture/awk
    PERL_BIN=/fixture/perl
    PYTHON3_BIN=/fixture/python3
    PKG_CONFIG_BIN=/fixture/pkg-config
    SH_BIN=/fixture/sh
    kernel_kcflags="-fdebug-prefix-map=$fixture/kernel-make-source=/usr/src/tb321fu-linux-source -fdebug-prefix-map=$fixture/kernel-make-build=/usr/src/tb321fu-linux-build"
    kernel_kaflags=$kernel_kcflags
    MAKE_BIN=/usr/bin/env
    export DTC=/tmp/hostile-dtc DTC_FLAGS=--hostile LOCALVERSION=-hostile
    export DEPMOD=/tmp/hostile-depmod
    export HOSTCFLAGS=-DHOSTILE MAKEFILES=/tmp/hostile.mk GNUMAKEFLAGS=-e
    export KBUILD_KCONFIG=/tmp/hostile-kconfig CPATH=/tmp/hostile-cpath
    export COMPILER_PATH=/tmp/hostile-compiler-path TAR_OPTIONS=--hostile
    export GZIP=--hostile XZ_OPT=--hostile DPKG_ROOT=/tmp/hostile-dpkg
    kernel_make /usr/bin/env
  )
)
expected_actual_kernel_make_env=$(cat <<EOF
PATH=/fixture/kbuild-tools
HOME=/nonexistent
LANG=C
LC_ALL=C
TZ=UTC
GIT_CONFIG_NOSYSTEM=1
GIT_CONFIG_GLOBAL=/dev/null
GIT_ATTR_NOSYSTEM=1
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
GIT_NO_REPLACE_OBJECTS=1
GIT_CONFIG_COUNT=3
GIT_CONFIG_KEY_0=core.fsmonitor
GIT_CONFIG_VALUE_0=false
GIT_CONFIG_KEY_1=core.untrackedCache
GIT_CONFIG_VALUE_1=false
GIT_CONFIG_KEY_2=core.excludesFile
GIT_CONFIG_VALUE_2=/dev/null
GIT_DIR=/fixture/git
GIT_WORK_TREE=$fixture/kernel-make-source
SOURCE_DATE_EPOCH=1700000000
ARCH=arm64
CROSS_COMPILE=/opt/tb321fu-toolchain/aarch64-linux-gnu-
KBUILD_BUILD_TIMESTAMP=2023-11-14 22:13:20 UTC
KBUILD_BUILD_USER=tb321fu-ci
KBUILD_BUILD_HOST=tb321fu-builder
KBUILD_BUILD_VERSION=1
KCONFIG_NOTIMESTAMP=1
CONFIG_SHELL=/fixture/sh
SHELL=/fixture/sh
KCFLAGS=-fdebug-prefix-map=$fixture/kernel-make-source=/usr/src/tb321fu-linux-source -fdebug-prefix-map=$fixture/kernel-make-build=/usr/src/tb321fu-linux-build
KAFLAGS=-fdebug-prefix-map=$fixture/kernel-make-source=/usr/src/tb321fu-linux-source -fdebug-prefix-map=$fixture/kernel-make-build=/usr/src/tb321fu-linux-build
O=$fixture/kernel-make-build
RUSTC=/bin/false
CC=/fixture/cross-gcc
AS=/fixture/cross-as
LD=/fixture/cross-ld
AR=/fixture/cross-ar
NM=/fixture/cross-nm
OBJCOPY=/fixture/cross-objcopy
OBJDUMP=/fixture/cross-objdump
READELF=/fixture/cross-readelf
STRIP=/fixture/cross-strip
HOSTCC=/fixture/host-gcc
HOSTCXX=/fixture/host-gxx
HOSTAS=/fixture/host-as
HOSTLD=/fixture/host-ld
HOSTAR=/fixture/host-ar
LEX=/fixture/flex
YACC=/fixture/bison
M4=/fixture/m4
BISON_PKGDATADIR=/fixture/bison-data
AWK=/fixture/awk
PERL=/fixture/perl
PYTHON3=/fixture/python3
PKG_CONFIG=/fixture/pkg-config
EOF
)
actual_kernel_make_env_sorted=$(LC_ALL=C sort <<<"$actual_kernel_make_env")
expected_actual_kernel_make_env_sorted=$(LC_ALL=C sort <<<"$expected_actual_kernel_make_env")
[ "$actual_kernel_make_env_sorted" = "$expected_actual_kernel_make_env_sorted" ] ||
  fail "executed kernel_make environment differs from the exact approved allowlist"

git -C "$source_dir" update-index --assume-unchanged tracked.txt
set +e
index_flags_output=$(env "${preflight_env[@]}" GITHUB_REPOSITORY="$producer_repository" \
  bash "$producer_packager" --preflight 2>&1)
index_flags_status=$?
set -e
[ "$index_flags_status" -ne 0 ] || fail "assume-unchanged kernel source entry was accepted"
grep -Fq 'kernel worktree has unsafe assume-unchanged/skip-worktree index flags before release packaging' \
  <<<"$index_flags_output" || fail "unsafe kernel source index flag failed at the wrong boundary"
git -C "$source_dir" update-index --no-assume-unchanged tracked.txt

for private_build_token in \
  'approved_config="$work/approved-kernel.config"' \
  'install -m 0644 "$kernel_build_input/.config" "$approved_config"' \
  'mkdir -m 0700 -- "$kernel_build"' \
  'install -m 0644 "$approved_config" "$kernel_build/.config"'; do
  require_literal "$private_build_token"
done
if grep -Eq '(cp[^\n]*[[:space:]]-[^[:space:]]*l|rsync[^\n]*--link-dest|ln[[:space:]])[^\n]*kernel_build_input' \
  "$packager"; then
  fail "private kernel build setup reuses authoritative files through hardlinks"
fi

cleanup_parent="$fixture/cleanup-parent"
cleanup_target="$cleanup_parent/.tb321fu-kernel-bootstrap-cleanup-fixture"
cleanup_sentinel="$cleanup_target/user-sentinel"
findmnt_failure_bin="$fixture/findmnt-failure-bin"
mkdir -p "$cleanup_target" "$findmnt_failure_bin"
printf 'must-survive\n' > "$cleanup_sentinel"
cat > "$findmnt_failure_bin/findmnt" <<'EOF'
#!/bin/sh
exit 73
EOF
chmod 0755 "$findmnt_failure_bin/findmnt"
set +e
mount_inspection_failure_output=$(PATH="$findmnt_failure_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  bash -c '. "$1"; ci_safe_rmtree "$2" "$3" "$4"' \
  bash "$common" "$cleanup_target" "$cleanup_parent" \
  .tb321fu-kernel-bootstrap 2>&1)
mount_inspection_failure_status=$?
set -e
[ "$mount_inspection_failure_status" -ne 0 ] ||
  fail "cleanup accepted a failed mount-table inspection"
grep -Fq 'refusing cleanup because mount inspection failed' \
  <<<"$mount_inspection_failure_output" ||
  fail "failed mount-table inspection was rejected at the wrong cleanup boundary"
grep -Fxq 'must-survive' "$cleanup_sentinel" ||
  fail "cleanup removed data after mount-table inspection failed"

cleanup_symlink_target="$cleanup_parent/.tb321fu-kernel-bootstrap-real-target"
cleanup_symlink_candidate="$cleanup_parent/.tb321fu-kernel-bootstrap-symlink"
mkdir "$cleanup_symlink_target"
printf 'must-survive\n' > "$cleanup_symlink_target/user-sentinel"
ln -s "$cleanup_symlink_target" "$cleanup_symlink_candidate"
set +e
cleanup_symlink_output=$(bash -c '. "$1"; ci_safe_rmtree "$2" "$3" "$4"' \
  bash "$common" "$cleanup_symlink_candidate" "$cleanup_parent" \
  .tb321fu-kernel-bootstrap 2>&1)
cleanup_symlink_status=$?
set -e
[ "$cleanup_symlink_status" -ne 0 ] ||
  fail "cleanup accepted a symlink candidate"
grep -Fq 'cleanup candidate must be a real directory' <<<"$cleanup_symlink_output" ||
  fail "cleanup symlink candidate failed at the wrong boundary"
[ -L "$cleanup_symlink_candidate" ] ||
  fail "cleanup replaced or removed its symlink candidate"
grep -Fxq 'must-survive' "$cleanup_symlink_target/user-sentinel" ||
  fail "cleanup followed a symlink and deleted its target"

cleanup_regular_candidate="$cleanup_parent/.tb321fu-kernel-bootstrap-regular"
printf 'must-survive\n' > "$cleanup_regular_candidate"
set +e
cleanup_regular_output=$(bash -c '. "$1"; ci_safe_rmtree "$2" "$3" "$4"' \
  bash "$common" "$cleanup_regular_candidate" "$cleanup_parent" \
  .tb321fu-kernel-bootstrap 2>&1)
cleanup_regular_status=$?
set -e
[ "$cleanup_regular_status" -ne 0 ] ||
  fail "cleanup accepted a regular-file candidate"
grep -Fq 'cleanup candidate must be a real directory' <<<"$cleanup_regular_output" ||
  fail "cleanup regular-file candidate failed at the wrong boundary"
grep -Fxq 'must-survive' "$cleanup_regular_candidate" ||
  fail "cleanup deleted a regular-file candidate"

sdk_archive_function=$(sed -n '/^write_kernel_sdk_archive() {$/,/^}$/p' "$packager")
[ -n "$sdk_archive_function" ] || fail "unable to extract kernel SDK archive function"
sdk_archive_function_flat=${sdk_archive_function//$'\n'/ }
if grep -Eq '(-t[a-z]*f|--list)[^|]*[|][[:space:]]*(grep|head).*-[^[:space:]]*q' \
  <<<"$sdk_archive_function_flat"; then
  fail "kernel SDK archive validation uses an early-exiting member-list consumer"
fi
grep -Fq 'kernel SDK archive contains too many members' <<<"$sdk_archive_function" ||
  fail "kernel SDK archive validation does not bound its fully consumed member list"
if grep -Fq 'GREP_BIN' <<<"$sdk_archive_function"; then
  fail "kernel SDK archive function references the undefined GREP_BIN variable"
fi
sdk_archive_function_file="$fixture/write-kernel-sdk-archive-function.sh"
sdk_path_validation_function=$(sed -n '/^validate_sdk_relative_path() {$/,/^}$/p' "$packager")
[ -n "$sdk_path_validation_function" ] ||
  fail "unable to extract kernel SDK path validation function"
{
  printf '%s\n' 'ci_die() { printf "fixture error: %s\\n" "$*" >&2; exit 1; }'
  printf '%s\n' "$sdk_path_validation_function"
  printf '%s\n' "$sdk_archive_function"
} > "$sdk_archive_function_file"
for unsafe_sdk_path in 'directory\hostile' 'drive:escape/member'; do
  set +e
  unsafe_sdk_path_output=$(bash -c '. "$1"; validate_sdk_relative_path "$2"' \
    bash "$sdk_archive_function_file" "$unsafe_sdk_path" 2>&1)
  unsafe_sdk_path_status=$?
  set -e
  [ "$unsafe_sdk_path_status" -ne 0 ] ||
    fail "unsafe kernel SDK path was accepted: $unsafe_sdk_path"
  grep -Fq 'kernel SDK manifest contains an unsafe path' \
    <<<"$unsafe_sdk_path_output" ||
    fail "unsafe kernel SDK path failed at the wrong boundary: $unsafe_sdk_path"
done
set +e
non_ascii_sdk_path_output=$(bash -c '. "$1"; validate_sdk_relative_path "$2"' \
  bash "$sdk_archive_function_file" $'nonascii-\303\251/member' 2>&1)
non_ascii_sdk_path_status=$?
set -e
[ "$non_ascii_sdk_path_status" -ne 0 ] ||
  fail "non-ASCII kernel SDK path was accepted"
grep -Fq 'kernel SDK manifest path must be printable ASCII' \
  <<<"$non_ascii_sdk_path_output" ||
  fail "non-ASCII kernel SDK path failed at the wrong boundary"
sdk_root="$fixture/sdk-root"
sdk_function_work="$fixture/sdk-function-work"
sdk_archive_fixture="$fixture/sdk-fixture.tar.gz"
mkdir -p "$sdk_root/entries" "$sdk_function_work"
printf 'payload\n' > "$sdk_root/payload.txt"
printf 'hardlink payload\n' > "$sdk_root/hardlink-a"
ln "$sdk_root/hardlink-a" "$sdk_root/hardlink-b"
for sdk_member in {000..127}; do
  printf '%s\n' "$sdk_member" > "$sdk_root/entries/member-$sdk_member"
done
ln -s . "$sdk_root/source"
(
  # shellcheck source=/dev/null
  . "$sdk_archive_function_file"
  work="$sdk_function_work"
  SOURCE_DATE_EPOCH=1700000000
  FIND_BIN=/usr/bin/find
  SORT_BIN=/usr/bin/sort
  TAR_BIN=/usr/bin/tar
  GZIP_BIN=/usr/bin/gzip
  write_kernel_sdk_archive "$sdk_root" "$sdk_archive_fixture"
)
sdk_archive_members="$fixture/sdk-archive-members.list"
tar -tzf "$sdk_archive_fixture" > "$sdk_archive_members"
[ "$(wc -l < "$sdk_archive_members")" -eq 132 ] ||
  fail "kernel SDK archive member listing was incomplete or duplicated members"
grep -Fxq './payload.txt' "$sdk_archive_members" ||
  fail "kernel SDK archive omitted its root payload"
grep -Fxq './entries/member-127' "$sdk_archive_members" ||
  fail "kernel SDK archive member listing did not reach the final member"
if grep -Eq '^\./source/?$' "$sdk_archive_members"; then
  fail "kernel SDK archive retained the transient source symlink"
fi
sdk_extract="$fixture/sdk-extract"
mkdir "$sdk_extract"
tar -xzf "$sdk_archive_fixture" -C "$sdk_extract"
[ ! "$sdk_extract/hardlink-a" -ef "$sdk_extract/hardlink-b" ] ||
  fail "kernel SDK archive retained hardlink inode coupling"

for sdk_limit_token in \
  'kernel SDK contains a regular file larger than 8 GiB' \
  'kernel SDK regular-file total exceeds 32 GiB' \
  'kernel SDK manifest has too many records' \
  'kernel SDK manifest exceeds the 16 MiB consumer limit' \
  'kernel SDK symlink target must be bounded printable ASCII' \
  'kernel SDK archive contains too many source entries' \
  'kernel SDK archive contains too many members' \
  'kernel modules manifest has too many records' \
  'kernel modules manifest exceeds the 16 MiB consumer limit' \
  '[ "$size" -le 8589934592 ]' \
  '[ "$total_regular_bytes" -le 34359738368 ]' \
  '[ "$record_count" -le 200000 ]' \
  '[ "$archive_entry_count" -le 200000 ]' \
  '[ "$(wc -l < "$member_list")" -le 200000 ]' \
  '[ "$modules_manifest_file_count" -le 400000 ]' \
  '"$TAR_BIN" --format=gnu --hard-dereference --null --no-recursion'; do
  require_literal "$sdk_limit_token"
done

toolchain_manifest_function=$(sed -n '/^write_kernel_toolchain_manifest() {$/,/^}$/p' "$packager")
for required_tool_label in \
  gcc as ld ar nm objcopy objdump readelf strip rustc host-gcc host-gxx \
  host-as host-ld host-ar flex \
  bison m4 awk perl python3 pkg-config pahole git make depmod modinfo tar gzip xz \
  dpkg-deb fdtget bash sh bc getconf sha1sum ln uname cmp head expr uniq; do
  grep -Eq "(^|[[:space:]])${required_tool_label}([[:space:]\\\\;]|$)" \
    <<<"$toolchain_manifest_function" ||
    fail "kernel toolchain evidence omits required tool: $required_tool_label"
done
expected_toolchain_labels=$(cat <<'EOF'
gcc
as
ld
ar
nm
objcopy
objdump
readelf
strip
rustc
host-gcc
host-gxx
host-as
host-ld
host-ar
flex
bison
m4
awk
perl
python3
pkg-config
pahole
git
make
depmod
modinfo
tar
gzip
xz
dpkg-deb
fdtget
bash
sh
bc
getconf
sha1sum
ln
uname
sha256sum
find
sort
xargs
rsync
cp
dpkg
touch
realpath
nproc
date
install
stat
grep
sed
readlink
wc
tr
cut
findmnt
curl
flock
mv
chmod
mkdir
mktemp
rm
cat
dirname
basename
env
true
cmp
head
expr
uniq
EOF
)
actual_toolchain_labels=$(awk '
  /^[[:space:]]+for tool_label in \\/ { capture = 1; next }
  capture {
    line = $0
    finished = line ~ /;[[:space:]]*do[[:space:]]*$/
    sub(/;[[:space:]]*do[[:space:]]*$/, "", line)
    sub(/\\[[:space:]]*$/, "", line)
    count = split(line, fields, /[[:space:]]+/)
    for (field_index = 1; field_index <= count; field_index++) {
      if (length(fields[field_index])) print fields[field_index]
    }
    if (finished) exit
  }
' <<<"$toolchain_manifest_function")
[ "$actual_toolchain_labels" = "$expected_toolchain_labels" ] ||
  fail "kernel toolchain evidence labels differ from the exact approved order"
for tool_policy_token in \
  'declare -A LOCKED_TOOL_PATH=()' \
  'declare -A LOCKED_TOOL_COMMAND_PATH=()' \
  'declare -A LOCKED_TOOL_COMMAND_NAME=()' \
  'declare -A LOCKED_TOOL_SHA256=()' \
  'declare -A LOCKED_TOOL_VERSION=()' \
  'declare -A LOCKED_TOOL_STATE=()' \
  'declare -A LOCKED_TOOL_COMMAND_STATE=()' \
  'm4:m4' \
  'capture_bison_data_identity' \
  'canonical_data_tree_sha256' \
  'verify_bison_data_identity' \
  "printf 'bison-data-directory\\t%s\\n'" \
  "printf 'bison-data-sha256\\t%s\\n'" \
  'cut:cut' \
  'findmnt:findmnt' \
  'findmnt() { "${LOCKED_TOOL_PATH[findmnt]}" "$@"; }' \
  'cut() { "${LOCKED_TOOL_PATH[cut]}" "$@"; }' \
  '"$MAKE_BIN" -C "$kernel_source"' \
  'depmod_config="$work/depmod.conf"' \
  'install -m 0644 /dev/null "$depmod_config"' \
  '"$DEPMOD_BIN" -C "$depmod_config" -b "$modules_root" "$kernel_release"' \
  "printf 'depmod-config\\tempty-private-v1\\n'" \
  'vermagic=$("$MODINFO_BIN" -F vermagic "$module")' \
  '"$DPKG_DEB_BIN" --root-owner-group' \
  '--threads-max=1 -Zxz -z6' \
  "printf 'dpkg-deb-threads-max\\t1\\n'" \
  "printf 'dpkg-deb-compressor-type\\txz\\n'" \
  "printf 'dpkg-deb-compressor-level\\t6\\n'" \
  '"$TAR_BIN" --format=gnu --hard-dereference --null --no-recursion --sort=name' \
  '"$GZIP_BIN" -6 -n' \
  '"$TAR_BIN" -tzf "$destination" > "$member_list"' \
  "verify_locked_tools 'before bootstrap promotion'" \
  "verify_locked_tools 'after final stage verification'"; do
  require_literal "$tool_policy_token"
done
[ "$(grep -Fc '"$TAR_BIN" --format=gnu' "$packager")" -eq 3 ] ||
  fail "all three producer tar streams must use the fixed GNU format"
[ "$(grep -Fc '"$GZIP_BIN" -6 -n' "$packager")" -eq 3 ] ||
  fail "all three producer gzip streams must use fixed level 6 without timestamps"

tool_identity_function_file="$fixture/tool-identity-functions.sh"
: > "$tool_identity_function_file"
for tool_function_name in resolve_tool_path capture_tool_identity verify_locked_tools; do
  tool_function=$(sed -n "/^${tool_function_name}() {$/,/^}$/p" "$packager")
  [ -n "$tool_function" ] || fail "unable to extract $tool_function_name"
  printf '%s\n' "$tool_function" >> "$tool_identity_function_file"
done
fixture_tool="$fixture/identity-locked-tool"
cat > "$fixture_tool" <<'EOF'
#!/bin/sh
printf 'tb321fu fixture tool AAA\n'
EOF
chmod 0755 "$fixture_tool"
set +e
tool_drift_output=$(
  (
    # shellcheck source=common.sh
    . "$common"
    declare -A LOCKED_TOOL_PATH=()
    declare -A LOCKED_TOOL_COMMAND_PATH=()
    declare -A LOCKED_TOOL_COMMAND_NAME=()
    declare -A LOCKED_TOOL_SHA256=()
    declare -A LOCKED_TOOL_VERSION=()
    declare -A LOCKED_TOOL_STATE=()
    declare -A LOCKED_TOOL_COMMAND_STATE=()
    # shellcheck source=/dev/null
    . "$tool_identity_function_file"
    LOCKED_TOOL_PATH[sha256sum]=/usr/bin/sha256sum
    LOCKED_TOOL_PATH[stat]=/usr/bin/stat
    LOCKED_TOOL_PATH[realpath]=/usr/bin/realpath
    verify_bison_data_identity() { :; }
    resolve_tool_path fixture-tool "$fixture_tool"
    capture_tool_identity fixture-tool
    verify_locked_tools 'before fixture mutation'
    fixture_tool_mtime=$(/usr/bin/stat -c '%Y' -- "$fixture_tool")
    printf '#!/bin/sh\nprintf '\''tb321fu fixture tool BBB\\n'\''\n' > "$fixture_tool"
    chmod 0755 "$fixture_tool"
    touch -d "@$fixture_tool_mtime" "$fixture_tool"
    verify_locked_tools 'after fixture mutation'
  ) 2>&1
)
tool_drift_status=$?
set -e
[ "$tool_drift_status" -ne 0 ] || fail "post-resolution tool byte drift was accepted"
grep -Fq 'locked tool bytes changed after fixture mutation: fixture-tool' \
  <<<"$tool_drift_output" ||
  fail "post-resolution tool byte drift failed at the wrong boundary"

bison_data_function_file="$fixture/bison-data-functions.sh"
: > "$bison_data_function_file"
for bison_data_function_name in \
  canonical_data_tree_sha256 capture_bison_data_identity verify_bison_data_identity; do
  bison_data_function=$(sed -n \
    "/^${bison_data_function_name}() {$/,/^}$/p" "$packager")
  [ -n "$bison_data_function" ] ||
    fail "unable to extract $bison_data_function_name"
  printf '%s\n' "$bison_data_function" >> "$bison_data_function_file"
done
bison_data_fixture="$fixture/bison-data"
fake_bison="$fixture/fake-bison"
mkdir -m 0755 -- "$bison_data_fixture" "$bison_data_fixture/skeletons"
printf 'fixture AAA\n' > "$bison_data_fixture/skeletons/yacc.c"
chmod 0644 "$bison_data_fixture/skeletons/yacc.c"
cat > "$fake_bison" <<EOF_FAKE_BISON
#!/bin/sh
[ "\${1-}" = --print-datadir ] || exit 97
printf '%s\n' '$bison_data_fixture'
EOF_FAKE_BISON
chmod 0755 "$fake_bison"
set +e
bison_data_drift_output=$(
  (
    # shellcheck source=common.sh
    . "$common"
    declare -A LOCKED_TOOL_PATH=()
    LOCKED_TOOL_PATH[bison]="$fake_bison"
    LOCKED_TOOL_PATH[realpath]=/usr/bin/realpath
    LOCKED_TOOL_PATH[find]=/usr/bin/find
    LOCKED_TOOL_PATH[wc]=/usr/bin/wc
    LOCKED_TOOL_PATH[awk]=/usr/bin/awk
    LOCKED_TOOL_PATH[tar]=/usr/bin/tar
    LOCKED_TOOL_PATH[sha256sum]=/usr/bin/sha256sum
    LOCKED_TOOL_PATH[stat]=/usr/bin/stat
    # shellcheck source=/dev/null
    . "$bison_data_function_file"
    capture_bison_data_identity
    verify_bison_data_identity 'before fixture mutation'
    fixture_data_mtime=$(/usr/bin/stat -c '%Y' -- \
      "$bison_data_fixture/skeletons/yacc.c")
    printf 'fixture BBB\n' > "$bison_data_fixture/skeletons/yacc.c"
    touch -d "@$fixture_data_mtime" "$bison_data_fixture/skeletons/yacc.c"
    verify_bison_data_identity 'after fixture mutation'
  ) 2>&1
)
bison_data_drift_status=$?
set -e
[ "$bison_data_drift_status" -ne 0 ] ||
  fail "post-capture Bison data-tree byte drift was accepted"
grep -Fq 'Bison data tree bytes changed after fixture mutation' \
  <<<"$bison_data_drift_output" ||
  fail "Bison data-tree drift failed at the wrong boundary: $bison_data_drift_output"

kernel_path_function_file="$fixture/kernel-locked-path-functions.sh"
: > "$kernel_path_function_file"
for kernel_path_function_name in prepare_kernel_locked_path verify_kernel_locked_path; do
  kernel_path_function=$(sed -n "/^${kernel_path_function_name}() {$/,/^}$/p" "$packager")
  [ -n "$kernel_path_function" ] ||
    fail "unable to extract $kernel_path_function_name"
  printf '%s\n' "$kernel_path_function" >> "$kernel_path_function_file"
done
run_kernel_path_fixture() (
  local scenario=$1 destination="$fixture/kernel-locked-path-$1"

  # shellcheck source=common.sh
  . "$common"
  declare -A LOCKED_TOOL_PATH=()
  declare -A LOCKED_TOOL_COMMAND_NAME=()
  LOCKED_TOOL_PATH[fixture-true]=$(realpath -e -- /usr/bin/true)
  LOCKED_TOOL_COMMAND_NAME[fixture-true]=true
  LOCKED_TOOL_PATH[fixture-false]=$(realpath -e -- /usr/bin/false)
  LOCKED_TOOL_COMMAND_NAME[fixture-false]=false
  LN_BIN=/usr/bin/ln
  READLINK_BIN=/usr/bin/readlink
  # shellcheck source=/dev/null
  . "$kernel_path_function_file"
  prepare_kernel_locked_path "$destination"
  case "$scenario" in
    pass) ;;
    retarget)
      rm "$destination/true"
      ln -s "${LOCKED_TOOL_PATH[fixture-false]}" "$destination/true"
      ;;
    extra)
      printf 'unexpected\n' > "$destination/unexpected"
      ;;
    *) ci_die 'unknown kernel locked-path fixture scenario' ;;
  esac
  verify_kernel_locked_path "$destination"
)
run_kernel_path_fixture pass
set +e
retargeted_kernel_path_output=$(run_kernel_path_fixture retarget 2>&1)
retargeted_kernel_path_status=$?
set -e
[ "$retargeted_kernel_path_status" -ne 0 ] ||
  fail "retargeted private Kbuild tool link was accepted"
grep -Eq 'private Kbuild tool link (target changed|resolves to unexpected bytes)' \
  <<<"$retargeted_kernel_path_output" ||
  fail "retargeted private Kbuild tool link failed at the wrong boundary"
set +e
extra_kernel_path_output=$(run_kernel_path_fixture extra 2>&1)
extra_kernel_path_status=$?
set -e
[ "$extra_kernel_path_status" -ne 0 ] ||
  fail "unexpected private Kbuild tool-path entry was accepted"
grep -Fq 'private Kbuild tool path contains a non-symlink entry' \
  <<<"$extra_kernel_path_output" ||
  fail "unexpected private Kbuild tool-path entry failed at the wrong boundary"

host_compiler_path="$fixture/host-compiler-tools"
mkdir -m 0700 -- "$host_compiler_path"
for host_compiler_tool in gcc g++ as ld ar; do
  host_compiler_target=$(type -P -- "$host_compiler_tool") ||
    fail "host compiler closure tool is unavailable: $host_compiler_tool"
  host_compiler_target=$(realpath -e -- "$host_compiler_target") ||
    fail "cannot resolve host compiler closure tool: $host_compiler_tool"
  ln -s -- "$host_compiler_target" "$host_compiler_path/$host_compiler_tool"
done
printf 'int main(void) { return 0; }\n' > "$fixture/host-probe.c"
printf 'int main() { return 0; }\n' > "$fixture/host-probe.cc"
for host_probe in c cc; do
  case "$host_probe" in
    c) host_driver=gcc ;;
    cc) host_driver=g++ ;;
  esac
  env -i \
    PATH="$host_compiler_path" \
    HOME=/nonexistent LANG=C LC_ALL=C TZ=UTC \
    "$host_compiler_path/$host_driver" -fno-lto -c \
    "$fixture/host-probe.$host_probe" -o "$fixture/host-probe-$host_probe.o"
  env -i \
    PATH="$host_compiler_path" \
    HOME=/nonexistent LANG=C LC_ALL=C TZ=UTC \
    "$host_compiler_path/$host_driver" -fno-lto \
    "$fixture/host-probe-$host_probe.o" -o "$fixture/host-probe-$host_probe"
  [ -s "$fixture/host-probe-$host_probe" ] ||
    fail "private host compiler closure did not link $host_probe"
done
env -i \
  PATH="$host_compiler_path" \
  HOME=/nonexistent LANG=C LC_ALL=C TZ=UTC \
  "$host_compiler_path/ar" rcs \
  "$fixture/host-probe.a" "$fixture/host-probe-c.o"
[ -s "$fixture/host-probe.a" ] ||
  fail 'private host compiler closure did not produce an archive'

kernel_archive_fixture_name=tb321fu-kernel-artifacts-fixture.tar.gz
device_archive_fixture_name=tb321fu-device-debs-fixture.tar.gz
sdk_archive_fixture_name=tb321fu-kernel-build-sdk-fixture.tar.gz
stage_checksum_names=(
  "$kernel_archive_fixture_name"
  "$device_archive_fixture_name"
  "$sdk_archive_fixture_name"
  KERNEL-SOURCE-LOCK.tsv
  KERNEL-BUNDLE.tsv
  MODULES.sha256
  KERNEL-SDK-MANIFEST.tsv
  KERNEL-TOOLCHAIN.tsv
  KBUILD-FLAGS.tsv
)
verify_stage_fixture() (
  local stage_path=$1

  # shellcheck source=common.sh
  . "$common"
  ci_verify_kernel_bootstrap_stage \
    "$stage_path" \
    "$kernel_archive_fixture_name" \
    "$device_archive_fixture_name" \
    "$sdk_archive_fixture_name" \
    /usr/bin/sha256sum \
    /usr/bin/stat
)
expect_stage_failure() {
  local label=$1 expected=$2 stage_path=$3 output status

  set +e
  output=$(verify_stage_fixture "$stage_path" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$label was accepted by final stage verification"
  grep -Fq -- "$expected" <<<"$output" ||
    fail "$label failed at the wrong final stage boundary"
}

valid_stage="$fixture/valid-final-stage"
mkdir "$valid_stage"
for stage_name in "${stage_checksum_names[@]}"; do
  printf 'fixture payload: %s\n' "$stage_name" > "$valid_stage/$stage_name"
  chmod 0644 "$valid_stage/$stage_name"
done
(
  cd "$valid_stage"
  sha256sum -- "${stage_checksum_names[@]}" > SHA256SUMS.txt
)
chmod 0644 "$valid_stage/SHA256SUMS.txt"
verify_stage_fixture "$valid_stage"

extra_stage="$fixture/extra-final-stage"
cp -a "$valid_stage" "$extra_stage"
printf 'unexpected\n' > "$extra_stage/UNEXPECTED"
chmod 0644 "$extra_stage/UNEXPECTED"
expect_stage_failure \
  'extra final stage member' \
  'kernel bootstrap stage must contain exactly ten root files' \
  "$extra_stage"

symlink_stage="$fixture/symlink-final-stage"
cp -a "$valid_stage" "$symlink_stage"
rm "$symlink_stage/KERNEL-BUNDLE.tsv"
ln -s KERNEL-SOURCE-LOCK.tsv "$symlink_stage/KERNEL-BUNDLE.tsv"
expect_stage_failure \
  'symlink final stage member' \
  'kernel bootstrap stage member must be a regular file: KERNEL-BUNDLE.tsv' \
  "$symlink_stage"

mode_stage="$fixture/mode-final-stage"
cp -a "$valid_stage" "$mode_stage"
chmod 0600 "$mode_stage/KERNEL-BUNDLE.tsv"
expect_stage_failure \
  'noncanonical final stage mode' \
  'kernel bootstrap stage member mode must be 0644: KERNEL-BUNDLE.tsv' \
  "$mode_stage"

short_checksum_stage="$fixture/short-checksum-final-stage"
cp -a "$valid_stage" "$short_checksum_stage"
sed -i '$d' "$short_checksum_stage/SHA256SUMS.txt"
expect_stage_failure \
  'short final checksum manifest' \
  'kernel bootstrap checksum manifest must contain exactly nine records' \
  "$short_checksum_stage"

corrupt_stage="$fixture/corrupt-final-stage"
cp -a "$valid_stage" "$corrupt_stage"
printf 'post-checksum corruption\n' >> "$corrupt_stage/KERNEL-BUNDLE.tsv"
expect_stage_failure \
  'checksum-mismatched final stage member' \
  'kernel bootstrap checksum verification failed' \
  "$corrupt_stage"

verify_dtb_fixture() (
  local dtb_path=$1

  # shellcheck source=common.sh
  . "$common"
  ci_verify_tb321fu_haptics_dtb "$dtb_path" /usr/bin/fdtget
)
expect_dtb_failure() {
  local label=$1 expected=$2 dtb_path=$3 output status

  set +e
  output=$(verify_dtb_fixture "$dtb_path" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$label was accepted by the compiled DTB contract"
  grep -Fq -- "$expected" <<<"$output" ||
    fail "$label failed at the wrong compiled DTB contract boundary"
}

valid_dts="$fixture/valid-aw86937.dts"
valid_dtb="$fixture/valid-aw86937.dtb"
cat > "$valid_dts" <<'EOF'
/dts-v1/;

/ {
  fixture-i2c {
    #address-cells = <1>;
    #size-cells = <0>;
    haptics-right@5a { compatible = "lenovo,tb321fu-aw86937", "awinic,aw86937"; reg = <0x5a>; label = "aw86937-haptics-right"; };
    haptics-left@5b { compatible = "lenovo,tb321fu-aw86937", "awinic,aw86937"; reg = <0x5b>; label = "aw86937-haptics-left"; };
  };
};
EOF
dtc -q -I dts -O dtb -o "$valid_dtb" "$valid_dts"
verify_dtb_fixture "$valid_dtb"

missing_left_dts="$fixture/missing-left-aw86937.dts"
missing_left_dtb="$fixture/missing-left-aw86937.dtb"
grep -Fv 'haptics-left@5b' "$valid_dts" > "$missing_left_dts"
dtc -q -I dts -O dtb -o "$missing_left_dtb" "$missing_left_dts"
expect_dtb_failure \
  'single-node AW86937 DTB' \
  'compiled DTB lacks the two TB321FU AW86937 nodes' \
  "$missing_left_dtb"

wrong_reg_dts="$fixture/wrong-reg-aw86937.dts"
wrong_reg_dtb="$fixture/wrong-reg-aw86937.dtb"
sed 's/reg = <0x5b>/reg = <0x5c>/' "$valid_dts" > "$wrong_reg_dts"
dtc -q -I dts -O dtb -o "$wrong_reg_dtb" "$wrong_reg_dts"
expect_dtb_failure \
  'wrong-reg AW86937 DTB' \
  'compiled DTB AW86937 reg mismatch' \
  "$wrong_reg_dtb"

wrong_compatible_dts="$fixture/wrong-compatible-aw86937.dts"
wrong_compatible_dtb="$fixture/wrong-compatible-aw86937.dtb"
sed 's/"lenovo,tb321fu-aw86937", "awinic,aw86937"/"awinic,aw86937"/' \
  "$valid_dts" > "$wrong_compatible_dts"
dtc -q -I dts -O dtb -o "$wrong_compatible_dtb" "$wrong_compatible_dts"
expect_dtb_failure \
  'incomplete-compatible AW86937 DTB' \
  'compiled DTB AW86937 compatible mismatch' \
  "$wrong_compatible_dtb"

sensor_commit=1111111111111111111111111111111111111111
haptics_commit=2222222222222222222222222222222222222222
haptics_module_sha=$(printf '3%.0s' {1..64})
haptics_helper_binary_sha=$(printf '4%.0s' {1..64})
rootfs_config_fixture="$fixture/rootfs.env"
source_config_fixture="$fixture/source.env"
rootfs_github_env_fixture="$fixture/rootfs-github.env"
source_github_env_fixture="$fixture/source-github.env"
{
  printf 'SENSOR_PRODUCER_COMMIT=%s\n' "$sensor_commit"
  printf 'HAPTICS_PRODUCER_COMMIT=%s\n' "$haptics_commit"
} > "$rootfs_config_fixture"
GITHUB_ENV="$rootfs_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$rootfs_config_fixture"
{
  printf 'HAPTICS_MODULE_SHA256=%s\n' "$haptics_module_sha"
  printf 'HAPTICS_HELPER_BINARY_SHA256=%s\n' "$haptics_helper_binary_sha"
} > "$source_config_fixture"
GITHUB_ENV="$source_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$source_config_fixture"
read_exported_config() {
  local key=$1 file=$2
  awk -v key="$key" '
  index($0, key "<<") == 1 {
    delimiter = $0
    sub("^" key "<<", "", delimiter)
    found = 1
    while ((getline value) > 0) {
      if (value == delimiter) {
        closed = 1
        exit
      }
      print value
    }
    exit 2
  }
  END { if (!found || !closed) exit 3 }
  ' "$file"
}
propagated_sensor_commit=$(read_exported_config SENSOR_PRODUCER_COMMIT \
  "$rootfs_github_env_fixture") || fail "SENSOR_PRODUCER_COMMIT was not exported through workflow config"
[ "$propagated_sensor_commit" = "$sensor_commit" ] ||
  fail "SENSOR_PRODUCER_COMMIT changed during workflow config propagation"
propagated_haptics_commit=$(read_exported_config HAPTICS_PRODUCER_COMMIT \
  "$rootfs_github_env_fixture") || fail "HAPTICS_PRODUCER_COMMIT was not exported through workflow config"
[ "$propagated_haptics_commit" = "$haptics_commit" ] ||
  fail "HAPTICS_PRODUCER_COMMIT changed during workflow config propagation"
propagated_haptics_module_sha=$(read_exported_config HAPTICS_MODULE_SHA256 \
  "$source_github_env_fixture") || fail "HAPTICS_MODULE_SHA256 was not exported through workflow config"
[ "$propagated_haptics_module_sha" = "$haptics_module_sha" ] ||
  fail "HAPTICS_MODULE_SHA256 changed during workflow config propagation"
propagated_haptics_helper_binary_sha=$(read_exported_config \
  HAPTICS_HELPER_BINARY_SHA256 "$source_github_env_fixture") ||
  fail "HAPTICS_HELPER_BINARY_SHA256 was not exported through workflow config"
[ "$propagated_haptics_helper_binary_sha" = "$haptics_helper_binary_sha" ] ||
  fail "HAPTICS_HELPER_BINARY_SHA256 changed during workflow config propagation"

apt_sources_fixture=$'deb https://ports.ubuntu.com/ubuntu-ports resolute main\ndeb [arch=arm64 signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main'
apt_sources_b64=$(printf '%s' "$apt_sources_fixture" | base64 -w 0)
printf 'APT_SOURCES_LIST_B64=%s\n' "$apt_sources_b64" > "$rootfs_config_fixture"
GITHUB_ENV="$rootfs_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$rootfs_config_fixture"
propagated_apt_sources=$(read_exported_config APT_SOURCES_LIST "$rootfs_github_env_fixture") ||
  fail "APT_SOURCES_LIST_B64 was not exported as a multiline source list"
[ "$propagated_apt_sources" = "$apt_sources_fixture" ] ||
  fail "APT_SOURCES_LIST_B64 changed during configuration propagation"

resolv_fixture=$'nameserver 1.1.1.1\noptions timeout:1'
resolv_b64=$(printf '%s' "$resolv_fixture" | base64 -w 0)
printf 'RESOLV_CONF_CONTENT_B64=%s\n' "$resolv_b64" > "$rootfs_config_fixture"
GITHUB_ENV="$rootfs_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$rootfs_config_fixture"
propagated_resolv=$(read_exported_config RESOLV_CONF_CONTENT "$rootfs_github_env_fixture") ||
  fail "RESOLV_CONF_CONTENT_B64 was not exported as multiline resolver content"
[ "$propagated_resolv" = "$resolv_fixture" ] ||
  fail "RESOLV_CONF_CONTENT_B64 changed during configuration propagation"

printf 'APT_SOURCES_LIST=deb https://ports.ubuntu.com/ubuntu-ports resolute main\ndeb https://ports.ubuntu.com/ubuntu-ports resolute-updates main\n' > "$rootfs_config_fixture"
set +e
raw_multiline_apt_output=$(GITHUB_ENV="$rootfs_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$rootfs_config_fixture" 2>&1)
raw_multiline_apt_status=$?
set -e
[ "$raw_multiline_apt_status" -ne 0 ] ||
  fail "raw multiline APT source configuration was accepted without explicit encoding"
grep -Fq 'invalid config line, expected KEY=value' <<<"$raw_multiline_apt_output" ||
  fail "raw multiline APT source configuration failed at the wrong boundary"

printf 'APT_SOURCES_LIST=deb https://ports.ubuntu.com/ubuntu-ports resolute main\nAPT_SOURCES_LIST_B64=%s\n' "$apt_sources_b64" > "$rootfs_config_fixture"
: > "$rootfs_github_env_fixture"
GITHUB_ENV="$rootfs_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$rootfs_config_fixture"
propagated_apt_override=$(read_exported_config APT_SOURCES_LIST "$rootfs_github_env_fixture") ||
  fail "last APT source configuration was not exported"
[ "$propagated_apt_override" = "$apt_sources_fixture" ] ||
  fail "last APT source configuration did not override the earlier declaration"

printf 'HAPTICS_MODULE_SHA256=%s\n' "$(printf 'A%.0s' {1..64})" > "$source_config_fixture"
set +e
invalid_haptics_digest_output=$(GITHUB_ENV="$source_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$source_config_fixture" 2>&1)
invalid_haptics_digest_status=$?
set -e
[ "$invalid_haptics_digest_status" -ne 0 ] ||
  fail "uppercase haptics digest was accepted"
grep -Fq 'HAPTICS_MODULE_SHA256 must be empty or 64 lowercase hex characters' \
  <<<"$invalid_haptics_digest_output" ||
  fail "invalid haptics digest failed at the wrong boundary"

printf 'SENSOR_PRODUCER_COMMIT=%s\n' ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD > "$rootfs_config_fixture"
set +e
invalid_sensor_commit_output=$(GITHUB_ENV="$rootfs_github_env_fixture" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$rootfs_config_fixture" 2>&1)
invalid_sensor_commit_status=$?
set -e
[ "$invalid_sensor_commit_status" -ne 0 ] ||
  fail "uppercase sensor producer commit was accepted"
grep -Fq 'SENSOR_PRODUCER_COMMIT must be empty or 40 lowercase hex characters' \
  <<<"$invalid_sensor_commit_output" ||
  fail "invalid sensor producer commit failed at the wrong boundary"

printf 'KERNEL_BOOTSTRAP_POLICY=PASS\n'
