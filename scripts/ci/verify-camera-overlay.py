#!/usr/bin/env python3
"""Verify the closed TB321FU camera overlay tree."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import pathlib
import re
import stat
import sys


MAX_ENTRIES = 256
MAX_FILE_SIZE = 16 << 20
MAX_TOTAL_SIZE = 64 << 20
MAX_MANIFEST_SIZE = 256 << 10
MAX_PATH_LENGTH = 240
MAX_PATH_DEPTH = 16
MAX_LINK_LENGTH = 240
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PLUGIN_PATH = "usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"


class ContractError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ContractError(message)


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


def validate_relative_path(value: str) -> pathlib.PurePosixPath:
    if not value or len(value) > MAX_PATH_LENGTH or "\\" in value or "\x00" in value:
        fail(f"invalid overlay path: {value!r}")
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"non-canonical overlay path: {value!r}")
    if len(path.parts) > MAX_PATH_DEPTH:
        fail(f"overlay path is too deep: {value!r}")
    return path


def validate_link_target(value: str, name: str) -> None:
    if (
        not value
        or value == "-"
        or len(os.fsencode(value)) > MAX_LINK_LENGTH
        or any(character in value for character in ("\x00", "\r", "\n", "\t"))
    ):
        fail(f"invalid symlink target for {name}: {value!r}")


def fingerprint_regular(
    path: pathlib.Path, metadata: os.stat_result | None = None
) -> tuple[int, int, str]:
    before = metadata or path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        fail(f"overlay member is not a private regular file: {path}")
    if before.st_size > MAX_FILE_SIZE:
        fail(f"overlay member exceeds the file-size limit: {path}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if stat_identity(opened) != stat_identity(before) or not stat.S_ISREG(opened.st_mode):
            fail(f"overlay member changed while opening: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(fd, 1 << 20):
            digest.update(chunk)
        after = os.fstat(fd)
        if stat_identity(after) != stat_identity(opened):
            fail(f"overlay member changed while hashing: {path}")
    finally:
        os.close(fd)
    return stat.S_IMODE(before.st_mode), before.st_size, digest.hexdigest()


Record = tuple[str, int, int, str, str]


def parse_manifest(path: pathlib.Path, require_plugin: bool = True) -> tuple[dict[str, Record], bytes]:
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o644
        or metadata.st_size > MAX_MANIFEST_SIZE
    ):
        fail("overlay manifest must be one regular 0644 bounded file")
    raw = path.read_bytes()
    if len(raw) != metadata.st_size or b"\r" in raw or b"\x00" in raw:
        fail("overlay manifest changed or has invalid encoding")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ContractError("overlay manifest is not UTF-8") from exc
    if not lines or lines[0] != "path\ttype\tmode\tsize\tsha256\tlink_target":
        fail("overlay manifest header mismatch")
    if not 0 < len(lines) - 1 <= MAX_ENTRIES:
        fail("overlay manifest entry count is invalid")

    records: dict[str, Record] = {}
    previous = b""
    total_size = 0
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 6:
            fail("overlay manifest row does not have six fields")
        name, kind, mode_text, size_text, digest, link_target = fields
        validate_relative_path(name)
        encoded_name = name.encode("utf-8")
        if previous and encoded_name <= previous:
            fail(f"overlay manifest order/identity violation: {name}")
        previous = encoded_name
        if name in records or kind not in {"directory", "file", "symlink"}:
            fail(f"unsupported or duplicate overlay member: {name}")
        if not re.fullmatch(r"0[0-7]{3}", mode_text):
            fail(f"invalid overlay mode for {name}")
        if not size_text.isascii() or not size_text.isdecimal():
            fail(f"invalid overlay size for {name}")
        mode = int(mode_text, 8)
        size = int(size_text, 10)
        if kind == "directory":
            if mode != 0o755 or size != 0 or digest != "-" or link_target != "-":
                fail(f"directory manifest contract mismatch for {name}")
        elif kind == "file":
            if mode not in {0o644, 0o755} or size > MAX_FILE_SIZE:
                fail(f"file manifest metadata mismatch for {name}")
            if not SHA256_RE.fullmatch(digest) or link_target != "-":
                fail(f"file manifest digest/link mismatch for {name}")
            total_size += size
            if total_size > MAX_TOTAL_SIZE:
                fail("overlay manifest aggregate size limit exceeded")
        else:
            if mode != 0o777 or digest != "-":
                fail(f"symlink manifest metadata mismatch for {name}")
            validate_link_target(link_target, name)
            if size != len(os.fsencode(link_target)):
                fail(f"symlink manifest size mismatch for {name}")
        records[name] = (kind, mode, size, digest, link_target)
    if require_plugin and (PLUGIN_PATH not in records or records[PLUGIN_PATH][0] != "file"):
        fail("overlay manifest does not contain the canonical SPA plugin")
    return records, raw


def validate_root(path: pathlib.Path) -> pathlib.Path:
    absolute = pathlib.Path(os.path.abspath(os.fspath(path)))
    metadata = absolute.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or absolute.is_symlink()
        or stat.S_IMODE(metadata.st_mode) != 0o755
    ):
        fail("overlay root must be a real 0755 directory")
    if absolute.resolve(strict=True) != absolute:
        fail("overlay root path must not traverse symlinks")
    return absolute


def inspect_tree(root: pathlib.Path) -> tuple[dict[str, Record], int]:
    records: dict[str, Record] = {}
    total_size = 0
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: os.fsencode(entry.name))
        except OSError as exc:
            raise ContractError(f"cannot enumerate overlay directory: {directory}") from exc
        for entry in entries:
            path = pathlib.Path(entry.path)
            name = path.relative_to(root).as_posix()
            validate_relative_path(name)
            metadata = path.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode):
                if mode != 0o755:
                    fail(f"overlay directory mode mismatch: {name}")
                record: Record = ("directory", mode, 0, "-", "-")
                stack.append(path)
            elif stat.S_ISREG(metadata.st_mode):
                mode, size, digest = fingerprint_regular(path, metadata)
                total_size += size
                if total_size > MAX_TOTAL_SIZE:
                    fail("overlay tree aggregate size limit exceeded")
                record = ("file", mode, size, digest, "-")
            elif stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(path)
                validate_link_target(target, name)
                metadata_after = path.lstat()
                if stat_identity(metadata_after) != stat_identity(metadata):
                    fail(f"overlay symlink changed while reading: {name}")
                record = ("symlink", mode, metadata.st_size, "-", target)
            else:
                fail(f"overlay contains an unsupported member type: {name}")
            records[name] = record
            if len(records) > MAX_ENTRIES:
                fail("overlay tree entry limit exceeded")
    return records, total_size


def plugin_override_record(path: pathlib.Path) -> Record:
    mode, size, digest = fingerprint_regular(path)
    if mode != 0o644:
        fail("replacement SPA plugin mode must be 0644")
    return ("file", mode, size, digest, "-")


def runtime_override_records(expected: dict[str, Record], output: pathlib.Path) -> dict[str, Record]:
    spec = importlib.util.spec_from_file_location(
        'overlay_runtime_contract', pathlib.Path(__file__).with_name('verify-libcamera-runtime.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    runtime = module.verify(output)
    if not module.COMPILED <= expected.keys():
        fail('baseline lacks a required paired runtime member')
    for name in runtime.keys() & expected.keys():
        if name not in module.COMPILED and runtime[name] != expected[name]:
            fail('rebuilt runtime changed baseline data or symlinks: ' + name)
    replacements = {}
    for name in module.COMPILED:
        before, after = expected[name], runtime[name]
        if before[0] != 'file' or after[0] != 'file':
            fail('compiled runtime replacement must remain a regular file')
        replacements[name] = ('file', before[1], after[2], after[3], '-')
    return replacements


def verify(root: pathlib.Path, manifest: pathlib.Path, replacement_plugin: pathlib.Path | None,
           replacement_runtime: pathlib.Path | None = None) -> None:
    checked_root = validate_root(root)
    expected, raw_manifest = parse_manifest(manifest)
    if replacement_runtime is not None:
        expected.update(runtime_override_records(expected, replacement_runtime))
    if replacement_plugin is not None:
        expected[PLUGIN_PATH] = plugin_override_record(replacement_plugin)
    actual, total_size = inspect_tree(checked_root)
    if expected.keys() != actual.keys():
        missing = sorted(expected.keys() - actual.keys())
        extra = sorted(actual.keys() - expected.keys())
        fail(f"overlay tree membership mismatch: missing={missing} extra={extra}")
    for name, expected_record in expected.items():
        if actual[name] != expected_record:
            fail(
                f"overlay metadata/content mismatch for {name}: "
                f"expected={expected_record!r} actual={actual[name]!r}"
            )
    print("CAMERA_OVERLAY_VERIFY=PASS")
    print(f"manifest_sha256={hashlib.sha256(raw_manifest).hexdigest()}")
    print(f"entries={len(expected)}")
    print(f"bytes={total_size}")
    print(f"plugin_replaced={int(replacement_plugin is not None)}")
    print(f"runtime_replaced={int(replacement_runtime is not None)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--replacement-plugin", type=pathlib.Path)
    parser.add_argument("--replacement-runtime", type=pathlib.Path)
    arguments = parser.parse_args()
    verify(arguments.root, arguments.manifest, arguments.replacement_plugin, arguments.replacement_runtime)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError) as error:
        print(f"CAMERA_OVERLAY_VERIFY=FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
