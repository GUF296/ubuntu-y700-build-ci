#!/usr/bin/env python3
"""Validate canonical TB321FU kernel bundle metadata and evidence files."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import stat
import sys


MAX_METADATA_BYTES = 64 * 1024
MAX_SDK_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_SDK_MANIFEST_RECORDS = 200_000

HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX64_OR_UNUSED = re.compile(r"(?:[0-9a-f]{64}|unused)")
KERNEL_RELEASE = re.compile(r"[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}")
DTB_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\.dtb")
TIMESTAMP = re.compile(r"[0-9A-Za-z][0-9A-Za-z,:+._ -]{0,95}")
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
DECIMAL = re.compile(r"[0-9]{1,12}")
MODE = re.compile(r"[0-7]{3,4}")
CROSS_COMPILE = re.compile(r"/?[A-Za-z0-9][A-Za-z0-9._+/-]{0,254}-")
ABSOLUTE_DATA_PATH = re.compile(r"/[A-Za-z0-9._+/-]{1,511}")
PRINTABLE = re.compile(r"[ -~]{1,512}")
UNSET = re.compile(r"unset")


BUNDLE_FIELDS = (
    ("schema", re.compile(r"tb321fu\.kernel-bundle/v2")),
    ("kernel-source-commit", HEX40),
    ("kernel-release", KERNEL_RELEASE),
    ("kernel-config-sha256", HEX64),
    ("kernel-image-sha256", HEX64),
    ("kernel-dtb-name", DTB_NAME),
    ("kernel-dtb-sha256", HEX64),
    ("kernel-modules-deb-sha256", HEX64),
    ("kernel-modules-manifest-sha256", HEX64),
    ("kernel-sdk-archive-sha256", HEX64),
    ("kernel-sdk-manifest-sha256", HEX64),
    ("kernel-toolchain-manifest-sha256", HEX64),
    ("kbuild-flags-sha256", HEX64),
    ("rustc-sha256", HEX64),
    ("rustc", PRINTABLE),
    ("source-date-epoch", DECIMAL),
    ("kbuild-build-timestamp", TIMESTAMP),
    ("kbuild-build-user", IDENTIFIER),
    ("kbuild-build-host", IDENTIFIER),
    ("kbuild-build-version", re.compile(r"[1-9][0-9]{0,8}")),
    ("kernel-bundle-id", HEX64),
)

KBUILD_FLAGS_FIELDS = (
    ("schema", re.compile(r"tb321fu\.kbuild-flags/v2")),
    ("environment-policy", re.compile(r"isolated-allowlist-v1")),
    (
        "path",
        re.compile(r"private-locked-tool-directory-v1"),
    ),
    ("config-shell", re.compile(r"absolute-locked-sh-v1")),
    ("build-path-policy", re.compile(r"deterministic-input-key-v1")),
    ("lc-all", re.compile(r"C")),
    ("lang", re.compile(r"C")),
    ("tz", re.compile(r"UTC")),
    ("arch", re.compile(r"arm64")),
    ("cross-compile", CROSS_COMPILE),
    ("kconfig-notimestamp", re.compile(r"1")),
    ("dtb-contract", re.compile(r"tb321fu-aw86937-dual-v1")),
    ("depmod-config", re.compile(r"empty-private-v1")),
    ("kcflags", re.compile(r"debug-prefix-map-source-and-build-v1")),
    ("kaflags", re.compile(r"debug-prefix-map-source-and-build-v1")),
    ("kcppflags", UNSET),
    ("krustflags", UNSET),
    ("kbuild-cflags", UNSET),
    ("kbuild-aflags", UNSET),
    ("kbuild-cppflags", UNSET),
    ("kbuild-rustflags", UNSET),
    ("cflags", UNSET),
    ("cxxflags", UNSET),
    ("cppflags", UNSET),
    ("asflags", UNSET),
    ("ldflags", UNSET),
    ("cflags-kernel", UNSET),
    ("cflags-module", UNSET),
    ("aflags-kernel", UNSET),
    ("aflags-module", UNSET),
    ("ldflags-vmlinux", UNSET),
    ("ldflags-module", UNSET),
    ("hostcflags", UNSET),
    ("hostcxxflags", UNSET),
    ("hostldflags", UNSET),
    ("usercflags", UNSET),
    ("userldflags", UNSET),
    ("localversion", UNSET),
    ("dtc", UNSET),
    ("dtc-flags", UNSET),
    ("objcopyflags", UNSET),
    ("host-extracflags", UNSET),
    ("host-extracxxflags", UNSET),
    ("host-extrarustflags", UNSET),
    ("hostldlibs", UNSET),
    ("procmacroldflags", UNSET),
    ("kbuild-extra-warn", UNSET),
    ("kbuild-clippy", UNSET),
    ("kbuild-checksrc", UNSET),
    ("kbuild-extmod-output", UNSET),
    ("kbuild-nocmddep", UNSET),
    ("kbuild-nsdeps", UNSET),
    ("kbuild-preserve", UNSET),
    ("kbuild-symtypes", UNSET),
    ("kbuild-gendwarfksyms-stable", UNSET),
    ("kbuild-kconfig", UNSET),
    ("kconfig-autoconfig", UNSET),
    ("kconfig-autoheader", UNSET),
    ("config-prefix", UNSET),
    ("kconfig-defconfig-list", UNSET),
    ("kconfig-allconfig", UNSET),
    ("kconfig-overwriteconfig", UNSET),
    ("kconfig-warn-unknown-symbols", UNSET),
    ("kconfig-werror", UNSET),
    ("kconfig-nosilentupdate", UNSET),
    ("makefiles", UNSET),
    ("gnumakeflags", UNSET),
    ("makeflags", UNSET),
    ("mflags", UNSET),
    ("makeoverrides", UNSET),
    ("cpath", UNSET),
    ("gcc-exec-prefix", UNSET),
    ("compiler-path", UNSET),
    ("library-path", UNSET),
    ("pkg-config-path", UNSET),
    ("tar-options", UNSET),
    ("gzip-env", UNSET),
    ("xz-opt", UNSET),
    ("xz-defaults", UNSET),
    ("dpkg-deb-threads-max", re.compile(r"1")),
    ("dpkg-deb-compressor-type", re.compile(r"xz")),
    ("dpkg-deb-compressor-level", re.compile(r"6")),
    ("source-date-epoch", DECIMAL),
    ("kbuild-build-timestamp", TIMESTAMP),
    ("kbuild-build-user", IDENTIFIER),
    ("kbuild-build-host", IDENTIFIER),
    ("kbuild-build-version", re.compile(r"[1-9][0-9]{0,8}")),
)

TOOLCHAIN_TOOL_NAMES = (
    "gcc",
    "as",
    "ld",
    "ar",
    "nm",
    "objcopy",
    "objdump",
    "readelf",
    "strip",
    "rustc",
    "host-gcc",
    "host-gxx",
    "host-as",
    "host-ld",
    "host-ar",
    "flex",
    "bison",
    "m4",
    "awk",
    "perl",
    "python3",
    "pkg-config",
    "pahole",
    "git",
    "make",
    "depmod",
    "modinfo",
    "tar",
    "gzip",
    "xz",
    "dpkg-deb",
    "fdtget",
    "bash",
    "sh",
    "bc",
    "getconf",
    "sha1sum",
    "ln",
    "uname",
    "sha256sum",
    "find",
    "sort",
    "xargs",
    "rsync",
    "cp",
    "dpkg",
    "touch",
    "realpath",
    "nproc",
    "date",
    "install",
    "stat",
    "grep",
    "sed",
    "readlink",
    "wc",
    "tr",
    "cut",
    "findmnt",
    "curl",
    "flock",
    "mv",
    "chmod",
    "mkdir",
    "mktemp",
    "rm",
    "cat",
    "dirname",
    "basename",
    "env",
    "true",
    "cmp",
    "head",
    "expr",
    "uniq",
)

TOOLCHAIN_FIELDS = (
    ("schema", re.compile(r"tb321fu\.kernel-toolchain/v2")),
    ("cross-compile", CROSS_COMPILE),
    ("bison-data-directory", ABSOLUTE_DATA_PATH),
    ("bison-data-sha256", HEX64),
) + tuple(
    field
    for tool in TOOLCHAIN_TOOL_NAMES
    for field in (
        (f"{tool}-sha256", HEX64_OR_UNUSED if tool == "pahole" else HEX64),
        (f"{tool}-version", PRINTABLE),
    )
)


class BundleError(ValueError):
    """Raised when bundle evidence violates the canonical contract."""


def read_ascii_regular(path: pathlib.Path, label: str, maximum: int) -> tuple[bytes, str]:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise BundleError(f"cannot stat {label} {path}: {exc}") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise BundleError(f"{label} must be a regular file: {path}")
    if metadata.st_size > maximum:
        raise BundleError(f"{label} exceeds size limit: {path}")
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise BundleError(f"cannot read {label} {path}: {exc}") from exc
    if len(raw) > maximum:
        raise BundleError(f"{label} exceeds size limit: {path}")
    if not raw.endswith(b"\n"):
        raise BundleError(f"{label} must end with LF: {path}")
    if b"\x00" in raw:
        raise BundleError(f"{label} contains NUL: {path}")
    if b"\r" in raw:
        raise BundleError(f"{label} contains CR: {path}")
    try:
        return raw, raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise BundleError(f"{label} must contain ASCII only: {path}") from exc


def parse_ordered_tsv(
    path: pathlib.Path,
    label: str,
    fields: tuple[tuple[str, re.Pattern[str]], ...],
    maximum: int = MAX_METADATA_BYTES,
) -> tuple[dict[str, str], bytes]:
    raw, text = read_ascii_regular(path, label, maximum)
    lines = text.splitlines()
    if len(lines) != len(fields):
        raise BundleError(
            f"{label} has {len(lines)} fields, expected {len(fields)}: {path}"
        )

    values: dict[str, str] = {}
    for index, ((expected_key, validator), line) in enumerate(
        zip(fields, lines, strict=True), start=1
    ):
        if line.count("\t") != 1:
            raise BundleError(f"{label} field {index} must contain exactly one tab: {path}")
        key, value = line.split("\t", 1)
        if key != expected_key:
            raise BundleError(
                f"{label} field {index} must be {expected_key}, "
                f"found {key or '<empty>'}: {path}"
            )
        if validator.fullmatch(value) is None:
            raise BundleError(f"invalid {label} {key}: {path}")
        values[key] = value
    return values, raw


def parse_bundle(path: pathlib.Path) -> tuple[dict[str, str], bytes]:
    values, raw = parse_ordered_tsv(path, "bundle", BUNDLE_FIELDS)
    identity = b"".join(raw.splitlines(keepends=True)[:-1])
    actual_id = hashlib.sha256(identity).hexdigest()
    if values["kernel-bundle-id"] != actual_id:
        raise BundleError(
            "kernel-bundle-id mismatch: "
            f"expected {actual_id}, found {values['kernel-bundle-id']}: {path}"
        )
    return values, raw


def validate_sdk_path(path: str, source: pathlib.Path) -> None:
    if not path.startswith("./") or path == "./" or len(path) > 4096:
        raise BundleError(f"invalid SDK manifest path: {source}")
    if "//" in path or "\\" in path or path.endswith("/"):
        raise BundleError(f"invalid SDK manifest path: {source}")
    components = path[2:].split("/")
    if ":" in components[0]:
        raise BundleError(f"invalid SDK manifest path: {source}")
    for component in components:
        if not component or component in {".", ".."} or len(component) > 255:
            raise BundleError(f"invalid SDK manifest path: {source}")


def parse_sdk_manifest(path: pathlib.Path) -> tuple[dict[str, str], bytes]:
    raw, text = read_ascii_regular(path, "SDK manifest", MAX_SDK_MANIFEST_BYTES)
    lines = text.splitlines()
    if not lines or lines[0] != "schema\ttb321fu.kernel-sdk-manifest/v1":
        raise BundleError(f"invalid SDK manifest header: {path}")
    if len(lines) == 1:
        raise BundleError(f"SDK manifest has no entries: {path}")
    if len(lines) - 1 > MAX_SDK_MANIFEST_RECORDS:
        raise BundleError(f"SDK manifest has too many entries: {path}")

    previous_path = ""
    files: dict[str, str] = {}
    for index, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != 4:
            raise BundleError(f"malformed SDK manifest record at line {index}: {path}")
        kind, digest, mode, entry_path = fields
        if kind not in {"file", "symlink"}:
            raise BundleError(f"invalid SDK manifest record type at line {index}: {path}")
        if HEX64.fullmatch(digest) is None or MODE.fullmatch(mode) is None:
            raise BundleError(f"invalid SDK manifest record at line {index}: {path}")
        validate_sdk_path(entry_path, path)
        if entry_path == "./source":
            raise BundleError(f"SDK manifest must omit the source link: {path}")
        if previous_path and entry_path <= previous_path:
            raise BundleError(f"SDK manifest paths are not strictly ordered: {path}")
        previous_path = entry_path
        if kind == "file":
            files[entry_path] = digest

    required = {
        "./.config",
        "./Module.symvers",
        "./include/config/kernel.release",
        "./include/generated/autoconf.h",
        "./include/generated/utsrelease.h",
    }
    if not required.issubset(files):
        raise BundleError(f"SDK manifest lacks required generated build files: {path}")
    return files, raw


def parse_expectation(argument: str) -> tuple[str, str]:
    if "=" not in argument:
        raise BundleError(f"expectation must be KEY=VALUE: {argument}")
    key, value = argument.split("=", 1)
    known = {name for name, _ in BUNDLE_FIELDS}
    if key not in known or not value:
        raise BundleError(f"invalid expectation: {argument}")
    return key, value


def validate_cross_compile(value: str, label: str) -> None:
    if not value.startswith("/") or ".." in value or "//" in value:
        raise BundleError(f"invalid {label} cross-compile prefix")


def validate_absolute_data_path(value: str, label: str) -> None:
    if (
        not value.startswith("/")
        or value.endswith("/")
        or "//" in value
        or "\\" in value
    ):
        raise BundleError(f"invalid {label} data path")
    components = value[1:].split("/")
    if any(
        component in {"", ".", ".."} or len(component) > 255
        for component in components
    ):
        raise BundleError(f"invalid {label} data path")


def verify_linked_metadata(
    bundle: dict[str, str], args: argparse.Namespace
) -> None:
    if args.kbuild_flags is not None:
        flags, raw = parse_ordered_tsv(
            args.kbuild_flags, "Kbuild flags", KBUILD_FLAGS_FIELDS
        )
        digest = hashlib.sha256(raw).hexdigest()
        if digest != bundle["kbuild-flags-sha256"]:
            raise BundleError("Kbuild flags manifest SHA-256 mismatch")
        validate_cross_compile(flags["cross-compile"], "Kbuild flags")
        for key in (
            "source-date-epoch",
            "kbuild-build-timestamp",
            "kbuild-build-user",
            "kbuild-build-host",
            "kbuild-build-version",
        ):
            if flags[key] != bundle[key]:
                raise BundleError(f"Kbuild flags {key} differs from bundle")
    if args.toolchain is not None:
        toolchain, raw = parse_ordered_tsv(
            args.toolchain, "toolchain manifest", TOOLCHAIN_FIELDS
        )
        digest = hashlib.sha256(raw).hexdigest()
        if digest != bundle["kernel-toolchain-manifest-sha256"]:
            raise BundleError("toolchain manifest SHA-256 mismatch")
        validate_cross_compile(toolchain["cross-compile"], "toolchain")
        validate_absolute_data_path(
            toolchain["bison-data-directory"], "toolchain Bison"
        )
        pahole_unused = toolchain["pahole-sha256"] == "unused"
        if pahole_unused != (toolchain["pahole-version"] == "unused"):
            raise BundleError("toolchain pahole unused state is inconsistent")
        if toolchain["rustc-sha256"] != bundle["rustc-sha256"]:
            raise BundleError("toolchain rustc SHA-256 differs from bundle")
        if toolchain["rustc-version"] != bundle["rustc"]:
            raise BundleError("toolchain rustc version differs from bundle")
        if args.kbuild_flags is not None:
            flags, _ = parse_ordered_tsv(
                args.kbuild_flags, "Kbuild flags", KBUILD_FLAGS_FIELDS
            )
            if toolchain["cross-compile"] != flags["cross-compile"]:
                raise BundleError("toolchain cross-compile differs from Kbuild flags")
    if args.sdk_manifest is not None:
        files, raw = parse_sdk_manifest(args.sdk_manifest)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != bundle["kernel-sdk-manifest-sha256"]:
            raise BundleError("SDK manifest SHA-256 mismatch")
        if files["./.config"] != bundle["kernel-config-sha256"]:
            raise BundleError("SDK manifest kernel config differs from bundle")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate canonical TB321FU KERNEL-BUNDLE.tsv metadata."
    )
    parser.add_argument("bundle", type=pathlib.Path)
    parser.add_argument(
        "--identical",
        action="append",
        default=[],
        type=pathlib.Path,
        help="also validate this bundle and require byte identity",
    )
    parser.add_argument(
        "--kbuild-flags",
        type=pathlib.Path,
        help="validate the KBUILD-FLAGS.tsv file bound by this bundle",
    )
    parser.add_argument(
        "--toolchain",
        type=pathlib.Path,
        help="validate the KERNEL-TOOLCHAIN.tsv file bound by this bundle",
    )
    parser.add_argument(
        "--sdk-manifest",
        type=pathlib.Path,
        help="validate the KERNEL-SDK-MANIFEST.tsv file bound by this bundle",
    )
    parser.add_argument(
        "--expect",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="require one exact canonical field value",
    )
    parser.add_argument(
        "--emit-tsv",
        action="store_true",
        help="write the validated canonical TSV bytes to stdout",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        values, raw = parse_bundle(args.bundle)
        verify_linked_metadata(values, args)
        for other_path in args.identical:
            _, other_raw = parse_bundle(other_path)
            if other_raw != raw:
                raise BundleError(
                    f"bundle metadata is not byte-identical: {args.bundle} != {other_path}"
                )
        seen: set[str] = set()
        for argument in args.expect:
            key, expected = parse_expectation(argument)
            if key in seen:
                raise BundleError(f"duplicate expectation for {key}")
            seen.add(key)
            if values[key] != expected:
                raise BundleError(
                    f"expectation mismatch for {key}: "
                    f"expected {expected}, found {values[key]}"
                )
    except BundleError as exc:
        print(f"kernel bundle metadata verification failed: {exc}", file=sys.stderr)
        return 1

    if args.emit_tsv:
        sys.stdout.buffer.write(raw)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
