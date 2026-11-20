#!/usr/bin/env python3
"""Use the target dynamic loader's --list mode; never start camera applications."""
import argparse
import os
import pathlib
import stat
import subprocess

PREFIX = '/opt/libcamera-y700/'
LIB = PREFIX + 'lib/aarch64-linux-gnu/'
SEEDS = (PREFIX + 'bin/cam', LIB + 'libcamera-base.so.0.7.1', LIB + 'libcamera.so.0.7.1',
         LIB + 'libcamera/ipa/ipa_soft_simple.so', PREFIX + 'libexec/libcamera/soft_ipa_proxy',
         LIB + 'gstreamer-1.0/libgstlibcamera.so',
         '/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so')
LIBRARY_PATH = LIB.rstrip('/') + ':/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu'
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C', 'LANG': 'C'}

def check_loader(command):
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                            env=ENV, timeout=30, check=False)
    output = result.stdout.decode('utf-8', errors='strict')
    errors = result.stderr.decode('utf-8', errors='strict')
    if (result.returncode != 0 or 'not found' in (output + errors)
            or '=>' not in output or len(output) + len(errors) > 1 << 20):
        raise RuntimeError('target dynamic loader rejected camera dependencies: ' + (errors + output)[-4000:])
    return output

def verify_rootfs(root):
    root = root.absolute()
    if (root == pathlib.Path('/') or root.resolve(strict=True) != root
            or not stat.S_ISDIR(root.lstat().st_mode)):
        raise RuntimeError('rootfs must be a real isolated directory, never the host root')
    for name in SEEDS:
        try:
            metadata = (root / name.lstrip('/')).lstat()
        except (FileNotFoundError, NotADirectoryError) as error:
            raise RuntimeError('required camera loader seed is missing: ' + name) from error
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise RuntimeError('camera loader seed must be a private regular file: ' + name)
    # Check the complete payload before starting the target loader, so a partial
    # installation always identifies the missing member.
    if os.geteuid() != 0:
        raise RuntimeError('rootfs loader validation requires the existing privileged image-build context')
    for name in SEEDS:
        output = check_loader(['/usr/sbin/chroot', str(root), '/lib/ld-linux-aarch64.so.1',
                               '--list', '--library-path', LIBRARY_PATH, name])
        for soname in ('libcamera.so.0.7', 'libcamera-base.so.0.7'):
            matching = [line.strip() for line in output.splitlines() if line.strip().startswith(soname + ' => ')]
            if matching and not all(line.startswith(soname + ' => ' + LIB) for line in matching):
                raise RuntimeError('target loader selected a noncandidate libcamera dependency')
    print('CAMERA_TARGET_LOADER=PASS objects=' + str(len(SEEDS)))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rootfs', required=True, type=pathlib.Path)
    try:
        verify_rootfs(parser.parse_args().rootfs)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('CAMERA_TARGET_LOADER=FAIL: ' + str(error))
