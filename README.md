# Ubuntu Y700 Build CI

GitHub Actions CI for building Lenovo Y700/TB321FU ARM64 rootfs and GRUB/FAT boot images.

The repository is intentionally structured as a standard source-driven build pipeline. Device payloads are inputs, not hardcoded policy inside the rootfs builder.

Scalar workflow controls are validated before they are serialized into the
configuration blocks: `rootfs_image_size` accepts a positive binary size from
`1G` through `64T` with an optional `K`, `M`, `G`, or `T` suffix; `rootfs_label`
is a 1-16 character ext4 label; and `hostname_name` is a single 1-63 character
RFC 1123 hostname label. These controls must be single-line values. Rootfs
locale records must name at least one locale and `LANG_NAME` must match a
listed locale (the built-in `C`, `POSIX`, and `C.UTF-8` locales are accepted
without a generated record).

Advanced configuration is resource-bounded before it reaches image tools:
each config file is at most 256 KiB/1024 lines; package lists are at most
64 KiB/1024 tokens; locale and APT source lists contain at most 128 records;
and resolv.conf content and authorized keys have bounded bytes, lines and line
lengths. `CHUNK_SIZE` and `BOOT_CHUNK_SIZE` are either empty or an integer 7-Zip
volume size from 1 MiB through 64 GiB (for example, `100M`).

## Workflow

Primary workflow:

- `.github/workflows/build-rootfs-and-grub.yml`

The workflow exposes output/release controls, Ubuntu mirror, image size, rootfs label, hostname and three advanced config blocks in the GitHub Actions UI. Default-user, sudo and SDDM autologin settings are `rootfs_config` keys rather than separate UI fields.

The release/output controls and advanced override inputs are:

- `release_tag`: optional release tag to upload artifacts to.
- `prerelease`: must be enabled for remediation releases.
- `output_prefix`: output filename prefix.
- `rootfs_config`: optional rootfs overrides as `KEY=value` lines.
- `boot_config`: optional GRUB/FAT boot overrides as `KEY=value` lines.
- `source_config`: optional kernel/SDK input-profile overrides (URL, SHA-256 and producer identity) as `KEY=value` lines.

The built-in rootfs/device archive values document the last tested release baseline. They predate the remediation bundle contract and are intentionally rejected by the new verifier unless replaced by a complete matching handoff. The built-in kernel source profile pins the canonical `20260729.4` bootstrap artifact, SDK and producer identity. A remediation build must use the complete matching rootfs and haptics URL/SHA override set documented below. If an advanced override input is filled, its `KEY=value` lines are appended after the built-in defaults and before the common UI fields are applied.

## Rootfs Config

Optional override example:

```text
DISTRO=noble
ARCH=arm64
MIRROR=https://ports.ubuntu.com/ubuntu-ports
ROOTFS_IMAGE_SIZE=14G
ROOTFS_UUID=
ROOTFS_LABEL=Ubuntu
ROOTFS_PARTLABEL=userdata
HOSTNAME_NAME=y700
DEFAULT_USER_NAME=y700
ROOT_PASSWORD_MODE=locked
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
DEB_ARCHIVE_SHA256=
SENSOR_DEB_ARCHIVE=
SENSOR_DEB_ARCHIVE_SHA256=
SENSOR_PRODUCER_COMMIT=
HAPTICS_DEB_ARCHIVE=
HAPTICS_DEB_ARCHIVE_SHA256=
HAPTICS_PRODUCER_COMMIT=
CLEAN_APT_CACHE=1
COMPRESS=7z
CHUNK_SIZE=
KEEP_RAW_IMAGE=0
```

Password hashes are repository secrets (`DEFAULT_USER_PASSWORD_HASH` and `ROOT_PASSWORD_HASH`), not config-file keys. The config parser rejects and does not serialize them.

## Boot Config

Optional override example:

```text
BOOT_IMAGE_SIZE=14G
BOOT_FAT_BITS=32
BOOT_FAT_LABEL=Y700GRUB
BOOT_FAT_VOLUME_ID=00000000
BOOT_SECTOR_SIZE=512
BOOT_CLUSTER_SECTORS=
GRUB_TIMEOUT=3
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
KERNEL_ARTIFACT_ARCHIVE=
KERNEL_ARTIFACT_ARCHIVE_SHA256=
KERNEL_BUILD_ARCHIVE=
KERNEL_BUILD_ARCHIVE_SHA256=
KERNEL_BOOTSTRAP_PRODUCER_COMMIT=
KERNEL_BOOTSTRAP_PRODUCER_TREE=
KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256=
HAPTICS_MODULE_SHA256=
HAPTICS_HELPER_BINARY_SHA256=
BOOTAA64_EFI_URL=
QCOMRAMP_EFI_URL=
QCOMRAMP_CFG_NAME=qcomramp.cfg
GRUB_BUILD_ARCHIVE=
DTB_NAME=sm8650-lenovo-tb321fu.dtb
```

## Scripts

- `scripts/ci/build-rootfs-image.sh`: builds an ext4 rootfs image from debootstrap plus declared overlays/debs.
- `scripts/ci/build-grub-image.sh`: builds a FAT boot image containing BOOTAA64.EFI, a prebuilt or generated QCOMRAMP.EFI, Image, DTB and GRUB config.
- `scripts/ci/build-tb321fu-camera-stack-deb.sh`: rebuilds the complete locked-source libcamera/IPA/proxy/cam/GStreamer runtime twice, then rebuilds SPA against that exact header/library pair. Only eight approved compiled/signature files replace the historical overlay; tuning, services, wrappers and links remain unchanged. Reproducible build and signature checks are not hardware acceptance. Untagged development builds may use an explicit baseline overlay archive or directory.
- `scripts/ci/pack-disk-image.sh`: optional GPT disk image packer for a FAT boot image plus ext4 rootfs image.
- `scripts/ci/apply-workflow-config.sh`: validates dispatch config blocks and exports allowed keys into the workflow environment.
- `scripts/ci/package-kernel-bootstrap.sh`: cleanly rebuilds and packages one commit/config-bound Image, DTB and modules pair while preserving the tested rootfs/compat payload bytes.
- `scripts/ci/verify-kernel-bundle.sh`: verifies and stages the kernel/device/sensor/haptics handoff before rootfs or GRUB construction.
- `scripts/ci/verify-kernel-bundle.py`: canonical parser for the ordered `KERNEL-BUNDLE.tsv` identity contract.

## Policy Boundary

The rootfs builder does not hardcode one historical verified Y700 state. Use `OVERLAY_ARCHIVE`, `DEB_ARCHIVE`, and the source artifact inputs to select the device payload for each build. The workflow verifies the complete kernel/device/sensor/haptics handoff first and replaces those four inputs with SHA-verified local staged copies, so downstream rootfs and GRUB steps cannot independently select mismatched archives.

## Release Assets

When `release_tag` is set, the build job stages the user-facing boot/rootfs artifacts plus the small audit metadata that binds their kernel inputs. The write-scoped job creates and verifies a prerelease draft; it does not automatically make that draft public.

- `boot.img.7z`
- `grub.img.7z`
- `rootfs.img.7z` or split parts such as `rootfs.img.7z.000` and `rootfs.img.7z.001`
- `SHA256SUMS.txt`
- `KERNEL-BUNDLE.tsv`
- `VERIFIED-BUNDLE.tsv`
- `VERIFIED-INPUTS.tsv`
- `KERNEL-SOURCE-LOCK.tsv`, `SENSOR-SOURCE-LOCK.tsv`, `HAPTICS-SOURCE-LOCK.tsv`, and `HAPTICS-BUILD-TOOLS.tsv`
- `MODULES.sha256`, `KERNEL-SDK-MANIFEST.tsv`, `KERNEL-TOOLCHAIN.tsv`, and `KBUILD-FLAGS.tsv`
- `ROOTFS-PACKAGES.tsv`, the sorted installed package/version/architecture inventory
- `APT-PROVENANCE.tsv`, `APT-BOOTSTRAP.tsv`, and `APT-SOURCES.txt`, sanitized APT transaction, debootstrap bootstrap, and source evidence
- `tb321fu-camera-stack_<approved-version>_arm64.deb`, `SHA256SUMS-tb321fu-camera-stack-debs.txt`, and the sanitized Camera producer/build report; the approved version comes only from `scripts/ci/CAMERA-PACKAGE-VERSION`

The release notes include the rootfs, boot and source config used for that build. Password and password-hash assignments are rejected during config parsing and are never serialized into the notes. Release uploads require single-file archives; leave `CHUNK_SIZE` and `BOOT_CHUNK_SIZE` empty when creating a release. The UEFI `boot.img.7z` asset is committed under `source/boot-image/` so release builds do not depend on a previous release to supply it.

When `release_tag` is non-empty on the remediation branch, `prerelease=true` is mandatory. Kernel/device/sensor/haptics inputs and any optional external rootfs/GRUB inputs must be approved HTTPS+SHA-256 identities. Camera production is locked to the committed closed source and the version in `scripts/ci/CAMERA-PACKAGE-VERSION`; a directory/archive override or another package version is rejected. Producer and consumer defaults read that same policy. Development overrides remain available only to untagged artifact builds. The tested 2026-06-29 release and its assets are never replaced.

## Chinese Input

The default rootfs includes Fcitx 5 Chinese input support:

- `fcitx5`, `fcitx5-chinese-addons`, `fcitx5-pinyin`, Qt/GTK/KDE frontends, and Noto CJK fonts.
- System and user-session input method environment variables are preconfigured for Fcitx.
- `/etc/skel` and the default user home are seeded with Fcitx autostart and a default profile containing US keyboard plus Pinyin.
- KWin is preconfigured to keep Plasma Keyboard enabled as the Wayland virtual keyboard, so the touchscreen keyboard and Fcitx can coexist.

Set `INSTALL_FCITX5_CHINESE=0` in `rootfs_config` to opt out.

## External Device Debs

The remediation workflow consumes prebuilt device deb archives that have already passed their producer gates:

- `SENSOR_DEB_ARCHIVE` plus `SENSOR_DEB_ARCHIVE_SHA256`: dispatcher-approved archive containing exactly `qcom-sns-libssc`, `qcom-sns-hexagonrpc`, `qcom-sns-iio-sensor-proxy`, and `tb321fu-sensors` plus their source/checksum locks. The external archive SHA is the compiled-asset trust root.
- `SENSOR_PRODUCER_COMMIT`: exact clean sensor-producer commit recorded in that source lock; remediation dispatches must set it explicitly so the historical default archive cannot be accepted accidentally. Matching this label proves lock consistency, not source derivation of the compiled DEBs; publish the commit and retain the producer run separately for rebuild comparison.
- `HAPTICS_DEB_ARCHIVE` plus `HAPTICS_DEB_ARCHIVE_SHA256`: exact six-root archive containing the verified `tb321fu-haptics` package, strict v4 `HAPTICS-SOURCE-LOCK.tsv`, ordered `HAPTICS-BUILD-TOOLS.tsv`, single-ref `HAPTICS-PRODUCER.bundle`, fixed nine-entry checksum manifest, and `HAPTICS-SOURCE-SNAPSHOT/` bound to the selected kernel bundle and its exact toolchain manifest.
- `HAPTICS_PRODUCER_COMMIT`: exact clean haptics-producer commit recorded in that source lock.
- `HAPTICS_MODULE_SHA256` and `HAPTICS_HELPER_BINARY_SHA256`: independently approved compiled-payload digests from the authenticated haptics producer run.

Sensor and haptics packages are intentionally not rebuilt inline by this consumer workflow. The legacy inline builders produce a different package contract and are not release inputs. Build each component in its owning producer repository, publish the exact producer commit and strict archive, then pass the archive URL/SHA and required external digest pins here. Deprecated inline-producer config keys are rejected instead of being silently ignored.

Recommended split:

- `tb321fu-sensor-debs`: build from the upstream-derived `libssc`, `iio-sensor-proxy`, and `hexagonrpc` sources plus TB321FU patches/registry data, then release a sensor deb archive.
- `tb321fu-haptics-debs`: build the AW86937 external module from the matching Linux source/build artifacts plus TB321FU haptics glue, then release a haptics deb archive.

The historical defaults remain visible for baseline provenance only. They do not contain the complete remediation identity and are not accepted for a new remediation build.

## Remediation Bootstrap Handoff

The release is intentionally a two-stage handoff. First commit the final kernel changes, approve the post-`olddefconfig` configuration digest, set `EXPECTED_KERNEL_RELEASE` to the exact `kernelrelease` derived from the authoritative Git refs, set `KERNEL_PACKAGE_VERSION` to that same value, and directly execute `package-kernel-bootstrap.sh` from the clean commit-bound source/build. The producer checks exact release equality before the full Image/modules/DTB build, so ref or shallow-state drift cannot silently rename the module ABI. It emits a kernel archive, replacement device-DEB archive, and one compressed full kernel SDK archive, with byte-identical `KERNEL-BUNDLE.tsv` and `SOURCE-LOCK.tsv` files. Its input-keyed build path, target debug-prefix maps, and host C/C++ file-prefix maps make repeated production stable in the same authoritative WSL source/output-parent workspace. `KERNEL-TOOLCHAIN.tsv` binds separate host and cross compiler/binutils identities, the absolute `m4` dependency used by Flex/Bison, and the canonical Bison data-directory tree digest; all are rechecked around each Kbuild invocation. The full SDK still contains Kbuild text metadata tied to the checkout path, so cross-checkout or cross-machine byte identity is not claimed. The SDK archive is a producer handoff for the haptics build; it does not duplicate an unpacked SDK tree and is not an end-user rootfs release asset.

Build haptics only from that matching SDK archive and exact `KERNEL-BUNDLE.tsv`, not from a mutable local kernel directory. Build sensors from the clean sensor producer, publish that exact producer commit, and record the authenticated producer run used to approve the sensor archive digest. Publish only these bounded bootstrap archives as prerelease inputs, then dispatch this workflow from the exact remediation branch with `prerelease=true`.

Once the four-input verifier succeeds, the staged sensor archive and verified haptics archive or directory take exclusive precedence. The device archive may not carry reserved sensor or haptics package names, and the rootfs builder rejects duplicate package identities, colliding DEB basenames, or an archive plus a same-component DEB directory instead of allowing one input bucket to replace another.

Replace every placeholder below with one immutable HTTPS release URL and its lowercase SHA-256. Put these eight lines in `rootfs_config`:

```text
DEB_ARCHIVE=<device-deb-archive-url>
DEB_ARCHIVE_SHA256=<64-hex-sha256>
SENSOR_DEB_ARCHIVE=<sensor-deb-archive-url>
SENSOR_DEB_ARCHIVE_SHA256=<64-hex-sha256>
SENSOR_PRODUCER_COMMIT=<40-hex-sensor-producer-commit>
HAPTICS_DEB_ARCHIVE=<haptics-deb-archive-url>
HAPTICS_DEB_ARCHIVE_SHA256=<64-hex-sha256>
HAPTICS_PRODUCER_COMMIT=<40-hex-haptics-producer-commit>
```

Put these nine lines in `source_config`:

```text
KERNEL_ARTIFACT_ARCHIVE=<kernel-artifact-archive-url>
KERNEL_ARTIFACT_ARCHIVE_SHA256=<64-hex-sha256>
KERNEL_BUILD_ARCHIVE=<kernel-sdk-archive-url>
KERNEL_BUILD_ARCHIVE_SHA256=<64-hex-sha256>
KERNEL_BOOTSTRAP_PRODUCER_COMMIT=<40-hex-approved-producer-commit>
KERNEL_BOOTSTRAP_PRODUCER_TREE=<40-hex-approved-producer-tree>
KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256=<64-hex-approved-producer-tree-sha256>
HAPTICS_MODULE_SHA256=<64-lowercase-hex-sha256>
HAPTICS_HELPER_BINARY_SHA256=<64-lowercase-hex-sha256>
```

Leave `boot_config` empty. This preserves the tested template, EFI payload, `PARTLABEL=userdata`, and `drm_client_lib.active=none` handoff. Tagged releases accept only the producer commit/tree/tree digest committed in the release profile; changing those values requires a reviewed source-profile update rather than a dispatch-only trust change. Before any rootfs/GRUB work, the verifier recomputes the bundle ID, requires identical kernel/device metadata, verifies the complete SDK archive against the bound `KERNEL-SDK-MANIFEST.tsv`, verifies Image/DTB/config/modules, checks every kernel and haptics module vermagic, and requires the exact clean haptics producer commit. It rejects any missing, extra, duplicate, or reordered haptics v4 source-lock field; verifies the source lock's toolchain-manifest digest against the selected kernel bundle; verifies the fixed isolated build-environment policy; recomputes the digest over all 69 exact ordered build-tool records; recomputes all five fixed-path source snapshot hashes; and checks the exact firmware, module, and helper paths, modes, and final binary hashes inside the DEB. The module/helper binary digests are trusted dispatcher inputs copied independently from an authenticated producer run (or compared across two producer builds); they prevent archive-internal lock rewriting but are not a claim of bit-identical source-derived reproduction. The sensor verifier separately enforces the exact package set, control relationships, audited maintainer-script and privileged runtime-policy digests, AArch64 ELF identity, and all 541 device-data checksums. Its external archive SHA is likewise a dispatcher-approved compiled-asset trust root; the matching sensor producer commit is a recoverability/provenance label and does not by itself prove a bit-identical source rebuild. `VERIFIED-INPUTS.tsv` records one authoritative value for each URL/SHA/commit input even though the raw advanced config notes retain historical defaults followed by overrides.

Passing these gates proves build and package consistency, not tablet behavior. Camera, audio, sensor SSR/resume, haptics cancellation/suspend, display, touch and boot still require the prerelease hardware checklist on TB321FU.
