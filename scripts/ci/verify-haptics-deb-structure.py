#!/usr/bin/env python3
"""Verify the exact ar and tar member contract of a TB321FU haptics DEB."""

from __future__ import annotations

import argparse
import os
import re
import resource
import subprocess
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path


AR_MAGIC = b"!<arch>\n"
AR_HEADER_BYTES = 60
AR_TRAILER = b"`\n"
ARCHIVE_MEMBER_RE = re.compile(r"^(control|data)\.tar\.(gz|xz|zst)$")
MAX_DEB_BYTES = 64 * 1024 * 1024
MAX_TAR_BYTES = 128 * 1024 * 1024
MAX_TAR_MEMBERS = 4096
MAX_HELPER_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class ArMember:
    name: str
    mtime: int
    uid: int
    gid: int
    mode: int
    payload: bytes


def parse_decimal(raw: bytes, label: str) -> int:
    text = raw.decode("ascii").strip()
    if not text or not text.isdecimal():
        raise ValueError(f"invalid ar {label}: {text!r}")
    return int(text, 10)


def parse_octal(raw: bytes, label: str) -> int:
    text = raw.decode("ascii").strip()
    if not text or any(char not in "01234567" for char in text):
        raise ValueError(f"invalid ar {label}: {text!r}")
    return int(text, 8)


def read_ar(path: Path) -> list[ArMember]:
    with path.open("rb") as handle:
        data = handle.read(MAX_DEB_BYTES + 1)
    if len(data) > MAX_DEB_BYTES:
        raise ValueError("haptics DEB exceeds size limit")
    if not data.startswith(AR_MAGIC):
        raise ValueError("haptics DEB lacks the ar archive magic")
    offset = len(AR_MAGIC)
    members: list[ArMember] = []
    while offset < len(data):
        if len(data) - offset < AR_HEADER_BYTES:
            raise ValueError("truncated ar member header")
        header = data[offset : offset + AR_HEADER_BYTES]
        offset += AR_HEADER_BYTES
        if header[58:60] != AR_TRAILER:
            raise ValueError("invalid ar member trailer")
        raw_name = header[0:16].decode("ascii").strip()
        if raw_name.startswith(("/", "#1/")):
            raise ValueError(f"extended ar member names are forbidden: {raw_name!r}")
        name = raw_name.removesuffix("/")
        size = parse_decimal(header[48:58], "size")
        end = offset + size
        if end > len(data):
            raise ValueError(f"truncated ar member payload: {name}")
        members.append(
            ArMember(
                name=name,
                mtime=parse_decimal(header[16:28], "mtime"),
                uid=parse_decimal(header[28:34], "uid"),
                gid=parse_decimal(header[34:40], "gid"),
                mode=parse_octal(header[40:48], "mode"),
                payload=data[offset:end],
            )
        )
        if size % 2 and data[end : end + 1] != b"\n":
            raise ValueError(f"invalid ar member padding: {name}")
        offset = end + (size % 2)
    if offset != len(data):
        raise ValueError("ar archive has trailing bytes")
    return members


def run_dpkg_tar(deb: Path, option: str, destination: Path) -> None:
    def limit_child_files() -> None:
        resource.setrlimit(
            resource.RLIMIT_FSIZE, (MAX_TAR_BYTES + 1, MAX_TAR_BYTES + 1)
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with temporary.open("wb") as stdout, tempfile.TemporaryFile() as stderr:
            try:
                subprocess.run(
                    ["dpkg-deb", option, str(deb)],
                    check=True,
                    stdout=stdout,
                    stderr=stderr,
                    timeout=30,
                    preexec_fn=limit_child_files,
                )
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                if stdout.tell() > MAX_TAR_BYTES:
                    raise ValueError(
                        f"decompressed tar exceeds size limit: {deb.name}"
                    ) from error
                stderr.seek(0)
                diagnostic = stderr.read(512)
                raise ValueError(
                    f"dpkg-deb failed for {deb.name}: "
                    f"{diagnostic.decode(errors='replace')}"
                ) from error
            if stdout.tell() > MAX_TAR_BYTES:
                raise ValueError(f"decompressed tar exceeds size limit: {deb.name}")
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def normalize_tar_name(raw: str) -> str:
    if raw in (".", "./"):
        return ""
    if not raw.startswith("./"):
        raise ValueError(f"tar member must use a ./ relative path: {raw!r}")
    name = raw[2:].rstrip("/")
    if not name or "\\" in name or "\x00" in name:
        raise ValueError(f"unsafe tar member path: {raw!r}")
    parts = name.split("/")
    if any(part in ("", ".", "..") or len(part.encode()) > 255 for part in parts):
        raise ValueError(f"unsafe tar member path: {raw!r}")
    if len(name.encode()) >= 4096:
        raise ValueError(f"overlong tar member path: {raw!r}")
    return name


def expected_control_members() -> dict[str, tuple[str, int]]:
    return {
        "": ("dir", 0o755),
        "control": ("file", 0o644),
        "postinst": ("file", 0o755),
        "postrm": ("file", 0o755),
    }


def expected_data_members(kernel_release: str) -> dict[str, tuple[str, int]]:
    directories = {
        "",
        "etc",
        "etc/skel",
        "etc/skel/.config",
        "usr",
        "usr/bin",
        "usr/lib",
        "usr/lib/firmware",
        "usr/lib/modules",
        f"usr/lib/modules/{kernel_release}",
        f"usr/lib/modules/{kernel_release}/extra",
        "usr/lib/systemd",
        "usr/lib/systemd/system",
        "usr/lib/udev",
        "usr/lib/udev/rules.d",
        "usr/libexec",
        "usr/libexec/tb321fu-haptics",
    }
    files = {
        "etc/skel/.config/plasmakeyboardrc": 0o644,
        "usr/bin/tb321fu-haptic-test": 0o755,
        "usr/lib/firmware/haptic_click.bin": 0o644,
        "usr/lib/firmware/haptic_ram.bin": 0o644,
        f"usr/lib/modules/{kernel_release}/extra/aw86937-haptics.ko": 0o644,
        "usr/lib/systemd/system/tb321fu-haptics.service": 0o644,
        "usr/lib/udev/rules.d/90-tb321fu-haptics.rules": 0o644,
        "usr/libexec/tb321fu-haptics/bind-aw86937": 0o755,
    }
    result = {name: ("dir", 0o755) for name in directories}
    result.update({name: ("file", mode) for name, mode in files.items()})
    return result


def verify_tar(
    path: Path,
    label: str,
    expected: dict[str, tuple[str, int]],
    source_date_epoch: int,
) -> None:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"{label} tar is not a regular file")
    if path.stat().st_size > MAX_TAR_BYTES:
        raise ValueError(f"{label} tar exceeds size limit")
    with tarfile.open(path, mode="r:") as archive:
        members = []
        for member in archive:
            if len(members) >= MAX_TAR_MEMBERS:
                raise ValueError(f"{label} tar has too many members")
            members.append(member)
        if archive.pax_headers:
            raise ValueError(f"{label} tar contains global PAX metadata")
    actual: dict[str, tarfile.TarInfo] = {}
    for member in members:
        if member.pax_headers:
            raise ValueError(f"{label} tar contains per-member PAX metadata")
        if member.sparse is not None:
            raise ValueError(f"{label} tar contains a sparse member")
        if member.name.endswith("/") and not member.isdir():
            raise ValueError(
                f"{label} non-directory member has a trailing slash: {member.name!r}"
            )
        name = normalize_tar_name(member.name)
        if name in actual:
            raise ValueError(f"{label} tar contains duplicate member: {name or '.'}")
        actual[name] = member
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        raise ValueError(
            f"{label} tar member set mismatch; missing={missing!r} extra={extra!r}"
        )
    for name, (kind, mode) in expected.items():
        member = actual[name]
        valid_type = member.isdir() if kind == "dir" else member.isreg()
        if not valid_type:
            raise ValueError(f"{label} member has wrong type: {name or '.'}")
        if member.mode & 0o7777 != mode:
            raise ValueError(
                f"{label} member has wrong mode: {name or '.'}: "
                f"expected {mode:04o}, got {member.mode & 0o7777:04o}"
            )
        if member.uid != 0 or member.gid != 0:
            raise ValueError(
                f"{label} member is not owned by root:root: {name or '.'}: "
                f"{member.uid}:{member.gid}"
            )
        if member.mtime != source_date_epoch:
            raise ValueError(
                f"{label} member has wrong mtime: {name or '.'}: "
                f"expected {source_date_epoch}, got {member.mtime}"
            )


def verify_aarch64_elf(raw: bytes, label: str) -> None:
    def integer(offset: int, size: int) -> int:
        return int.from_bytes(raw[offset : offset + size], "little")

    if (
        len(raw) < 64
        or raw[:4] != b"\x7fELF"
        or raw[4] != 2
        or raw[5] != 1
        or raw[6] != 1
        or integer(16, 2) not in (2, 3)
        or integer(18, 2) != 183
        or integer(20, 4) != 1
        or integer(52, 2) != 64
    ):
        raise ValueError(f"{label} is not AArch64 ELF")
    program_offset = integer(32, 8)
    program_entry_size = integer(54, 2)
    program_count = integer(56, 2)
    if (
        program_offset < 64
        or program_entry_size != 56
        or program_count < 1
        or program_count > 256
        or program_offset + program_entry_size * program_count > len(raw)
    ):
        raise ValueError(f"{label} has invalid ELF program headers")
    loadable = False
    substantive_load = False
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        if integer(offset, 4) != 1:
            continue
        file_offset = integer(offset + 8, 8)
        virtual_address = integer(offset + 16, 8)
        file_size = integer(offset + 32, 8)
        memory_size = integer(offset + 40, 8)
        alignment = integer(offset + 48, 8)
        if (
            file_offset > len(raw)
            or file_size > len(raw) - file_offset
            or memory_size == 0
            or file_size > memory_size
            or (alignment not in (0, 1) and alignment & (alignment - 1))
            or (
                alignment not in (0, 1)
                and virtual_address % alignment != file_offset % alignment
            )
        ):
            raise ValueError(f"{label} has an invalid ELF load segment")
        loadable = True
        substantive_load = substantive_load or file_size > 0
    if not loadable:
        raise ValueError(f"{label} has no ELF load segment")
    if not substantive_load:
        raise ValueError(f"{label} has no file-backed ELF load segment")


def verify_helper_elf(data_tar: Path) -> None:
    helper_name = "./usr/bin/tb321fu-haptic-test"
    with tarfile.open(data_tar, mode="r:") as archive:
        member = archive.getmember(helper_name)
        if member.size > MAX_HELPER_BYTES:
            raise ValueError("haptics helper exceeds size limit")
        handle = archive.extractfile(member)
        if handle is None:
            raise ValueError("cannot read haptics helper payload")
        raw = handle.read(MAX_HELPER_BYTES + 1)
    if len(raw) > MAX_HELPER_BYTES:
        raise ValueError("haptics helper exceeds size limit")
    verify_aarch64_elf(raw, "haptics helper")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--deb", required=True, type=Path)
    parser.add_argument("--control-tar", required=True, type=Path)
    parser.add_argument("--data-tar", required=True, type=Path)
    parser.add_argument("--kernel-release", required=True)
    parser.add_argument("--source-date-epoch", required=True, type=int)
    parser.add_argument("--extract-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.deb.is_file() or args.deb.is_symlink():
        raise ValueError("haptics DEB is not a regular file")
    members = read_ar(args.deb)
    if len(members) != 3:
        raise ValueError(f"haptics DEB must contain exactly three ar members, got {len(members)}")
    if members[0].name != "debian-binary" or members[0].payload != b"2.0\n":
        raise ValueError("haptics DEB has an invalid debian-binary member")
    if not ARCHIVE_MEMBER_RE.fullmatch(members[1].name) or not members[1].name.startswith("control.tar."):
        raise ValueError(f"unexpected haptics control member: {members[1].name}")
    if not ARCHIVE_MEMBER_RE.fullmatch(members[2].name) or not members[2].name.startswith("data.tar."):
        raise ValueError(f"unexpected haptics data member: {members[2].name}")
    for member in members:
        if member.uid != 0 or member.gid != 0 or member.mode & 0o7777 != 0o644:
            raise ValueError(
                f"haptics ar member metadata mismatch: {member.name}: "
                f"mode={member.mode & 0o7777:04o} owner={member.uid}:{member.gid}"
            )
        if member.mtime != args.source_date_epoch:
            raise ValueError(
                f"haptics ar member mtime mismatch: {member.name}: "
                f"expected {args.source_date_epoch}, got {member.mtime}"
            )
    run_dpkg_tar(args.deb, "--ctrl-tarfile", args.control_tar)
    run_dpkg_tar(args.deb, "--fsys-tarfile", args.data_tar)
    if args.extract_only:
        return 0
    verify_tar(
        args.control_tar,
        "haptics control",
        expected_control_members(),
        args.source_date_epoch,
    )
    verify_tar(
        args.data_tar,
        "haptics data",
        expected_data_members(args.kernel_release),
        args.source_date_epoch,
    )
    verify_helper_elf(args.data_tar)
    print("HAPTICS_DEB_STRUCTURE=PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValueError, tarfile.TarError) as error:
        print(f"haptics DEB rejected: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
