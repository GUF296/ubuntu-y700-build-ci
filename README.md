# Ubuntu Y700 Build CI

GitHub Actions CI for building Lenovo Y700/TB321FU ARM64 rootfs and GRUB/FAT boot images.

The repository is intentionally structured as a standard source-driven build pipeline. Device payloads are inputs, not hardcoded policy inside the rootfs builder.

## Workflow

Primary workflow:

- `.github/workflows/build-rootfs-and-grub.yml`

It has only four dispatch inputs:

- `release_tag`: optional release tag to upload artifacts to.
- `output_prefix`: output filename prefix.
- `rootfs_config`: rootfs settings as `KEY=value` lines.
- `boot_config`: GRUB/FAT boot settings as `KEY=value` lines.
- `source_config`: input artifact URLs as `KEY=value` lines.

This avoids GitHub's workflow input count limit while still allowing all build-time parameters to be changed from the Actions UI or `gh workflow run`.

## Rootfs Config

Example:

```text
DISTRO=noble
ARCH=arm64
MIRROR=http://ports.ubuntu.com/ubuntu-ports
ROOTFS_IMAGE_SIZE=14G
ROOTFS_UUID=
ROOTFS_LABEL=Y700ROOTFS
ROOTFS_PARTLABEL=userdata
HOSTNAME_NAME=y700
DEFAULT_USER_NAME=y700
DEFAULT_USER_PASSWORD=1234
ROOT_PASSWORD_MODE=locked
ROOT_PASSWORD=
USER_SUDO_MODE=password
TZ_REGION=Asia/Shanghai
LANG_NAME=zh_CN.UTF-8
PACKAGE_LIST=
DESKTOP_ENV=plasma-desktop
OVERLAY_ARCHIVE=
DEB_ARCHIVE=
CLEAN_APT_CACHE=1
COMPRESS=7z
CHUNK_SIZE=1500m
KEEP_RAW_IMAGE=0
```

## Boot Config

Example:

```text
BOOT_IMAGE_SIZE=14G
BOOT_FAT_BITS=32
BOOT_FAT_LABEL=Y700GRUB
BOOT_SECTOR_SIZE=512
BOOT_CLUSTER_SECTORS=
ROOT_SELECTOR=partlabel
ROOT_PARTLABEL=userdata
ROOT_UUID=
ROOTARGS=
ROOTARGS_EXTRA=
STABLEARGS=drm_client_lib.active=none
BOOT_COMPRESS=7z
BOOT_CHUNK_SIZE=1500m
KEEP_BOOT_IMAGE=0
```

## Source Config

Example:

```text
KERNEL_ARTIFACT_ARCHIVE=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/y700-kernel-artifacts-7.1.1-g5df8e852ea72.tar.gz
BOOTAA64_EFI_URL=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/BOOTAA64.EFI
QCOMRAMP_EFI_URL=https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/bootstrap-y700-20260625/QCOMRAMP-CONFIGFILE.EFI
QCOMRAMP_CFG_NAME=qcomramp.cfg
GRUB_BUILD_ARCHIVE=
DTB_NAME=sm8650-lenovo-tb321fu.dtb
```

## Scripts

- `scripts/ci/build-rootfs-image.sh`: builds an ext4 rootfs image from debootstrap plus declared overlays/debs.
- `scripts/ci/build-grub-image.sh`: builds a FAT boot image containing BOOTAA64.EFI, a prebuilt or generated QCOMRAMP.EFI, Image, DTB and GRUB config.
- `scripts/ci/pack-disk-image.sh`: optional GPT disk image packer for a FAT boot image plus ext4 rootfs image.
- `scripts/ci/apply-workflow-config.sh`: validates dispatch config blocks and exports allowed keys into the workflow environment.

## Policy Boundary

The rootfs builder does not hardcode one historical verified Y700 state. Use `OVERLAY_ARCHIVE`, `DEB_ARCHIVE`, and the source artifact inputs to select the device payload for each build. Separate verification profiles can be added as independent workflow steps without making the rootfs construction script depend on one fixed baseline.
