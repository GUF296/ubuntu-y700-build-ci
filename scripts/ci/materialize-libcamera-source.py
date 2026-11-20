#!/usr/bin/env python3
"""Materialize the repository-locked libcamera source package for a clean build."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
PROFILE = SCRIPT_DIR.parent.parent / "source/tb321fu-camera-rootfs-overlay/source/libcamera-producer"
HEADER = "path\ttype\tmode\tsize\tsha256\tlink_target"
FILES = {"SOURCE-LOCK.json": 16 << 10, "SOURCE-MANIFEST.tsv": 3 << 20,
         "libcamera-source.tar.xz": 32 << 20}
FIELDS = {"schema", "git_head", "source_kind", "source_epoch", "source_tree_sha256",
          "version", "archive", "archive_sha256", "archive_bytes",
          "manifest_sha256", "members", "extra_source_paths"}
spec = importlib.util.spec_from_file_location(
    "libcamera_source_export", SCRIPT_DIR / "export-libcamera-source.py"
)
assert spec is not None and spec.loader is not None
exporter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = exporter
spec.loader.exec_module(exporter)

class SourceError(RuntimeError):
    pass

def fail(message):
    raise SourceError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail("duplicate source-lock field")
        result[key] = value
    return result

def snapshot_profile(profile: pathlib.Path) -> dict[str, bytes]:
    if profile.is_symlink():
        fail("source profile must not be a symlink")
    root = os.open(profile, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        root_stat = os.fstat(root)
        if set(os.listdir(root)) != set(FILES):
            fail("source profile is not the exact three-file input set")
        result, identities = {}, {}
        for name, limit in FILES.items():
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=root)
            with os.fdopen(descriptor, "rb") as stream:
                before = os.fstat(stream.fileno())
                if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                        or stat.S_IMODE(before.st_mode) != 0o644
                        or not 0 < before.st_size <= limit):
                    fail("source profile member type/mode/size/link mismatch: " + name)
                data = stream.read(limit + 1)
                if (len(data) != before.st_size
                        or exporter.fingerprint(os.fstat(stream.fileno())) != exporter.fingerprint(before)):
                    fail("source profile changed during capture: " + name)
                result[name] = data
                identities[name] = exporter.fingerprint(before)
        for name, saved in identities.items():
            if exporter.fingerprint(os.stat(name, dir_fd=root, follow_symlinks=False)) != saved:
                fail("source profile namespace changed: " + name)
        if set(os.listdir(root)) != set(FILES):
            fail("source profile membership changed")
        now = profile.stat(follow_symlinks=False)
        if (now.st_dev, now.st_ino) != (root_stat.st_dev, root_stat.st_ino):
            fail("source profile root changed")
        return result
    finally:
        os.close(root)

def validate_profile(data: dict[str, bytes]):
    lock = json.loads(data["SOURCE-LOCK.json"].decode(), object_pairs_hook=unique_object)
    if not isinstance(lock, dict) or set(lock) != FIELDS:
        fail("source lock has an unsupported field set")
    if (lock["schema"] != "tb321fu-libcamera-source-v1"
            or lock["source_kind"] != "worktree-snapshot"
            or lock["archive"] != "libcamera-source.tar.xz"
            or lock["extra_source_paths"] != list(exporter.EXTRA_FILES)):
        fail("source lock profile identity mismatch")
    for key, length in (("git_head", 40), ("source_tree_sha256", 64),
                        ("archive_sha256", 64), ("manifest_sha256", 64)):
        if not isinstance(lock[key], str) or not re.fullmatch("[0-9a-f]{" + str(length) + "}", lock[key]):
            fail("source lock has an invalid digest: " + key)
    for key in ("members", "archive_bytes", "source_epoch"):
        if type(lock[key]) is not int or lock[key] < 0:
            fail("source lock has an invalid integer: " + key)
    if not 1 <= lock["members"] <= exporter.MAX_FILES + 1:
        fail("source member count exceeds its bound")
    archive = data["libcamera-source.tar.xz"]
    text = data["SOURCE-MANIFEST.tsv"]
    if len(archive) != lock["archive_bytes"] or sha(archive) != lock["archive_sha256"]:
        fail("source archive does not match its lock")
    if sha(text) != lock["manifest_sha256"] or not text.endswith(bytes([10])) or bytes([13]) in text:
        fail("source manifest digest/framing mismatch")
    lines = text.decode("utf-8").splitlines()
    if not lines or lines[0] != HEADER:
        fail("source manifest header mismatch")
    entries = {}
    for line in lines[1:]:
        fields = line.split(chr(9))
        if len(fields) != 6:
            fail("source manifest row shape mismatch")
        name, kind, mode, size, digest, target = fields
        exporter.relative_path(name)
        if name in entries or kind not in ("file", "symlink"):
            fail("duplicate or unsupported source member")
        if not re.fullmatch(r"0|[1-9][0-9]{0,8}", size):
            fail("invalid source member size")
        count = int(size)
        if count > exporter.MAX_FILE_BYTES:
            fail("source member exceeds size bound")
        if kind == "file":
            if mode not in ("0644", "0755") or target != "-" or not re.fullmatch(r"[0-9a-f]{64}", digest):
                fail("source file metadata mismatch")
        elif (mode != "0777" or digest != "-" or "/" in target
              or target in ("", ".", "..") or len(target.encode()) != count
              or any(ord(character) < 32 for character in target)):
            fail("source link metadata mismatch")
        entries[name] = (kind, int(mode, 8), count, digest, target)
    if len(entries) != lock["members"] or list(entries) != sorted(entries, key=lambda name: name.encode()):
        fail("source manifest count/order mismatch")
    if sum(row[2] for row in entries.values()) > exporter.MAX_SOURCE_BYTES:
        fail("source manifest exceeds aggregate size bound")
    if ".tarball-version" not in entries or any(path not in entries for path in exporter.EXTRA_FILES):
        fail("source manifest omits required profile members")
    tree_text = (HEADER + chr(10) + chr(10).join(
        line for line in lines[1:] if not line.startswith(".tarball-version" + chr(9))
    ) + chr(10)).encode()
    if sha(tree_text) != lock["source_tree_sha256"]:
        fail("source tree identity does not match its manifest")
    version = "0.7.1+tb321fu." + lock["source_tree_sha256"][:16]
    if lock["version"] != version:
        fail("source version is not content-derived")
    expected_version = (version + chr(10)).encode()
    if entries[".tarball-version"] != ("file", 0o644, len(expected_version), sha(expected_version), "-"):
        fail("tarball version does not match the locked source identity")
    directories = {"libcamera"}
    for name, row in entries.items():
        directories.update(str(parent) for parent in pathlib.PurePosixPath("libcamera", name).parents
                           if str(parent) != ".")
        if row[0] == "symlink":
            target = str(pathlib.PurePosixPath(name).parent / row[4])
            if target not in entries or entries[target][0] != "file":
                fail("source link target is not an in-tree regular member")
    if len(directories) + len(entries) > 20000:
        fail("source archive tree is too large")
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:xz") as bundle:
        for info in bundle:
            name = info.name
            if name in seen or len(seen) >= len(directories) + len(entries):
                fail("source archive contains duplicate/extra members")
            seen.add(name)
            if (info.uid != 0 or info.gid != 0 or info.uname or info.gname
                    or info.mtime != lock["source_epoch"] or info.sparse is not None
                    or set(info.pax_headers) - {"path", "linkpath"}):
                fail("source archive metadata is outside the canonical export profile")
            if name in directories:
                if not info.isdir() or info.mode != 0o755 or info.size != 0:
                    fail("source archive directory metadata mismatch")
                continue
            if not name.startswith("libcamera/") or name[10:] not in entries:
                fail("source archive contains an undeclared path")
            row = entries[name[10:]]
            if row[0] == "symlink":
                if not info.issym() or info.mode != 0o777 or info.size != 0 or info.linkname != row[4]:
                    fail("source archive link mismatch")
            else:
                if info.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or info.mode != row[1] or info.size != row[2]:
                    fail("source archive file type/mode/size mismatch")
                member = bundle.extractfile(info)
                if member is None:
                    fail("source archive member is unreadable")
                with member:
                    content = member.read(exporter.MAX_FILE_BYTES + 1)
                if len(content) != row[2] or sha(content) != row[3]:
                    fail("source archive member digest mismatch")
        if seen != directories | {"libcamera/" + name for name in entries}:
            fail("source archive member set is incomplete")
    return lock, entries, directories

def verify_tree(root, entries, directories):
    expected = set(entries) | {name[10:] for name in directories if name != "libcamera"}
    actual = set()
    for base, dirs, files in os.walk(root, followlinks=False):
        for leaf in dirs + files:
            path = pathlib.Path(base) / leaf
            name = path.relative_to(root).as_posix()
            actual.add(name)
            if name not in expected:
                fail("materialized source contains an extra member")
            if name not in entries:
                value = path.lstat()
                if not stat.S_ISDIR(value.st_mode) or stat.S_IMODE(value.st_mode) != 0o755:
                    fail("materialized source directory mode/type mismatch")
    if actual != expected:
        fail("materialized source tree is incomplete")
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for name, row in entries.items():
            mode = "120000" if row[0] == "symlink" else ("100755" if row[1] == 0o755 else "100644")
            member = exporter.read_member(descriptor, name, mode)
            if ((row[0] == "file" and sha(member.data) != row[3])
                    or (row[0] == "symlink" and member.data.decode() != row[4])):
                fail("materialized source data differs from its manifest")
    finally:
        os.close(descriptor)

def materialize(profile: pathlib.Path, output: pathlib.Path) -> dict:
    profile = profile.absolute()
    output = output.absolute()
    output = output.parent.resolve(strict=True) / output.name
    if output.exists() or output.is_symlink() or output.is_relative_to(profile.resolve()):
        fail("source destination is occupied or inside the input profile")
    data = snapshot_profile(profile)
    lock, entries, directories = validate_profile(data)
    staging = pathlib.Path(tempfile.mkdtemp(prefix=".libcamera-materialize.", dir=output.parent))
    try:
        archive = staging / "input.tar.xz"
        archive.write_bytes(data["libcamera-source.tar.xz"])
        unpacked = staging / "unpacked"
        result = subprocess.run(
            ["/usr/bin/python3", "-I", "-B", str(SCRIPT_DIR / "safe-extract-archive.py"),
             str(archive), str(unpacked)], env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
            stdin=subprocess.DEVNULL, capture_output=True, timeout=60, check=False,
            umask=0o022,
        )
        if result.returncode != 0:
            fail("safe source extraction failed")
        source = unpacked / "libcamera"
        if set(os.listdir(unpacked)) != {"libcamera"} or source.is_symlink():
            fail("source archive root is not canonical")
        verify_tree(source, entries, directories)
        exporter.promote(source, output)
        return lock
    finally:
        shutil.rmtree(staging)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    lock = materialize(PROFILE, arguments.output)
    print(json.dumps(lock, sort_keys=True))
    print("LIBCAMERA_SOURCE_MATERIALIZATION=PASS")

if __name__ == "__main__":
    try:
        main()
    except (SourceError, exporter.ExportError, OSError, ValueError, tarfile.TarError,
            subprocess.SubprocessError) as error:
        raise SystemExit("LIBCAMERA_SOURCE_MATERIALIZATION=FAIL: " + str(error))
