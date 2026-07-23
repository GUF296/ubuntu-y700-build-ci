#!/usr/bin/env python3
"""Hostile fixtures for the canonical TB321FU kernel bundle parser."""

from __future__ import annotations

import hashlib
import pathlib
import subprocess
import sys
import tempfile


SCRIPT = pathlib.Path(__file__).with_name("verify-kernel-bundle.py")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tsv(fields: list[tuple[str, str]]) -> bytes:
    return "".join(f"{key}\t{value}\n" for key, value in fields).encode("ascii")


def make_flags(source_epoch: str, cross_compile: str = "aarch64-linux-gnu-") -> bytes:
    return tsv(
        [
            ("schema", "tb321fu.kbuild-flags/v1"),
            ("arch", "arm64"),
            ("cross-compile", cross_compile),
            ("kconfig-notimestamp", "1"),
            ("kcflags", "unset"),
            ("kaflags", "unset"),
            ("kcppflags", "unset"),
            ("krustflags", "unset"),
            ("kbuild-cflags", "unset"),
            ("kbuild-aflags", "unset"),
            ("kbuild-cppflags", "unset"),
            ("kbuild-rustflags", "unset"),
            ("cflags", "unset"),
            ("cxxflags", "unset"),
            ("cppflags", "unset"),
            ("asflags", "unset"),
            ("ldflags", "unset"),
            ("cflags-kernel", "unset"),
            ("cflags-module", "unset"),
            ("aflags-kernel", "unset"),
            ("aflags-module", "unset"),
            ("ldflags-vmlinux", "unset"),
            ("ldflags-module", "unset"),
            ("hostcflags", "unset"),
            ("hostcxxflags", "unset"),
            ("hostldflags", "unset"),
            ("usercflags", "unset"),
            ("userldflags", "unset"),
            ("makeflags", "unset"),
            ("makeoverrides", "unset"),
            ("source-date-epoch", source_epoch),
            ("kbuild-build-timestamp", "2026-07-15 00:00:00 UTC"),
            ("kbuild-build-user", "tb321fu-ci"),
            ("kbuild-build-host", "tb321fu-builder"),
            ("kbuild-build-version", "1"),
        ]
    )


def make_toolchain(cross_compile: str = "aarch64-linux-gnu-") -> bytes:
    fields = [
        ("schema", "tb321fu.kernel-toolchain/v1"),
        ("cross-compile", cross_compile),
    ]
    for tool, digest in (
        ("gcc", "3" * 64),
        ("as", "4" * 64),
        ("ld", "5" * 64),
        ("ar", "6" * 64),
        ("nm", "7" * 64),
        ("objcopy", "8" * 64),
        ("strip", "9" * 64),
        ("rustc", "a" * 64),
        ("make", "b" * 64),
        ("dpkg-deb", "c" * 64),
    ):
        fields.extend(
            [(f"{tool}-sha256", digest), (f"{tool}-version", f"fixture {tool} 1.0")]
        )
    return tsv(fields)


def make_sdk_manifest(config_sha: str) -> bytes:
    return tsv(
        [
            ("schema", "tb321fu.kernel-sdk-manifest/v1"),
            ("file", f"{config_sha}\t644\t./.config"),
            ("file", f"{'d' * 64}\t644\t./Module.symvers"),
            ("file", f"{'e' * 64}\t644\t./include/config/kernel.release"),
            ("file", f"{'f' * 64}\t644\t./include/generated/autoconf.h"),
            ("file", f"{'0' * 64}\t644\t./include/generated/utsrelease.h"),
        ]
    )


def make_bundle(**overrides: str) -> tuple[bytes, bytes, bytes, bytes]:
    source_epoch = overrides.get("source-date-epoch", "1784073600")
    config_sha = overrides.get("kernel-config-sha256", "2" * 64)
    cross_compile = overrides.get("_cross_compile", "aarch64-linux-gnu-")
    flags = make_flags(source_epoch, cross_compile)
    toolchain = make_toolchain(cross_compile)
    sdk_manifest = make_sdk_manifest(config_sha)
    fields = [
        ("schema", "tb321fu.kernel-bundle/v2"),
        ("kernel-source-commit", "1" * 40),
        ("kernel-release", "7.1.1-g111111111111"),
        ("kernel-config-sha256", config_sha),
        ("kernel-image-sha256", "3" * 64),
        ("kernel-dtb-name", "sm8650-lenovo-tb321fu.dtb"),
        ("kernel-dtb-sha256", "4" * 64),
        ("kernel-modules-deb-sha256", "5" * 64),
        ("kernel-modules-manifest-sha256", "6" * 64),
        ("kernel-sdk-archive-sha256", "7" * 64),
        ("kernel-sdk-manifest-sha256", sha(sdk_manifest)),
        ("kernel-toolchain-manifest-sha256", sha(toolchain)),
        ("kbuild-flags-sha256", sha(flags)),
        ("rustc-sha256", "a" * 64),
        ("rustc", "fixture rustc 1.0"),
        ("source-date-epoch", source_epoch),
        ("kbuild-build-timestamp", "2026-07-15 00:00:00 UTC"),
        ("kbuild-build-user", "tb321fu-ci"),
        ("kbuild-build-host", "tb321fu-builder"),
        ("kbuild-build-version", "1"),
    ]
    fields = [(key, overrides.get(key, value)) for key, value in fields]
    identity = tsv(fields)
    bundle_id = overrides.get("kernel-bundle-id", sha(identity))
    return identity + tsv([("kernel-bundle-id", bundle_id)]), flags, toolchain, sdk_manifest


def run(
    bundle: pathlib.Path,
    flags: pathlib.Path,
    toolchain: pathlib.Path,
    sdk_manifest: pathlib.Path,
    *arguments: str,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            str(bundle),
            "--kbuild-flags",
            str(flags),
            "--toolchain",
            str(toolchain),
            "--sdk-manifest",
            str(sdk_manifest),
            *arguments,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def require_failure(
    bundle: pathlib.Path,
    flags: pathlib.Path,
    toolchain: pathlib.Path,
    sdk_manifest: pathlib.Path,
    data: bytes,
    expected: bytes,
    *arguments: str,
) -> None:
    bundle.write_bytes(data)
    result = run(bundle, flags, toolchain, sdk_manifest, *arguments)
    if result.returncode == 0 or expected not in result.stderr:
        raise SystemExit(
            f"fixture did not fail at {expected!r}: "
            f"status={result.returncode} stderr={result.stderr!r}"
        )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="tb321fu-kernel-bundle-metadata.") as temp:
        root = pathlib.Path(temp)
        bundle = root / "KERNEL-BUNDLE.tsv"
        identical = root / "identical.tsv"
        flags = root / "KBUILD-FLAGS.tsv"
        toolchain = root / "KERNEL-TOOLCHAIN.tsv"
        sdk_manifest = root / "KERNEL-SDK-MANIFEST.tsv"
        valid, flags_bytes, toolchain_bytes, sdk_manifest_bytes = make_bundle()
        bundle.write_bytes(valid)
        identical.write_bytes(valid)
        flags.write_bytes(flags_bytes)
        toolchain.write_bytes(toolchain_bytes)
        sdk_manifest.write_bytes(sdk_manifest_bytes)

        result = run(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            "--identical",
            str(identical),
            "--expect",
            "kernel-release=7.1.1-g111111111111",
            "--emit-tsv",
        )
        if result.returncode or result.stdout != valid:
            raise SystemExit(
                f"valid fixture failed: status={result.returncode} "
                f"stderr={result.stderr!r}"
            )

        require_failure(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            valid[:-1],
            b"bundle must end with LF",
        )
        require_failure(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            valid.replace(b"\n", b"\r\n"),
            b"bundle contains CR",
        )
        require_failure(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            valid.replace(b"schema\t", b"kernel-release\t", 1),
            b"bundle field 1 must be schema",
        )
        require_failure(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            valid.replace(b"schema\t", b"schema\textra\t", 1),
            b"exactly one tab",
        )
        hostile, _, _, _ = make_bundle(
            **{"kbuild-build-timestamp": "$(touch owned)"}
        )
        require_failure(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            hostile,
            b"invalid bundle kbuild-build-timestamp",
        )
        wrong_id, _, _, _ = make_bundle(**{"kernel-bundle-id": "0" * 64})
        require_failure(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            wrong_id,
            b"kernel-bundle-id mismatch",
        )
        require_failure(
            bundle,
            flags,
            toolchain,
            sdk_manifest,
            b"x" * (64 * 1024) + b"\n",
            b"bundle exceeds size limit",
        )

        bundle.write_bytes(valid)
        other, _, _, _ = make_bundle(**{"source-date-epoch": "1784073601"})
        identical.write_bytes(other)
        result = run(bundle, flags, toolchain, sdk_manifest, "--identical", str(identical))
        if result.returncode == 0 or b"not byte-identical" not in result.stderr:
            raise SystemExit("non-identical valid bundle was accepted")

        result = run(bundle, flags, toolchain, sdk_manifest, "--expect", "kernel-release=7.1.1-wrong")
        if result.returncode == 0 or b"expectation mismatch" not in result.stderr:
            raise SystemExit("mismatched expectation was accepted")

        flags.write_bytes(flags_bytes.replace(b"kcflags\tunset", b"kcflags\t-hostile"))
        result = run(bundle, flags, toolchain, sdk_manifest)
        if result.returncode == 0 or b"invalid Kbuild flags kcflags" not in result.stderr:
            raise SystemExit("hostile inherited Kbuild flag was accepted")
        flags.write_bytes(flags_bytes)

        sdk_manifest.write_bytes(
            sdk_manifest_bytes.replace(b"./Module.symvers", b"./source", 1)
        )
        result = run(bundle, flags, toolchain, sdk_manifest)
        if result.returncode == 0 or b"SDK manifest must omit the source link" not in result.stderr:
            raise SystemExit("SDK source symlink was accepted")
        sdk_manifest.write_bytes(sdk_manifest_bytes)

        toolchain.write_bytes(toolchain_bytes.replace(b"rustc-version\tfixture rustc 1.0", b"rustc-version\tother rustc"))
        result = run(bundle, flags, toolchain, sdk_manifest)
        if result.returncode == 0 or b"toolchain manifest SHA-256 mismatch" not in result.stderr:
            raise SystemExit("tampered toolchain manifest was accepted")

        hostile_bundle, hostile_flags, hostile_toolchain, hostile_sdk = make_bundle(
            _cross_compile="a/../hostile-"
        )
        bundle.write_bytes(hostile_bundle)
        flags.write_bytes(hostile_flags)
        toolchain.write_bytes(hostile_toolchain)
        sdk_manifest.write_bytes(hostile_sdk)
        result = run(bundle, flags, toolchain, sdk_manifest)
        if result.returncode == 0 or b"invalid Kbuild flags cross-compile prefix" not in result.stderr:
            raise SystemExit("unsafe cross-compile prefix was accepted")

    print("KERNEL_BUNDLE_METADATA=PASS")


if __name__ == "__main__":
    main()
