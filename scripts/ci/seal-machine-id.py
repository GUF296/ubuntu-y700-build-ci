#!/usr/bin/env python3
"""Seal machine identity after the last image mutation; never read an ID."""
import os
import secrets
import stat
import sys
from contextlib import ExitStack
from pathlib import PurePosixPath

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
NAME = "machine-id"
LINK = "../../../etc/machine-id"


def seal(root):
    path = PurePosixPath(root)
    if path.anchor != "/" or path == PurePosixPath("/") or ".." in path.parts:
        raise ValueError("expected a non-host absolute image root")
    with ExitStack() as opened:
        def directory(name, parent=None):
            fd = os.open(name, DIR, dir_fd=parent)
            opened.callback(os.close, fd)
            return fd

        fd = directory("/")
        host = os.fstat(fd)
        for part in path.parts[1:]:
            fd = directory(part, fd)
        image = os.fstat(fd)
        if os.path.samestat(host, image):
            raise ValueError("refusing the host root")

        def trusted(fd):
            st = os.fstat(fd)
            if st.st_dev != image.st_dev or st.st_uid != os.geteuid() or st.st_mode & 0o022:
                raise ValueError("untrusted image identity directory")
            return fd

        etc = trusted(directory("etc", trusted(fd)))
        dbus = fd
        for part in ("var", "lib", "dbus"):
            try:
                dbus = trusted(directory(part, dbus))
            except FileNotFoundError:
                dbus = None
                break

        def kind(parent):
            try:
                return os.stat(NAME, dir_fd=parent, follow_symlinks=False).st_mode
            except FileNotFoundError:
                return None

        # Preflight both paths before changing either; do not follow an old link.
        primary = kind(etc)
        if primary is not None and not stat.S_ISREG(primary):
            raise ValueError("unsafe system machine-id entry")
        legacy = kind(dbus) if dbus is not None else None
        if legacy is not None and stat.S_ISLNK(legacy):
            link = os.readlink(NAME, dir_fd=dbus)
            if not link.endswith("/machine-id") or str(PurePosixPath(link)) not in ("/etc/machine-id", LINK):
                raise ValueError("unsafe legacy machine-id target")
        elif legacy is not None and not stat.S_ISREG(legacy):
            raise ValueError("unsafe legacy machine-id entry")

        def replace(parent, make_link):
            tmp = ".tb321fu-id-" + secrets.token_hex(12)
            if make_link:
                os.symlink(LINK, tmp, dir_fd=parent)
                new = None
            else:
                new = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            try:
                if new is not None:
                    try:
                        os.fchmod(new, 0o644)  # June image mode; empty, not uninitialized.
                    finally:
                        os.close(new)
                os.replace(tmp, NAME, src_dir_fd=parent, dst_dir_fd=parent)
            finally:
                try:
                    os.unlink(tmp, dir_fd=parent)
                except FileNotFoundError:
                    pass

        # Replace inodes, never truncate through an input hard link. Absent or
        # valid D-Bus links are kept; formerly independent IDs share systemd's.
        replace(etc, False)
        if legacy is not None and stat.S_ISREG(legacy):
            replace(dbus, True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: seal-machine-id.py ABSOLUTE_IMAGE_ROOT")
    try:
        seal(sys.argv[1])
    except (OSError, ValueError) as exc:
        sys.exit("cannot seal image machine identity: " + str(exc))
