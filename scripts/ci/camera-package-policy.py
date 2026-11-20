#!/usr/bin/env python3
"""Read the single committed camera release version and exact asset names."""
import argparse
import os
import pathlib
import re
import stat

VERSION_PATH = pathlib.Path(__file__).with_name('CAMERA-PACKAGE-VERSION')
CHECKSUM_NAME = 'SHA256SUMS-tb321fu-camera-stack-debs.txt'

def approved_version(path=VERSION_PATH):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or stat.S_IMODE(before.st_mode) != 0o644 or not 2 <= before.st_size <= 65):
            raise RuntimeError('camera version policy must be one bounded regular 0644 file')
        data = stream.read(66)
        after = os.fstat(stream.fileno())
        identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(before) != identity(after) or identity(path.lstat()) != identity(after):
            raise RuntimeError('camera version policy changed during read')
    if (not data.endswith(bytes([10])) or not re.fullmatch(rb'[0-9][A-Za-z0-9.-]{0,63}', data[:-1])
            or data[:-1].endswith(b'-')):
        raise RuntimeError('camera release version must be one canonical filename-safe Debian version')
    return data[:-1].decode('ascii')

def deb_name():
    return 'tb321fu-camera-stack_' + approved_version() + '_arm64.deb'

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('field', choices=('version', 'deb-name', 'checksum-name', 'rootfs-default'))
    try:
        field = parser.parse_args().field
        if field == 'rootfs-default':
            print('CAMERA_STACK_DEB_VERSION=' + approved_version())
        else:
            print(approved_version() if field == 'version' else deb_name() if field == 'deb-name' else CHECKSUM_NAME)
    except (RuntimeError, OSError, ValueError) as error:
        raise SystemExit('CAMERA_PACKAGE_POLICY=FAIL: ' + str(error))
