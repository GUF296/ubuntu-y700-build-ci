#!/usr/bin/env python3
"""Export the reviewed libcamera worktree as a deterministic, complete source input.

This is an operator-side export of a trusted checkout, not an approval of its
code. The committed archive/lock become CI inputs; no mutable worktree or
generated signing key is needed by the consumer.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import errno
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
from dataclasses import dataclass

DEFAULT_COMMIT = "2985ca6ac024ff89a077f088de49f7a69ab40d37"
EXTRA_FILES = (
    "include/libcamera/internal/camera_flash.h",
    "src/ipa/simple/data/gc13a0.yaml",
    "src/ipa/simple/data/sc202cs.yaml",
    "src/ipa/simple/data/sc820cs.yaml",
    "src/libcamera/camera_flash.cpp",
)
MAX_FILES = 5000
MAX_FILE_BYTES = 16 << 20
MAX_SOURCE_BYTES = 128 << 20
GIT_ENV = {
    "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TZ": "UTC",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
    "GIT_NO_LAZY_FETCH": "1",
}

class ExportError(RuntimeError):
    pass

@dataclass(frozen=True)
class Member:
    path: str
    kind: str
    mode: int
    data: bytes
    identity: tuple[int, ...] | None

def fingerprint(value: os.stat_result) -> tuple[int, ...]:
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def git(source: pathlib.Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(source), *arguments], env=GIT_ENV,
        stdin=subprocess.DEVNULL, capture_output=True, timeout=30, check=False,
    )
    if result.returncode != 0:
        raise ExportError("source Git query failed: " + " ".join(arguments))
    return result.stdout

def relative_path(name: str) -> tuple[str, ...]:
    parts = tuple(name.split("/"))
    if (not name or name.startswith("/") or len(name.encode()) > 4096
            or any(part in ("", ".", "..", ".git") for part in parts)
            or any(ord(char) < 32 or char == chr(127) for char in name)
            or len(parts) > 128 or "ipa-priv-key.pem" in parts):
        raise ExportError("unsafe or private source path")
    return parts

@contextlib.contextmanager
def parent_fd(root_fd: int, name: str):
    parts = relative_path(name)
    current = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                                | os.O_CLOEXEC, dir_fd=current)
            os.close(current)
            current = following
        yield current, parts[-1]
    finally:
        os.close(current)

def read_member(root_fd: int, name: str, mode: str) -> Member:
    with parent_fd(root_fd, name) as (parent, leaf):
        before = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        if mode == "120000":
            if not stat.S_ISLNK(before.st_mode):
                raise ExportError("source link type changed: " + name)
            target = os.readlink(leaf, dir_fd=parent)
            # The fixed source baseline has only two sibling LICENSES links.
            # Do not generalize this into accepting arbitrary link graphs.
            if ("/" in target or target in ("", ".", "..")
                    or any(ord(char) < 32 for char in target)):
                raise ExportError("unsupported source link target: " + name)
            data = target.encode("utf-8")
            kind, archive_mode = "symlink", 0o777
        else:
            archive_mode = 0o755 if mode == "100755" else 0o644
            if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                    or stat.S_IMODE(before.st_mode) != archive_mode
                    or before.st_size > MAX_FILE_BYTES):
                raise ExportError("source file type/mode/link/size mismatch: " + name)
            descriptor = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 dir_fd=parent)
            with os.fdopen(descriptor, "rb") as stream:
                if fingerprint(os.fstat(stream.fileno())) != fingerprint(before):
                    raise ExportError("source changed before capture: " + name)
                data = stream.read(MAX_FILE_BYTES + 1)
                if (len(data) != before.st_size or len(data) > MAX_FILE_BYTES
                        or fingerprint(os.fstat(stream.fileno())) != fingerprint(before)):
                    raise ExportError("source changed during capture: " + name)
            kind = "file"
        if fingerprint(os.stat(leaf, dir_fd=parent, follow_symlinks=False)) != fingerprint(before):
            raise ExportError("source namespace changed: " + name)
        return Member(name, kind, archive_mode, data, fingerprint(before))

def capture(source: pathlib.Path, commit: str) -> tuple[list[Member], int]:
    if source.is_symlink() or not source.is_dir():
        raise ExportError("source must be a real checkout directory")
    if git(source, "rev-parse", "HEAD").decode().strip() != commit:
        raise ExportError("source HEAD is not the explicitly selected commit")
    if (source / ".tarball-version").exists() or (source / ".tarball-version").is_symlink():
        raise ExportError("input checkout already contains a version override")
    git(source, "diff", "--cached", "--quiet", "--no-ext-diff", "HEAD")
    if pathlib.Path(git(source, "rev-parse", "--show-toplevel").decode().strip()).resolve() != source:
        raise ExportError("source is not the checkout root")
    tree = git(source, "ls-tree", "-rz", "HEAD")
    paths: dict[str, str] = {}
    for record in tree.split(bytes([0])):
        if not record:
            continue
        meta, raw_name = record.split(bytes([9]), 1)
        mode, kind, _oid = meta.decode("ascii").split()
        name = raw_name.decode("utf-8")
        relative_path(name)
        if mode not in ("100644", "100755", "120000") or kind != "blob":
            raise ExportError("unsupported tracked source member: " + name)
        paths[name] = mode
    for name in EXTRA_FILES:
        if name not in paths:
            paths[name] = "100644"
    if not 1 <= len(paths) <= MAX_FILES or ".tarball-version" in paths:
        raise ExportError("source member set is unsupported")
    root_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        root_identity = os.fstat(root_fd)
        members = []
        total = 0
        for name, mode in sorted(paths.items(), key=lambda item: item[0].encode()):
            member = read_member(root_fd, name, mode)
            total += len(member.data)
            if total > MAX_SOURCE_BYTES:
                raise ExportError("source snapshot exceeds total-size bound")
            members.append(member)
        by_name = {member.path: member for member in members}
        for member in members:
            if member.kind == "symlink":
                target = str(pathlib.PurePosixPath(member.path).parent / member.data.decode())
                if target not in by_name or by_name[target].kind != "file":
                    raise ExportError("source link has no regular in-tree target")
            with parent_fd(root_fd, member.path) as (parent, leaf):
                if fingerprint(os.stat(leaf, dir_fd=parent, follow_symlinks=False)) != member.identity:
                    raise ExportError("source drifted before export: " + member.path)
        current_root = source.stat(follow_symlinks=False)
        if (current_root.st_dev, current_root.st_ino) != (root_identity.st_dev, root_identity.st_ino):
            raise ExportError("source checkout root changed")
    finally:
        os.close(root_fd)
    if git(source, "rev-parse", "HEAD").decode().strip() != commit:
        raise ExportError("source HEAD changed during capture")
    epoch = int(git(source, "show", "-s", "--format=%ct", commit).strip())
    if epoch < 0:
        raise ExportError("invalid source epoch")
    meson = by_name.get("meson.build")
    if meson is None or b"version : '0.7.1'" not in meson.data:
        raise ExportError("source is not the approved libcamera 0.7.1 profile")
    return members, epoch

def manifest(members: list[Member]) -> bytes:
    rows = ["path\ttype\tmode\tsize\tsha256\tlink_target"]
    for member in sorted(members, key=lambda item: item.path.encode()):
        target = member.data.decode() if member.kind == "symlink" else "-"
        sha = "-" if member.kind == "symlink" else digest(member.data)
        rows.append("\t".join((member.path, member.kind, f"0{member.mode:o}",
                               str(len(member.data)), sha, target)))
    return ("\n".join(rows) + "\n").encode()

def promote(staging: pathlib.Path, output: pathlib.Path) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    rename = getattr(library, "renameat2", None)
    if rename is None:
        raise ExportError("atomic no-clobber source export requires renameat2")
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(staging), -100, os.fsencode(output), 1) != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise ExportError("output appeared during export; it was not overwritten")
        raise OSError(code, os.strerror(code))

def export_source(source: pathlib.Path, output: pathlib.Path, commit: str) -> dict:
    source = source.absolute()
    output = output.absolute()
    if output.name in ("", ".", ".."):
        raise ExportError("invalid output directory name")
    output = output.parent.resolve(strict=True) / output.name
    if output.exists() or output.is_symlink():
        raise ExportError("source export output must not already exist")
    if output.is_relative_to(source.resolve()):
        raise ExportError("source export must be outside its input checkout")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ExportError("source commit must be a complete lowercase object id")
    members, epoch = capture(source, commit)
    source_digest = digest(manifest(members))
    version = "0.7.1+tb321fu." + source_digest[:16]
    members.append(Member(".tarball-version", "file", 0o644, (version + "\n").encode(), None))
    member_manifest = manifest(members)
    staging = pathlib.Path(tempfile.mkdtemp(prefix=".libcamera-source-export.", dir=output.parent))
    try:
        archive = staging / "libcamera-source.tar.xz"
        with tarfile.open(archive, "w:xz", format=tarfile.PAX_FORMAT, preset=6) as bundle:
            directories = {"libcamera"}
            for member in members:
                directories.update(str(parent) for parent in
                                   pathlib.PurePosixPath("libcamera", member.path).parents
                                   if str(parent) != ".")
            entries = [(name, None) for name in directories]
            entries.extend(("libcamera/" + member.path, member) for member in members)
            for name, member in sorted(entries, key=lambda item: item[0].encode()):
                info = tarfile.TarInfo(name)
                info.mtime = epoch
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                if member is None:
                    info.type, info.mode = tarfile.DIRTYPE, 0o755
                    bundle.addfile(info)
                elif member.kind == "symlink":
                    info.type, info.mode, info.linkname = tarfile.SYMTYPE, 0o777, member.data.decode()
                    bundle.addfile(info)
                else:
                    info.mode, info.size = member.mode, len(member.data)
                    bundle.addfile(info, io.BytesIO(member.data))
        (staging / "SOURCE-MANIFEST.tsv").write_bytes(member_manifest)
        lock = {
            "schema": "tb321fu-libcamera-source-v1", "git_head": commit,
            "source_kind": "worktree-snapshot", "source_epoch": epoch,
            "source_tree_sha256": source_digest, "version": version,
            "archive": archive.name, "archive_sha256": digest(archive.read_bytes()),
            "archive_bytes": archive.stat().st_size,
            "manifest_sha256": digest(member_manifest), "members": len(members),
            "extra_source_paths": list(EXTRA_FILES),
        }
        (staging / "SOURCE-LOCK.json").write_text(
            json.dumps(lock, ensure_ascii=True, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
        for item in staging.iterdir():
            item.chmod(0o644)
            with item.open("rb") as stream:
                os.fsync(stream.fileno())
        staging.chmod(0o755)
        promote(staging, output)
        return lock
    finally:
        if staging.exists():
            shutil.rmtree(staging)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--commit", default=DEFAULT_COMMIT)
    arguments = parser.parse_args()
    lock = export_source(arguments.source, arguments.output, arguments.commit)
    print(json.dumps(lock, sort_keys=True))
    print("LIBCAMERA_SOURCE_EXPORT=PASS")

if __name__ == "__main__":
    try:
        main()
    except (ExportError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit("LIBCAMERA_SOURCE_EXPORT=FAIL: " + str(error))
