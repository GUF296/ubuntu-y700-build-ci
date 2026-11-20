#!/usr/bin/env python3
"""Publish three verified build outputs without replacing existing files."""
import argparse
import fcntl
import os
import re
import shutil
import stat
from pathlib import Path


REPORT = 'tb321fu-camera-stack-build-report.txt'
CHECKSUM = 'SHA256SUMS-tb321fu-camera-stack-debs.txt'
PACKAGE = re.compile(r'tb321fu-camera-stack_[0-9][0-9A-Za-z.+:~-]{0,63}_arm64\.deb')
TRANSACTION = '.tb321fu-camera-package-transaction-v1'
MARKER = 'pending-'


def same_file(first, second):
    try:
        return os.path.samestat(first.lstat(), second.lstat())
    except FileNotFoundError:
        return False


def open_output(path):
    # Walk from a pinned parent at each step so rename cannot redirect a
    # later operation through a symlink. The Linux producer also uses procfs.
    path = path.absolute()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(path.anchor, flags)
    try:
        for part in path.parts[1:]:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def sync_file(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_CLOEXEC', 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def settle(output):
    """Rollback linked sidecars or finish a committed DEB after interruption."""
    transaction = output / TRANSACTION
    try:
        info = transaction.lstat()
    except FileNotFoundError:
        return
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise RuntimeError(f'unrecognized camera transaction: {transaction}')
    entries = {path.name for path in transaction.iterdir()}
    if entries:
        markers = [name for name in entries if name.startswith(MARKER) and
                   PACKAGE.fullmatch(name[len(MARKER):])]
        if len(markers) != 1:
            raise RuntimeError(f'unrecognized camera transaction: {transaction}')
        marker = markers[0]
        deb = marker[len(MARKER):]
        names = (REPORT, CHECKSUM, deb)
        if entries - {*names, marker}:
            raise RuntimeError(f'unexpected files in camera transaction: {transaction}')
        for name in entries:
            if not stat.S_ISREG((transaction / name).lstat().st_mode):
                raise RuntimeError(f'unexpected file type in camera transaction: {name}')
        committed = same_file(transaction / deb, output / deb)
        if not committed:
            for name in names:
                if same_file(transaction / name, output / name):
                    (output / name).unlink()
        # Make the public result durable before retiring its proof. Keep the
        # DEB receipt until all sidecar receipts have durably disappeared.
        sync_directory(output)
        for name in names[:-1]:
            if name in entries:
                (transaction / name).unlink()
        sync_directory(transaction)
        if deb in entries:
            (transaction / deb).unlink()
            sync_directory(transaction)
        (transaction / marker).unlink()
    transaction.rmdir()
    sync_directory(output)


def publish(output, deb, source=None, inherited_lock_fd=None):
    if not PACKAGE.fullmatch(deb):
        raise ValueError('invalid camera package filename')
    names = (REPORT, CHECKSUM, deb)
    descriptor = open_output(output)
    try:
        if inherited_lock_fd is None:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
        else:
            if not os.path.samestat(os.fstat(descriptor), os.fstat(inherited_lock_fd)):
                raise RuntimeError('camera lock descriptor does not identify the output directory')
            fcntl.flock(inherited_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        output = Path(f'/proc/self/fd/{descriptor}')
        # A directory from a previous producer version may still be in use.
        if os.path.lexists(output / '.tb321fu-camera-package.lock'):
            raise RuntimeError('legacy camera lock present; use a fresh output directory')
        settle(output)
        for name in names:
            if os.path.lexists(output / name):
                raise FileExistsError(f'camera output already exists; refusing replacement: {output / name}')
        if source is None:
            return
        transaction = output / TRANSACTION
        transaction.mkdir(mode=0o700)
        try:
            (transaction / (MARKER + deb)).touch(exist_ok=False)
            sync_file(transaction / (MARKER + deb))
            sync_directory(transaction)
            for name in names:
                with (source / name).open('rb') as src, (transaction / name).open('xb') as dst:
                    shutil.copyfileobj(src, dst)
                    dst.flush()
                    os.fchmod(dst.fileno(), 0o644)
                    os.fsync(dst.fileno())
            sync_directory(transaction)
            # link() is an atomic no-replace operation. The DEB itself is the
            # commit marker, visible only after both complete sidecars exist.
            sync_directory(output)
            for name in names[:-1]:
                os.link(transaction / name, output / name)
            sync_directory(output)
            os.link(transaction / deb, output / deb)
            sync_directory(output)
        finally:
            settle(output)
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('deb')
    parser.add_argument('source', type=Path, nargs='?')
    parser.add_argument('--lock-fd', type=int, default=None)
    args = parser.parse_args()
    publish(args.output, args.deb, args.source, args.lock_fd)
