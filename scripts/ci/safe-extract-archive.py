#!/usr/bin/env python3
"""Safely merge a tar or ZIP archive into a destination directory."""

from __future__ import annotations

import os
import shutil
import stat
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath


def clean_name(value: str) -> PurePosixPath:
    if not value or "\x00" in value or "\\" in value:
        raise ValueError(f"unsafe empty/NUL/backslash path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or (path.parts and ":" in path.parts[0]):
        raise ValueError(f"unsafe absolute/drive path: {value!r}")
    parts = tuple(part for part in path.parts if part not in ("", "."))
    if ".." in parts:
        raise ValueError(f"unsafe parent traversal: {value!r}")
    return PurePosixPath(*parts)


def link_is_contained(member: PurePosixPath, target: str, *, hardlink: bool) -> bool:
    if not target or "\x00" in target or "\\" in target:
        return False
    link = PurePosixPath(target)
    if link.is_absolute() or (link.parts and ":" in link.parts[0]):
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
    return True


def ensure_parent_contained(root: Path, target: Path) -> None:
    root_real = root.resolve(strict=True)
    parent_real = target.parent.resolve(strict=True)
    try:
        parent_real.relative_to(root_real)
    except ValueError as error:
        raise ValueError(f"destination parent escapes root: {target}") from error


def validate_tar(handle: tarfile.TarFile) -> list[tarfile.TarInfo]:
    result: list[tarfile.TarInfo] = []
    seen: set[PurePosixPath] = set()
    for member in handle.getmembers():
        name = clean_name(member.name)
        if not name.parts:
            continue
        if name in seen:
            raise ValueError(f"duplicate archive member: {member.name!r}")
        seen.add(name)
        if member.ischr() or member.isblk() or member.isfifo() or member.isdev():
            raise ValueError(f"unsupported special member: {member.name!r}")
        if not (member.isdir() or member.isreg() or member.issym() or member.islnk()):
            raise ValueError(f"unsupported member type: {member.name!r}")
        if member.issym() and not link_is_contained(name, member.linkname, hardlink=False):
            raise ValueError(f"unsafe symlink: {member.name!r} -> {member.linkname!r}")
        if member.islnk() and not link_is_contained(name, member.linkname, hardlink=True):
            raise ValueError(f"unsafe hardlink: {member.name!r} -> {member.linkname!r}")
        result.append(member)
    return result


def extract_tar(archive: Path, destination: Path) -> int:
    with tarfile.open(archive, mode="r:*") as handle:
        members = validate_tar(handle)
        # Python 3.12's data filter checks the resolved destination for every member,
        # including pre-existing symlink parents in merge destinations.
        handle.extractall(destination, members=members, filter="data")
    return len(members)


def zip_mode(info: zipfile.ZipInfo) -> int:
    return (info.external_attr >> 16) & 0xFFFF


def extract_zip(archive: Path, destination: Path) -> int:
    with zipfile.ZipFile(archive) as handle:
        entries: list[tuple[zipfile.ZipInfo, PurePosixPath, str | None]] = []
        seen: set[PurePosixPath] = set()
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
            if kind == stat.S_IFLNK:
                link_target = handle.read(info).decode("utf-8")
                if not link_is_contained(name, link_target, hardlink=False):
                    raise ValueError(f"unsafe ZIP symlink: {info.filename!r} -> {link_target!r}")
            elif kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f"unsupported ZIP member type: {info.filename!r}")
            entries.append((info, name, link_target))

        for info, name, link_target in entries:
            target = destination.joinpath(*name.parts)
            if info.is_dir() or stat.S_ISDIR(zip_mode(info)):
                target.mkdir(parents=True, exist_ok=True)
                ensure_parent_contained(destination, target)
            elif link_target is None:
                target.parent.mkdir(parents=True, exist_ok=True)
                ensure_parent_contained(destination, target)
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
            target.parent.mkdir(parents=True, exist_ok=True)
            ensure_parent_contained(destination, target)
            if target.exists() or target.is_symlink():
                target.unlink()
            target.symlink_to(link_target)
    return len(entries)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: safe-extract-archive.py ARCHIVE DESTINATION", file=sys.stderr)
        return 2
    archive = Path(sys.argv[1]).resolve(strict=True)
    destination = Path(sys.argv[2]).resolve(strict=False)
    if destination.exists() and not destination.is_dir():
        raise ValueError(f"destination is not a directory: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    if tarfile.is_tarfile(archive):
        count = extract_tar(archive, destination)
    elif zipfile.is_zipfile(archive):
        count = extract_zip(archive, destination)
    else:
        raise ValueError(f"unsupported archive format (tar/ZIP only): {archive}")
    print(f"PASS safely extracted {count} members: {archive} -> {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f"archive rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
