# Ubuntu Y700 Build CI

GitHub Actions CI for building Lenovo Y700/TB321FU ARM64 rootfs and GRUB/FAT boot images.

The repository is intentionally structured as a standard source-driven build pipeline. Device payloads are inputs, not hardcoded policy inside the rootfs builder.

## Workflow

Primary workflow:

- `.github/workflows/build-rootfs-and-grub.yml`

The workflow exposes common dispatch inputs directly in the GitHub Actions UI, including output prefix, Ubuntu mirror, image sizes, rootfs labels, default user settings, sudo mode, and optional SDDM autologin.

It also keeps three optional advanced override inputs:

- `release_tag`: optional release tag to upload artifacts to.
- `output_prefix`: output filename prefix.
- `rootfs_config`: optional rootfs overrides as `KEY=value` lines.
- `boot_config`: optional GRUB/FAT boot overrides as `KEY=value` lines.
- `source_config`: optional input artifact URL overrides as `KEY=value` lines.

Leave the advanced override inputs empty for the built-in verified defaults. If an advanced override input is filled, its `KEY=value` lines are appended after the built-in defaults and before the common UI fields are applied.

## Rootfs Config

Optional override example:

```text
DISTRO=noble
ARCH=arm64
MIRROR=http://ports.ubuntu.com/ubuntu-ports
ROOTFS_IMAGE_SIZE=14G
ROOTFS_UUID=
ROOTFS_LABEL=Ubuntu
ROOTFS_PARTLABEL=userdata
HOSTNAME_NAME=y700
DEFAULT_USER_NAME=y700
DEFAULT_USER_PASSWORD=1234
ROOT_PASSWORD_MODE=locked
ROOT_PASSWORD=
USER_SUDO_MODE=password
SDDM_AUTOLOGIN=0
SDDM_AUTOLOGIN_SESSION=plasma
TZ_REGION=Asia/Shanghai
LANG_NAME=zh_CN.UTF-8
PACKAGE_LIST=
DESKTOP_ENV=plasma-desktop
INSTALL_FIREFOX=1
INSTALL_FCITX5_CHINESE=1
DISABLE_SNAPD=1
OVERLAY_ARCHIVE=
DEB_ARCHIVE=
SENSOR_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-20260626.1/tb321fu-sensor-debs_20260626.1_arm64.tar.gz
HAPTICS_DEB_ARCHIVE=https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20260627.1/tb321fu-haptics-debs_20260627.1_arm64.tar.gz
CLEAN_APT_CACHE=1
COMPRESS=7z
CHUNK_SIZE=
KEEP_RAW_IMAGE=0
```

## Boot Config

Optional override example:

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
BOOT_CHUNK_SIZE=
KEEP_BOOT_IMAGE=0
```

## Source Config

Optional override example:

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
- `scripts/ci/build-tb321fu-camera-stack-deb.sh`: builds the live-verified TB321FU camera stack deb from `source/tb321fu-camera-rootfs-overlay` or an explicit camera overlay archive.
- `scripts/ci/pack-disk-image.sh`: optional GPT disk image packer for a FAT boot image plus ext4 rootfs image.
- `scripts/ci/apply-workflow-config.sh`: validates dispatch config blocks and exports allowed keys into the workflow environment.

## Policy Boundary

The rootfs builder does not hardcode one historical verified Y700 state. Use `OVERLAY_ARCHIVE`, `DEB_ARCHIVE`, and the source artifact inputs to select the device payload for each build. Separate verification profiles can be added as independent workflow steps without making the rootfs construction script depend on one fixed baseline.

## Release Assets

When `release_tag` is set, the release intentionally uploads only the user-facing boot/rootfs artifacts:

- `boot.img.7z`
- `grub.img.7z`
- `rootfs.img.7z` or split parts such as `rootfs.img.7z.000` and `rootfs.img.7z.001`
- `SHA256SUMS.txt`

The release notes include the rootfs, boot and source config used for that build. Password-like values are redacted from the notes. Release uploads require single-file archives; leave `CHUNK_SIZE` and `BOOT_CHUNK_SIZE` empty when creating a release. The UEFI `boot.img.7z` asset is committed under `source/boot-image/` so release builds do not depend on a previous release to supply it.

New releases created by the workflow are normal GitHub Releases, not prereleases.

## Chinese Input

The default rootfs includes Fcitx 5 Chinese input support:

- `fcitx5`, `fcitx5-chinese-addons`, `fcitx5-pinyin`, Qt/GTK/KDE frontends, and Noto CJK fonts.
- System and user-session input method environment variables are preconfigured for Fcitx.
- `/etc/skel` and the default user home are seeded with Fcitx autostart and a default profile containing US keyboard plus Pinyin.
- KWin is preconfigured to keep Plasma Keyboard enabled as the Wayland virtual keyboard, so the touchscreen keyboard and Fcitx can coexist.

Set `INSTALL_FCITX5_CHINESE=0` in `rootfs_config` to opt out.

## External Device Debs

The rootfs workflow can consume prebuilt device deb archives instead of rebuilding every device package inline:

- `SENSOR_DEB_ARCHIVE`: tar/zip archive containing the verified `qcom-sns-*` and `tb321fu-sensors` debs. Current default: `https://github.com/GUF296/tb321fu-sensor-debs/releases/download/tb321fu-sensor-debs-20260626.1/tb321fu-sensor-debs_20260626.1_arm64.tar.gz`.
- `HAPTICS_DEB_ARCHIVE`: tar/zip archive containing the verified `tb321fu-haptics` deb. Current default: `https://github.com/GUF296/tb321fu-haptics-debs/releases/download/tb321fu-haptics-debs-20260627.1/tb321fu-haptics-debs_20260627.1_arm64.tar.gz`.

When `BUILD_Y700_SENSOR_DEBS=1` or `BUILD_TB321FU_HAPTICS_DEB=1`, the workflow now requires either a prebuilt deb archive/directory or all source inputs needed to build that component. It intentionally fails on missing inputs rather than producing a successful rootfs with missing sensor or haptics support.

Recommended split:

- `tb321fu-sensor-debs`: build from the upstream-derived `libssc`, `iio-sensor-proxy`, and `hexagonrpc` sources plus TB321FU patches/registry data, then release a sensor deb archive.
- `tb321fu-haptics-debs`: build the AW86937 external module from the matching Linux source/build artifacts plus TB321FU haptics glue, then release a haptics deb archive.

The rootfs workflow references those release assets through `SENSOR_DEB_ARCHIVE` and `HAPTICS_DEB_ARCHIVE` by default.
