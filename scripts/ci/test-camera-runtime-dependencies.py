#!/usr/bin/env python3
"""Check camera ELF dependencies against package control without installation."""
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
PREFIX = 'opt/libcamera-y700/'
LIB = PREFIX + 'lib/aarch64-linux-gnu/'
ELFS = (PREFIX + 'bin/cam', LIB + 'libcamera-base.so.0.7.1', LIB + 'libcamera.so.0.7.1',
        LIB + 'libcamera/ipa/ipa_soft_simple.so', PREFIX + 'libexec/libcamera/soft_ipa_proxy',
        LIB + 'gstreamer-1.0/libgstlibcamera.so',
        'usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so')
# This mapping is verified against the recorded Ubuntu ARM64 package ownership.
# Unknown dependencies fail; they are never guessed or silently omitted.
PACKAGES = {'ld-linux-aarch64.so.1': 'libc6', 'libc.so.6': 'libc6', 'libm.so.6': 'libc6',
    'libgcc_s.so.1': 'libgcc-s1', 'libstdc++.so.6': 'libstdc++6', 'libdw.so.1': 'libdw1t64',
    'libEGL.so.1': 'libegl1', 'libGLESv2.so.2': 'libgles2', 'libgnutls.so.30': 'libgnutls30t64',
    'libudev.so.1': 'libudev1', 'libyaml-0.so.2': 'libyaml-0-2',
    'libunwind.so.8': 'libunwind8', 'libunwind-aarch64.so.8': 'libunwind8',
    'libevent-2.1.so.7': 'libevent-2.1-7t64',
    'libevent_pthreads-2.1.so.7': 'libevent-pthreads-2.1-7t64',
    'libglib-2.0.so.0': 'libglib2.0-0t64', 'libgobject-2.0.so.0': 'libglib2.0-0t64',
    'libgio-2.0.so.0': 'libglib2.0-0t64', 'libgstreamer-1.0.so.0': 'libgstreamer1.0-0',
    'libgstbase-1.0.so.0': 'libgstreamer1.0-0',
    'libgstvideo-1.0.so.0': 'libgstreamer-plugins-base1.0-0',
    'libgstallocators-1.0.so.0': 'libgstreamer-plugins-base1.0-0'}

def required_packages(root):
    needed, supplied = set(), set()
    for name in ELFS:
        text = subprocess.check_output(['/usr/bin/readelf', '-d', str(root / name)],
                text=True, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, timeout=30)
        needed.update(re.findall(r'\(NEEDED\).*?\[(.*?)\]', text))
        supplied.update(re.findall(r'\(SONAME\).*?\[(.*?)\]', text))
    external = needed - supplied
    unknown = external - PACKAGES.keys()
    if unknown:
        raise RuntimeError('unknown external camera ELF libraries: ' + ', '.join(sorted(unknown)))
    return {PACKAGES[name] for name in external}

def verify_depends(value, required):
    entries = [part.strip() for part in value.strip().split(',')]
    if any(not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*', entry) for entry in entries):
        raise RuntimeError('camera package expects unconditional unambiguous runtime dependencies')
    if len(set(entries)) != len(entries):
        raise RuntimeError('duplicate camera dependency declaration')
    missing = required - set(entries)
    if missing:
        raise RuntimeError('undeclared required camera packages: ' + ', '.join(sorted(missing)))

PLUGIN_ROLES = {'gstreamer1.0-libcamera', 'libspa-0.2-libcamera'}
GST_SYSTEM = 'usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so'
GST_TARGET = LIB + 'gstreamer-1.0/libgstlibcamera.so'
SPA_SYSTEM = 'usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so'


def verify_plugin_roles(root, fields):
    # Unversioned Provides matches the plugin contract, not the distro libcamera
    # release number. Do not advertise an unverified versioned virtual package.
    for field, required in (('Provides', PLUGIN_ROLES | {'y700-camera-stack'}),
                            ('Replaces', PLUGIN_ROLES | {'y700-daily-rootfs-overlay'}),
                            ('Conflicts', PLUGIN_ROLES)):
        entries = [p.strip() for p in fields[field].split(',')]
        if len(entries) != len(set(entries)) or not required <= set(entries):
            raise RuntimeError('camera package has incomplete or duplicate plugin ' + field)
    link = root / GST_SYSTEM
    if not link.is_symlink() or str(link.readlink()) != '/' + GST_TARGET:
        raise RuntimeError('camera package does not supply the system GStreamer plugin link')
    for name in (GST_TARGET, SPA_SYSTEM):
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise RuntimeError('camera package does not supply the advertised plugin: ' + name)


def verify_deb(deb):
    if not deb.is_file() or deb.is_symlink() or deb.stat().st_size > 256 << 20:
        raise RuntimeError('invalid camera DEB input')
    with tempfile.TemporaryDirectory(prefix='tb321fu-camera-dependencies-') as directory:
        root = pathlib.Path(directory) / 'payload'
        subprocess.run(['/usr/bin/dpkg-deb', '-x', str(deb), str(root)], check=True, timeout=60)
        required = required_packages(root)
        depends = subprocess.check_output(['/usr/bin/dpkg-deb', '-f', str(deb), 'Depends'], text=True, timeout=30)
        verify_depends(depends, required)
        verify_plugin_roles(root, {field: subprocess.check_output(['/usr/bin/dpkg-deb', '-f', str(deb), field],
                text=True, timeout=30) for field in ('Provides', 'Replaces', 'Conflicts')})
    print('CAMERA_RUNTIME_DEPENDENCIES=PASS packages=' + str(len(required)))

class DependencyTests(unittest.TestCase):
    def test_source_control_covers_real_baseline_libraries(self):
        source = (HERE / 'build-tb321fu-camera-stack-deb.sh').read_text()
        values = re.findall(r'^Depends: (.+)$', source, flags=re.M)
        self.assertEqual(len(values), 1)
        required = required_packages(REPO / 'source/tb321fu-camera-rootfs-overlay/rootfs-overlay')
        self.assertEqual(len(required), 15)
        verify_depends(values[0], required)
        self.assertNotIn('Historically device-tested libcamera payload', source)

    def test_plugin_roles_present_without_reinstalling_conflicting_binaries(self):
        source = (HERE / 'build-tb321fu-camera-stack-deb.sh').read_text()
        fields = {k: re.findall('^' + k + ': (.+)$', source, flags=re.M) for k in
                  ('Provides', 'Replaces', 'Conflicts')}
        self.assertTrue(all(len(v) == 1 for v in fields.values()))
        fields = {k:v[0] for k,v in fields.items()}
        root = REPO / 'source/tb321fu-camera-rootfs-overlay/rootfs-overlay'
        verify_plugin_roles(root, fields)
        for key in fields:
            for role in PLUGIN_ROLES:
                incomplete = ', '.join(v.strip() for v in fields[key].split(',') if v.strip() != role)
                with self.subTest(key=key, role=role), self.assertRaisesRegex(RuntimeError, key):
                    verify_plugin_roles(root, {**fields, key: incomplete})
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, 'GStreamer plugin link'):
                verify_plugin_roles(pathlib.Path(directory), fields)

    def test_missing_ambiguous_and_duplicate_dependencies_fail(self):
        required = {'libdw1t64', 'libgnutls30t64'}
        for value in ('libdw1t64', 'libgnutls30t64', 'libdw1t64 | libc6, libgnutls30t64',
                      'libdw1t64, libdw1t64, libgnutls30t64'):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                verify_depends(value, required)
        verify_depends('libdw1t64, libgnutls30t64, libc6', required)

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--deb':
        try:
            verify_deb(pathlib.Path(sys.argv[2]))
        except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
            raise SystemExit('CAMERA_RUNTIME_DEPENDENCIES=FAIL: ' + str(error))
    else:
        unittest.main()
