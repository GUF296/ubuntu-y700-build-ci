#!/usr/bin/env python3
"""Safely merge a tar or ZIP archive into a destination directory."""

from __future__ import annotations

import os
import shutil
import stat
import struct
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath


MIB = 1024 * 1024
GIB = 1024 * MIB


def positive_limit(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw, 10)
    except ValueError as error:
        raise ValueError(f"{name} must be a decimal integer: {raw!r}") from error
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


MAX_MEMBERS = positive_limit("SAFE_EXTRACT_MAX_MEMBERS", 200_000)
MAX_FILE_BYTES = positive_limit("SAFE_EXTRACT_MAX_FILE_BYTES", 8 * GIB)
MAX_TOTAL_BYTES = positive_limit("SAFE_EXTRACT_MAX_TOTAL_BYTES", 32 * GIB)
MAX_ARCHIVE_BYTES = positive_limit("SAFE_EXTRACT_MAX_ARCHIVE_BYTES", 64 * GIB)
MAX_COMPRESSION_RATIO = positive_limit("SAFE_EXTRACT_MAX_COMPRESSION_RATIO", 1_000)
MIN_FREE_BYTES = positive_limit("SAFE_EXTRACT_MIN_FREE_BYTES", 64 * MIB)
MAX_ZIP_DIRECTORY_BYTES = positive_limit(
    "SAFE_EXTRACT_MAX_ZIP_DIRECTORY_BYTES", 128 * MIB
)
MAX_EXTENSION_BYTES = positive_limit("SAFE_EXTRACT_MAX_EXTENSION_BYTES", MIB)
MAX_PATH_BYTES = 4_096
MAX_COMPONENT_BYTES = 255
MAX_PATH_COMPONENTS = 128
MAX_LINK_TARGET_BYTES = 4_096


def validate_archive_byte_budget(metadata: os.stat_result, archive: Path) -> int:
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"archive is not a regular file: {archive}")
    if metadata.st_size > MAX_ARCHIVE_BYTES:
        raise ValueError(
            f"archive exceeds compressed-byte limit: "
            f"{metadata.st_size} > {MAX_ARCHIVE_BYTES}"
        )
    return metadata.st_size


def clean_name(value: str) -> PurePosixPath:
    if not value or "\x00" in value or "\\" in value:
        raise ValueError(f"unsafe empty/NUL/backslash path: {value!r}")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise ValueError(f"archive path contains control characters: {value!r}")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ValueError(f"archive path is not UTF-8: {value!r}") from error
    if len(encoded) > MAX_PATH_BYTES:
        raise ValueError(f"archive path exceeds {MAX_PATH_BYTES} bytes: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or (path.parts and ":" in path.parts[0]):
        raise ValueError(f"unsafe absolute/drive path: {value!r}")
    parts = tuple(part for part in path.parts if part not in ("", "."))
    if ".." in parts:
        raise ValueError(f"unsafe parent traversal: {value!r}")
    if len(parts) > MAX_PATH_COMPONENTS:
        raise ValueError(
            f"archive path exceeds {MAX_PATH_COMPONENTS} components: {value!r}"
        )
    for part in parts:
        if len(part.encode("utf-8")) > MAX_COMPONENT_BYTES:
            raise ValueError(
                f"archive path component exceeds {MAX_COMPONENT_BYTES} bytes: {part!r}"
            )
    return PurePosixPath(*parts)


def link_is_contained(member: PurePosixPath, target: str, *, hardlink: bool) -> bool:
    if not target or "\x00" in target or "\\" in target:
        return False
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in target):
        return False
    try:
        encoded = target.encode("utf-8")
    except UnicodeEncodeError:
        return False
    if len(encoded) > MAX_LINK_TARGET_BYTES:
        return False
    link = PurePosixPath(target)
    if link.is_absolute() or (link.parts and ":" in link.parts[0]):
        return False
    if len(link.parts) > MAX_PATH_COMPONENTS:
        return False
    if any(len(part.encode("utf-8")) > MAX_COMPONENT_BYTES for part in link.parts):
        return False
    base = PurePosixPath() if hardlink else member.parent
    stack: list[str] = []
    for part in (base / link).parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not stack:
                return False
            stack.pop()
        else:
            stack.append(part)
            if len(stack) > MAX_PATH_COMPONENTS:
                return False
    return True


def ensure_contained(root: Path, candidate: Path, description: str) -> None:
    root_real = root.resolve(strict=True)
    candidate_real = candidate.resolve(strict=True)
    try:
        candidate_real.relative_to(root_real)
    except ValueError as error:
        raise ValueError(f"{description} escapes destination root: {candidate}") from error


def ensure_link_target_contained(root: Path, candidate: Path, description: str) -> None:
    """Check a link target after resolving existing symlink components.

    A ZIP symlink may intentionally be dangling, so unlike regular extraction
    paths its final target need not exist yet. ``strict=False`` still resolves
    every existing parent/component and therefore rejects a target that would
    dereference an already-present escaping symlink.
    """
    root_real = root.resolve(strict=True)
    try:
        candidate_real = candidate.resolve(strict=False)
    except (OSError, RuntimeError) as error:
        raise ValueError(f"{description} cannot be resolved safely: {candidate}") from error
    try:
        candidate_real.relative_to(root_real)
    except ValueError as error:
        raise ValueError(f"{description} escapes destination root: {candidate}") from error


def ensure_directory(root: Path, directory: Path) -> None:
    """Create a directory path without traversing an unchecked symlink parent."""
    root_real = root.resolve(strict=True)
    try:
        relative = directory.relative_to(root)
    except ValueError as error:
        raise ValueError(f"directory is outside destination root: {directory}") from error

    current = root
    for part in relative.parts:
        candidate = current / part
        if candidate.is_symlink():
            resolved = candidate.resolve(strict=True)
            try:
                resolved.relative_to(root_real)
            except ValueError as error:
                raise ValueError(f"destination symlink escapes root: {candidate}") from error
            if not resolved.is_dir():
                raise ValueError(f"destination symlink is not a directory: {candidate}")
            current = resolved
            continue
        if candidate.exists():
            if not candidate.is_dir():
                raise ValueError(f"destination ancestor is not a directory: {candidate}")
        else:
            candidate.mkdir(mode=0o755)
        current = candidate


def validate_resource_budget(
    archive_bytes: int, destination: Path, members: int, total_bytes: int
) -> None:
    if members > MAX_MEMBERS:
        raise ValueError(f"archive has too many members: {members} > {MAX_MEMBERS}")
    if total_bytes > MAX_TOTAL_BYTES:
        raise ValueError(
            f"archive expands beyond total limit: {total_bytes} > {MAX_TOTAL_BYTES}"
        )
    if total_bytes and archive_bytes == 0:
        raise ValueError("non-empty archive has zero compressed bytes")
    if archive_bytes and total_bytes > archive_bytes * MAX_COMPRESSION_RATIO:
        raise ValueError(
            "archive compression ratio exceeds limit: "
            f"{total_bytes}/{archive_bytes} > {MAX_COMPRESSION_RATIO}"
        )
    free_bytes = shutil.disk_usage(destination).free
    if total_bytes > max(0, free_bytes - MIN_FREE_BYTES):
        raise ValueError(
            f"archive needs {total_bytes} bytes but destination has only "
            f"{free_bytes} bytes free with a {MIN_FREE_BYTES}-byte reserve"
        )


def _read_exact(source, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = source.read(length - len(result))
        if not chunk:
            raise ValueError("tar extension record is truncated")
        result.extend(chunk)
    return bytes(result)


def _reject_sparse_pax(payload: bytes) -> None:
    offset = 0
    while offset < len(payload) and payload[offset] != 0:
        separator = payload.find(b" ", offset)
        if separator <= offset or not payload[offset:separator].isdigit():
            return
        length = int(payload[offset:separator], 10)
        end = offset + length
        if length < 5 or end > len(payload):
            return
        record = payload[separator + 1 : end]
        if not record.endswith(b"\n"):
            return
        key = record[:-1].split(b"=", 1)[0]
        if key.startswith(b"GNU.sparse."):
            raise ValueError("sparse TAR metadata is unsupported")
        offset = end


class BoundedTarInfo(tarfile.TarInfo):
    """Bound hidden TAR extension records before tarfile materializes them."""

    @staticmethod
    def _account_extension(handle: tarfile.TarFile, size: int) -> None:
        if size < 0 or size > MAX_EXTENSION_BYTES:
            raise ValueError(f"tar extension record exceeds {MAX_EXTENSION_BYTES} bytes")
        count = getattr(handle, "_safe_extension_count", 0) + 1
        total = getattr(handle, "_safe_extension_bytes", 0) + size
        if count > MAX_MEMBERS:
            raise ValueError("tar archive has too many extension records")
        if total > MAX_TOTAL_BYTES:
            raise ValueError("tar extension records exceed total size limit")
        handle._safe_extension_count = count
        handle._safe_extension_bytes = total

    def _proc_pax(self, handle: tarfile.TarFile):
        self._account_extension(handle, self.size)
        position = handle.fileobj.tell()
        payload = _read_exact(handle.fileobj, self._block(self.size))
        _reject_sparse_pax(payload[: self.size])
        try:
            handle.fileobj.seek(position)
        except (OSError, ValueError) as error:
            raise ValueError("tar extension stream cannot be rewound safely") from error
        return super()._proc_pax(handle)

    def _proc_gnulong(self, handle: tarfile.TarFile):
        self._account_extension(handle, self.size)
        return super()._proc_gnulong(handle)

    def _proc_sparse(self, handle: tarfile.TarFile):
        raise ValueError("sparse TAR members are unsupported")


def validate_tar(handle: tarfile.TarFile) -> tuple[list[tarfile.TarInfo], int]:
    result: list[tarfile.TarInfo] = []
    seen: set[PurePosixPath] = set()
    total_bytes = 0
    header_count = 0
    # Iterate headers instead of calling getmembers(), which materializes an
    # unbounded list before MAX_MEMBERS can be enforced.  Keep only the bounded
    # set needed by extractall().
    for member in handle:
        header_count += 1
        if header_count + getattr(handle, "_safe_extension_count", 0) > MAX_MEMBERS:
            raise ValueError("archive has too many members")
        name = clean_name(member.name)
        if not name.parts:
            continue
        if name in seen:
            raise ValueError(f"duplicate archive member: {member.name!r}")
        seen.add(name)
        if member.ischr() or member.isblk() or member.isfifo() or member.isdev():
            raise ValueError(f"unsupported special member: {member.name!r}")
        if getattr(member, "sparse", None):
            raise ValueError(f"sparse TAR member is unsupported: {member.name!r}")
        if not (member.isdir() or member.isreg() or member.issym() or member.islnk()):
            raise ValueError(f"unsupported member type: {member.name!r}")
        if member.size < 0 or member.size > MAX_FILE_BYTES:
            raise ValueError(f"archive member exceeds file limit: {member.name!r}")
        if member.isreg():
            total_bytes += member.size
            if total_bytes > MAX_TOTAL_BYTES:
                raise ValueError("archive expands beyond total size limit")
        if member.issym() and not link_is_contained(name, member.linkname, hardlink=False):
            raise ValueError(f"unsafe symlink: {member.name!r} -> {member.linkname!r}")
        if member.islnk():
            raise ValueError(f"tar hardlinks are unsupported: {member.name!r}")
        result.append(member)
    return result, total_bytes


def reject_preexisting_target_aliases(
    destination: Path, members: list[tuple[PurePosixPath, bool]]
) -> None:
    for name, directory in members:
        target = destination.joinpath(*name.parts)
        ensure_link_target_contained(destination, target.parent, "destination parent")
        try:
            metadata = target.lstat()
        except FileNotFoundError:
            continue
        if directory:
            continue
        if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
            raise ValueError(f"refusing to replace hard-linked destination file: {target}")


def extract_tar(handle: tarfile.TarFile, archive_bytes: int, destination: Path) -> int:
    members, total_bytes = validate_tar(handle)
    validate_resource_budget(archive_bytes, destination, len(members), total_bytes)
    reject_preexisting_target_aliases(
        destination,
        [(clean_name(member.name), member.isdir()) for member in members],
    )
    # Python 3.12's data filter checks the resolved destination for every member,
    # including pre-existing symlink parents in merge destinations.
    handle.extractall(destination, members=members, filter="data")
    return len(members)


def zip_mode(info: zipfile.ZipInfo) -> int:
    return (info.external_attr >> 16) & 0xFFFF


def _read_at(handle, archive_size: int, offset: int, length: int) -> bytes:
    if offset < 0 or length < 0 or offset > archive_size or length > archive_size - offset:
        raise zipfile.BadZipFile("ZIP metadata points outside the archive")
    handle.seek(offset)
    data = handle.read(length)
    if len(data) != length:
        raise zipfile.BadZipFile("truncated ZIP metadata")
    return data


ZIP_EOCD_SIGNATURE = b"PK\x05\x06"
ZIP64_EOCD_SIGNATURE = b"PK\x06\x06"
ZIP64_LOCATOR_SIGNATURE = b"PK\x06\x07"
ZIP_CENTRAL_SIGNATURE = b"PK\x01\x02"
ZIP_EOCD_SIZE = 22
ZIP64_EOCD_SIZE = 56
ZIP64_LOCATOR_SIZE = 20
ZIP_CENTRAL_FIXED_SIZE = 46


def _find_zip_eocd(handle, archive_size: int) -> int:
    """Find the one unambiguous EOCD whose comment terminates the archive."""
    tail_size = min(archive_size, ZIP_EOCD_SIZE + 0xFFFF)
    tail_start = archive_size - tail_size
    handle.seek(tail_start)
    tail = handle.read(tail_size)
    if len(tail) != tail_size:
        raise zipfile.BadZipFile("truncated ZIP end record search window")

    candidates: list[int] = []
    search_from = 0
    while True:
        relative = tail.find(ZIP_EOCD_SIGNATURE, search_from)
        if relative < 0:
            break
        if relative + ZIP_EOCD_SIZE <= len(tail):
            comment_size = struct.unpack_from("<H", tail, relative + 20)[0]
            if relative + ZIP_EOCD_SIZE + comment_size == len(tail):
                candidates.append(tail_start + relative)
        search_from = relative + 1

    if len(candidates) != 1:
        raise zipfile.BadZipFile("ZIP end record is missing or ambiguous")
    return candidates[0]


def _read_zip64_directory_fields(
    handle,
    archive_size: int,
    end_offset: int,
    classic_fields: tuple[int, int, int, int],
) -> tuple[int, int, int, int, int]:
    """Read and cross-check ZIP64 fields, returning counts, size, offset, anchor."""
    locator_offset = end_offset - ZIP64_LOCATOR_SIZE
    locator = _read_at(handle, archive_size, locator_offset, ZIP64_LOCATOR_SIZE)
    if locator[:4] != ZIP64_LOCATOR_SIGNATURE:
        raise zipfile.BadZipFile("ZIP64 locator is missing")
    locator_disk, relative_record_offset, total_disks = struct.unpack_from(
        "<IQI", locator, 4
    )
    if locator_disk != 0 or total_disks != 1:
        raise zipfile.BadZipFile("multi-disk ZIP64 archives are unsupported")

    expected_record_offset = locator_offset - ZIP64_EOCD_SIZE
    if relative_record_offset > expected_record_offset:
        raise zipfile.BadZipFile("ZIP64 locator points past its end record")
    record_offset = relative_record_offset
    record = _read_at(handle, archive_size, record_offset, ZIP64_EOCD_SIZE)
    if record[:4] != ZIP64_EOCD_SIGNATURE:
        # A prepended self-extracting stub shifts the logical offset. Match
        # Python's ZIP reader and use the physically implied record location.
        if record_offset == expected_record_offset:
            raise zipfile.BadZipFile("ZIP64 end record is missing")
        record_offset = expected_record_offset
        record = _read_at(handle, archive_size, record_offset, ZIP64_EOCD_SIZE)
    if record[:4] != ZIP64_EOCD_SIGNATURE:
        raise zipfile.BadZipFile("ZIP64 end record is missing")

    record_size = struct.unpack_from("<Q", record, 4)[0]
    if record_size < 44:
        raise zipfile.BadZipFile("ZIP64 end record is malformed")
    if record_size > archive_size - record_offset - 12:
        raise zipfile.BadZipFile("ZIP64 end record is truncated")
    if record_offset + 12 + record_size != locator_offset:
        raise zipfile.BadZipFile("ZIP64 end record does not meet its locator")

    (
        _signature,
        _size,
        _created_version,
        _needed_version,
        disk_number,
        directory_disk,
        entries_this_disk,
        entries_total,
        directory_size,
        directory_offset,
    ) = struct.unpack("<4sQHHIIQQQQ", record)
    if disk_number != 0 or directory_disk != 0 or entries_this_disk != entries_total:
        raise zipfile.BadZipFile("multi-disk ZIP64 archive metadata is unsupported")
    if directory_offset + directory_size != relative_record_offset:
        raise zipfile.BadZipFile("ZIP64 central-directory offsets disagree")

    classic_entries_this_disk, classic_entries_total, classic_size, classic_offset = (
        classic_fields
    )
    for classic, extended, sentinel in (
        (classic_entries_this_disk, entries_this_disk, classic_entries_this_disk == 0xFFFF),
        (classic_entries_total, entries_total, classic_entries_total == 0xFFFF),
        (classic_size, directory_size, classic_size == 0xFFFFFFFF),
        (classic_offset, directory_offset, classic_offset == 0xFFFFFFFF),
    ):
        if not sentinel and classic != extended:
            raise zipfile.BadZipFile("classic and ZIP64 directory metadata disagree")

    return entries_this_disk, entries_total, directory_size, directory_offset, record_offset


def _count_zip_central_directory(
    handle, directory_start: int, directory_size: int, expected_count: int
) -> int:
    """Count central records without constructing ZipInfo objects."""
    directory_end = directory_start + directory_size
    cursor = directory_start
    handle.seek(directory_start)
    count = 0
    while cursor < directory_end:
        remaining = directory_end - cursor
        if remaining < ZIP_CENTRAL_FIXED_SIZE:
            raise zipfile.BadZipFile("truncated ZIP central directory")
        fixed = handle.read(ZIP_CENTRAL_FIXED_SIZE)
        if len(fixed) != ZIP_CENTRAL_FIXED_SIZE:
            raise zipfile.BadZipFile("truncated ZIP central directory")
        if fixed[:4] != ZIP_CENTRAL_SIGNATURE:
            raise zipfile.BadZipFile("bad magic number for ZIP central directory")
        filename_size, extra_size, comment_size = struct.unpack_from("<HHH", fixed, 28)
        record_size = ZIP_CENTRAL_FIXED_SIZE + filename_size + extra_size + comment_size
        if record_size > remaining:
            raise zipfile.BadZipFile("ZIP central-directory record exceeds its span")
        variable = handle.read(record_size - ZIP_CENTRAL_FIXED_SIZE)
        if len(variable) != record_size - ZIP_CENTRAL_FIXED_SIZE:
            raise zipfile.BadZipFile("truncated ZIP central-directory record")
        cursor += record_size
        count += 1
        if count > expected_count or count > MAX_MEMBERS:
            raise ValueError("ZIP archive has too many central-directory members")
    if count != expected_count:
        raise zipfile.BadZipFile(
            "ZIP central-directory entry count disagrees with its end record"
        )
    return count


def validate_zip_directory_budget(handle, archive_size: int) -> None:
    """Reject oversized or inconsistent ZIP metadata before ZipFile opens it."""
    if archive_size < ZIP_EOCD_SIZE:
        raise zipfile.BadZipFile("ZIP is smaller than an end record")
    end_offset = _find_zip_eocd(handle, archive_size)
    end_record = _read_at(handle, archive_size, end_offset, ZIP_EOCD_SIZE)
    (
        _signature,
        disk_number,
        directory_disk,
        classic_entries_this_disk,
        classic_entries_total,
        classic_directory_size,
        classic_directory_offset,
        _comment_size,
    ) = struct.unpack("<4sHHHHIIH", end_record)
    if disk_number != 0 or directory_disk != 0:
        raise zipfile.BadZipFile("multi-disk ZIP archives are unsupported")
    if (
        classic_entries_this_disk != 0xFFFF
        and classic_entries_total != 0xFFFF
        and classic_entries_this_disk != classic_entries_total
    ):
        raise zipfile.BadZipFile("ZIP end-record member counts disagree")

    sentinel = (
        classic_entries_this_disk == 0xFFFF
        or classic_entries_total == 0xFFFF
        or classic_directory_size == 0xFFFFFFFF
        or classic_directory_offset == 0xFFFFFFFF
    )
    locator_present = (
        end_offset >= ZIP64_LOCATOR_SIZE
        and _read_at(handle, archive_size, end_offset - ZIP64_LOCATOR_SIZE, 4)
        == ZIP64_LOCATOR_SIGNATURE
    )
    if sentinel and not locator_present:
        raise zipfile.BadZipFile("ZIP64 locator is missing")

    anchor = end_offset
    if locator_present:
        (
            entries_this_disk,
            entries_total,
            directory_size,
            directory_offset,
            anchor,
        ) = _read_zip64_directory_fields(
            handle,
            archive_size,
            end_offset,
            (
                classic_entries_this_disk,
                classic_entries_total,
                classic_directory_size,
                classic_directory_offset,
            ),
        )
    else:
        entries_this_disk = classic_entries_this_disk
        entries_total = classic_entries_total
        directory_size = classic_directory_size
        directory_offset = classic_directory_offset

    if entries_this_disk != entries_total:
        raise zipfile.BadZipFile("ZIP member counts disagree")
    if entries_total > MAX_MEMBERS:
        raise ValueError("ZIP archive has too many members")
    if directory_size > MAX_ZIP_DIRECTORY_BYTES:
        raise ValueError("ZIP central directory exceeds metadata size limit")
    if directory_offset > archive_size or directory_size > archive_size - directory_offset:
        raise zipfile.BadZipFile("ZIP central directory is outside the archive")
    directory_start = anchor - directory_size
    if directory_start < 0 or directory_start < directory_offset:
        raise zipfile.BadZipFile("ZIP central directory has an invalid physical offset")
    _count_zip_central_directory(handle, directory_start, directory_size, entries_total)


def validate_zip_link_graph(
    entries: list[tuple[zipfile.ZipInfo, PurePosixPath, str | None]],
) -> None:
    """Validate every ZIP link after resolving links supplied by the archive.

    Checking a target against the destination before links are created misses a
    forward edge such as ``B -> A/../outside`` followed by ``A -> .``.  The
    second link makes the first edge leave the destination even though neither
    lexical target contains ``..`` at the archive root.  Resolve the complete
    in-archive graph in memory before writing any member.
    """

    links: dict[tuple[str, ...], tuple[str, ...]] = {
        tuple(name.parts): tuple(PurePosixPath(link_target).parts)
        for _info, name, link_target in entries
        if link_target is not None
    }

    def resolve(parts: tuple[str, ...], description: str) -> tuple[str, ...]:
        stack: list[str] = []
        pending = list(parts)
        follows = 0
        while pending:
            part = pending.pop(0)
            if part in ("", "."):
                continue
            if part == "..":
                if not stack:
                    raise ValueError(f"ZIP link graph escapes destination root: {description}")
                stack.pop()
                continue
            stack.append(part)
            target = links.get(tuple(stack))
            if target is None:
                continue
            follows += 1
            if follows > MAX_PATH_COMPONENTS:
                raise ValueError(f"ZIP link graph contains a cycle: {description}")
            stack.pop()
            pending[0:0] = list(target)
        return tuple(stack)

    for _info, name, link_target in entries:
        if link_target is None:
            continue
        parent = tuple(name.parent.parts)
        resolve(parent, f"{name} parent")
        resolve(parent + tuple(PurePosixPath(link_target).parts), f"{name} -> {link_target}")


def extract_zip(archive_file, archive_bytes: int, destination: Path) -> int:
    validate_zip_directory_budget(archive_file, archive_bytes)
    archive_file.seek(0)
    with zipfile.ZipFile(archive_file) as handle:
        entries: list[tuple[zipfile.ZipInfo, PurePosixPath, str | None]] = []
        seen: set[PurePosixPath] = set()
        total_bytes = 0
        for info in handle.infolist():
            if info.flag_bits & 0x1:
                raise ValueError(f"encrypted ZIP member is unsupported: {info.filename!r}")
            name = clean_name(info.filename)
            if not name.parts:
                continue
            if name in seen:
                raise ValueError(f"duplicate ZIP member: {info.filename!r}")
            seen.add(name)
            mode = zip_mode(info)
            kind = stat.S_IFMT(mode)
            link_target: str | None = None
            if info.file_size < 0 or info.file_size > MAX_FILE_BYTES:
                raise ValueError(f"ZIP member exceeds file limit: {info.filename!r}")
            if info.file_size and info.compress_size == 0:
                raise ValueError(f"ZIP member has impossible zero compressed size: {info.filename!r}")
            if info.compress_size and info.file_size > info.compress_size * MAX_COMPRESSION_RATIO:
                raise ValueError(f"ZIP member compression ratio exceeds limit: {info.filename!r}")
            if kind == stat.S_IFLNK:
                if info.file_size > MAX_LINK_TARGET_BYTES:
                    raise ValueError(f"ZIP symlink target is too large: {info.filename!r}")
                link_target = handle.read(info).decode("utf-8")
                if not link_is_contained(name, link_target, hardlink=False):
                    raise ValueError(f"unsafe ZIP symlink: {info.filename!r} -> {link_target!r}")
            elif kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f"unsupported ZIP member type: {info.filename!r}")
            entries.append((info, name, link_target))
            if link_target is None and not info.is_dir() and not stat.S_ISDIR(mode):
                total_bytes += info.file_size
                if total_bytes > MAX_TOTAL_BYTES:
                    raise ValueError("ZIP archive expands beyond total size limit")
            if len(entries) > MAX_MEMBERS:
                raise ValueError("ZIP archive has too many members")

        validate_zip_link_graph(entries)
        validate_resource_budget(archive_bytes, destination, len(entries), total_bytes)
        reject_preexisting_target_aliases(
            destination,
            [
                (name, info.is_dir() or stat.S_ISDIR(zip_mode(info)))
                for info, name, _link_target in entries
            ],
        )

        for info, name, link_target in entries:
            target = destination.joinpath(*name.parts)
            if info.is_dir() or stat.S_ISDIR(zip_mode(info)):
                ensure_directory(destination, target)
            elif link_target is None:
                ensure_directory(destination, target.parent)
                ensure_contained(destination, target.parent, "destination parent")
                if target.is_symlink():
                    target.unlink()
                elif target.exists() and not target.is_file():
                    raise ValueError(f"refusing to replace non-file: {target}")
                flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
                fd = os.open(target, flags, (zip_mode(info) & 0o777) or 0o644)
                with os.fdopen(fd, "wb") as output, handle.open(info) as source:
                    shutil.copyfileobj(source, output)
                os.chmod(target, (zip_mode(info) & 0o777) or 0o644)

        # Create links only after all directories and regular files, preventing a
        # later member from traversing a symlink introduced by the same archive.
        for _, name, link_target in entries:
            if link_target is None:
                continue
            target = destination.joinpath(*name.parts)
            ensure_directory(destination, target.parent)
            ensure_contained(destination, target.parent, "destination parent")
            ensure_link_target_contained(
                destination,
                target.parent / link_target,
                "ZIP symlink target",
            )
            if target.exists() or target.is_symlink():
                target.unlink()
            target.symlink_to(link_target)
    return len(entries)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: safe-extract-archive.py ARCHIVE DESTINATION", file=sys.stderr)
        return 2
    archive_input = Path(sys.argv[1])
    destination_input = Path(sys.argv[2])

    def reject_symlink_components(path: Path, description: str) -> None:
        absolute = path.absolute()
        current = Path(absolute.anchor)
        for component in absolute.parts[1:]:
            current /= component
            if current.is_symlink():
                raise ValueError(f"{description} contains a symlink component: {current}")

    reject_symlink_components(archive_input, "archive path")
    reject_symlink_components(destination_input, "destination path")
    destination = destination_input.resolve(strict=False)
    if destination_input.is_symlink():
        raise ValueError(f"destination must not be a symlink: {destination_input}")
    if destination.exists() and not destination.is_dir():
        raise ValueError(f"destination is not a directory: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or not destination.is_dir():
        raise ValueError(f"destination is not a real directory: {destination}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(archive_input, flags)
    with os.fdopen(descriptor, "rb") as archive_file:
        metadata = os.fstat(archive_file.fileno())
        archive_bytes = validate_archive_byte_budget(metadata, archive_input)
        identity = (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )
        archive_file.seek(0)
        try:
            tar_handle = tarfile.open(
                fileobj=archive_file, mode="r:*", tarinfo=BoundedTarInfo
            )
        except tarfile.ReadError:
            archive_file.seek(0)
            count = extract_zip(archive_file, archive_bytes, destination)
        else:
            with tar_handle:
                count = extract_tar(tar_handle, archive_bytes, destination)
        final_metadata = os.fstat(archive_file.fileno())
        final_identity = (
            final_metadata.st_dev,
            final_metadata.st_ino,
            final_metadata.st_size,
            final_metadata.st_mtime_ns,
            final_metadata.st_ctime_ns,
        )
        if final_identity != identity:
            raise ValueError("archive changed while it was being extracted")
    print(f"PASS safely extracted {count} members: {archive_input} -> {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f"archive rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
