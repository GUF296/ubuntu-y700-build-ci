#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: package-kernel-bootstrap.sh

Required environment:
  KERNEL_SOURCE_DIR             authoritative kernel worktree
  KERNEL_GIT_DIR                authoritative Git object database
  KERNEL_BUILD_DIR              completed out-of-tree kernel build
  EXPECTED_KERNEL_COMMIT        exact 40-hex source commit
  EXPECTED_KERNEL_CONFIG_SHA256 exact approved post-olddefconfig .config digest
  KERNEL_PACKAGE_VERSION        Debian version for the modules package
  BASE_DEVICE_DEB_ARCHIVE       tested device archive to update
  BASE_DEVICE_DEB_ARCHIVE_SHA256

Optional environment:
  OUTPUT_DIR                    default: out/tb321fu-kernel-bootstrap
  SOURCE_DATE_EPOCH             default: kernel commit timestamp
  KERNEL_BUILD_JOBS             default: host CPU count
  ARCH                          default: arm64
  CROSS_COMPILE                 default: aarch64-linux-gnu-
  DTB_NAME                      default: sm8650-lenovo-tb321fu.dtb
  KBUILD_BUILD_TIMESTAMP        default: UTC kernel commit timestamp
  KBUILD_BUILD_USER             default: tb321fu-ci
  KBUILD_BUILD_HOST             default: tb321fu-builder
  KBUILD_BUILD_VERSION          default: 1

Options:
  --preflight                   validate source/config/build identity only

The baseline rootfs-overlay DEB and compat overlay are copied byte-for-byte.
Only the kernel-modules DEB is replaced. Image, DTB and modules must come from
the same clean, commit-bound build.
EOF
}

mode=build
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --preflight) mode=preflight; shift ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

for command in git make sha256sum find sort xargs rsync dpkg dpkg-deb depmod modinfo tar touch realpath nproc date install awk stat; do
  ci_require_cmd "$command"
done

: "${KERNEL_SOURCE_DIR:?set KERNEL_SOURCE_DIR}"
: "${KERNEL_GIT_DIR:?set KERNEL_GIT_DIR}"
: "${KERNEL_BUILD_DIR:?set KERNEL_BUILD_DIR}"
: "${EXPECTED_KERNEL_COMMIT:?set EXPECTED_KERNEL_COMMIT}"
: "${EXPECTED_KERNEL_CONFIG_SHA256:?set EXPECTED_KERNEL_CONFIG_SHA256}"
: "${KERNEL_PACKAGE_VERSION:?set KERNEL_PACKAGE_VERSION}"
: "${BASE_DEVICE_DEB_ARCHIVE:?set BASE_DEVICE_DEB_ARCHIVE}"
: "${BASE_DEVICE_DEB_ARCHIVE_SHA256:?set BASE_DEVICE_DEB_ARCHIVE_SHA256}"

ARCH=${ARCH:-arm64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
DTB_NAME=${DTB_NAME:-sm8650-lenovo-tb321fu.dtb}
OUTPUT_DIR=${OUTPUT_DIR:-out/tb321fu-kernel-bootstrap}
KERNEL_BUILD_JOBS=${KERNEL_BUILD_JOBS:-$(nproc)}

[[ $EXPECTED_KERNEL_COMMIT =~ ^[0-9a-f]{40}$ ]] || ci_die "EXPECTED_KERNEL_COMMIT must be 40 lowercase hex characters"
[[ $EXPECTED_KERNEL_CONFIG_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid EXPECTED_KERNEL_CONFIG_SHA256"
[[ $BASE_DEVICE_DEB_ARCHIVE_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || ci_die "invalid baseline archive SHA-256"
[[ $DTB_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\.dtb$ ]] || ci_die "unsafe DTB_NAME"
[[ $KERNEL_PACKAGE_VERSION =~ ^[0-9][0-9A-Za-z.+~_-]{0,63}$ ]] || ci_die "unsafe KERNEL_PACKAGE_VERSION"
[[ $KERNEL_BUILD_JOBS =~ ^[1-9][0-9]{0,3}$ ]] || ci_die "invalid KERNEL_BUILD_JOBS"
dpkg --validate-version "$KERNEL_PACKAGE_VERSION" >/dev/null || ci_die "invalid KERNEL_PACKAGE_VERSION"
ci_require_cmd "${CROSS_COMPILE}gcc"

kernel_source=$(realpath -e -- "$KERNEL_SOURCE_DIR")
kernel_git=$(realpath -e -- "$KERNEL_GIT_DIR")
kernel_build=$(realpath -e -- "$KERNEL_BUILD_DIR")
[ -d "$kernel_source" ] || ci_die "kernel source is not a directory"
[ -d "$kernel_git/objects" ] || ci_die "KERNEL_GIT_DIR is not a Git object database"
[ -d "$kernel_build" ] || ci_die "kernel build is not a directory"
[ -s "$kernel_build/.config" ] || ci_die "kernel build has no prepared .config"

git_cmd=(git --git-dir="$kernel_git" --work-tree="$kernel_source")
expected_config_sha=${EXPECTED_KERNEL_CONFIG_SHA256,,}

verify_kernel_source_state() {
  local phase=$1 actual status ignored config_sha

  actual=$("${git_cmd[@]}" rev-parse HEAD)
  [ "$actual" = "$EXPECTED_KERNEL_COMMIT" ] ||
    ci_die "kernel commit mismatch $phase: expected $EXPECTED_KERNEL_COMMIT, got $actual"
  status=$("${git_cmd[@]}" status --porcelain=v1 --untracked-files=all)
  [ -z "$status" ] || ci_die "kernel worktree must be clean $phase"
  ignored=$("${git_cmd[@]}" status --porcelain=v1 --ignored --untracked-files=all | awk '$1 == "!!"')
  [ -z "$ignored" ] || ci_die "kernel worktree contains ignored files $phase"
  config_sha=$(sha256sum "$kernel_build/.config" | awk '{print $1}')
  [ "$config_sha" = "$expected_config_sha" ] ||
    ci_die "kernel config SHA-256 mismatch $phase: expected $expected_config_sha, got $config_sha"
}

actual_commit=$("${git_cmd[@]}" rev-parse HEAD)

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$("${git_cmd[@]}" show -s --format=%ct "$actual_commit")}
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]{1,12}$ ]] || ci_die "invalid SOURCE_DATE_EPOCH"
export SOURCE_DATE_EPOCH
KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-$(LC_ALL=C date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')}
KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-tb321fu-ci}
KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-tb321fu-builder}
KBUILD_BUILD_VERSION=${KBUILD_BUILD_VERSION:-1}
[[ $KBUILD_BUILD_TIMESTAMP =~ ^[0-9A-Za-z][0-9A-Za-z,:+._\ -]{0,95}$ ]] || ci_die "invalid KBUILD_BUILD_TIMESTAMP"
[[ $KBUILD_BUILD_USER =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || ci_die "invalid KBUILD_BUILD_USER"
[[ $KBUILD_BUILD_HOST =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || ci_die "invalid KBUILD_BUILD_HOST"
[[ $KBUILD_BUILD_VERSION =~ ^[1-9][0-9]{0,8}$ ]] || ci_die "invalid KBUILD_BUILD_VERSION"
export KBUILD_BUILD_TIMESTAMP KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_VERSION
export KCONFIG_NOTIMESTAMP=1

verify_kernel_source_state "before release packaging"
if [ "$mode" = preflight ]; then
  printf 'KERNEL_BOOTSTRAP_PREFLIGHT=PASS commit=%s config=%s\n' \
    "$actual_commit" "$expected_config_sha"
  exit 0
fi

output_parent=$(dirname -- "$OUTPUT_DIR")
output_name=$(basename -- "$OUTPUT_DIR")
case "$output_name" in
  tb321fu-kernel-bootstrap*) ;;
  *) ci_die "OUTPUT_DIR basename must start with tb321fu-kernel-bootstrap" ;;
esac
mkdir -p "$output_parent"
output_parent=$(realpath -e -- "$output_parent")
output_path="$output_parent/$output_name"
if [ -e "$output_path" ]; then
  ci_safe_rmtree "$output_path" "$output_parent" tb321fu-kernel-bootstrap
fi

work=$(mktemp -d "$output_parent/.tb321fu-kernel-bootstrap.XXXXXX")
cleanup() {
  if [ -d "$work" ]; then
    ci_safe_rmtree "$work" "$output_parent" .tb321fu-kernel-bootstrap
  fi
}
trap cleanup EXIT

baseline_archive="$work/baseline-device-debs.tar.gz"
baseline_dir="$work/baseline"
mkdir -p "$baseline_dir"
ci_download "$BASE_DEVICE_DEB_ARCHIVE" "$baseline_archive" "$BASE_DEVICE_DEB_ARCHIVE_SHA256"
ci_extract_archive "$baseline_archive" "$baseline_dir"

mapfile -d '' baseline_modules < <(find "$baseline_dir" -maxdepth 1 -type f -name 'y700-daily-kernel-modules_*.deb' -print0)
mapfile -d '' baseline_rootfs < <(find "$baseline_dir" -maxdepth 1 -type f -name 'y700-daily-rootfs-overlay_*.deb' -print0)
mapfile -d '' baseline_compat < <(find "$baseline_dir" -maxdepth 1 -type f -name 'y700-compat1-extra-rootfs-overlay.tar.gz' -print0)
[ "${#baseline_modules[@]}" -eq 1 ] || ci_die "baseline archive must contain exactly one kernel modules DEB"
[ "${#baseline_rootfs[@]}" -eq 1 ] || ci_die "baseline archive must contain exactly one rootfs overlay DEB"
[ "${#baseline_compat[@]}" -eq 1 ] || ci_die "baseline archive must contain exactly one compat overlay"
baseline_count=$(find "$baseline_dir" -maxdepth 1 -type f | wc -l)
[ "$baseline_count" -eq 3 ] || ci_die "baseline archive must contain exactly the three expected regular files"
[ -z "$(find "$baseline_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] || ci_die "baseline archive contains a non-regular member"

rootfs_sha=$(sha256sum "${baseline_rootfs[0]}" | awk '{print $1}')
compat_sha=$(sha256sum "${baseline_compat[0]}" | awk '{print $1}')

approved_config="$work/approved-kernel.config"
install -m 0644 "$kernel_build/.config" "$approved_config"
env GIT_DIR="$kernel_git" GIT_WORK_TREE="$kernel_source" \
  make -C "$kernel_source" O="$kernel_build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" clean
install -m 0644 "$approved_config" "$kernel_build/.config"
env GIT_DIR="$kernel_git" GIT_WORK_TREE="$kernel_source" \
  make -C "$kernel_source" O="$kernel_build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
verify_kernel_source_state "after clean configuration restore"

kernel_release=$(env GIT_DIR="$kernel_git" GIT_WORK_TREE="$kernel_source" \
  make -s -C "$kernel_source" O="$kernel_build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)
[[ $kernel_release =~ ^[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}$ ]] || ci_die "unsafe kernel release: $kernel_release"
case "$kernel_release" in
  *-g"${actual_commit:0:12}"*) ;;
  *) ci_die "kernel release does not bind the expected commit: $kernel_release" ;;
esac

env GIT_DIR="$kernel_git" GIT_WORK_TREE="$kernel_source" \
  make -C "$kernel_source" O="$kernel_build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  -j"$KERNEL_BUILD_JOBS" Image modules "qcom/$DTB_NAME"
[ "$(cat "$kernel_build/include/config/kernel.release")" = "$kernel_release" ] || ci_die "built kernel.release does not match source commit"
grep -Fxq "#define UTS_RELEASE \"$kernel_release\"" "$kernel_build/include/generated/utsrelease.h" || ci_die "UTS_RELEASE does not match built kernel release"

image="$kernel_build/arch/arm64/boot/Image"
dtb="$kernel_build/arch/arm64/boot/dts/qcom/$DTB_NAME"
[ -s "$image" ] || ci_die "missing kernel Image"
[ -s "$dtb" ] || ci_die "missing $DTB_NAME"

modules_root="$work/modules-root"
env GIT_DIR="$kernel_git" GIT_WORK_TREE="$kernel_source" \
  make -C "$kernel_source" O="$kernel_build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  INSTALL_MOD_PATH="$modules_root" DEPMOD=/bin/true modules_install
verify_kernel_source_state "after kernel build and modules_install"
[ -d "$modules_root/lib/modules/$kernel_release" ] || ci_die "modules_install produced the wrong kernel release"
[ "$(find "$modules_root/lib/modules" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] || ci_die "modules_install produced multiple releases"
rm -f -- "$modules_root/lib/modules/$kernel_release/build" "$modules_root/lib/modules/$kernel_release/source"
depmod -b "$modules_root" "$kernel_release"

module_count=0
while IFS= read -r -d '' module; do
  vermagic=$(modinfo -F vermagic "$module")
  case "$vermagic" in
    "$kernel_release"|"$kernel_release "*) ;;
    *) ci_die "module vermagic mismatch: $module: $vermagic" ;;
  esac
  module_count=$((module_count + 1))
done < <(find "$modules_root/lib/modules/$kernel_release" -type f -name '*.ko*' -print0)
[ "$module_count" -gt 0 ] || ci_die "no installed kernel modules found"

package_root="$work/package-root"
mkdir -p "$package_root/DEBIAN" "$package_root/usr/lib"
rsync -aH --numeric-ids "$modules_root/lib/modules" "$package_root/usr/lib/"
cat > "$package_root/DEBIAN/control" <<EOF
Package: y700-daily-kernel-modules
Version: $KERNEL_PACKAGE_VERSION
Section: misc
Priority: optional
Architecture: arm64
Depends: kmod
Maintainer: TB321FU Linux build <noreply@localhost>
Description: Lenovo TB321FU kernel modules for $kernel_release.
EOF
cat > "$package_root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
current_release='$kernel_release'
if command -v depmod >/dev/null 2>&1; then
  depmod "\$current_release"
fi
exit 0
EOF
find "$package_root" -type d -exec chmod 0755 {} +
find "$package_root" -type f -exec chmod 0644 {} +
chmod 0755 "$package_root/DEBIAN/postinst"
[ -z "$(find "$package_root" -type d ! -perm 0755 -print -quit)" ] || ci_die "package contains a non-0755 directory"
[ -z "$(find "$package_root" -type f ! -path '*/DEBIAN/postinst' ! -perm 0644 -print -quit)" ] ||
  ci_die "package contains a regular file with an unexpected mode"
[ "$(stat -c '%a' "$package_root/DEBIAN/postinst")" = 755 ] || ci_die "postinst must be mode 0755"
find "$package_root" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"

stage="$work/stage"
artifacts="$work/kernel-artifacts"
device="$work/device-debs"
mkdir -p "$stage" "$artifacts" "$device"
modules_deb="$device/y700-daily-kernel-modules_${KERNEL_PACKAGE_VERSION}_arm64.deb"
dpkg-deb --root-owner-group -Zxz -b "$package_root" "$modules_deb" >/dev/null

cp -a "${baseline_rootfs[0]}" "$device/"
cp -a "${baseline_compat[0]}" "$device/"
[ "$(sha256sum "$device/$(basename -- "${baseline_rootfs[0]}")" | awk '{print $1}')" = "$rootfs_sha" ] || ci_die "rootfs baseline changed"
[ "$(sha256sum "$device/$(basename -- "${baseline_compat[0]}")" | awk '{print $1}')" = "$compat_sha" ] || ci_die "compat baseline changed"

cp -a "$image" "$artifacts/Image"
cp -a "$dtb" "$artifacts/$DTB_NAME"
cp -a "$kernel_build/.config" "$artifacts/kernel.config"
packager_sha=$(sha256sum "$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")" | awk '{print $1}')
common_sha=$(sha256sum "$SCRIPT_DIR/common.sh" | awk '{print $1}')
compiler_version=$("${CROSS_COMPILE}gcc" --version | sed -n '1p')
compiler_path=$(realpath -e -- "$(command -v "${CROSS_COMPILE}gcc")")
compiler_sha=$(sha256sum "$compiler_path" | awk '{print $1}')
make_version=$(make --version | sed -n '1p')
dpkg_deb_version=$(dpkg-deb --version | sed -n '1p')
config_sha=$(sha256sum "$kernel_build/.config" | awk '{print $1}')

bundle_identity="$work/KERNEL-BUNDLE.identity.tsv"
bundle_file="$work/KERNEL-BUNDLE.tsv"
{
  printf 'schema\ttb321fu.kernel-bundle/v1\n'
  printf 'kernel-source-commit\t%s\n' "$actual_commit"
  printf 'kernel-release\t%s\n' "$kernel_release"
  printf 'kernel-config-sha256\t%s\n' "$config_sha"
  printf 'source-date-epoch\t%s\n' "$SOURCE_DATE_EPOCH"
  printf 'kbuild-build-timestamp\t%s\n' "$KBUILD_BUILD_TIMESTAMP"
  printf 'kbuild-build-user\t%s\n' "$KBUILD_BUILD_USER"
  printf 'kbuild-build-host\t%s\n' "$KBUILD_BUILD_HOST"
  printf 'kbuild-build-version\t%s\n' "$KBUILD_BUILD_VERSION"
} > "$bundle_identity"
kernel_bundle_id=$(sha256sum "$bundle_identity" | awk '{print $1}')
cp "$bundle_identity" "$bundle_file"
printf 'kernel-bundle-id\t%s\n' "$kernel_bundle_id" >> "$bundle_file"
install -m 0644 "$bundle_file" "$artifacts/KERNEL-BUNDLE.tsv"
install -m 0644 "$bundle_file" "$device/KERNEL-BUNDLE.tsv"

(
  cd "$modules_root"
  find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
) > "$artifacts/MODULES.sha256"
{
  printf 'schema\ttb321fu.kernel-bootstrap/v2\n'
  printf 'kernel_bundle_id\t%s\n' "$kernel_bundle_id"
  printf 'kernel_commit\t%s\n' "$actual_commit"
  printf 'kernel_release\t%s\n' "$kernel_release"
  printf 'source_date_epoch\t%s\n' "$SOURCE_DATE_EPOCH"
  printf 'config_sha256\t%s\n' "$config_sha"
  printf 'image_sha256\t%s\n' "$(sha256sum "$image" | awk '{print $1}')"
  printf 'dtb_sha256\t%s\n' "$(sha256sum "$dtb" | awk '{print $1}')"
  printf 'modules_deb_sha256\t%s\n' "$(sha256sum "$modules_deb" | awk '{print $1}')"
  printf 'baseline_archive_sha256\t%s\n' "${BASE_DEVICE_DEB_ARCHIVE_SHA256,,}"
  printf 'baseline_rootfs_sha256\t%s\n' "$rootfs_sha"
  printf 'baseline_compat_sha256\t%s\n' "$compat_sha"
  printf 'packager_sha256\t%s\n' "$packager_sha"
  printf 'common_sh_sha256\t%s\n' "$common_sha"
  printf 'compiler_sha256\t%s\n' "$compiler_sha"
  printf 'compiler\t%s\n' "$compiler_version"
  printf 'kbuild_build_timestamp\t%s\n' "$KBUILD_BUILD_TIMESTAMP"
  printf 'kbuild_build_user\t%s\n' "$KBUILD_BUILD_USER"
  printf 'kbuild_build_host\t%s\n' "$KBUILD_BUILD_HOST"
  printf 'kbuild_build_version\t%s\n' "$KBUILD_BUILD_VERSION"
  printf 'make\t%s\n' "$make_version"
  printf 'dpkg_deb\t%s\n' "$dpkg_deb_version"
  printf 'module_count\t%s\n' "$module_count"
} > "$artifacts/SOURCE-LOCK.tsv"
install -m 0644 "$artifacts/SOURCE-LOCK.tsv" "$device/SOURCE-LOCK.tsv"

find "$artifacts" "$device" -type f -exec chmod 0644 {} +
find "$artifacts" "$device" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
kernel_archive="$stage/tb321fu-kernel-artifacts-${kernel_release}.tar.gz"
device_archive="$stage/tb321fu-device-debs-${kernel_release}.tar.gz"
tar -C "$artifacts" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -czf "$kernel_archive" .
tar -C "$device" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -czf "$device_archive" .
cp -a "$artifacts/SOURCE-LOCK.tsv" "$stage/KERNEL-SOURCE-LOCK.tsv"
cp -a "$bundle_file" "$stage/KERNEL-BUNDLE.tsv"
(
  cd "$stage"
  sha256sum -- "$(basename -- "$kernel_archive")" "$(basename -- "$device_archive")" \
    KERNEL-SOURCE-LOCK.tsv KERNEL-BUNDLE.tsv > SHA256SUMS.txt
)

mv "$stage" "$output_path"
trap - EXIT
cleanup
printf 'KERNEL_BOOTSTRAP=PASS release=%s commit=%s bundle=%s modules=%d output=%s\n' \
  "$kernel_release" "$actual_commit" "$kernel_bundle_id" "$module_count" "$output_path"
