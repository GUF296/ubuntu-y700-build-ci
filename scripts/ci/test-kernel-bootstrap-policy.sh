#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
packager="$SCRIPT_DIR/package-kernel-bootstrap.sh"
common="$SCRIPT_DIR/common.sh"
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
  'kernel worktree has unsafe assume-unchanged/skip-worktree index flags $phase' \
  'kernel config SHA-256 mismatch $phase' \
  'ci_sanitized_git_env git --no-replace-objects' \
  'ci_sanitized_kernel_env' \
  'Build from a fresh private O= directory.' \
  'kernel build input changed while bootstrap packaging ran' \
  'kernel_make -j"$KERNEL_BUILD_JOBS" Image modules "qcom/$DTB_NAME"' \
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
  'rustc_sha256' \
  'kernel-sdk-archive-sha256' \
  'KERNEL-SDK-MANIFEST.tsv' \
  'KERNEL-TOOLCHAIN.tsv' \
  'KBUILD-FLAGS.tsv' \
  'MODULES.sha256' \
  'eight-member baseline archive must contain the complete replaceable metadata set' \
  'baseline_sdk_metadata' \
  'verify_bootstrap_producer_state' \
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

for token in KCFLAGS KAFLAGS KCPPFLAGS KRUSTFLAGS; do
  grep -Fq -- "$token" "$common" ||
    fail "missing kernel-environment sanitization token: $token"
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

set +e
invalid_cross_compile_output=$(env "${common_env[@]}" \
  EXPECTED_KERNEL_COMMIT=0000000000000000000000000000000000000000 \
  CROSS_COMPILE='../hostile-' bash "$packager" 2>&1)
invalid_cross_compile_status=$?
set -e
[ "$invalid_cross_compile_status" -ne 0 ] || fail "unsafe cross compiler prefix was accepted"
grep -Fq 'unsafe CROSS_COMPILE' <<<"$invalid_cross_compile_output" ||
  fail "unsafe cross compiler prefix failed at the wrong boundary"

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
printf 'CONFIG_TB321FU_FIXTURE=y\nCONFIG_RUSTC_VERSION=0\n' > "$build_dir/.config"
fixture_commit=$(git -C "$source_dir" rev-parse HEAD)
fixture_config_sha=$(sha256sum "$build_dir/.config" | awk '{print $1}')
producer_root="$fixture/bootstrap-producer"
producer_scripts="$producer_root/scripts/ci"
producer_packager="$producer_scripts/package-kernel-bootstrap.sh"
mkdir -p "$producer_scripts"
cp "$packager" "$producer_packager"
cp "$SCRIPT_DIR/common.sh" "$producer_scripts/common.sh"
chmod 0755 "$producer_packager"
git -C "$producer_root" init -q
git -C "$producer_root" config user.name 'TB321FU producer fixture'
git -C "$producer_root" config user.email noreply@localhost
git -C "$producer_root" add scripts/ci/package-kernel-bootstrap.sh scripts/ci/common.sh
git -C "$producer_root" commit -qm 'bootstrap producer fixture'
producer_repository=GUF296/ubuntu-y700-build-ci
producer_commit=$(git -C "$producer_root" rev-parse HEAD)
producer_tree=$(git -C "$producer_root" rev-parse HEAD^{tree})
producer_tree_sha256=$(git -C "$producer_root" cat-file tree "$producer_tree" | sha256sum | awk '{print $1}')
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
  KCFLAGS='-include /tmp/hostile-kcflags' \
  KAFLAGS='-include /tmp/hostile-kaflags' \
  KCPPFLAGS='-include /tmp/hostile-kcppflags' \
  KRUSTFLAGS='--cfg hostile_krustflags' \
  KBUILD_CFLAGS='-DHOSTILE_KBUILD_CFLAGS' \
  KBUILD_AFLAGS='-DHOSTILE_KBUILD_AFLAGS' \
  KBUILD_CPPFLAGS='-DHOSTILE_KBUILD_CPPFLAGS' \
  KBUILD_RUSTFLAGS='--cfg hostile_kbuild_rustflags' \
  CFLAGS='-DHOSTILE_CFLAGS' \
  LDFLAGS='-Wl,--hostile' \
  HOSTCFLAGS='-DHOSTILE_HOSTCFLAGS' \
  LDFLAGS_vmlinux='-Wl,--hostile-vmlinux' \
  MAKEFLAGS='-e --eval=hostile' \
  bash -c '. "$1"; ci_sanitized_kernel_env ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- env' \
  bash "$SCRIPT_DIR/common.sh")
for hostile_variable in \
  KCFLAGS KAFLAGS KCPPFLAGS KRUSTFLAGS KBUILD_CFLAGS KBUILD_AFLAGS \
  KBUILD_CPPFLAGS KBUILD_RUSTFLAGS CFLAGS LDFLAGS HOSTCFLAGS \
  LDFLAGS_vmlinux MAKEFLAGS; do
  if grep -Fq "${hostile_variable}=" <<<"$hostile_kernel_env"; then
    fail "hostile inherited kernel build variable survived sanitization: $hostile_variable"
  fi
done
grep -Fxq 'ARCH=arm64' <<<"$hostile_kernel_env" ||
  fail "explicit kernel architecture did not survive sanitization"
grep -Fxq 'CROSS_COMPILE=aarch64-linux-gnu-' <<<"$hostile_kernel_env" ||
  fail "explicit kernel toolchain prefix did not survive sanitization"

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

clone_source="$fixture/clone-source"
clone_destination="$fixture/clone-destination"
mkdir -p "$clone_source/include/config" "$clone_source/include/generated" "$clone_destination"
printf 'original-config\n' > "$clone_source/.config"
printf 'authoritative-sentinel\n' > "$clone_source/include/generated/sentinel"
install -m 0644 "$clone_source/.config" "$clone_destination/.config"
[ ! "$clone_source/.config" -ef "$clone_destination/.config" ] ||
  fail "private kernel .config shares an inode with the authoritative input"
[ ! -e "$clone_destination/include/generated/sentinel" ] ||
  fail "private kernel output inherited an authoritative generated file"
printf 'private-config\n' > "$clone_destination/.config"
install -d -m 0755 "$clone_destination/include/generated"
printf 'private-sentinel\n' > "$clone_destination/include/generated/sentinel"
grep -Fxq 'original-config' "$clone_source/.config" ||
  fail "private kernel config write changed the authoritative build input"
grep -Fxq 'authoritative-sentinel' "$clone_source/include/generated/sentinel" ||
  fail "private kernel generated-file write changed the authoritative build input"
grep -Fxq 'private-config' "$clone_destination/.config" ||
  fail "private kernel config was not written"
grep -Fxq 'private-sentinel' "$clone_destination/include/generated/sentinel" ||
  fail "private kernel generated file was not written"

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
