#!/usr/bin/env python3
"""Verify the closed source and toolchain contract for the camera SPA plugin."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import stat
import subprocess
import sys
from collections.abc import Callable


MAX_ENTRIES = 256
MAX_FILE_SIZE = 1 << 20
MAX_TOTAL_SIZE = 4 << 20
MAX_PATH_LENGTH = 240
MAX_PATH_DEPTH = 12
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+:-]*$")
EXPECTED_PACKAGES = frozenset(
    {
        "binutils-aarch64-linux-gnu",
        "cpp-13-aarch64-linux-gnu",
        "dpkg",
        "g++-13-aarch64-linux-gnu",
        "gcc-13-aarch64-linux-gnu",
        "libc6-dev-arm64-cross",
        "libspa-0.2-dev:amd64",
        "libstdc++-13-dev-arm64-cross",
        "meson",
        "ninja-build",
        "pkg-config:amd64",
        "rsync",
    }
)
EXPECTED_COMMANDS = frozenset(
    {
        "/usr/bin/aarch64-linux-gnu-g++-13",
        "/usr/bin/aarch64-linux-gnu-gcc-13",
        "/usr/bin/aarch64-linux-gnu-readelf",
        "/usr/bin/aarch64-linux-gnu-strings",
        "/usr/bin/aarch64-linux-gnu-strip",
        "/usr/bin/dpkg",
        "/usr/bin/dpkg-deb",
        "/usr/bin/meson",
        "/usr/bin/ninja",
        "/usr/bin/pkg-config",
        "/usr/bin/rsync",
    }
)


class ContractError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ContractError(message)


def sha256_fd(fd: int) -> str:
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while chunk := os.read(fd, 1 << 20):
        digest.update(chunk)
    return digest.hexdigest()


def stat_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def read_regular_bytes(
    path: pathlib.Path,
    before: os.stat_result,
    maximum_size: int,
    label: str,
) -> bytes:
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size > maximum_size
    ):
        fail(f"{label} must be one bounded private regular file")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if stat_identity(opened) != stat_identity(before):
            fail(f"{label} changed while opening")
        chunks: list[bytes] = []
        total = 0
        while chunk := os.read(fd, min(1 << 20, maximum_size + 1 - total)):
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum_size:
                fail(f"{label} exceeds its size limit")
        after = os.fstat(fd)
        if stat_identity(after) != stat_identity(opened):
            fail(f"{label} changed while reading")
    finally:
        os.close(fd)
    return b"".join(chunks)


def validate_secure_directory(path: pathlib.Path, expected_uid: int, expected_gid: int) -> None:
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        fail(f"toolchain command parent must be a non-symlink directory: {path}")
    if metadata.st_uid != expected_uid or metadata.st_gid != expected_gid:
        fail(f"toolchain command parent ownership mismatch: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        fail(f"toolchain command parent is group/world writable: {path}")


def validate_command_metadata(
    path: pathlib.Path,
    metadata: os.stat_result,
    *,
    expected_uid: int,
    expected_gid: int,
) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"toolchain command target is not a regular file: {path}")
    if metadata.st_uid != expected_uid or metadata.st_gid != expected_gid:
        fail(f"toolchain command target ownership mismatch: {path}")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode & 0o022:
        fail(f"toolchain command target is group/world writable: {path}")
    if mode & 0o111 == 0:
        fail(f"toolchain command target is not executable: {path}")


def verify_command_identity(
    command: pathlib.Path,
    expected_digest: str,
    expected_version: str,
    *,
    expected_uid: int = 0,
    expected_gid: int = 0,
    required_parent: pathlib.Path = pathlib.Path("/usr/bin"),
    version_probe: Callable[[str], str] | None = None,
) -> None:
    if command.parent != required_parent:
        fail(f"toolchain command is outside the locked directory: {command}")
    validate_secure_directory(required_parent, expected_uid, expected_gid)

    entry_before = command.lstat()
    if entry_before.st_uid != expected_uid or entry_before.st_gid != expected_gid:
        fail(f"toolchain command entry ownership mismatch: {command}")

    link_target: str | None = None
    if stat.S_ISLNK(entry_before.st_mode):
        link_target = os.readlink(command)
        if (
            not link_target
            or "/" in link_target
            or "\\" in link_target
            or link_target in {".", ".."}
        ):
            fail(f"toolchain command has an unsafe symlink target: {command}")
        target = required_parent / link_target
    elif stat.S_ISREG(entry_before.st_mode):
        target = command
    else:
        fail(f"toolchain command entry type mismatch: {command}")

    target_before = target.lstat()
    validate_command_metadata(
        target,
        target_before,
        expected_uid=expected_uid,
        expected_gid=expected_gid,
    )
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(target, flags)
    try:
        opened = os.fstat(fd)
        validate_command_metadata(
            target,
            opened,
            expected_uid=expected_uid,
            expected_gid=expected_gid,
        )
        if stat_identity(opened) != stat_identity(target_before):
            fail(f"toolchain command target changed while opening: {command}")
        if sha256_fd(fd) != expected_digest:
            fail(f"toolchain command digest drift for {command}")
    finally:
        os.close(fd)

    probe = version_probe or command_version
    actual_version = probe(str(target))
    if expected_version not in actual_version.split() and actual_version != expected_version:
        fail(f"toolchain command version drift for {command}: {actual_version!r}")

    entry_after = command.lstat()
    target_after = target.lstat()
    if stat_identity(entry_after) != stat_identity(entry_before):
        fail(f"toolchain command entry changed during verification: {command}")
    if stat_identity(target_after) != stat_identity(target_before):
        fail(f"toolchain command target changed during verification: {command}")
    if link_target is not None and os.readlink(command) != link_target:
        fail(f"toolchain command symlink retargeted during verification: {command}")
    fd = os.open(target, flags)
    try:
        reopened = os.fstat(fd)
        if stat_identity(reopened) != stat_identity(target_before):
            fail(f"toolchain command target changed while reopening: {command}")
        if sha256_fd(fd) != expected_digest:
            fail(f"toolchain command content changed during verification: {command}")
    finally:
        os.close(fd)


def validate_producer_root(path: pathlib.Path) -> pathlib.Path:
    absolute = pathlib.Path(os.path.abspath(os.fspath(path)))
    metadata = absolute.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or absolute.is_symlink():
        fail("producer root must be a non-symlink directory")
    resolved = absolute.resolve(strict=True)
    if resolved != absolute:
        fail("producer root path must not traverse symlinks")
    return absolute


def validate_relative_path(value: str) -> pathlib.PurePosixPath:
    if not value or len(value) > MAX_PATH_LENGTH or "\\" in value or "\x00" in value:
        fail(f"invalid manifest path: {value!r}")
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"non-canonical manifest path: {value!r}")
    if len(path.parts) > MAX_PATH_DEPTH:
        fail(f"manifest path is too deep: {value!r}")
    return path


def parse_manifest(path: pathlib.Path) -> tuple[dict[str, tuple[str, int, int, str]], bytes]:
    metadata = path.lstat()
    if stat.S_IMODE(metadata.st_mode) != 0o644:
        fail("producer manifest mode mismatch")
    raw = read_regular_bytes(path, metadata, 256 * 1024, "producer manifest")
    if len(raw) > 256 * 1024 or b"\r" in raw or b"\x00" in raw:
        fail("producer manifest has invalid encoding or size")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ContractError("producer manifest is not UTF-8") from exc
    lines = text.splitlines()
    if not lines or lines[0] != "path\ttype\tmode\tsize\tsha256":
        fail("producer manifest header mismatch")
    if len(lines) - 1 > MAX_ENTRIES:
        fail("producer manifest entry limit exceeded")

    records: dict[str, tuple[str, int, int, str]] = {}
    previous = b""
    total_size = 0
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 5:
            fail("producer manifest row does not have five fields")
        name, kind, mode_text, size_text, digest = fields
        validate_relative_path(name)
        encoded_name = name.encode("utf-8")
        if (
            name == "SOURCE-MANIFEST.tsv"
            or (previous and encoded_name <= previous)
            or name in records
        ):
            fail(f"producer manifest order/identity violation: {name!r}")
        previous = encoded_name
        if kind not in {"directory", "file"}:
            fail(f"unsupported producer member type for {name}")
        if not re.fullmatch(r"0[0-7]{3}", mode_text):
            fail(f"invalid mode for {name}")
        mode = int(mode_text, 8)
        if not size_text.isascii() or not size_text.isdecimal():
            fail(f"invalid size for {name}")
        size = int(size_text, 10)
        if size > MAX_FILE_SIZE:
            fail(f"producer member is too large: {name}")
        if not SHA256_RE.fullmatch(digest):
            fail(f"invalid digest for {name}")
        if kind == "directory" and (mode != 0o755 or size != 0 or digest != EMPTY_SHA256):
            fail(f"directory contract mismatch for {name}")
        if kind == "file" and mode != 0o644:
            fail(f"file mode contract mismatch for {name}")
        total_size += size
        if total_size > MAX_TOTAL_SIZE:
            fail("producer manifest aggregate size limit exceeded")
        records[name] = (kind, mode, size, digest)
    return records, raw


def inspect_tree(root: pathlib.Path) -> tuple[dict[str, tuple[str, int, int, str]], int]:
    root_stat = root.lstat()
    if not stat.S_ISDIR(root_stat.st_mode) or root.is_symlink():
        fail("producer root must be a non-symlink directory")
    records: dict[str, tuple[str, int, int, str]] = {}
    total_size = 0
    stack = [root]
    while stack:
        directory = stack.pop()
        for entry in sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name), reverse=True):
            path = pathlib.Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if relative == "SOURCE-MANIFEST.tsv":
                metadata = path.lstat()
                if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o644 or metadata.st_nlink != 1:
                    fail("SOURCE-MANIFEST.tsv must be one private regular 0644 file")
                continue
            validate_relative_path(relative)
            metadata = path.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode):
                if mode != 0o755:
                    fail(f"directory mode mismatch for {relative}")
                records[relative] = ("directory", mode, 0, EMPTY_SHA256)
                stack.append(path)
            elif stat.S_ISREG(metadata.st_mode):
                if mode != 0o644 or metadata.st_nlink != 1:
                    fail(f"file mode or hardlink mismatch for {relative}")
                if metadata.st_size > MAX_FILE_SIZE:
                    fail(f"producer member is too large: {relative}")
                total_size += metadata.st_size
                if total_size > MAX_TOTAL_SIZE:
                    fail("producer tree aggregate size limit exceeded")
                raw = read_regular_bytes(
                    path, metadata, MAX_FILE_SIZE, f"producer member {relative}"
                )
                records[relative] = (
                    "file",
                    mode,
                    metadata.st_size,
                    hashlib.sha256(raw).hexdigest(),
                )
            else:
                fail(f"unsupported producer member type for {relative}")
            if len(records) > MAX_ENTRIES:
                fail("producer tree entry limit exceeded")
    return records, total_size


def parse_toolchain(path: pathlib.Path) -> list[tuple[str, str, str, str]]:
    metadata = path.lstat()
    if stat.S_IMODE(metadata.st_mode) != 0o644:
        fail("toolchain lock mode mismatch")
    raw = read_regular_bytes(path, metadata, 64 * 1024, "toolchain lock")
    if len(raw) > 64 * 1024 or b"\r" in raw or b"\x00" in raw:
        fail("toolchain lock has invalid encoding or size")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ContractError("toolchain lock is not UTF-8") from exc
    if not lines or lines[0] != "kind\tname\tversion\tsha256":
        fail("toolchain lock header mismatch")
    rows: list[tuple[str, str, str, str]] = []
    seen: set[tuple[str, str]] = set()
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 4:
            fail("toolchain lock row does not have four fields")
        kind, name, version, digest = fields
        if kind not in {"package", "command"} or not version or (kind, name) in seen:
            fail(f"invalid toolchain row: {line!r}")
        seen.add((kind, name))
        if kind == "package":
            if not PACKAGE_RE.fullmatch(name) or digest != "-":
                fail(f"invalid package lock: {name!r}")
        else:
            if not name.startswith("/usr/bin/") or not SHA256_RE.fullmatch(digest):
                fail(f"invalid command lock: {name!r}")
        rows.append((kind, name, version, digest))
    if not rows:
        fail("empty toolchain lock")
    package_names = {name for kind, name, _, _ in rows if kind == "package"}
    command_names = {name for kind, name, _, _ in rows if kind == "command"}
    if package_names != EXPECTED_PACKAGES:
        fail(
            "toolchain package closure mismatch: "
            f"missing={sorted(EXPECTED_PACKAGES - package_names)} "
            f"extra={sorted(package_names - EXPECTED_PACKAGES)}"
        )
    if command_names != EXPECTED_COMMANDS:
        fail(
            "toolchain command closure mismatch: "
            f"missing={sorted(EXPECTED_COMMANDS - command_names)} "
            f"extra={sorted(command_names - EXPECTED_COMMANDS)}"
        )
    return rows


def command_version(path: str) -> str:
    name = pathlib.Path(path).name
    if name in {"aarch64-linux-gnu-g++-13", "aarch64-linux-gnu-gcc-13"}:
        arguments = [path, "-dumpfullversion"]
    else:
        arguments = [path, "--version"]
    result = subprocess.run(
        arguments,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=10,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC"},
    )
    return result.stdout.splitlines()[0].strip()


def check_toolchain(rows: list[tuple[str, str, str, str]]) -> None:
    for kind, name, version, digest in rows:
        if kind == "package":
            result = subprocess.run(
                ["/usr/bin/dpkg-query", "--show", "--showformat=${Version}", name],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC"},
            )
            if result.stdout != version:
                fail(f"toolchain package drift for {name}: {result.stdout!r}")
            continue
        verify_command_identity(pathlib.Path(name), digest, version)

    aliases = {
        "/usr/bin/aarch64-linux-gnu-g++": "/usr/bin/aarch64-linux-gnu-g++-13",
        "/usr/bin/aarch64-linux-gnu-gcc": "/usr/bin/aarch64-linux-gnu-gcc-13",
    }
    for alias, target in aliases.items():
        if os.path.realpath(alias) != target:
            fail(f"toolchain alias drift: {alias}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--check-tools", action="store_true")
    parser.add_argument("--print-manifest", action="store_true")
    arguments = parser.parse_args()
    if arguments.check_tools and arguments.print_manifest:
        fail("--check-tools and --print-manifest are mutually exclusive")
    root = validate_producer_root(arguments.root)
    manifest = root / "SOURCE-MANIFEST.tsv"
    actual, total_size = inspect_tree(root)
    if arguments.print_manifest:
        print("path\ttype\tmode\tsize\tsha256")
        for name in sorted(actual, key=lambda value: value.encode("utf-8")):
            kind, mode, size, digest = actual[name]
            print(f"{name}\t{kind}\t0{mode:03o}\t{size}\t{digest}")
        return 0
    expected, raw_manifest = parse_manifest(manifest)
    if expected.keys() != actual.keys():
        missing = sorted(expected.keys() - actual.keys())
        extra = sorted(actual.keys() - expected.keys())
        fail(f"producer tree membership mismatch: missing={missing} extra={extra}")
    for name, record in expected.items():
        if actual[name] != record:
            fail(f"producer tree metadata/content mismatch: {name}")

    toolchain = parse_toolchain(root / "TOOLCHAIN.tsv")
    if arguments.check_tools:
        check_toolchain(toolchain)

    print("CAMERA_PRODUCER_VERIFY=PASS")
    print(f"manifest_sha256={hashlib.sha256(raw_manifest).hexdigest()}")
    print(f"entries={len(expected)}")
    print(f"bytes={total_size}")
    print(f"toolchain_checked={int(arguments.check_tools)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, subprocess.SubprocessError) as exc:
        print(f"CAMERA_PRODUCER_VERIFY=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
