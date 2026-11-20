#!/usr/bin/env python3
"""Verify a closed-world TB321FU Kbuild SDK archive and its manifest."""

from __future__ import annotations

import argparse
import bz2
import hashlib
import lzma
import os
import pathlib
import re
import stat
import sys
import tarfile
import time
import zlib
from dataclasses import dataclass
from pathlib import PurePosixPath


MAX_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 200_000
MAX_ARCHIVE_FILE_BYTES = 8 * 1024 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 32 * 1024 * 1024 * 1024
MAX_EXTENSION_BYTES = 1 * 1024 * 1024
MAX_COMPRESSION_RATIO = 1_000
MAX_PATH_BYTES = 4_096
MAX_COMPONENT_BYTES = 255
MAX_PATH_COMPONENTS = 128
MAX_LINK_TARGET_BYTES = 4_096
MAX_EXTRACTED_MEMBERS = MAX_ARCHIVE_MEMBERS
MAX_EXTRACTED_FILE_BYTES = MAX_ARCHIVE_FILE_BYTES
MAX_EXTRACTED_TOTAL_BYTES = MAX_ARCHIVE_TOTAL_BYTES
DIRECTORY_MODE = 0o755
SYMLINK_MODE = 0o777
FILE_MODES = {0o600, 0o644, 0o755}
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
SCHEMA_V1 = "tb321fu.kernel-sdk-manifest/v1"
SCHEMA_V2 = "tb321fu.kernel-sdk-manifest/v2"
SUPPORTED_SCHEMAS = frozenset({SCHEMA_V1, SCHEMA_V2})
DEFAULT_DEADLINE_SECONDS = 300
REQUIRED_FILES = (
    "./.config",
    "./Module.symvers",
    "./include/config/kernel.release",
    "./include/generated/autoconf.h",
    "./include/generated/utsrelease.h",
)
# The tested Kbuild SDK carries these two reviewed empty directory trees.
# Manifest v1 records only files and symlinks, so all directory headers in the
# trees are permitted beyond parents of manifest records, while descendants
# remain forbidden.
OPTIONAL_EMPTY_DIRECTORY_MEMBERS = frozenset(
    {
        "./arch",
        "./arch/arm64",
        "./arch/arm64/tools",
        "./scripts",
        "./scripts/kconfig",
        "./scripts/kconfig/lxdialog",
    }
)
OPTIONAL_EMPTY_DIRECTORY_ROOTS = frozenset(
    {
        "./arch/arm64/tools",
        "./scripts/kconfig/lxdialog",
    }
)


class SDKError(ValueError):
    """Raised when an SDK archive violates the release contract."""


ARCHIVE_READ_ERRORS = (
    OSError,
    tarfile.TarError,
    EOFError,
    ValueError,
    zlib.error,
    lzma.LZMAError,
)
VERIFICATION_ERRORS = (SDKError,) + ARCHIVE_READ_ERRORS


@dataclass(frozen=True)
class ManifestRecord:
    kind: str
    digest: str
    mode: int
    path: str


@dataclass(frozen=True)
class Manifest:
    schema: str
    records: dict[str, ManifestRecord]


def verification_deadline() -> float:
    raw = os.environ.get(
        "TB321FU_KERNEL_SDK_DEADLINE_SECONDS", str(DEFAULT_DEADLINE_SECONDS)
    )
    if re.fullmatch(r"[1-9][0-9]{0,3}", raw) is None:
        raise SDKError("TB321FU_KERNEL_SDK_DEADLINE_SECONDS must be 1..3600")
    seconds = int(raw, 10)
    if seconds > 3600:
        raise SDKError("TB321FU_KERNEL_SDK_DEADLINE_SECONDS must be 1..3600")
    return time.monotonic() + seconds


def check_deadline(deadline: float, label: str) -> None:
    if time.monotonic() >= deadline:
        raise SDKError(f"kernel SDK verification deadline exceeded while {label}")


def canonical_path(value: str, *, label: str) -> str:
    if not value or "\x00" in value or "\\" in value:
        raise SDKError(f"unsafe {label} path: {value!r}")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise SDKError(f"{label} path is not UTF-8") from exc
    if len(encoded) > MAX_PATH_BYTES:
        raise SDKError(f"{label} path exceeds {MAX_PATH_BYTES} bytes")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise SDKError(f"{label} path contains a control character")
    path = PurePosixPath(value)
    if path.is_absolute() or (path.parts and ":" in path.parts[0]):
        raise SDKError(f"unsafe absolute {label} path: {value!r}")
    parts = tuple(part for part in path.parts if part not in ("", "."))
    if ".." in parts:
        raise SDKError(f"unsafe parent traversal in {label} path: {value!r}")
    if not parts:
        raise SDKError(f"empty {label} path")
    if len(parts) > MAX_PATH_COMPONENTS:
        raise SDKError(f"{label} path exceeds {MAX_PATH_COMPONENTS} components")
    for part in parts:
        if len(part.encode("utf-8")) > MAX_COMPONENT_BYTES:
            raise SDKError(f"{label} path component exceeds {MAX_COMPONENT_BYTES} bytes: {part!r}")
    return "./" + "/".join(parts)


def root_source_path(path: str) -> bool:
    return path == "./source" or path.startswith("./source/")


def parse_manifest(path: pathlib.Path, deadline: float) -> Manifest:
    check_deadline(deadline, "opening the manifest")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise SDKError(f"cannot read SDK manifest {path}: {exc}") from exc
    try:
        with os.fdopen(descriptor, "rb") as source:
            manifest_stat = os.fstat(source.fileno())
            if not stat.S_ISREG(manifest_stat.st_mode):
                raise SDKError("SDK manifest must be a regular file")
            if manifest_stat.st_size > MAX_MANIFEST_BYTES:
                raise SDKError(f"SDK manifest exceeds {MAX_MANIFEST_BYTES} bytes")
            raw = source.read(MAX_MANIFEST_BYTES + 1)
            check_deadline(deadline, "reading the manifest")
            final_stat = os.fstat(source.fileno())
            identity = lambda value: (
                value.st_dev,
                value.st_ino,
                value.st_mode,
                value.st_size,
                value.st_mtime_ns,
                value.st_ctime_ns,
            )
            if identity(manifest_stat) != identity(final_stat):
                raise SDKError("SDK manifest changed while it was being read")
    except OSError as exc:
        raise SDKError(f"cannot read SDK manifest {path}: {exc}") from exc
    if len(raw) > MAX_MANIFEST_BYTES:
        raise SDKError(f"SDK manifest exceeds {MAX_MANIFEST_BYTES} bytes")
    if not raw.endswith(b"\n"):
        raise SDKError("SDK manifest must end with LF")
    if b"\r" in raw or b"\0" in raw:
        raise SDKError("SDK manifest contains CR or NUL")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise SDKError("SDK manifest must be ASCII") from exc

    lines = text.splitlines()
    if not lines or not lines[0].startswith("schema\t"):
        raise SDKError("SDK manifest first record must declare a supported schema")
    schema = lines[0].removeprefix("schema\t")
    if schema not in SUPPORTED_SCHEMAS:
        raise SDKError(f"SDK manifest has unsupported schema: {schema!r}")
    if len(lines) - 1 > MAX_ARCHIVE_MEMBERS:
        raise SDKError(f"SDK manifest has more than {MAX_ARCHIVE_MEMBERS} records")

    records: dict[str, ManifestRecord] = {}
    previous_path: str | None = None
    for number, line in enumerate(lines[1:], start=2):
        check_deadline(deadline, "parsing the manifest")
        if line.count("\t") != 3:
            raise SDKError(f"SDK manifest record {number} must contain exactly four fields")
        kind, digest, mode_text, raw_path = line.split("\t")
        allowed_kinds = {"file", "symlink"}
        if schema == SCHEMA_V2:
            allowed_kinds.add("directory")
        if kind not in allowed_kinds:
            raise SDKError(f"SDK manifest record {number} has unsupported type: {kind!r}")
        if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
            raise SDKError(f"SDK manifest record {number} has invalid SHA-256")
        if len(mode_text) not in (3, 4) or any(character not in "01234567" for character in mode_text):
            raise SDKError(f"SDK manifest record {number} has invalid mode")
        if mode_text.startswith("0"):
            raise SDKError(f"SDK manifest record {number} mode must not have a leading zero")
        if not raw_path.startswith("./"):
            raise SDKError(f"SDK manifest record {number} path must begin with ./")
        record_path = canonical_path(raw_path, label="SDK manifest")
        if record_path != raw_path:
            raise SDKError(f"SDK manifest record {number} path is not canonical")
        if schema == SCHEMA_V1 and (
            record_path in OPTIONAL_EMPTY_DIRECTORY_ROOTS
            or any(
                record_path.startswith(directory + "/")
                for directory in OPTIONAL_EMPTY_DIRECTORY_ROOTS
            )
        ):
            raise SDKError(
                "SDK manifest optional structural directories must remain empty: "
                f"{record_path}"
            )
        if root_source_path(record_path):
            raise SDKError("SDK manifest must not describe ./source")
        if previous_path is not None and record_path <= previous_path:
            raise SDKError("SDK manifest records must be strictly sorted by path")
        previous_path = record_path
        if record_path in records:
            raise SDKError(f"SDK manifest has duplicate path: {record_path}")
        records[record_path] = ManifestRecord(kind, digest, int(mode_text, 8), record_path)

        mode = int(mode_text, 8)
        if kind == "file" and mode not in FILE_MODES:
            raise SDKError(f"SDK manifest record {number} has unsupported file mode: {mode:o}")
        if kind == "symlink" and mode != SYMLINK_MODE:
            raise SDKError(f"SDK manifest record {number} symlink mode must be {SYMLINK_MODE:o}")
        if kind == "directory" and (mode != DIRECTORY_MODE or digest != EMPTY_SHA256):
            raise SDKError(
                f"SDK manifest record {number} directory must be mode {DIRECTORY_MODE:o} "
                "with the empty SHA-256"
            )

    for required in REQUIRED_FILES:
        record = records.get(required)
        if record is None or record.kind != "file":
            raise SDKError(f"SDK manifest is missing required regular file: {required}")
        if record.mode != 0o644:
            raise SDKError(f"SDK manifest required file mode must be 644: {required}")
    if schema == SCHEMA_V2:
        for record_path in records:
            check_deadline(deadline, "validating SDK v2 manifest parents")
            for parent in parent_paths(record_path):
                parent_record = records.get(parent)
                if parent_record is None or parent_record.kind != "directory":
                    raise SDKError(
                        "SDK v2 manifest path lacks an explicit directory parent: "
                        f"{record_path} via {parent}"
                    )
    check_deadline(deadline, "finishing manifest validation")
    return Manifest(schema, records)


def digest_stream(
    source,
    *,
    limit: int | None = None,
    deadline: float | None = None,
    label: str = "reading a stream",
) -> str:
    digest = hashlib.sha256()
    total = 0
    while True:
        if deadline is not None:
            check_deadline(deadline, label)
        chunk = source.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if limit is not None and total > limit:
            raise SDKError(f"stream exceeds {limit} bytes")
        digest.update(chunk)
    return digest.hexdigest()


def digest_link_target(target: str, *, label: str) -> str:
    try:
        encoded = target.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise SDKError(f"{label} symlink target is not UTF-8") from exc
    if len(encoded) > MAX_LINK_TARGET_BYTES:
        raise SDKError(f"{label} symlink target exceeds {MAX_LINK_TARGET_BYTES} bytes")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in target):
        raise SDKError(f"{label} symlink target contains a control character")
    return hashlib.sha256(encoded).hexdigest()


def resolve_contained_symlink(path: str, target: str) -> str | None:
    if not target or "\x00" in target or "\\" in target:
        return None
    parsed = PurePosixPath(target)
    if parsed.is_absolute() or (parsed.parts and ":" in parsed.parts[0]):
        return None
    try:
        encoded = target.encode("utf-8")
    except UnicodeEncodeError:
        return None
    if len(encoded) > MAX_LINK_TARGET_BYTES:
        return None
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in target):
        return None
    target_parts = tuple(part for part in parsed.parts if part not in ("", "."))
    if len(target_parts) > MAX_PATH_COMPONENTS:
        return None
    if any(len(part.encode("utf-8")) > MAX_COMPONENT_BYTES for part in target_parts):
        return None
    if ".." in target_parts:
        return None
    stack = list(PurePosixPath(path[2:]).parent.parts)
    for part in target_parts:
        stack.append(part)
        if len(stack) > MAX_PATH_COMPONENTS:
            return None
    return "./" + "/".join(stack) if stack else "."


def parent_paths(path: str) -> set[str]:
    parts = PurePosixPath(path[2:]).parts
    return {"./" + "/".join(parts[:depth]) for depth in range(1, len(parts))}


def structural_directories(
    records: dict[str, ManifestRecord], deadline: float
) -> set[str]:
    directories: set[str] = set()
    for path in records:
        check_deadline(deadline, "calculating structural directories")
        directories.update(parent_paths(path))
        if len(directories) > MAX_ARCHIVE_MEMBERS:
            raise SDKError("SDK namespace has too many structural directories")
    check_deadline(deadline, "finishing structural directory calculation")
    return directories


def require_exact_directory_members(
    records: dict[str, ManifestRecord],
    directories: set[str],
    deadline: float,
    *,
    label: str,
) -> None:
    required = structural_directories(records, deadline)
    missing = sorted(required - directories)
    check_deadline(deadline, f"comparing {label} required directories")
    unexpected = sorted(directories - required - OPTIONAL_EMPTY_DIRECTORY_MEMBERS)
    check_deadline(deadline, f"comparing {label} unexpected directories")
    if missing or unexpected:
        raise SDKError(
            f"{label} directory members differ from the SDK contract: "
            f"missing={missing!r} unexpected={unexpected!r}"
        )


def require_manifest_directory_members(
    manifest: Manifest, directories: set[str], deadline: float, *, label: str
) -> None:
    if manifest.schema == SCHEMA_V1:
        require_exact_directory_members(
            manifest.records, directories, deadline, label=label
        )
        return
    expected: set[str] = set()
    for path, record in manifest.records.items():
        check_deadline(deadline, f"collecting {label} manifest directories")
        if record.kind == "directory":
            expected.add(path)
    missing = sorted(expected - directories)
    check_deadline(deadline, f"comparing {label} manifest directories")
    unexpected = sorted(directories - expected)
    check_deadline(deadline, f"finishing {label} directory comparison")
    if missing or unexpected:
        raise SDKError(
            f"{label} directory members differ from the SDK v2 manifest: "
            f"missing={missing!r} unexpected={unexpected!r}"
        )


def require_manifest_records(
    manifest: Manifest,
    actual: dict[str, ManifestRecord],
    deadline: float,
    *,
    label: str,
) -> None:
    if manifest.schema == SCHEMA_V1:
        comparable: dict[str, ManifestRecord] = {}
        for path, record in actual.items():
            check_deadline(deadline, f"collecting {label} records")
            if record.kind != "directory":
                comparable[path] = record
    else:
        comparable = actual
    require_identical_records(manifest.records, comparable, deadline, label=label)


def validate_archive_namespace(
    member_kinds: dict[str, str],
    records: dict[str, ManifestRecord],
    link_targets: dict[str, str],
    deadline: float,
) -> None:
    known_directories = structural_directories(records, deadline) | {
        path for path, kind in member_kinds.items() if kind == "directory"
    }
    check_deadline(deadline, "collecting SDK namespace directories")

    for path, kind in member_kinds.items():
        check_deadline(deadline, "validating SDK namespace parents")
        for parent in parent_paths(path):
            parent_kind = member_kinds.get(parent)
            if parent_kind is not None and parent_kind != "directory":
                raise SDKError(
                    f"SDK archive member has a non-directory parent: {path} via {parent}"
                )

    resolved_cache: dict[str, str] = {}
    for path, target in link_targets.items():
        check_deadline(deadline, "validating SDK symlink namespace")
        chain: list[str] = []
        seen: set[str] = set()
        current = path
        while True:
            check_deadline(deadline, "resolving SDK symlink namespace")
            if current in resolved_cache:
                terminal = resolved_cache[current]
                break
            if current in seen:
                raise SDKError(f"SDK archive has a symlink cycle through: {current}")
            seen.add(current)
            chain.append(current)
            current_target = link_targets.get(current)
            if current_target is None:
                # The first iteration always has a target; subsequent iterations
                # reach this branch only for malformed namespace maps.
                terminal = current
                break
            resolved = resolve_contained_symlink(current, current_target)
            if resolved is None:
                raise SDKError(
                    f"SDK archive symlink escapes the direct root: {current} -> {current_target!r}"
                )
            if resolved == "." or resolved in known_directories:
                terminal = resolved
                break
            record = records.get(resolved)
            if record is None:
                raise SDKError(
                    f"SDK archive symlink has a dangling target: {path} -> {target!r}"
                )
            if record.kind == "file":
                terminal = resolved
                break
            current = resolved
        for link in chain:
            resolved_cache[link] = terminal
    check_deadline(deadline, "finishing SDK namespace validation")


class BoundedTarInfo(tarfile.TarInfo):
    """Bound GNU/PAX extension payloads before tarfile materializes them."""

    @staticmethod
    def _account_extension(handle: tarfile.TarFile, size: int) -> None:
        if size < 0 or size > MAX_EXTENSION_BYTES:
            raise SDKError(f"SDK archive extension payload exceeds {MAX_EXTENSION_BYTES} bytes")
        count = getattr(handle, "_sdk_extension_count", 0) + 1
        total = getattr(handle, "_sdk_extension_bytes", 0) + size
        if count > MAX_ARCHIVE_MEMBERS:
            raise SDKError("SDK archive has too many extension headers")
        if total > MAX_ARCHIVE_TOTAL_BYTES:
            raise SDKError("SDK archive extension payloads exceed the total size limit")
        handle._sdk_extension_count = count
        handle._sdk_extension_bytes = total

    def _proc_pax(self, handle: tarfile.TarFile):
        self._account_extension(handle, self.size)
        # The deterministic SDK contract has no PAX producer. Reject before
        # tarfile reads or interprets attacker-controlled extension payloads.
        raise SDKError("SDK archive uses unsupported PAX metadata")

    def _proc_gnulong(self, handle: tarfile.TarFile):
        self._account_extension(handle, self.size)
        return super()._proc_gnulong(handle)

    def _proc_sparse(self, handle: tarfile.TarFile):
        # tarfile otherwise follows an attacker-controlled sparse-extension
        # chain before the normal member validation loop sees this member.
        raise SDKError("SDK archive uses unsupported GNU sparse metadata")


class _TarTailScanner:
    """Consume a decompressed tar stream and reject bytes after its end marker."""

    _PAX_TYPES = (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.SOLARIS_XHDTYPE)
    _GNU_EXTENSION_TYPES = (tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK)

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.remaining = 0
        self.extension_count = 0
        self.extension_bytes = 0
        self.zero_blocks = 0
        self.ended = False
        self.total = 0

    def feed(self, data: bytes) -> None:
        self.total += len(data)
        if self.total > MAX_ARCHIVE_TOTAL_BYTES + MAX_ARCHIVE_MEMBERS * 1024 + 1024 * 1024:
            raise SDKError("SDK archive decompressed stream exceeds the safety limit")
        if self.ended:
            if data.strip(b"\0"):
                raise SDKError("SDK archive contains trailing data after the tar end marker")
            return
        self.buffer.extend(data)
        while True:
            if self.remaining:
                amount = min(self.remaining, len(self.buffer))
                del self.buffer[:amount]
                self.remaining -= amount
                if self.remaining:
                    return
                continue
            if len(self.buffer) < 512:
                return
            block = bytes(self.buffer[:512])
            del self.buffer[:512]
            if block == bytes(512):
                self.zero_blocks += 1
                if self.zero_blocks >= 2:
                    self.ended = True
                    if self.buffer and self.buffer.strip(b"\0"):
                        raise SDKError("SDK archive contains trailing data after the tar end marker")
                    self.buffer.clear()
                continue
            self.zero_blocks = 0
            member_type = block[156:157]
            if member_type == tarfile.GNUTYPE_SPARSE:
                raise SDKError("SDK archive uses unsupported GNU sparse metadata")
            try:
                size = tarfile.nti(block[124:136])
            except (TypeError, ValueError) as exc:
                raise SDKError("SDK archive has an invalid tar member size") from exc
            if size < 0:
                raise SDKError("SDK archive has a negative tar member size")
            if member_type in self._PAX_TYPES:
                raise SDKError("SDK archive uses unsupported PAX metadata")
            if member_type in self._GNU_EXTENSION_TYPES:
                if size > MAX_EXTENSION_BYTES:
                    raise SDKError(
                        f"SDK archive extension payload exceeds {MAX_EXTENSION_BYTES} bytes"
                    )
                self.extension_count += 1
                self.extension_bytes += size
                if self.extension_count > MAX_ARCHIVE_MEMBERS:
                    raise SDKError("SDK archive has too many extension headers")
                if self.extension_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                    raise SDKError(
                        "SDK archive extension payloads exceed the total size limit"
                    )
            self.remaining = ((size + 511) // 512) * 512

    def finish(self) -> None:
        if not self.ended or self.remaining or self.buffer:
            raise SDKError("SDK archive tar stream ended before its complete end marker")


def _feed_decompressed(
    decompressor, compressed: bytes, scanner: _TarTailScanner, deadline: float
) -> None:
    pending = compressed
    while True:
        check_deadline(deadline, "validating the compressed archive stream")
        try:
            output = decompressor.decompress(pending, 1024 * 1024)
        except TypeError as exc:
            raise SDKError("SDK archive decompressor lacks bounded output") from exc
        scanner.feed(output)
        if getattr(decompressor, "eof", False):
            if getattr(decompressor, "unused_data", b""):
                raise SDKError("SDK archive contains trailing compressed bytes")
            return
        unconsumed = getattr(decompressor, "unconsumed_tail", b"")
        if unconsumed:
            if unconsumed == pending and not output:
                raise SDKError("SDK archive decompressor made no progress")
            pending = unconsumed
            continue
        if not getattr(decompressor, "needs_input", True):
            if not output:
                raise SDKError("SDK archive decompressor made no progress")
            pending = b""
            continue
        return


def _strict_tar_stream(descriptor: int, archive_bytes: int, deadline: float) -> None:
    """Validate compression termination and tar trailing bytes on a pinned FD."""
    os.lseek(descriptor, 0, os.SEEK_SET)
    raw = os.fdopen(os.dup(descriptor), "rb")
    scanner = _TarTailScanner()
    try:
        prefix = raw.read(6)
        raw.seek(0)
        if prefix.startswith(b"\x1f\x8b"):
            decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        elif prefix.startswith(b"BZh"):
            decompressor = bz2.BZ2Decompressor()
        elif prefix.startswith(b"\xfd7zXZ\x00"):
            decompressor = lzma.LZMADecompressor()
        else:
            decompressor = None
        while True:
            check_deadline(deadline, "reading the compressed archive stream")
            chunk = raw.read(64 * 1024)
            if not chunk:
                break
            if decompressor is None:
                scanner.feed(chunk)
                continue
            try:
                _feed_decompressed(decompressor, chunk, scanner, deadline)
            except (OSError, EOFError, ValueError, zlib.error, lzma.LZMAError) as exc:
                if isinstance(exc, SDKError):
                    raise
                raise SDKError(f"SDK archive compression stream is corrupt: {exc}") from exc
            if getattr(decompressor, "eof", False) and getattr(decompressor, "unused_data", b""):
                raise SDKError("SDK archive contains trailing compressed bytes")
        if decompressor is not None and not getattr(decompressor, "eof", False):
            raise SDKError("SDK archive compression stream is truncated")
        scanner.finish()
    finally:
        raw.close()


def archive_records(
    archive: pathlib.Path, deadline: float
) -> tuple[dict[str, ManifestRecord], set[str]]:
    check_deadline(deadline, "opening the archive")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(archive, flags)
    except OSError as exc:
        raise SDKError(f"cannot open SDK archive {archive}: {exc}") from exc
    archive_file = os.fdopen(descriptor, "rb")
    metadata = os.fstat(archive_file.fileno())
    if not stat.S_ISREG(metadata.st_mode):
        archive_file.close()
        raise SDKError("SDK archive must be a regular file")
    archive_bytes = metadata.st_size
    identity = (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )
    if archive_bytes <= 0:
        archive_file.close()
        raise SDKError("SDK archive must be non-empty")
    if archive_bytes > MAX_ARCHIVE_BYTES:
        archive_file.close()
        raise SDKError(f"SDK archive exceeds {MAX_ARCHIVE_BYTES} compressed bytes")
    try:
        handle = tarfile.open(fileobj=archive_file, mode="r:*", tarinfo=BoundedTarInfo)
    except ARCHIVE_READ_ERRORS as exc:
        archive_file.close()
        raise SDKError(f"cannot read SDK archive {archive}: {exc}") from exc

    with archive_file, handle:
        records: dict[str, ManifestRecord] = {}
        candidates: set[str] = set()
        member_kinds: dict[str, str] = {}
        link_targets: dict[str, str] = {}
        directory_members: set[str] = set()
        total_bytes = 0
        member_count = 0
        root_header_seen = False
        members = iter(handle)
        while True:
            check_deadline(deadline, "walking archive members")
            try:
                member = next(members)
            except StopIteration:
                break
            except ARCHIVE_READ_ERRORS as exc:
                raise SDKError(f"cannot read SDK archive {archive}: {exc}") from exc
            member_count += 1
            if member_count + getattr(handle, "_sdk_extension_count", 0) > MAX_ARCHIVE_MEMBERS:
                raise SDKError(f"SDK archive has too many members: {member_count}")
            if member.name in ("", ".", "./"):
                if root_header_seen:
                    raise SDKError("SDK archive has duplicate root directory headers")
                root_header_seen = True
                if member.isdir():
                    if member.mode & 0o7777 != DIRECTORY_MODE:
                        raise SDKError(f"SDK archive root directory mode must be {DIRECTORY_MODE:o}")
                    continue
                raise SDKError("SDK archive root must be a directory")
            if not member.name.startswith("./"):
                raise SDKError(f"SDK archive member must begin with ./: {member.name!r}")
            member_path = canonical_path(member.name, label="SDK archive")
            if member_path in candidates:
                raise SDKError(f"SDK archive has duplicate member: {member_path}")
            candidates.add(member_path)
            if root_source_path(member_path):
                raise SDKError("SDK archive must not contain ./source")
            canonical_directory_name = (
                member_path + "/" if member_path != "./" else "./"
            )
            if member.isdir():
                if member.name not in {member_path, canonical_directory_name}:
                    raise SDKError(
                        f"SDK archive directory path is not canonical: {member.name!r}"
                    )
            elif member_path != member.name:
                raise SDKError(f"SDK archive member path is not canonical: {member.name!r}")
            if member_path in OPTIONAL_EMPTY_DIRECTORY_ROOTS and not member.isdir():
                raise SDKError(
                    "SDK archive optional structural roots must be directories: "
                    f"{member_path}"
                )
            if any(
                member_path.startswith(directory + "/")
                for directory in OPTIONAL_EMPTY_DIRECTORY_ROOTS
            ):
                raise SDKError(
                    "SDK archive optional structural directories must remain empty: "
                    f"{member_path}"
                )
            if member.islnk() or member.ischr() or member.isblk() or member.isfifo() or member.isdev():
                raise SDKError(f"SDK archive has unsupported member type: {member_path}")
            if member.isdir():
                if member.mode & 0o7777 != DIRECTORY_MODE:
                    raise SDKError(f"SDK archive directory mode must be {DIRECTORY_MODE:o}: {member_path}")
                records[member_path] = ManifestRecord(
                    "directory", EMPTY_SHA256, DIRECTORY_MODE, member_path
                )
                member_kinds[member_path] = "directory"
                directory_members.add(member_path)
                continue
            if member.isreg():
                if member.mode & 0o7777 not in FILE_MODES:
                    raise SDKError(f"SDK archive has unsupported file mode: {member_path}")
                if member.size < 0 or member.size > MAX_ARCHIVE_FILE_BYTES:
                    raise SDKError(f"SDK archive member exceeds size limit: {member_path}")
                total_bytes += member.size
                if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                    raise SDKError("SDK archive expands beyond the total size limit")
                try:
                    source = handle.extractfile(member)
                    if source is None:
                        raise SDKError(f"cannot read SDK archive member: {member_path}")
                    with source:
                        digest = digest_stream(
                            source,
                            limit=MAX_ARCHIVE_FILE_BYTES,
                            deadline=deadline,
                            label=f"hashing archive member {member_path}",
                        )
                except SDKError:
                    raise
                except ARCHIVE_READ_ERRORS as exc:
                    raise SDKError(
                        f"cannot read SDK archive member: {member_path}: {exc}"
                    ) from exc
                kind = "file"
            elif member.issym():
                if member.mode & 0o7777 != SYMLINK_MODE:
                    raise SDKError(f"SDK archive symlink mode must be {SYMLINK_MODE:o}: {member_path}")
                digest = digest_link_target(member.linkname, label="SDK archive")
                total_bytes += len(member.linkname.encode("utf-8"))
                if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                    raise SDKError("SDK archive expands beyond the total size limit")
                kind = "symlink"
                link_targets[member_path] = member.linkname
            else:
                raise SDKError(f"SDK archive has unsupported member type: {member_path}")
            if total_bytes > archive_bytes * MAX_COMPRESSION_RATIO:
                raise SDKError("SDK archive compression ratio exceeds the safety limit")
            records[member_path] = ManifestRecord(kind, digest, member.mode & 0o7777, member_path)
            member_kinds[member_path] = kind
        validate_archive_namespace(member_kinds, records, link_targets, deadline)
        _strict_tar_stream(archive_file.fileno(), archive_bytes, deadline)
        final_metadata = os.fstat(archive_file.fileno())
        final_identity = (
            final_metadata.st_dev,
            final_metadata.st_ino,
            final_metadata.st_size,
            final_metadata.st_mtime_ns,
            final_metadata.st_ctime_ns,
        )
        if final_identity != identity:
            raise SDKError("SDK archive changed while it was being verified")
        check_deadline(deadline, "finishing archive validation")
    return records, directory_members


def direct_root_candidates(
    records: dict[str, ManifestRecord], deadline: float
) -> set[str]:
    paths = set(records)
    check_deadline(deadline, "indexing SDK root candidates")
    candidates: set[str] = set()
    anchor = REQUIRED_FILES[0]
    anchor_suffix = anchor[1:]
    for path in paths:
        check_deadline(deadline, "discovering SDK root candidates")
        if path == anchor:
            candidate = "."
            prefix = ""
        elif path.endswith(anchor_suffix):
            candidate = path[: -len(anchor_suffix)]
            prefix = candidate[2:] + "/"
        else:
            continue
        required = {f"./{prefix}{required_path[2:]}" for required_path in REQUIRED_FILES}
        if required <= paths:
            candidates.add(candidate)
    check_deadline(deadline, "finishing SDK root discovery")
    return candidates


def _metadata_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _open_extracted_directory(parent_fd: int, name: str, path: str) -> tuple[int, os.stat_result]:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError as exc:
        raise SDKError(f"cannot open extracted SDK directory {path}: {exc}") from exc
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        os.close(descriptor)
        raise SDKError(f"extracted SDK member is not a real directory: {path}")
    return descriptor, metadata


def _extracted_regular_digest(
    parent_fd: int,
    name: str,
    path: str,
    initial: os.stat_result,
    deadline: float,
) -> str:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError as exc:
        raise SDKError(f"cannot open extracted SDK file: {path}: {exc}") from exc
    try:
        opened = os.fstat(descriptor)
        if _metadata_identity(opened) != _metadata_identity(initial):
            raise SDKError(f"extracted SDK file changed before reading: {path}")
        source = os.fdopen(descriptor, "rb")
        descriptor = -1
        try:
            digest = digest_stream(
                source,
                limit=MAX_EXTRACTED_FILE_BYTES,
                deadline=deadline,
                label=f"hashing extracted file {path}",
            )
            final = os.fstat(source.fileno())
            if _metadata_identity(final) != _metadata_identity(initial):
                raise SDKError(f"extracted SDK file changed while reading: {path}")
            return digest
        finally:
            source.close()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def extracted_records(
    root: pathlib.Path, deadline: float
) -> tuple[dict[str, ManifestRecord], set[str]]:
    check_deadline(deadline, "opening the extracted tree")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        root_fd = os.open(root, flags)
    except OSError as exc:
        raise SDKError(f"cannot open extracted SDK root {root}: {exc}") from exc
    try:
        root_stat = os.fstat(root_fd)
        if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
            raise SDKError("extracted SDK root must be a real directory")
        if root_stat.st_mode & 0o7777 != DIRECTORY_MODE:
            raise SDKError(f"extracted SDK root mode must be {DIRECTORY_MODE:o}")

        records: dict[str, ManifestRecord] = {}
        member_kinds: dict[str, str] = {}
        link_targets: dict[str, str] = {}
        directory_members: set[str] = set()
        member_count = 0
        total_bytes = 0

        def account_member(path: str, size: int = 0) -> None:
            nonlocal member_count, total_bytes
            if path in member_kinds:
                raise SDKError(f"extracted SDK has duplicate member: {path}")
            member_count += 1
            if member_count > MAX_EXTRACTED_MEMBERS:
                raise SDKError(f"extracted SDK has too many members: {member_count}")
            if size < 0 or size > MAX_EXTRACTED_FILE_BYTES:
                raise SDKError(f"extracted SDK member exceeds size limit: {path}")
            total_bytes += size
            if total_bytes > MAX_EXTRACTED_TOTAL_BYTES:
                raise SDKError("extracted SDK expands beyond the total size limit")

        def walk(directory_fd: int, prefix: tuple[str, ...]) -> None:
            nonlocal total_bytes
            check_deadline(deadline, "walking the extracted tree")
            before = os.fstat(directory_fd)
            try:
                entries = os.scandir(directory_fd)
            except OSError as exc:
                raise SDKError(
                    f"cannot enumerate extracted SDK directory {'/'.join(prefix)}: {exc}"
                ) from exc
            try:
                for entry in entries:
                    check_deadline(deadline, "walking extracted members")
                    name = entry.name
                    if name in ("", ".", "..") or "/" in name or "\\" in name:
                        raise SDKError(f"extracted SDK has an unsafe member name: {name!r}")
                    relative = "/".join((*prefix, name))
                    path = canonical_path(relative, label="extracted SDK")
                    if root_source_path(path):
                        raise SDKError("extracted SDK must not contain ./source")
                    try:
                        initial = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    except OSError as exc:
                        raise SDKError(f"cannot stat extracted SDK member {path}: {exc}") from exc
                    mode = initial.st_mode
                    if stat.S_ISLNK(mode):
                        try:
                            target = os.readlink(name, dir_fd=directory_fd)
                            final = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                        except OSError as exc:
                            raise SDKError(f"cannot read extracted SDK symlink {path}: {exc}") from exc
                        if _metadata_identity(final) != _metadata_identity(initial):
                            raise SDKError(f"extracted SDK symlink changed while reading: {path}")
                        account_member(path)
                        if resolve_contained_symlink(path, target) is None:
                            raise SDKError(
                                f"extracted SDK symlink escapes the direct root: {path} -> {target!r}"
                            )
                        if mode & 0o7777 != SYMLINK_MODE:
                            raise SDKError(
                                f"extracted SDK symlink mode must be {SYMLINK_MODE:o}: {path}"
                            )
                        records[path] = ManifestRecord(
                            "symlink", digest_link_target(target, label="extracted SDK"), mode & 0o7777, path
                        )
                        total_target_bytes = len(target.encode("utf-8"))
                        if total_target_bytes:
                            total_bytes += total_target_bytes
                            if total_bytes > MAX_EXTRACTED_TOTAL_BYTES:
                                raise SDKError(
                                    "extracted SDK expands beyond the total size limit"
                                )
                        member_kinds[path] = "symlink"
                        link_targets[path] = target
                    elif stat.S_ISDIR(mode):
                        if mode & 0o7777 != DIRECTORY_MODE:
                            raise SDKError(
                                f"extracted SDK directory mode must be {DIRECTORY_MODE:o}: {path}"
                            )
                        account_member(path)
                        records[path] = ManifestRecord(
                            "directory", EMPTY_SHA256, DIRECTORY_MODE, path
                        )
                        member_kinds[path] = "directory"
                        directory_members.add(path)
                        child_fd, child_stat = _open_extracted_directory(directory_fd, name, path)
                        if _metadata_identity(child_stat) != _metadata_identity(initial):
                            os.close(child_fd)
                            raise SDKError(f"extracted SDK directory changed before reading: {path}")
                        try:
                            walk(child_fd, (*prefix, name))
                        finally:
                            os.close(child_fd)
                    elif stat.S_ISREG(mode):
                        if mode & 0o7777 not in FILE_MODES:
                            raise SDKError(f"extracted SDK has unsupported file mode: {path}")
                        if initial.st_size > MAX_EXTRACTED_FILE_BYTES:
                            raise SDKError(f"extracted SDK member exceeds size limit: {path}")
                        if initial.st_nlink != 1:
                            raise SDKError(
                                f"extracted SDK has hard-linked regular file: {path}"
                            )
                        account_member(path, initial.st_size)
                        digest = _extracted_regular_digest(
                            directory_fd, name, path, initial, deadline
                        )
                        records[path] = ManifestRecord("file", digest, mode & 0o7777, path)
                        member_kinds[path] = "file"
                    else:
                        raise SDKError(f"extracted SDK has unsupported member type: {path}")
            finally:
                entries.close()
            after = os.fstat(directory_fd)
            if _metadata_identity(after) != _metadata_identity(before):
                raise SDKError(
                    f"extracted SDK directory changed while reading: {'/'.join(prefix) or '.'}"
                )

        walk(root_fd, ())
        final_root = os.fstat(root_fd)
        if _metadata_identity(final_root) != _metadata_identity(root_stat):
            raise SDKError("extracted SDK root changed while it was being verified")
        validate_archive_namespace(member_kinds, records, link_targets, deadline)
        check_deadline(deadline, "finishing extracted SDK validation")
        return records, directory_members
    finally:
        os.close(root_fd)


def validate_kernel_release_identity(
    records: dict[str, ManifestRecord], release: str, deadline: float
) -> None:
    check_deadline(deadline, "validating SDK release identity")
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}", release):
        raise SDKError(f"invalid expected kernel release: {release!r}")
    expected = {
        "./include/config/kernel.release": hashlib.sha256(f"{release}\n".encode("ascii")).hexdigest(),
        "./include/generated/utsrelease.h": hashlib.sha256(
            f'#define UTS_RELEASE "{release}"\n'.encode("ascii")
        ).hexdigest(),
    }
    for path, digest in expected.items():
        if records[path].digest != digest:
            raise SDKError(f"SDK release identity differs from expected kernel release: {path}")
    if records["./Module.symvers"].digest == EMPTY_SHA256:
        raise SDKError("SDK Module.symvers must be non-empty")
    check_deadline(deadline, "finishing SDK release identity validation")


def require_identical_records(
    expected: dict[str, ManifestRecord],
    actual: dict[str, ManifestRecord],
    deadline: float,
    *,
    label: str,
) -> None:
    check_deadline(deadline, f"indexing {label} records")
    expected_paths = set(expected)
    actual_paths = set(actual)
    check_deadline(deadline, f"comparing {label} paths")
    missing = sorted(expected_paths - actual_paths)
    check_deadline(deadline, f"sorting missing {label} paths")
    extra = sorted(actual_paths - expected_paths)
    check_deadline(deadline, f"sorting extra {label} paths")
    if missing or extra:
        raise SDKError(f"{label} paths differ from SDK manifest: missing={missing!r} extra={extra!r}")
    for path, expected_record in expected.items():
        check_deadline(deadline, f"comparing {label} records")
        actual_record = actual[path]
        if actual_record != expected_record:
            raise SDKError(
                f"{label} record differs from SDK manifest: {path} "
                f"expected={expected_record.kind}:{expected_record.digest}:{expected_record.mode:o} "
                f"actual={actual_record.kind}:{actual_record.digest}:{actual_record.mode:o}"
            )
    check_deadline(deadline, f"finishing {label} record comparison")


def verify_archive(
    archive: pathlib.Path,
    manifest_path: pathlib.Path,
    deadline: float,
    kernel_release: str | None = None,
) -> tuple[Manifest, set[str]]:
    manifest = parse_manifest(manifest_path, deadline)
    try:
        archived, archived_directories = archive_records(archive, deadline)
    except SDKError:
        raise
    except (OSError, tarfile.TarError, EOFError, ValueError, zlib.error) as exc:
        raise SDKError(f"cannot safely parse SDK archive {archive}: {exc}") from exc
    check_deadline(deadline, "starting archive contract comparison")
    roots = direct_root_candidates(archived, deadline)
    if roots != {"."}:
        raise SDKError(f"SDK archive must have exactly one direct Kbuild root, found {sorted(roots)!r}")
    require_manifest_records(manifest, archived, deadline, label="SDK archive")
    require_manifest_directory_members(
        manifest, archived_directories, deadline, label="SDK archive"
    )
    if kernel_release is not None:
        validate_kernel_release_identity(manifest.records, kernel_release, deadline)
    check_deadline(deadline, "finishing archive contract verification")
    return manifest, archived_directories


def verify(
    archive: pathlib.Path,
    manifest: pathlib.Path,
    extracted: pathlib.Path,
    deadline: float,
    kernel_release: str | None = None,
) -> None:
    expected, archived_directories = verify_archive(
        archive, manifest, deadline, kernel_release
    )
    extracted_records_map, extracted_directories = extracted_records(extracted, deadline)
    require_manifest_records(
        expected, extracted_records_map, deadline, label="extracted SDK"
    )
    require_manifest_directory_members(
        expected, extracted_directories, deadline, label="extracted SDK"
    )
    if extracted_directories != archived_directories:
        missing = sorted(archived_directories - extracted_directories)
        extra = sorted(extracted_directories - archived_directories)
        raise SDKError(
            "extracted SDK directory members differ from the archive: "
            f"missing={missing!r} extra={extra!r}"
        )
    check_deadline(deadline, "finishing extracted SDK comparison")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate a direct-root TB321FU Kbuild SDK archive against its external manifest."
    )
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("extracted_root", nargs="?", type=pathlib.Path)
    parser.add_argument("--kernel-release", help="bind SDK identity to this outer kernel release")
    parser.add_argument(
        "--archive-only",
        action="store_true",
        help="verify the archive and manifest before extraction",
    )
    args = parser.parse_args()
    try:
        deadline = verification_deadline()
        if args.archive_only:
            if args.extracted_root is not None:
                raise SDKError("--archive-only does not accept an extracted SDK root")
            verify_archive(args.archive, args.manifest, deadline, args.kernel_release)
        elif args.extracted_root is None:
            raise SDKError("an extracted SDK root is required without --archive-only")
        else:
            verify(
                args.archive,
                args.manifest,
                args.extracted_root,
                deadline,
                args.kernel_release,
            )
        check_deadline(deadline, "finishing kernel SDK verification")
    except VERIFICATION_ERRORS as exc:
        print(f"kernel SDK verification failed: {exc}", file=sys.stderr)
        return 1
    print("KERNEL_SDK=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
