#!/usr/bin/env python3
"""Verify the raw archive contract of a TB321FU kernel-modules DEB."""

from __future__ import annotations

import argparse
import fcntl
import lzma
import os
import pathlib
import re
import signal
import stat
import sys
from dataclasses import dataclass


AR_MAGIC = b"!<arch>\n"
AR_HEADER_BYTES = 60
AR_TRAILER = b"`\n"
AR_MEMBER_NAMES = ("debian-binary", "control.tar.xz", "data.tar.xz")
AR_MODE = 0o100644
MAX_DEB_BYTES = 512 * 1024 * 1024
MAX_CONTROL_XZ_BYTES = 8 * 1024 * 1024
MAX_CONTROL_TAR_BYTES = 4 * 1024 * 1024
MAX_DATA_TAR_BYTES = 2 * 1024 * 1024 * 1024
MAX_TAR_FILE_BYTES = 512 * 1024 * 1024
MAX_TAR_PAYLOAD_BYTES = 2 * 1024 * 1024 * 1024
MAX_TAR_MEMBERS = 100_000
MAX_PATH_BYTES = 4096
MAX_COMPONENT_BYTES = 255
MAX_PATH_COMPONENTS = 128
MAX_XZ_RATIO = 200
XZ_RATIO_ALLOWANCE = 1024 * 1024
XZ_MEMORY_LIMIT = 256 * 1024 * 1024
IO_CHUNK = 1024 * 1024
TAR_BLOCK_BYTES = 512
TAR_RECORD_BYTES = 10 * 1024
PACKAGE = "y700-daily-kernel-modules"
ARCHITECTURE = "arm64"
KERNEL_RELEASE_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}")
PACKAGE_VERSION_RE = re.compile(r"[0-9][0-9A-Za-z.+~_-]{0,63}")
MODULE_PATH_RE = re.compile(r".+\.ko")
GNU_TAR_MAGIC = b"ustar  \x00"
GNU_LONGNAME = "././@LongLink"

MODULE_METADATA = {
    "modules.alias",
    "modules.alias.bin",
    "modules.builtin",
    "modules.builtin.alias.bin",
    "modules.builtin.bin",
    "modules.builtin.modinfo",
    "modules.dep",
    "modules.dep.bin",
    "modules.devname",
    "modules.order",
    "modules.softdep",
    "modules.symbols",
    "modules.symbols.bin",
}


class DebError(ValueError):
    """Raised when a DEB violates the canonical raw archive contract."""


@dataclass(frozen=True)
class ArMember:
    name: str
    offset: int
    size: int


def ascii_field(value: int, width: int, label: str) -> bytes:
    text = str(value)
    if len(text) > width:
        raise DebError(f"{label} does not fit its ar field")
    return text.encode("ascii").ljust(width, b" ")


def parse_canonical_decimal(raw: bytes, label: str) -> int:
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise DebError(f"ar {label} is not ASCII") from exc
    digits = text.rstrip(" ")
    if not digits or text != digits.ljust(len(text), " ") or not digits.isdecimal():
        raise DebError(f"ar {label} is not canonical decimal")
    if len(digits) > 1 and digits.startswith("0"):
        raise DebError(f"ar {label} has a leading zero")
    return int(digits, 10)


def read_exact(handle, size: int, label: str) -> bytes:
    data = handle.read(size)
    if len(data) != size:
        raise DebError(f"truncated {label}")
    return data


def parse_ar(
    handle, metadata: os.stat_result, source_date_epoch: int
) -> tuple[ArMember, ArMember, ArMember]:
    if not stat.S_ISREG(metadata.st_mode):
        raise DebError("kernel modules DEB must be a regular file")
    if metadata.st_size <= len(AR_MAGIC) or metadata.st_size > MAX_DEB_BYTES:
        raise DebError(f"kernel modules DEB size is outside 1..{MAX_DEB_BYTES} bytes")

    members: list[ArMember] = []
    handle.seek(0)
    if read_exact(handle, len(AR_MAGIC), "ar magic") != AR_MAGIC:
        raise DebError("kernel modules DEB lacks the ar archive magic")
    for index, expected_name in enumerate(AR_MEMBER_NAMES):
        header = read_exact(handle, AR_HEADER_BYTES, f"ar header {index + 1}")
        if header[58:60] != AR_TRAILER:
            raise DebError(f"invalid ar member trailer: {expected_name}")
        expected_raw_name = expected_name.encode("ascii").ljust(16, b" ")
        if header[0:16] != expected_raw_name:
            actual_name = header[0:16].decode("ascii", errors="replace").strip()
            raise DebError(
                f"ar member {index + 1} must be {expected_name}, found {actual_name!r}; "
                "GNU/BSD ar name extensions, duplicates, extras, and reordering are forbidden"
            )
        if header[16:28] != ascii_field(source_date_epoch, 12, "source date epoch"):
            raise DebError(f"ar member mtime mismatch: {expected_name}")
        if header[28:34] != ascii_field(0, 6, "uid"):
            raise DebError(f"ar member uid mismatch: {expected_name}")
        if header[34:40] != ascii_field(0, 6, "gid"):
            raise DebError(f"ar member gid mismatch: {expected_name}")
        expected_mode = f"{AR_MODE:o}".encode("ascii").ljust(8, b" ")
        if header[40:48] != expected_mode:
            raise DebError(f"ar member mode mismatch: {expected_name}")
        size = parse_canonical_decimal(header[48:58], f"size for {expected_name}")
        if header[48:58] != ascii_field(size, 10, f"size for {expected_name}"):
            raise DebError(f"ar member size is not canonical: {expected_name}")
        if expected_name == "debian-binary" and size != 4:
            raise DebError("debian-binary ar member must be exactly four bytes")
        if expected_name == "control.tar.xz" and not 1 <= size <= MAX_CONTROL_XZ_BYTES:
            raise DebError("control.tar.xz ar member exceeds its size bound")
        if expected_name == "data.tar.xz" and not 1 <= size <= MAX_DEB_BYTES:
            raise DebError("data.tar.xz ar member exceeds its size bound")
        offset = handle.tell()
        end = offset + size
        if end > metadata.st_size:
            raise DebError(f"truncated ar member payload: {expected_name}")
        if expected_name == "debian-binary":
            if read_exact(handle, size, "debian-binary payload") != b"2.0\n":
                raise DebError("debian-binary payload must be exactly b'2.0\\n'")
        else:
            prefix = read_exact(handle, min(size, 6), f"{expected_name} prefix")
            if prefix != b"\xfd7zXZ\x00":
                raise DebError(f"{expected_name} is not an XZ stream")
            handle.seek(end)
        if size % 2:
            if read_exact(handle, 1, f"ar padding for {expected_name}") != b"\n":
                raise DebError(f"ar member has non-canonical padding: {expected_name}")
        members.append(ArMember(expected_name, offset, size))
    if handle.read(1):
        raise DebError("ar archive contains extra members or trailing bytes")
    return tuple(members)  # type: ignore[return-value]


class XZMemberReader:
    """Bounded, single-stream XZ reader over one ar member."""

    def __init__(self, handle, member: ArMember, output_limit: int, sink=None):
        self._handle = handle
        self._handle.seek(member.offset)
        self._compressed_remaining = member.size
        self._compressed_read = 0
        self._output_limit = output_limit
        self._output_read = 0
        self._buffer = bytearray()
        self._finished = False
        self._sink = sink
        self._decoder = lzma.LZMADecompressor(
            format=lzma.FORMAT_XZ, memlimit=XZ_MEMORY_LIMIT
        )

    def __enter__(self) -> "XZMemberReader":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        return None

    @property
    def output_read(self) -> int:
        return self._output_read

    def _pump(self) -> None:
        if self._finished:
            return
        if self._decoder.eof:
            if self._decoder.unused_data or self._compressed_remaining:
                raise DebError("XZ member contains concatenated streams or trailing bytes")
            self._finished = True
            return

        if self._decoder.needs_input:
            if self._compressed_remaining == 0:
                raise DebError("truncated XZ stream")
            size = min(IO_CHUNK, self._compressed_remaining)
            compressed = read_exact(self._handle, size, "XZ member")
            self._compressed_remaining -= size
            self._compressed_read += size
        else:
            compressed = b""

        remaining_output = self._output_limit - self._output_read
        maximum = min(IO_CHUNK, max(1, remaining_output + 1))
        try:
            output = self._decoder.decompress(compressed, max_length=maximum)
        except lzma.LZMAError as exc:
            raise DebError(f"invalid or over-budget XZ stream: {exc}") from exc
        if output:
            self._output_read += len(output)
            if self._output_read > self._output_limit:
                raise DebError(f"decompressed tar exceeds {self._output_limit} bytes")
            ratio_limit = max(XZ_RATIO_ALLOWANCE, self._compressed_read * MAX_XZ_RATIO)
            if self._output_read > ratio_limit:
                raise DebError(f"XZ decompression ratio exceeds {MAX_XZ_RATIO}:1")
            if self._sink is not None:
                self._sink.write(output)
            self._buffer.extend(output)
        elif not self._decoder.needs_input and not self._decoder.eof:
            raise DebError("XZ decoder made no progress")

        if self._decoder.eof:
            if self._decoder.unused_data or self._compressed_remaining:
                raise DebError("XZ member contains concatenated streams or trailing bytes")
            self._finished = True

    def read(self, size: int) -> bytes:
        if size < 0:
            raise DebError("internal negative XZ read")
        while len(self._buffer) < size and not self._finished:
            self._pump()
        result = bytes(self._buffer[:size])
        del self._buffer[: len(result)]
        return result

    def read_exact(self, size: int, label: str) -> bytes:
        data = self.read(size)
        if len(data) != size:
            raise DebError(f"truncated {label}")
        return data

    def discard_exact(self, size: int, label: str) -> None:
        remaining = size
        while remaining:
            chunk = self.read(min(IO_CHUNK, remaining))
            if not chunk:
                raise DebError(f"truncated {label}")
            remaining -= len(chunk)

    def finish(self) -> None:
        while not self._finished or self._buffer:
            chunk = self.read(IO_CHUNK)
            if not chunk and self._finished:
                break
            if any(chunk):
                raise DebError("tar contains non-zero bytes after its end markers")


def parse_tar_octal(raw: bytes, width: int, label: str) -> int:
    if len(raw) != width or raw[-1:] != b"\x00":
        raise DebError(f"tar {label} is not canonical NUL-terminated octal")
    digits = raw[:-1]
    if any(byte not in b"01234567" for byte in digits):
        raise DebError(f"tar {label} uses a non-octal or base-256 value")
    return int(digits, 8)


def decode_nul_field(raw: bytes, label: str, *, allow_full: bool = False) -> str:
    nul = raw.find(b"\x00")
    if nul < 0:
        if not allow_full:
            raise DebError(f"tar {label} lacks NUL termination")
        content = raw
    else:
        content = raw[:nul]
        if any(raw[nul:]):
            raise DebError(f"tar {label} has non-zero bytes after NUL")
    try:
        return content.decode("ascii")
    except UnicodeDecodeError as exc:
        raise DebError(f"tar {label} is not ASCII") from exc


def canonical_path(raw: str, member_type: bytes) -> str:
    if raw == "./":
        if member_type != b"5":
            raise DebError("tar root member must be a directory")
        return ""
    if not raw.startswith("./") or "\\" in raw or "\x00" in raw:
        raise DebError(f"unsafe or non-canonical tar member path: {raw!r}")
    if member_type == b"5":
        if not raw.endswith("/"):
            raise DebError(f"tar directory path must end with '/': {raw!r}")
        value = raw[2:-1]
    else:
        if raw.endswith("/"):
            raise DebError(f"tar non-directory path must not end with '/': {raw!r}")
        value = raw[2:]
    encoded = value.encode("ascii")
    if not encoded or len(encoded) > MAX_PATH_BYTES:
        raise DebError(f"tar member path length is unsafe: {raw!r}")
    parts = value.split("/")
    if len(parts) > MAX_PATH_COMPONENTS:
        raise DebError(f"tar member path has too many components: {raw!r}")
    for part in parts:
        if (
            part in ("", ".", "..")
            or len(part.encode("ascii")) > MAX_COMPONENT_BYTES
            or any(ord(character) < 0x21 or ord(character) > 0x7E for character in part)
            or "\\" in part
        ):
            raise DebError(f"unsafe or non-canonical tar member path: {raw!r}")
    return value


def expected_control(package_version: str, kernel_release: str) -> bytes:
    return (
        f"Package: {PACKAGE}\n"
        f"Version: {package_version}\n"
        "Section: misc\n"
        "Priority: optional\n"
        f"Architecture: {ARCHITECTURE}\n"
        "Depends: kmod\n"
        "Maintainer: TB321FU Linux build <noreply@localhost>\n"
        f"Description: Lenovo TB321FU kernel modules for {kernel_release}.\n"
    ).encode("ascii")


def expected_postinst(kernel_release: str) -> bytes:
    return (
        "#!/bin/sh\n"
        "set -e\n"
        f"current_release='{kernel_release}'\n"
        "if command -v depmod >/dev/null 2>&1; then\n"
        "  depmod \"$current_release\"\n"
        "fi\n"
        "exit 0\n"
    ).encode("ascii")


def parent_path(path: str) -> str:
    return path.rsplit("/", 1)[0] if "/" in path else ""


def validate_header(
    header: bytes,
    label: str,
) -> tuple[str, int, int, int, bytes]:
    if len(header) != TAR_BLOCK_BYTES:
        raise DebError(f"truncated {label} tar header")
    checksum_field = header[148:156]
    if checksum_field[6:8] != b"\x00 " or any(
        byte not in b"01234567" for byte in checksum_field[:6]
    ):
        raise DebError(f"{label} tar checksum field is not canonical")
    stored_checksum = int(checksum_field[:6], 8)
    checksum_header = bytearray(header)
    checksum_header[148:156] = b" " * 8
    if sum(checksum_header) != stored_checksum:
        raise DebError(f"{label} tar header checksum mismatch")
    if header[257:265] != GNU_TAR_MAGIC:
        raise DebError(f"{label} tar must use the canonical dpkg GNU header magic")
    if any(header[345:512]):
        raise DebError(f"{label} tar uses a prefix or unsupported GNU/PAX metadata")
    if decode_nul_field(header[265:297], "uname") != "root":
        raise DebError(f"{label} tar uname must be root")
    if decode_nul_field(header[297:329], "gname") != "root":
        raise DebError(f"{label} tar gname must be root")
    if any(header[157:257]) or any(header[329:345]):
        raise DebError(f"{label} tar uses link or device metadata")
    mode = parse_tar_octal(header[100:108], 8, "mode")
    uid = parse_tar_octal(header[108:116], 8, "uid")
    gid = parse_tar_octal(header[116:124], 8, "gid")
    size = parse_tar_octal(header[124:136], 12, "size")
    mtime = parse_tar_octal(header[136:148], 12, "mtime")
    if uid != 0 or gid != 0:
        raise DebError(f"{label} tar member is not owned by root:root")
    name = decode_nul_field(header[0:100], "name", allow_full=True)
    return name, mode, size, mtime, header[156:157]


def verify_tar(
    handle,
    member: ArMember,
    label: str,
    output_limit: int,
    source_date_epoch: int,
    package_version: str,
    kernel_release: str,
    control_archive: bool,
    sink=None,
) -> None:
    expected_control_files = {
        "control": expected_control(package_version, kernel_release),
        "postinst": expected_postinst(kernel_release),
    }
    release_root = f"usr/lib/modules/{kernel_release}"
    kernel_root = f"{release_root}/kernel"
    required_directories = {"", "usr", "usr/lib", "usr/lib/modules", release_root, kernel_root}
    required_metadata = {f"{release_root}/{name}" for name in MODULE_METADATA}
    seen: set[str] = set()
    directories: set[str] = set()
    data_files: set[str] = set()
    module_count = 0
    total_payload = 0
    pending_longname: str | None = None
    logical_members = 0
    zero_blocks = 0

    with XZMemberReader(handle, member, output_limit, sink) as archive:
        while True:
            header = archive.read(TAR_BLOCK_BYTES)
            if not header:
                raise DebError(f"{label} tar lacks two zero end markers")
            if len(header) != TAR_BLOCK_BYTES:
                raise DebError(f"truncated {label} tar end marker")
            if not any(header):
                zero_blocks += 1
                if zero_blocks == 2:
                    if pending_longname is not None:
                        raise DebError(f"{label} tar ends after an orphan GNU LongLink")
                    archive.finish()
                    if archive.output_read % TAR_RECORD_BYTES:
                        raise DebError(f"{label} tar size is not a complete GNU tar record")
                    break
                continue
            if zero_blocks:
                raise DebError(f"{label} tar contains a member after a zero end marker")

            raw_name, mode, size, mtime, member_type = validate_header(header, label)
            if size > MAX_TAR_FILE_BYTES:
                raise DebError(f"{label} tar member exceeds {MAX_TAR_FILE_BYTES} bytes")

            if member_type == b"L":
                if pending_longname is not None:
                    raise DebError(f"{label} tar contains stacked GNU LongLink records")
                if (
                    raw_name != GNU_LONGNAME
                    or mode != 0o644
                    or mtime != 0
                    or not 2 <= size <= MAX_PATH_BYTES + 4
                ):
                    raise DebError(f"{label} tar contains non-canonical GNU LongLink metadata")
                payload = archive.read_exact(size, f"{label} GNU LongLink payload")
                if not payload.endswith(b"\x00") or b"\x00" in payload[:-1]:
                    raise DebError(f"{label} GNU LongLink payload is malformed")
                try:
                    pending_longname = payload[:-1].decode("ascii")
                except UnicodeDecodeError as exc:
                    raise DebError(f"{label} GNU LongLink path is not ASCII") from exc
                if len(payload) - 1 <= 100:
                    raise DebError(f"{label} tar uses an unnecessary GNU LongLink")
                padding = (-size) % TAR_BLOCK_BYTES
                if any(archive.read_exact(padding, f"{label} GNU LongLink padding")):
                    raise DebError(f"{label} GNU LongLink has non-zero padding")
                continue

            if member_type not in (b"0", b"5"):
                raise DebError(
                    f"{label} tar contains a forbidden PAX/GNU/sparse/special member type: "
                    f"{member_type!r}"
                )
            if mtime != source_date_epoch:
                raise DebError(f"{label} tar member mtime differs from SOURCE_DATE_EPOCH")
            if pending_longname is None:
                logical_name = raw_name
            else:
                encoded_longname = pending_longname.encode("ascii")
                if header[0:100] != encoded_longname[:100]:
                    raise DebError(f"{label} GNU LongLink does not match its following header")
                logical_name = pending_longname
                pending_longname = None
            name = canonical_path(logical_name, member_type)
            if name in seen:
                raise DebError(f"{label} tar contains duplicate logical member: {name or '.'}")
            if logical_members == 0 and name != "":
                raise DebError(f"{label} tar root directory must be its first logical member")
            logical_members += 1
            if logical_members > MAX_TAR_MEMBERS:
                raise DebError(f"{label} tar has more than {MAX_TAR_MEMBERS} logical members")
            seen.add(name)

            if member_type == b"5":
                if mode != 0o755 or size != 0:
                    raise DebError(f"{label} tar directory mode/size mismatch: {name or '.'}")
                if name and parent_path(name) not in directories:
                    raise DebError(f"{label} tar directory lacks an explicit parent: {name}")
                directories.add(name)
            else:
                expected_mode = 0o755 if control_archive and name == "postinst" else 0o644
                if mode != expected_mode:
                    raise DebError(
                        f"{label} tar regular file mode mismatch: {name}: "
                        f"expected {expected_mode:04o}, got {mode:04o}"
                    )
                if parent_path(name) not in directories:
                    raise DebError(f"{label} tar file lacks an explicit directory parent: {name}")
                total_payload += size
                if total_payload > MAX_TAR_PAYLOAD_BYTES:
                    raise DebError(f"{label} tar payload exceeds {MAX_TAR_PAYLOAD_BYTES} bytes")
                if control_archive:
                    expected = expected_control_files.get(name)
                    if expected is None:
                        raise DebError(f"{label} tar contains an unexpected control member: {name}")
                    raw = archive.read_exact(size, f"{label} payload {name}")
                    if raw != expected:
                        raise DebError(f"{label} {name} differs byte-for-byte from producer contract")
                else:
                    if name in required_metadata:
                        pass
                    elif name.startswith(kernel_root + "/") and MODULE_PATH_RE.fullmatch(name):
                        if size == 0:
                            raise DebError(f"{label} contains an empty kernel module: {name}")
                        module_count += 1
                    else:
                        raise DebError(f"{label} tar contains an unexpected payload path: {name}")
                    data_files.add(name)
                    archive.discard_exact(size, f"{label} payload {name}")
            padding = (-size) % TAR_BLOCK_BYTES
            if any(archive.read_exact(padding, f"{label} member padding")):
                raise DebError(f"{label} tar member has non-zero padding: {name or '.'}")

    if control_archive:
        expected_members = {"", *expected_control_files}
        if seen != expected_members:
            missing = sorted(expected_members - seen)
            extra = sorted(seen - expected_members)
            raise DebError(
                f"{label} tar member closure mismatch; missing={missing!r} extra={extra!r}"
            )
    else:
        expected_directories = {""}
        for data_file in data_files:
            directory = parent_path(data_file)
            while directory:
                expected_directories.add(directory)
                directory = parent_path(directory)
        missing_directories = sorted(expected_directories - directories)
        extra_directories = sorted(directories - expected_directories)
        missing_metadata = sorted(required_metadata - data_files)
        if missing_directories or extra_directories or missing_metadata or module_count == 0:
            raise DebError(
                f"{label} tar payload closure mismatch; missing_directories={missing_directories!r} "
                f"extra_directories={extra_directories!r} "
                f"missing_metadata={missing_metadata!r} module_count={module_count}"
            )
        if not required_directories <= directories:
            raise DebError(f"{label} tar lacks the canonical release directory spine")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the exact raw structure of a TB321FU kernel-modules DEB"
    )
    parser.add_argument("--deb", required=True, type=pathlib.Path)
    parser.add_argument("--kernel-release", required=True)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--source-date-epoch", required=True, type=int)
    parser.add_argument(
        "--output-directory",
        type=pathlib.Path,
        help="atomically publish verified control.tar and data.tar in this directory",
    )
    return parser.parse_args()


OUTPUT_NAMES = ("control.tar", "data.tar")


def fsync_directory(path: pathlib.Path) -> None:
    flags = os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise DebError(f"cannot open output directory for fsync {path}: {exc}") from exc
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def remove_private_transaction(path: pathlib.Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise DebError(f"cannot inspect private output transaction {path}: {exc}") from exc
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise DebError(f"private output transaction is not a real directory: {path}")
    try:
        entries = list(os.scandir(path))
    except OSError as exc:
        raise DebError(f"cannot inspect private output transaction {path}: {exc}") from exc
    if len(entries) > len(OUTPUT_NAMES):
        raise DebError(f"private output transaction has unexpected entries: {path}")
    for entry in entries:
        if entry.name not in OUTPUT_NAMES:
            raise DebError(f"private output transaction has an unexpected entry: {entry.name}")
        entry_metadata = entry.stat(follow_symlinks=False)
        if not stat.S_ISREG(entry_metadata.st_mode) or entry_metadata.st_nlink != 1:
            raise DebError(f"private output transaction entry is unsafe: {entry.name}")
    for entry in entries:
        os.unlink(entry.path)
    fsync_directory(path)
    path.rmdir()
    fsync_directory(path.parent)


def validate_published_directory(path: pathlib.Path) -> None:
    metadata = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_mode & 0o7777 != 0o755
    ):
        raise DebError(f"published raw tar output is not a mode-0755 real directory: {path}")
    entries = {entry.name: entry for entry in os.scandir(path)}
    if set(entries) != set(OUTPUT_NAMES):
        raise DebError(f"published raw tar output has the wrong namespace: {path}")
    for name, entry in entries.items():
        metadata = entry.stat(follow_symlinks=False)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o7777 != 0o644
        ):
            raise DebError(f"published raw tar output is unsafe: {name}")


def files_identical(left: pathlib.Path, right: pathlib.Path) -> bool:
    if left.stat().st_size != right.stat().st_size:
        return False
    with left.open("rb") as left_stream, right.open("rb") as right_stream:
        while True:
            left_chunk = left_stream.read(IO_CHUNK)
            right_chunk = right_stream.read(IO_CHUNK)
            if left_chunk != right_chunk:
                return False
            if not left_chunk:
                return True


def prepare_output_transaction(path: pathlib.Path):
    if not path.name or path.name in (".", "..") or any(
        ord(character) < 0x20 or ord(character) == 0x7F for character in path.name
    ):
        raise DebError("raw tar output directory has an unsafe name")
    parent = path.parent
    try:
        parent_metadata = parent.lstat()
    except OSError as exc:
        raise DebError(f"cannot inspect raw tar output parent {parent}: {exc}") from exc
    if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
        raise DebError(f"raw tar output parent must be a real directory: {parent}")

    lock_path = parent / f".{path.name}.lock"
    lock_flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
    lock_descriptor = os.open(lock_path, lock_flags, 0o600)
    lock_metadata = os.fstat(lock_descriptor)
    if not stat.S_ISREG(lock_metadata.st_mode) or lock_metadata.st_nlink != 1:
        os.close(lock_descriptor)
        raise DebError(f"raw tar output lock is unsafe: {lock_path}")
    os.fchmod(lock_descriptor, 0o600)
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(lock_descriptor)
        raise DebError(f"another raw tar output transaction is active: {path}") from exc

    staging = parent / f".{path.name}.transaction"
    streams = []
    try:
        remove_private_transaction(staging)
        existing = path.exists() or path.is_symlink()
        if existing:
            validate_published_directory(path)
        staging.mkdir(mode=0o700)
        for name in OUTPUT_NAMES:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
            flags |= getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(staging / name, flags, 0o600)
            streams.append(os.fdopen(descriptor, "wb"))
        return lock_descriptor, staging, streams, existing
    except Exception:
        for stream in streams:
            if not stream.closed:
                stream.close()
        remove_private_transaction(staging)
        os.close(lock_descriptor)
        raise


def commit_output_transaction(
    output: pathlib.Path,
    staging: pathlib.Path,
    streams: list,
    existing: bool,
) -> None:
    for stream in streams:
        stream.flush()
        os.fchmod(stream.fileno(), 0o644)
        os.fsync(stream.fileno())
        stream.close()
    os.chmod(staging, 0o755)
    fsync_directory(staging)

    if existing:
        validate_published_directory(output)
        for name in OUTPUT_NAMES:
            if not files_identical(staging / name, output / name):
                raise DebError(f"existing published raw tar differs from verified bytes: {name}")
        remove_private_transaction(staging)
        return

    fault = os.environ.get("TB321FU_TEST_MODULE_PROMOTION_KILL", "")
    if fault not in ("", "before-rename", "after-rename"):
        raise DebError("invalid module-promotion fault-injection point")
    if fault == "before-rename":
        os.kill(os.getpid(), signal.SIGKILL)
    os.rename(staging, output)
    fsync_directory(output.parent)
    if fault == "after-rename":
        os.kill(os.getpid(), signal.SIGKILL)
    validate_published_directory(output)


def main() -> int:
    args = parse_args()
    if KERNEL_RELEASE_RE.fullmatch(args.kernel_release) is None:
        raise DebError("unsafe kernel release")
    if PACKAGE_VERSION_RE.fullmatch(args.package_version) is None:
        raise DebError("unsafe package version")
    if args.package_version != args.kernel_release:
        raise DebError("package version must equal the canonical kernel release")
    if not 0 <= args.source_date_epoch <= 0o77777777777:
        raise DebError("SOURCE_DATE_EPOCH does not fit canonical ar/tar metadata")
    output_streams = []
    output_lock = None
    output_staging = None
    output_existing = False
    try:
        if args.output_directory is not None:
            (
                output_lock,
                output_staging,
                output_streams,
                output_existing,
            ) = prepare_output_transaction(args.output_directory)

        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(args.deb, flags)
        with os.fdopen(descriptor, "rb") as handle:
            metadata = os.fstat(handle.fileno())
            identity = (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_size,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
            )
            members = parse_ar(handle, metadata, args.source_date_epoch)
            verify_tar(
                handle,
                members[1],
                "kernel modules control",
                MAX_CONTROL_TAR_BYTES,
                args.source_date_epoch,
                args.package_version,
                args.kernel_release,
                True,
                output_streams[0] if output_streams else None,
            )
            verify_tar(
                handle,
                members[2],
                "kernel modules data",
                MAX_DATA_TAR_BYTES,
                args.source_date_epoch,
                args.package_version,
                args.kernel_release,
                False,
                output_streams[1] if output_streams else None,
            )
            final_metadata = os.fstat(handle.fileno())
            final_identity = (
                final_metadata.st_dev,
                final_metadata.st_ino,
                final_metadata.st_size,
                final_metadata.st_mtime_ns,
                final_metadata.st_ctime_ns,
            )
            if final_identity != identity:
                raise DebError("kernel modules DEB changed while it was being verified")

        if args.output_directory is not None:
            assert output_lock is not None and output_staging is not None
            commit_output_transaction(
                args.output_directory,
                output_staging,
                output_streams,
                output_existing,
            )
    except Exception:
        for stream in output_streams:
            if not stream.closed:
                stream.close()
        raise
    finally:
        if output_staging is not None:
            remove_private_transaction(output_staging)
        if output_lock is not None:
            os.close(output_lock)
    print("KERNEL_MODULES_DEB=PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DebError, OSError, UnicodeError) as error:
        print(f"kernel modules DEB rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
