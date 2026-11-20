#!/usr/bin/env python3
"""Install the closed TB321FU camera overlay with rollback semantics.

The source tree is authenticated from a closed manifest before it is copied
through descriptor-relative, no-follow operations.  The target is then
modified through a journaled transaction located on the target filesystem.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
from typing import Iterable


MAX_COPY = 64 << 20
RUNTIME_BINARIES = (
    "opt/libcamera-y700/bin/cam",
    "opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy",
    "opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so",
    "opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so",
    "usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so",
)
REQUIRED_DATA = (
    "opt/libcamera-y700/share/libcamera/ipa/simple/gc13a0.yaml",
    "opt/libcamera-y700/share/libcamera/ipa/simple/sc202cs.yaml",
    "opt/libcamera-y700/share/libcamera/ipa/simple/sc820cs.yaml",
    "etc/systemd/user/pipewire.service.d/50-y700-libcamera-ipa.conf",
    "etc/systemd/user/pipewire.service.d/60-y700-libcamera-paths.conf",
    "etc/systemd/user/wireplumber.service.d/60-y700-libcamera-paths.conf",
    "etc/udev/rules.d/70-y700-camera-dma-heap.rules",
    "etc/ld.so.conf.d/y700-libcamera.conf",
)
SYSTEM_GST_PLUGIN = "usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
GST_PLUGIN_TARGET = "/opt/libcamera-y700/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
LEGACY_PATHS = (
    "etc/udev/rules.d/70-y700-dma-heap.rules",
    "etc/y700-camera-display-transform-mode",
    "etc/y700-camera-display-rotation-base",
    "etc/systemd/user/y700-display-rotation-update.path",
    "etc/systemd/user/y700-display-rotation-update.service",
    "etc/systemd/user/y700-display-rotation-dbus.service",
    "etc/systemd/user/y700-display-rotation-sync.service",
    "usr/local/libexec/y700-display-rotation-update",
    "usr/local/libexec/y700-display-rotation-dbus",
    "usr/local/bin/y700-display-rotation-sync",
    "run/y700-camera-display-rotation",
)
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)


class InstallError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise InstallError(message)


def load_verifier(path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("camera_overlay_verifier", path)
    if spec is None or spec.loader is None:
        fail(f"cannot load overlay verifier: {path}")
    module = importlib.util.module_from_spec(spec)
    # Dataclass/type introspection in the verifier expects its module to be
    # registered while executing (the same contract as a normal import).
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(spec.name, None)
        raise
    return module


def identity(metadata: os.stat_result) -> tuple[int, ...]:
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


def same_object(metadata: os.stat_result, saved: tuple[int, ...] | None) -> bool:
    """Compare an inode identity without treating directory churn as a swap."""
    return saved is not None and (
        metadata.st_dev == saved[0]
        and metadata.st_ino == saved[1]
        and stat.S_IFMT(metadata.st_mode) == stat.S_IFMT(saved[2])
    )


def same_record_object(current: tuple[int, ...], saved: tuple[int, ...] | None) -> bool:
    """Compare only the stable inode/type portion of two saved identities."""
    return saved is not None and (
        current[0] == saved[0]
        and current[1] == saved[1]
        and stat.S_IFMT(current[2]) == stat.S_IFMT(saved[2])
    )


def ensure_real_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    absolute = pathlib.Path(os.path.abspath(os.fspath(path)))
    metadata = absolute.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or absolute.is_symlink():
        fail(f"{label} must be a real directory")
    if absolute.resolve(strict=True) != absolute:
        fail(f"{label} must not traverse symlinks")
    return absolute


def split_name(name: str) -> tuple[str, ...]:
    if not name or "\\" in name or "\x00" in name:
        fail(f"invalid relative path: {name!r}")
    parts = tuple(name.split("/"))
    if any(not part or part in {".", ".."} for part in parts):
        fail(f"non-canonical relative path: {name!r}")
    return parts


def open_root(path: pathlib.Path) -> int:
    return os.open(os.fspath(path), os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)


def open_parent(root_fd: int, parts: tuple[str, ...], create: bool = False) -> tuple[int, list[str]]:
    """Open a relative parent without following any component symlink."""
    fd = os.dup(root_fd)
    created: list[str] = []
    try:
        for part in parts:
            try:
                child = os.open(part, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                                dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(part, 0o755, dir_fd=fd)
                created.append(part)
                child = os.open(part, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                                dir_fd=fd)
            os.close(fd)
            fd = child
        return fd, created
    except Exception:
        os.close(fd)
        raise


def lstat_at(parent_fd: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def copy_source_tree(source: pathlib.Path, destination: pathlib.Path, expected: dict[str, tuple[str, int, int, str, str]]) -> None:
    source = ensure_real_directory(source, "overlay source")
    destination.mkdir(mode=0o755)
    # The enclosing transaction is private. Match the authenticated root mode
    # without inheriting the operator's umask.
    destination.chmod(0o755)
    source_fd = open_root(source)
    try:
        names = sorted(expected, key=lambda value: (len(split_name(value)), os.fsencode(value)))
        for name in names:
            record = expected[name]
            parts = split_name(name)
            parent_fd, _ = open_parent(source_fd, parts[:-1])
            try:
                source_meta = lstat_at(parent_fd, parts[-1])
                if source_meta is None:
                    fail(f"source member disappeared: {name}")
                kind, mode, size, digest, link_target = record
                if stat.S_IMODE(source_meta.st_mode) != mode:
                    fail(f"source mode changed: {name}")
                target = destination.joinpath(*parts)
                target_parent = target.parent
                target_parent.mkdir(mode=0o755, exist_ok=True)
                if kind == "directory":
                    if not stat.S_ISDIR(source_meta.st_mode):
                        fail(f"source directory type changed: {name}")
                    target.mkdir(mode=mode)
                    target.chmod(mode)
                elif kind == "symlink":
                    if not stat.S_ISLNK(source_meta.st_mode):
                        fail(f"source symlink type changed: {name}")
                    actual_target = os.readlink(parts[-1], dir_fd=parent_fd)
                    if actual_target != link_target or source_meta.st_size != size:
                        fail(f"source symlink changed: {name}")
                    os.symlink(actual_target, target)
                else:
                    if not stat.S_ISREG(source_meta.st_mode) or source_meta.st_nlink != 1 or source_meta.st_size != size:
                        fail(f"source file identity changed: {name}")
                    fd = os.open(parts[-1], os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=parent_fd)
                    out_fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_CLOEXEC, mode)
                    try:
                        opened = os.fstat(fd)
                        if identity(opened) != identity(source_meta):
                            fail(f"source file replaced before copy: {name}")
                        digest_obj = hashlib.sha256()
                        total = 0
                        while True:
                            chunk = os.read(fd, 1 << 20)
                            if not chunk:
                                break
                            total += len(chunk)
                            if total > MAX_COPY or total > size:
                                fail(f"source file grew beyond authenticated size: {name}")
                            digest_obj.update(chunk)
                            view = memoryview(chunk)
                            while view:
                                written = os.write(out_fd, view)
                                if written <= 0:
                                    fail(f"short write while snapshotting {name}")
                                view = view[written:]
                        after = os.fstat(fd)
                        if total != size or digest_obj.hexdigest() != digest or identity(after) != identity(opened):
                            fail(f"source file changed while snapshotting: {name}")
                        os.fchmod(out_fd, mode)
                        os.fsync(out_fd)
                    finally:
                        os.close(out_fd)
                        os.close(fd)
            finally:
                os.close(parent_fd)
    finally:
        os.close(source_fd)


def target_record_at(root_fd: int, name: str) -> tuple[str, int, int, str, str, tuple[int, ...]] | None:
    """Read a target member through the authenticated root descriptor."""
    parts = split_name(name)
    try:
        parent_fd, _ = open_parent(root_fd, parts[:-1])
    except FileNotFoundError:
        # Missing parents are normal for legacy paths.  Symlink and
        # non-directory parents still fail closed in open_parent().
        return None
    try:
        metadata = lstat_at(parent_fd, parts[-1])
        if metadata is None:
            return None
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode):
            fd = os.open(parts[-1], os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                         dir_fd=parent_fd)
            try:
                opened = os.fstat(fd)
                if identity(opened) != identity(metadata):
                    fail(f"target directory changed while opening: {name}")
            finally:
                os.close(fd)
            return ("directory", mode, 0, "-", "-", identity(metadata))
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(parts[-1], dir_fd=parent_fd)
            after = lstat_at(parent_fd, parts[-1])
            if after is None or identity(after) != identity(metadata):
                fail(f"target symlink changed while reading: {name}")
            return ("symlink", mode, metadata.st_size, "-", target, identity(metadata))
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            fail(f"unsupported or hard-linked target member: {name}")
        if metadata.st_size > MAX_COPY:
            fail(f"target member is too large to authenticate: {name}")
        fd = os.open(parts[-1], os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC, dir_fd=parent_fd)
        try:
            opened = os.fstat(fd)
            if identity(opened) != identity(metadata):
                fail(f"target member changed while opening: {name}")
            digest_obj = hashlib.sha256()
            total = 0
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_COPY:
                    fail(f"target member grew beyond limit: {name}")
                digest_obj.update(chunk)
            after = os.fstat(fd)
            if identity(after) != identity(opened) or total != metadata.st_size:
                fail(f"target member changed while hashing: {name}")
            digest = digest_obj.hexdigest()
        finally:
            os.close(fd)
        return ("file", mode, metadata.st_size, digest, "-", identity(metadata))
    finally:
        os.close(parent_fd)


def reject_target_symlink_parents(target: pathlib.Path,
                                  names: Iterable[str]) -> None:
    """Reject a pre-existing symlink anywhere below the target root."""
    for name in names:
        parts = split_name(name)
        current = target
        for part in parts[:-1]:
            current = current / part
            try:
                metadata = current.lstat()
            except FileNotFoundError:
                break
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"target path has a symlink parent: {current}")
            if not stat.S_ISDIR(metadata.st_mode):
                fail(f"target path parent is not a directory: {current}")


def validate_camera_snapshot(snapshot: pathlib.Path, records: dict) -> None:
    """Check the authenticated, private payload before changing the target."""
    for name in (*RUNTIME_BINARIES, *REQUIRED_DATA):
        if name not in records or records[name][0] != "file":
            fail(f"camera overlay is missing a required file: {name}")
    for name in ("opt/libcamera-y700/bin/cam", "opt/libcamera-y700/libexec/libcamera/soft_ipa_proxy"):
        if records[name][1] != 0o755:
            fail(f"camera overlay is missing an executable: {name}")
    link = records.get(SYSTEM_GST_PLUGIN)
    if link is None or link[0] != "symlink" or link[4] != GST_PLUGIN_TARGET:
        fail("camera overlay system GStreamer plugin entry points at wrong target")
    marker = b"libcamera-y700-test"
    for name in RUNTIME_BINARIES:
        if marker in (snapshot / name).read_bytes():
            fail(f"rejected camera app-chain marker found in {name}")


def verify_target_member(root_fd: int, name: str, record: tuple[str, int, int, str, str]) -> None:
    actual = target_record_at(root_fd, name)
    if actual is None:
        fail(f"installed member is missing: {name}")
    kind, mode, size, digest, link_target = record
    if actual[:5] != (kind, mode, size, digest, link_target):
        fail(f"installed member mismatch: {name}: expected={record!r} actual={actual[:5]!r}")


@dataclasses.dataclass
class Mutation:
    path: str
    backup: str | None
    old: tuple[str, int, int, str, str, tuple[int, ...]] | None
    new_identity: tuple[int, ...] | None
    metadata_only: bool = False


class Transaction:
    def __init__(self, target: pathlib.Path, fail_after: int | None):
        self.target = ensure_real_directory(target, "target rootfs")
        self.fail_after = fail_after
        self.count = 0
        self.mutations: list[Mutation] = []
        self.txn = pathlib.Path(tempfile.mkdtemp(prefix=".tb321fu-camera-txn.", dir=self.target))
        self.backup = self.txn / "backup"
        self.journal_path = self.txn / "journal.jsonl"
        self.journal = None
        self.root_fd = -1
        self.closed = False
        self.committed = False
        try:
            os.chmod(self.txn, 0o700)
            self.backup.mkdir(mode=0o700)
            self.journal = self.journal_path.open("x", encoding="utf-8")
            self.root_fd = open_root(self.target)
        except Exception:
            if self.journal is not None:
                try:
                    self.journal.close()
                except OSError:
                    pass
            if self.root_fd >= 0:
                try:
                    os.close(self.root_fd)
                except OSError:
                    pass
            shutil.rmtree(self.txn, ignore_errors=True)
            raise

    def _record(self, mutation: Mutation) -> None:
        self.mutations.append(mutation)
        payload = dataclasses.asdict(mutation)
        assert self.journal is not None
        self.journal.write(json.dumps(payload, sort_keys=True) + "\n")
        self.journal.flush()
        os.fsync(self.journal.fileno())
        self.count += 1
        if self.fail_after is not None and self.count >= self.fail_after:
            raise InstallError(f"injected camera install failure after {self.count} mutations")

    def _parent(self, name: str, create: bool = False) -> tuple[int, tuple[str, ...]]:
        parts = split_name(name)
        fd, _ = open_parent(self.root_fd, parts[:-1], create=create)
        return fd, parts

    def _record_target(self, name: str):
        return target_record_at(self.root_fd, name)

    @staticmethod
    def _same_before_rename(current: tuple[str, int, int, str, str, tuple[int, ...]],
                            expected: tuple[str, int, int, str, str, tuple[int, ...]]) -> bool:
        # Directory ctime changes when children are created, so compare its
        # stable inode/type and mode.  File/symlink metadata is immutable for
        # the rename window and can be compared byte-for-byte.
        if not same_record_object(current[5], expected[5]):
            return False
        if current[0] == "directory":
            return current[1] == expected[1]
        return current[5] == expected[5]

    def _backup_existing(self, name: str, metadata: tuple[str, int, int, str, str, tuple[int, ...]] | None) -> str | None:
        if metadata is None:
            return None
        backup_name = f"{len(self.mutations):08d}"
        backup_path = self.backup / backup_name
        parent_fd, parts = self._parent(name)
        renamed = False
        try:
            current = self._record_target(name)
            if current is None or not self._same_before_rename(current, metadata):
                fail(f"target member changed before backup: {name}")
            os.rename(parts[-1], backup_path, src_dir_fd=parent_fd)
            renamed = True
            saved = backup_path.lstat()
            if not same_object(saved, metadata[5]):
                fail(f"backup identity mismatch: {name}")
        except Exception:
            if renamed:
                try:
                    if lstat_at(parent_fd, parts[-1]) is None:
                        os.rename(backup_path, parts[-1], dst_dir_fd=parent_fd)
                except OSError as restore_error:
                    raise InstallError(f"cannot restore backup after failed rename: {name}") from restore_error
            raise
        finally:
            os.close(parent_fd)
        return backup_name

    def _remove_new(self, name: str, expected: tuple[int, ...] | None,
                    expect_absent: bool = False) -> None:
        parent_fd, parts = self._parent(name)
        try:
            metadata = lstat_at(parent_fd, parts[-1])
            if metadata is None:
                return
            if expected is None and expect_absent:
                raise InstallError(f"refusing to remove an unknown concurrent member: {name}")
            if expected is not None and not same_object(metadata, expected):
                raise InstallError(f"refusing to remove concurrently changed installed member: {name}")
            if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                os.rmdir(parts[-1], dir_fd=parent_fd)
            else:
                os.unlink(parts[-1], dir_fd=parent_fd)
        finally:
            os.close(parent_fd)

    def _restore_unrecorded(self, name: str, backup_name: str | None,
                            new_identity: tuple[int, ...] | None) -> None:
        """Undo a mutation whose journal record was not appended.

        Never remove an object when its inode was not observed as ours.  This
        keeps a concurrent replacement intact and leaves the transaction
        recoverable for the caller when ownership cannot be proved.
        """
        try:
            parent_fd, parts = self._parent(name)
        except FileNotFoundError:
            if backup_name is not None:
                raise InstallError(f"cannot restore backup parent: {name}")
            return
        try:
            current = lstat_at(parent_fd, parts[-1])
            if current is not None:
                if new_identity is None or not same_object(current, new_identity):
                    raise InstallError(f"refusing to remove unknown concurrent member: {name}")
                if stat.S_ISDIR(current.st_mode) and not stat.S_ISLNK(current.st_mode):
                    os.rmdir(parts[-1], dir_fd=parent_fd)
                else:
                    os.unlink(parts[-1], dir_fd=parent_fd)
            if backup_name is not None:
                os.rename(self.backup / backup_name, parts[-1], dst_dir_fd=parent_fd)
        finally:
            os.close(parent_fd)

    def apply_member(self, name: str, record: tuple[str, int, int, str, str], snapshot: pathlib.Path) -> None:
        parts = split_name(name)
        metadata = self._record_target(name)
        kind, mode, _, _, link_target = record
        if kind == "directory" and metadata is not None and metadata[0] == "directory":
            if metadata[1] != mode:
                parent_fd, target_parts = self._parent(name)
                directory_fd: int | None = None
                old_mode = metadata[1]
                mutation_count = len(self.mutations)
                try:
                    directory_fd = os.open(target_parts[-1], os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                                           dir_fd=parent_fd)
                    opened = os.fstat(directory_fd)
                    if not same_object(opened, metadata[5]) or stat.S_IMODE(opened.st_mode) != old_mode:
                        fail(f"target directory changed before mode update: {name}")
                    os.fchmod(directory_fd, mode)
                    os.fsync(directory_fd)
                    new_identity = identity(os.fstat(directory_fd))
                    try:
                        self._record(Mutation(name, None, metadata, new_identity, True))
                    except Exception:
                        if len(self.mutations) == mutation_count:
                            current = os.fstat(directory_fd)
                            if (same_object(current, new_identity)
                                    and stat.S_IMODE(current.st_mode) == mode):
                                os.fchmod(directory_fd, old_mode)
                                os.fsync(directory_fd)
                        raise
                finally:
                    if directory_fd is not None:
                        os.close(directory_fd)
                    os.close(parent_fd)
            return

        backup_name: str | None = None
        parent_fd: int | None = None
        recorded = False
        mutation_count = len(self.mutations)
        created_identity: tuple[int, ...] | None = None
        try:
            backup_name = self._backup_existing(name, metadata)
            parent_fd, target_parts = self._parent(name)
            source_path = snapshot.joinpath(*parts)
            if kind == "directory":
                os.mkdir(target_parts[-1], mode, dir_fd=parent_fd)
                created = lstat_at(parent_fd, target_parts[-1])
                if created is None:
                    fail(f"installed directory disappeared immediately: {name}")
                created_identity = identity(created)
                directory_fd = os.open(target_parts[-1], os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                                       dir_fd=parent_fd)
                try:
                    if not same_object(os.fstat(directory_fd), created_identity):
                        fail(f"installed directory changed before mode normalization: {name}")
                    os.fchmod(directory_fd, mode)
                finally:
                    os.close(directory_fd)
            elif kind == "symlink":
                os.symlink(link_target, target_parts[-1], dir_fd=parent_fd)
                created = lstat_at(parent_fd, target_parts[-1])
                if created is None:
                    fail(f"installed symlink disappeared immediately: {name}")
                created_identity = identity(created)
            else:
                # Snapshot is private and already authenticated.  Copying via
                # a new target fd avoids inheriting source hardlinks/modes.
                source_fd = os.open(source_path, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                try:
                    destination_fd = os.open(target_parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_CLOEXEC,
                                             mode, dir_fd=parent_fd)
                    try:
                        created_identity = identity(os.fstat(destination_fd))
                        while True:
                            chunk = os.read(source_fd, 1 << 20)
                            if not chunk:
                                break
                            view = memoryview(chunk)
                            while view:
                                written = os.write(destination_fd, view)
                                if written <= 0:
                                    fail(f"short write installing {name}")
                                view = view[written:]
                        os.fchmod(destination_fd, mode)
                        os.fsync(destination_fd)
                    finally:
                        os.close(destination_fd)
                finally:
                    os.close(source_fd)
            installed = self._record_target(name)
            if installed is None:
                fail(f"installed member disappeared immediately: {name}")
            try:
                self._record(Mutation(name, backup_name, metadata, installed[5]))
                recorded = True
            except Exception:
                # _record appends before an injected post-commit failure.  In
                # that case leave the complete mutation for the outer reverse
                # journal; only a failure before append is repaired locally.
                recorded = len(self.mutations) != mutation_count
                raise
        except Exception:
            if not recorded and len(self.mutations) == mutation_count:
                self._restore_unrecorded(name, backup_name, created_identity)
            raise
        finally:
            if parent_fd is not None:
                os.close(parent_fd)

    def remove_legacy(self, name: str) -> None:
        metadata = self._record_target(name)
        if metadata is None:
            return
        backup_name = self._backup_existing(name, metadata)
        mutation_count = len(self.mutations)
        try:
            self._record(Mutation(name, backup_name, metadata, None))
        except Exception:
            if len(self.mutations) != mutation_count:
                raise
            self._restore_unrecorded(name, backup_name, None)
            raise

    def rollback(self) -> None:
        errors: list[str] = []
        for mutation in reversed(self.mutations):
            try:
                if mutation.metadata_only:
                    current = self._record_target(mutation.path)
                    if current is None or mutation.new_identity is None:
                        raise InstallError(f"metadata target disappeared during rollback: {mutation.path}")
                    if (not same_record_object(current[5], mutation.new_identity)
                            or current[1] != stat.S_IMODE(mutation.new_identity[2])):
                        raise InstallError(f"metadata target changed during rollback: {mutation.path}")
                    parent_fd, parts = self._parent(mutation.path)
                    directory_fd: int | None = None
                    try:
                        directory_fd = os.open(parts[-1], os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                                               dir_fd=parent_fd)
                        opened = os.fstat(directory_fd)
                        if (not same_object(opened, mutation.new_identity)
                                or stat.S_IMODE(opened.st_mode) != stat.S_IMODE(mutation.new_identity[2])):
                            raise InstallError(f"metadata target changed during rollback: {mutation.path}")
                        os.fchmod(directory_fd, mutation.old[1] if mutation.old else 0o755)
                        os.fsync(directory_fd)
                    finally:
                        if directory_fd is not None:
                            os.close(directory_fd)
                        os.close(parent_fd)
                    continue
                self._remove_new(
                    mutation.path,
                    mutation.new_identity,
                    expect_absent=mutation.backup is not None and mutation.new_identity is None,
                )
                if mutation.backup is not None:
                    parent_fd, parts = self._parent(mutation.path)
                    try:
                        os.rename(self.backup / mutation.backup, parts[-1], dst_dir_fd=parent_fd)
                    finally:
                        os.close(parent_fd)
            except Exception as exc:  # pragma: no cover - exercised by hostile races
                errors.append(f"{mutation.path}: {exc}")
        if errors:
            raise InstallError("rollback failed: " + "; ".join(errors))

    def close(self) -> None:
        if self.closed:
            return
        close_error: BaseException | None = None
        try:
            if self.journal is not None:
                self.journal.close()
        except BaseException as exc:
            close_error = exc
        finally:
            if self.root_fd >= 0:
                os.close(self.root_fd)
            self.closed = True
        if close_error is not None:
            raise close_error

    def commit(self) -> None:
        if self.committed:
            return
        # Files were synced as they were installed. Persist the directory
        # entries while rollback still owns its backups and root descriptor.
        parents = {split_name(m.path)[:-1] for m in self.mutations}
        for parts in sorted(parents, key=len, reverse=True):
            if parts:
                directory_fd, _ = open_parent(self.root_fd, parts)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        os.fsync(self.root_fd)
        self.journal.close()
        # This rename marks the point after which remnants are disposable.
        # A rename failure leaves the original journal available for rollback.
        retired = self.txn.with_name(self.txn.name.replace("-txn.", "-committed.", 1))
        self.txn.rename(retired)
        self.committed = True
        try:
            shutil.rmtree(retired)
            os.fsync(self.root_fd)
        except OSError as exc:
            print(f"camera overlay installed; cleanup of {retired} requires attention: {exc}", file=sys.stderr)
        finally:
            try:
                self.close()
            except OSError as exc:
                print(f"camera overlay installed; descriptor cleanup failed: {exc}", file=sys.stderr)


def install(overlay: pathlib.Path, manifest: pathlib.Path, target: pathlib.Path,
            verifier_path: pathlib.Path, fail_after: int | None) -> None:
    verifier = load_verifier(verifier_path)
    overlay = ensure_real_directory(overlay, "overlay source")
    target = ensure_real_directory(target, "target rootfs")
    expected, raw_manifest = verifier.parse_manifest(manifest)
    verifier.verify(overlay, manifest, None)
    reject_target_symlink_parents(target, tuple(expected) + LEGACY_PATHS)

    # Build the private source snapshot on the target filesystem.  The source
    # is checked again after the copy so a path substitution cannot inherit a
    # stale verification result.
    transaction = Transaction(target, fail_after)
    snapshot = transaction.txn / "snapshot"
    try:
        copy_source_tree(overlay, snapshot, expected)
        snapshot_manifest = transaction.txn / "OVERLAY-MANIFEST.tsv"
        snapshot_manifest.write_bytes(raw_manifest)
        snapshot_manifest.chmod(0o644)
        verifier.verify(snapshot, snapshot_manifest, None)
        validate_camera_snapshot(snapshot, expected)
        verifier.verify(overlay, manifest, None)

        for name in sorted(expected, key=lambda value: (len(split_name(value)), os.fsencode(value))):
            transaction.apply_member(name, expected[name], snapshot)
        for name in LEGACY_PATHS:
            if name not in expected:
                transaction.remove_legacy(name)
        for name, record in expected.items():
            verify_target_member(transaction.root_fd, name, record)
        for name in LEGACY_PATHS:
            if name not in expected and transaction._record_target(name) is not None:
                fail(f"legacy member survived installation: {name}")
        transaction.commit()
    except BaseException as error:
        rollback_error: BaseException | None = None
        close_error: BaseException | None = None
        rollback_attempted = False
        if not transaction.committed and not transaction.closed:
            rollback_attempted = True
            try:
                transaction.rollback()
            except BaseException as exc:
                rollback_error = exc
        if not transaction.closed:
            try:
                transaction.close()
            except BaseException as exc:
                close_error = exc
        cleanup_ok = rollback_attempted and rollback_error is None and close_error is None
        if transaction.txn.exists() and cleanup_ok:
            try:
                shutil.rmtree(transaction.txn)
            except BaseException as exc:
                cleanup_ok = False
                close_error = close_error or exc
        if rollback_error is not None:
            raise InstallError(
                f"camera overlay rollback failed; transaction preserved at {transaction.txn}"
            ) from rollback_error
        if close_error is not None:
            raise InstallError(
                f"camera overlay cleanup failed; transaction preserved at {transaction.txn}"
            ) from close_error
        if not cleanup_ok:
            raise InstallError(
                f"camera overlay transaction cleanup failed; transaction preserved at {transaction.txn}"
            ) from error
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--overlay", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--target", type=pathlib.Path, required=True)
    parser.add_argument("--verifier", type=pathlib.Path, required=True)
    parser.add_argument("--fail-after", type=int)
    args = parser.parse_args()
    if args.fail_after is not None and args.fail_after < 1:
        fail("--fail-after must be positive")
    install(args.overlay, args.manifest, args.target, args.verifier, args.fail_after)
    print("CAMERA_OVERLAY_INSTALL=PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (InstallError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"CAMERA_OVERLAY_INSTALL=FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
