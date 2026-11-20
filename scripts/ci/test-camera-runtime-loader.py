#!/usr/bin/env python3
"""Real loader fixtures: accept compatible providers, reject missing versions."""
import importlib.util
import json
import os
import pathlib
import shutil
import platform
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('camera_loader_test', HERE / 'verify-camera-runtime-loader.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)

class LoaderTests(unittest.TestCase):
    def test_rootfs_cannot_skip_or_ignore_loader_gate(self):
        spec = importlib.util.spec_from_file_location('camera_rootfs_workflow_contract', HERE / 'test-workflow-semantics.py')
        workflow = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(workflow)
        rootfs = HERE / 'build-rootfs-image.sh'
        workflow.validate_rootfs_contract(rootfs)
        source = rootfs.read_text()
        command = 'python3 -I -B "$SCRIPT_DIR/verify-camera-runtime-loader.py" --rootfs "$rootfs_dir"'
        self.assertEqual(source.count(command), 1)
        condition = 'if [ -n "${CAMERA_STACK_DEB_DIR:-}" ] || [ -f "$rootfs_dir/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1" ]; then'
        start = source.index(condition)
        end = source.index('\nfi', start) + 3
        block = source[start:end]
        mutations = (source.replace(command, 'true'),
                     source.replace(command, command + ' || true'),
                     source.replace(condition, 'if [ -f "$rootfs_dir/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1" ]; then'),
                     source.replace(condition, 'if [ -n "${CAMERA_STACK_DEB_DIR:-}" ]; then'),
                     source.replace(block, '') + '\n' + block + '\n')
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'rootfs.sh'
            for candidate in mutations:
                self.assertNotEqual(candidate, source)
                path.write_text(candidate)
                with self.assertRaises((RuntimeError, ValueError, SystemExit)):
                    workflow.validate_rootfs_contract(path)

    def run_image_gate(self, root, package_dir):
        source = (HERE / 'build-rootfs-image.sh').read_text()
        marker = source.index('  ci_log "validating camera dependencies with the target dynamic loader"')
        block = source[source.rindex('\nif ', 0, marker) + 1:source.index('\nfi', marker) + 3]
        return subprocess.run(['/bin/bash', '-eu', '-c', 'ci_log() { :; }\n' + block],
                              env={**M.ENV, 'rootfs_dir': str(root), 'SCRIPT_DIR': str(HERE),
                                   'CAMERA_STACK_DEB_DIR': package_dir},
                              capture_output=True, text=True, check=False)

    def test_image_gate_selection_and_missing_members(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.assertEqual(self.run_image_gate(root, '').returncode, 0)
            empty = self.run_image_gate(root, 'selected-camera-debs')
            self.assertNotEqual(empty.returncode, 0)
            self.assertIn('required camera loader seed is missing:', empty.stderr)
            # Use the package's real staging paths, including both prefix trees.
            paths = [root / name.lstrip('/') for name in M.SEEDS]
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            for name, path in zip(M.SEEDS, paths):
                with self.subTest(seed=name):
                    path.unlink()
                    result = self.run_image_gate(root, 'selected-camera-debs')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('required camera loader seed is missing: ' + name, result.stderr)
                    path.touch()
            paths[0].unlink()
            self.assertIn('required camera loader seed is missing: ' + M.SEEDS[0],
                          self.run_image_gate(root, '').stderr)

    @unittest.skipUnless(os.geteuid() == 0, 'actual chroot requires root')
    def test_complete_native_target_layout(self):
        host_loader = {'x86_64': '/lib64/ld-linux-x86-64.so.2', 'aarch64': '/lib/ld-linux-aarch64.so.1'}[platform.machine()]
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            loader = root / 'lib/ld-linux-aarch64.so.1'
            loader.parent.mkdir()
            shutil.copyfile(host_loader, loader)
            loader.chmod(0o755)
            for name in M.SEEDS:
                path = root / name.lstrip('/')
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile('/bin/true', path)
            libc = subprocess.check_output(['/usr/bin/cc', '-print-file-name=libc.so.6'], text=True).strip()
            shutil.copyfile(libc, root / M.LIB.lstrip('/') / 'libc.so.6')
            result = self.run_image_gate(root, 'selected-camera-debs')
            self.assertEqual((result.returncode, result.stdout.strip()), (0, 'CAMERA_TARGET_LOADER=PASS objects=7'), result.stderr)

    def test_host_root_rejected(self):
        with self.assertRaises(RuntimeError):
            M.verify_rootfs(pathlib.Path('/'))

    def test_real_version_failure_and_no_initializers(self):
        loader = {'x86_64': '/lib64/ld-linux-x86-64.so.2',
                  'aarch64': '/lib/ld-linux-aarch64.so.1'}[platform.machine()]
        with tempfile.TemporaryDirectory(prefix='tb321fu-loader-fixture-') as directory:
            root = pathlib.Path(directory)
            provider = root / 'provider.c'
            provider.write_text('int feature(void) { return 1; }')
            for label, version in (('old', 'VER_1'), ('new', 'VER_2')):
                target = root / label
                target.mkdir()
                script = target / 'version.map'
                script.write_text(version + ' { global: feature; local: *; };')
                subprocess.run(['/usr/bin/cc', '-shared', '-fPIC', str(provider),
                    '-Wl,-soname,libfixture.so.1', '-Wl,--version-script=' + str(script),
                    '-o', str(target / 'libfixture.so')], check=True, capture_output=True)
                (target / 'libfixture.so.1').symlink_to('libfixture.so')
            marker = root / 'initializer-ran'
            caller = root / 'caller.c'
            caller.write_text('#include <fcntl.h>\n#include <unistd.h>\n'
                'extern int feature(void); int call(void) { return feature(); }\n'
                '__attribute__((constructor)) void init(void) { int f = open(' + json.dumps(str(marker))
                + ', O_CREAT | O_WRONLY, 0600); if (f >= 0) close(f); }\n')
            output = root / 'consumer.so'
            subprocess.run(['/usr/bin/cc', '-shared', '-fPIC', str(caller), '-L' + str(root / 'new'),
                '-lfixture', '-o', str(output)], check=True, capture_output=True)
            valid = [loader, '--list', '--library-path', str(root / 'new'), str(output)]
            self.assertIn('libfixture.so.1', M.check_loader(valid))
            self.assertFalse(marker.exists(), '--list must never execute the application constructor')
            with self.assertRaisesRegex(RuntimeError, 'VER_2'):
                M.check_loader([loader, '--list', '--library-path', str(root / 'old'), str(output)])
            with self.assertRaisesRegex(RuntimeError, 'libfixture'):
                M.check_loader([loader, '--list', '--library-path', str(root / 'missing'), str(output)])
            self.assertFalse(marker.exists())

if __name__ == '__main__':
    unittest.main()
