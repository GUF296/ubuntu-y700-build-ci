#!/usr/bin/env python3
"""Create or verify the closed Camera producer artifact handoff."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import secrets
import stat
import sys
from dataclasses import dataclass


SCHEMA = "tb321fu.camera-artifact-handoff/v1"
MANIFEST_NAME = "CAMERA-HANDOFF.tsv"
REPORT_NAME = "tb321fu-camera-stack-build-report.txt"
CHECKSUM_NAME = "SHA256SUMS-tb321fu-camera-stack-debs.txt"
MAX_MANIFEST_BYTES = 64 * 1024
MAX_REPORT_BYTES = 4 * 1024 * 1024
MAX_CHECKSUM_BYTES = 1024
MAX_DEB_BYTES = 256 * 1024 * 1024
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^[0-9][0-9A-Za-z.+:~-]{0,63}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
DECIMAL = re.compile(r"^[1-9][0-9]*$")


class HandoffError(RuntimeError):
    pass


@dataclass(frozen=True)
class Context:
    enabled: str
    arch: str
    version: str
    repository: str
    commit: str
    run_id: str
    run_attempt: str
    source_archive: str
    source_archive_sha256: str
    source_directory: str

    @property
    def source_kind(self) -> str:
        if self.source_archive:
            return "archive"
        if self.source_directory:
            return "directory"
        return "repository"

    @property
    def deb_name(self) -> str:
        return f"tb321fu-camera-stack_{self.version}_{self.arch}.deb"

    @property
    def config_sha256(self) -> str:
        digest = hashlib.sha256()
        fields = (
            ("enabled", self.enabled),
            ("arch", self.arch),
            ("version", self.version),
            ("source_archive", self.source_archive),
            ("source_archive_sha256", self.source_archive_sha256),
            ("source_directory", self.source_directory),
        )
        for name, value in fields:
            encoded = value.encode("utf-8")
            digest.update(name.encode("ascii"))
            digest.update(b"\0")
            digest.update(str(len(encoded)).encode("ascii"))
            digest.update(b"\0")
            digest.update(encoded)
            digest.update(b"\0")
        return digest.hexdigest()


@dataclass(frozen=True)
class Member:
    name: str
    size: int
    sha256: str
    content: bytes | None


def fail(message: str) -> None:
    raise HandoffError(message)


def validate_plain_text(value: str, label: str, maximum: int = 4096) -> None:
    encoded = value.encode("utf-8")
    if len(encoded) > maximum:
        fail(f"{label} exceeds {maximum} encoded bytes")
    if any(byte < 0x20 or byte == 0x7F for byte in encoded):
        fail(f"{label} contains a control character")


def validate_context(context: Context) -> None:
    if context.enabled not in {"0", "1"}:
        fail("enabled must be 0 or 1")
    if context.arch != "arm64":
        fail("arch must be arm64")
    if not VERSION.fullmatch(context.version):
        fail("version is not a supported filename-safe Debian version")
    if not REPOSITORY.fullmatch(context.repository):
        fail("repository must be an owner/name pair")
    if not HEX40.fullmatch(context.commit):
        fail("commit must contain 40 lowercase hexadecimal characters")
    if not DECIMAL.fullmatch(context.run_id):
        fail("run-id must be a positive decimal integer")
    if not DECIMAL.fullmatch(context.run_attempt):
        fail("run-attempt must be a positive decimal integer")
    if context.source_archive and context.source_directory:
        fail("source archive and source directory are mutually exclusive")
    if context.source_archive_sha256 and not context.source_archive:
        fail("source archive SHA-256 requires a source archive")
    if context.source_archive_sha256 and not HEX64.fullmatch(
        context.source_archive_sha256
    ):
        fail("source archive SHA-256 must contain 64 lowercase hexadecimal characters")
    for label, value in (
        ("version", context.version),
        ("repository", context.repository),
        ("source archive", context.source_archive),
        ("source directory", context.source_directory),
    ):
        validate_plain_text(value, label)


def reject_symlink_ancestors(path: pathlib.Path) -> pathlib.Path:
    absolute = pathlib.Path(os.path.abspath(os.fspath(path)))
    current = pathlib.Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current /= component
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            fail(f"handoff path component is missing: {current}")
        if stat.S_ISLNK(info.st_mode):
            fail(f"handoff path contains a symlink component: {current}")
    return absolute


def identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_uid,
        info.st_gid,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def directory_binding(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_uid,
        info.st_gid,
        info.st_nlink,
    )


def open_root(path: pathlib.Path) -> tuple[pathlib.Path, int, os.stat_result]:
    absolute = reject_symlink_ancestors(path)
    flags = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(absolute, flags)
    except OSError as exc:
        fail(f"unable to open handoff directory: {exc}")
    info = os.fstat(descriptor)
    if not stat.S_ISDIR(info.st_mode):
        os.close(descriptor)
        fail("handoff root is not a directory")
    return absolute, descriptor, info


def validate_member_name(name: str) -> None:
    if not name or name in {".", ".."} or "/" in name or "\0" in name:
        fail(f"invalid handoff member name: {name!r}")
    validate_plain_text(name, "handoff member name", 255)


def read_member(
    root_fd: int,
    root_info: os.stat_result,
    name: str,
    maximum: int,
    *,
    collect: bool,
) -> Member:
    validate_member_name(name)
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=root_fd)
    except OSError as exc:
        fail(f"unable to open handoff member {name}: {exc}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail(f"handoff member is not a regular file: {name}")
        if before.st_nlink != 1:
            fail(f"handoff member has a hardlink alias: {name}")
        if before.st_uid != root_info.st_uid or before.st_gid != root_info.st_gid:
            fail(f"handoff member ownership differs from its directory: {name}")
        if stat.S_IMODE(before.st_mode) != 0o644:
            fail(f"handoff member mode is not 0644: {name}")
        if before.st_size < 0 or before.st_size > maximum:
            fail(f"handoff member exceeds its byte limit: {name}")
        digest = hashlib.sha256()
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                fail(f"handoff member exceeds its byte limit while reading: {name}")
            digest.update(chunk)
            if collect:
                chunks.append(chunk)
        after = os.fstat(descriptor)
        if identity(before) != identity(after) or total != before.st_size:
            fail(f"handoff member changed while it was read: {name}")
        rebound = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        if identity(after) != identity(rebound):
            fail(f"handoff member pathname changed while it was read: {name}")
        return Member(
            name=name,
            size=total,
            sha256=digest.hexdigest(),
            content=b"".join(chunks) if collect else None,
        )
    finally:
        os.close(descriptor)


def decode(member: Member, label: str) -> str:
    if member.content is None:
        fail(f"internal error: {label} content was not retained")
    try:
        return member.content.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"{label} is not valid UTF-8")


def parse_report(text: str, context: Context, deb_sha256: str) -> dict[str, str]:
    lines = text.splitlines()
    keys = (
        "TB321FU_CAMERA_STACK_DEB_BUILD",
        "version",
        "arch",
        "camera_input_kind",
        "deb",
        "camera_source_sha256",
        "camera_producer_manifest_sha256",
        "camera_toolchain_sha256",
        "camera_link_build_id",
        "camera_overlay_manifest_sha256",
        "camera_plugin_sha256",
    )
    if len(lines) < len(keys) + 2:
        fail("camera build report is missing its authenticated summary")
    values: dict[str, str] = {}
    for index, expected_key in enumerate(keys):
        key, separator, value = lines[index].partition("=")
        if not separator or key != expected_key or key in values:
            fail("camera build report summary has an unexpected key or order")
        values[key] = value
    expected = {
        "TB321FU_CAMERA_STACK_DEB_BUILD": "PASS",
        "version": context.version,
        "arch": context.arch,
        "camera_input_kind": context.source_kind,
        "deb": context.deb_name,
    }
    for key, value in expected.items():
        if values.get(key) != value:
            fail(f"camera build report {key} does not match the requested handoff")
    for key in (
        "camera_source_sha256",
        "camera_producer_manifest_sha256",
        "camera_toolchain_sha256",
        "camera_overlay_manifest_sha256",
        "camera_plugin_sha256",
    ):
        if not HEX64.fullmatch(values[key]):
            fail(f"camera build report {key} is not a SHA-256 value")
    if not HEX40.fullmatch(values["camera_link_build_id"]):
        fail("camera build report link build ID is malformed")
    if lines[len(keys)] != f"{deb_sha256}  {context.deb_name}":
        fail("camera build report DEB digest does not match the handoff payload")
    if lines[len(keys) + 1] != "":
        fail("camera build report summary is not terminated by a blank line")
    return values


def row(kind: str, name: str, value: str, digest: str = "-") -> tuple[str, ...]:
    for label, field in (
        ("manifest kind", kind),
        ("manifest name", name),
        ("manifest value", value),
        ("manifest digest", digest),
    ):
        validate_plain_text(field, label, 4096)
        if "\t" in field:
            fail(f"{label} contains a tab")
    return kind, name, value, digest


def inspect_payload(
    root_fd: int, root_info: os.stat_result, context: Context, report_name: str = REPORT_NAME
) -> tuple[list[tuple[str, ...]], set[str]]:
    rows = [
        row("schema", "format", SCHEMA),
        row("context", "enabled", context.enabled),
        row("context", "arch", context.arch),
        row("context", "version", context.version),
        row("context", "repository", context.repository),
        row("context", "commit", context.commit),
        row("context", "run_id", context.run_id),
        row("context", "run_attempt", context.run_attempt),
        row("context", "source_kind", context.source_kind),
        row("context", "source_config_sha256", context.config_sha256),
    ]
    if context.enabled == "0":
        return rows, set()

    deb = read_member(
        root_fd, root_info, context.deb_name, MAX_DEB_BYTES, collect=False
    )
    checksum = read_member(
        root_fd, root_info, CHECKSUM_NAME, MAX_CHECKSUM_BYTES, collect=True
    )
    report = read_member(
        root_fd, root_info, report_name, MAX_REPORT_BYTES, collect=True
    )
    checksum_text = decode(checksum, "camera checksum")
    if checksum_text != f"{deb.sha256}  {context.deb_name}\n":
        fail("camera checksum file does not bind exactly the handoff DEB")
    report_values = parse_report(decode(report, "camera build report"), context, deb.sha256)
    for name in (
        "camera_source_sha256",
        "camera_producer_manifest_sha256",
        "camera_toolchain_sha256",
        "camera_link_build_id",
        "camera_overlay_manifest_sha256",
        "camera_plugin_sha256",
    ):
        rows.append(row("metadata", name, report_values[name]))
    for member in sorted((deb, checksum, report), key=lambda item: item.name):
        rows.append(row("file", member.name, str(member.size), member.sha256))
    return rows, {context.deb_name, CHECKSUM_NAME, report_name}


def list_names(root_fd: int) -> set[str]:
    try:
        names = set(os.listdir(root_fd))
    except OSError as exc:
        fail(f"unable to enumerate handoff directory: {exc}")
    for name in names:
        validate_member_name(name)
    return names


def render_manifest(rows: list[tuple[str, ...]]) -> bytes:
    lines = ["kind\tname\tvalue\tsha256"]
    lines.extend("\t".join(fields) for fields in rows)
    return ("\n".join(lines) + "\n").encode("utf-8")


def parse_manifest(text: str) -> list[tuple[str, ...]]:
    lines = text.splitlines()
    if not lines or lines[0] != "kind\tname\tvalue\tsha256":
        fail("camera handoff manifest header mismatch")
    rows: list[tuple[str, ...]] = []
    seen: set[tuple[str, str]] = set()
    for line in lines[1:]:
        fields = tuple(line.split("\t"))
        if len(fields) != 4:
            fail("camera handoff manifest row does not have four fields")
        key = fields[0], fields[1]
        if key in seen:
            fail("camera handoff manifest contains a duplicate record")
        seen.add(key)
        rows.append(fields)
    return rows


def write_manifest(root_fd: int, payload: bytes) -> None:
    if len(payload) > MAX_MANIFEST_BYTES:
        fail("camera handoff manifest exceeds its byte limit")
    temporary = f".{MANIFEST_NAME}.tmp.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, 0o600, dir_fd=root_fd)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                fail("short write while creating camera handoff manifest")
            view = view[written:]
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o644)
        os.close(descriptor)
        descriptor = -1
        os.rename(temporary, MANIFEST_NAME, src_dir_fd=root_fd, dst_dir_fd=root_fd)
        os.fsync(root_fd)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=root_fd)
        except FileNotFoundError:
            pass


def create(directory: pathlib.Path, context: Context) -> None:
    _, root_fd, root_info = open_root(directory)
    try:
        before = directory_binding(root_info)
        rows, payload_names = inspect_payload(root_fd, root_info, context)
        if list_names(root_fd) != payload_names:
            fail("camera producer output contains an unexpected or missing member")
        write_manifest(root_fd, render_manifest(rows))
        if list_names(root_fd) != payload_names | {MANIFEST_NAME}:
            fail("camera handoff directory changed during manifest publication")
        if directory_binding(os.fstat(root_fd)) != before:
            fail("camera handoff directory identity changed during publication")
    finally:
        os.close(root_fd)


def verify(directory: pathlib.Path, context: Context) -> str:
    _, root_fd, root_info = open_root(directory)
    try:
        before = directory_binding(root_info)
        manifest = read_member(
            root_fd,
            root_info,
            MANIFEST_NAME,
            MAX_MANIFEST_BYTES,
            collect=True,
        )
        actual_rows = parse_manifest(decode(manifest, "camera handoff manifest"))
        expected_rows, payload_names = inspect_payload(root_fd, root_info, context)
        if actual_rows != expected_rows:
            fail("camera handoff manifest does not match its context or payload")
        if list_names(root_fd) != payload_names | {MANIFEST_NAME}:
            fail("camera handoff directory is not a closed member set")
        if directory_binding(os.fstat(root_fd)) != before:
            fail("camera handoff directory changed during verification")
        if context.enabled == "1":
            return next(r[3] for r in expected_rows if r[:2] == ("file", context.deb_name))
        return ""
    finally:
        os.close(root_fd)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("create", "verify"))
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--enabled", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--source-archive", default="")
    parser.add_argument("--source-archive-sha256", default="")
    parser.add_argument("--source-directory", default="")
    parser.add_argument("--print-deb-sha256", action="store_true",
                        help="verify only: emit the verified DEB digest (empty if disabled)")
    return parser.parse_args()


def main() -> int:
    options = arguments()
    context = Context(
        enabled=options.enabled,
        arch=options.arch,
        version=options.version,
        repository=options.repository,
        commit=options.commit,
        run_id=options.run_id,
        run_attempt=options.run_attempt,
        source_archive=options.source_archive,
        source_archive_sha256=options.source_archive_sha256,
        source_directory=options.source_directory,
    )
    try:
        validate_context(context)
        if options.mode == "create":
            if options.print_deb_sha256:
                fail("--print-deb-sha256 requires verify mode")
            create(options.directory, context)
            print("CAMERA_ARTIFACT_HANDOFF_CREATE=PASS")
        else:
            digest = verify(options.directory, context)
            print(digest if options.print_deb_sha256 else "CAMERA_ARTIFACT_HANDOFF_VERIFY=PASS")
    except (HandoffError, OSError) as exc:
        print(f"camera artifact handoff failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
