#!/usr/bin/env python3
"""Camera publication contract tests; no package install or network activity."""
import hashlib
import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('camera_release_tests', HERE / 'verify-camera-release-assets.py')
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)
H, P = R.handoff, R.policy
REPOSITORY = 'owner/repository'
COMMIT = '0123456789abcdef0123456789abcdef01234567'
RUN_ID, RUN_ATTEMPT = '123456789', '1'

spec = importlib.util.spec_from_file_location('camera_package_publish', HERE / 'publish-camera-package.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class CameraPackagePublicationTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='tb321fu-camera-output-test-')
        self.addCleanup(scratch.cleanup)
        self.scratch = pathlib.Path(scratch.name)
        self.source, self.output = self.scratch / 'source', self.scratch / 'output'
        self.source.mkdir()
        self.output.mkdir()
        self.deb = 'tb321fu-camera-stack_1.0~test+1_arm64.deb'
        self.names = (publisher.REPORT, publisher.CHECKSUM, self.deb)
        for name in self.names:
            (self.source / name).write_text('source ' + name)
        self.unrelated = self.output / 'unrelated'
        self.unrelated.write_bytes(b'keep')

    def assert_publication(self):
        self.assertEqual(set(self.output.iterdir()), {self.unrelated, *(self.output / name for name in self.names)})
        self.assertEqual(self.unrelated.read_bytes(), b'keep')
        for name in self.names:
            final = self.output / name
            self.assertEqual(final.read_bytes(), (self.source / name).read_bytes())
            self.assertEqual(final.stat().st_mode & 0o777, 0o644)
            self.assertEqual(final.stat().st_nlink, 1)

    def test_preexisting_output_directory_and_concurrent_publishers(self):
        cmd = [sys.executable, '-I', '-B', str(HERE / 'publish-camera-package.py'),
               str(self.output), self.deb, str(self.source)]
        with subprocess.Popen(cmd, stderr=subprocess.PIPE) as first, subprocess.Popen(cmd, stderr=subprocess.PIPE) as second:
            responses = [proc.communicate(timeout=10)[1] for proc in (first, second)]
            self.assertEqual(sorted([first.returncode, second.returncode]), [0, 1])
        self.assertIn(b'refusing replacement', b''.join(responses))
        self.assert_publication()

    def test_failed_copy_and_late_name_collision(self):
        (self.source / self.deb).unlink()
        with self.assertRaises(FileNotFoundError):
            publisher.publish(self.output, self.deb, self.source)
        self.assertEqual(list(self.output.iterdir()), [self.unrelated])
        (self.source / self.deb).write_text('package')
        link = os.link
        def compete(source, destination):
            if destination.name == publisher.CHECKSUM:
                destination.write_text('other writer')
            link(source, destination)
        with mock.patch.object(publisher.os, 'link', side_effect=compete), self.assertRaises(FileExistsError):
            publisher.publish(self.output, self.deb, self.source)
        self.assertEqual((self.output / publisher.CHECKSUM).read_text(), 'other writer')
        self.assertEqual(set(self.output.iterdir()), {self.output / publisher.CHECKSUM, self.unrelated})

    def test_directory_lock_spans_preflight_and_publication(self):
        import fcntl
        descriptor = os.open(self.output, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        publisher.publish(self.output, self.deb, inherited_lock_fd=descriptor)
        rival = os.open(self.output, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, rival)
        with self.assertRaises(BlockingIOError):
            fcntl.flock(rival, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with self.assertRaisesRegex(RuntimeError, 'descriptor'):
            publisher.publish(self.source, self.deb, inherited_lock_fd=descriptor)
        publisher.publish(self.output, self.deb, self.source, descriptor)
        self.assert_publication()

    def test_symlink_ancestor_and_legacy_lock(self):
        alias = self.scratch / 'alias'
        alias.symlink_to(self.scratch, target_is_directory=True)
        with self.assertRaises(OSError):
            publisher.publish(alias / 'output', self.deb, self.source)
        legacy = self.output / '.tb321fu-camera-package.lock'
        legacy.symlink_to(self.unrelated)
        with self.assertRaisesRegex(RuntimeError, 'legacy'):
            publisher.publish(self.output, self.deb, self.source)
        self.assertTrue(legacy.is_symlink())
        self.assertEqual(self.unrelated.read_bytes(), b'keep')

    def test_files_and_sidecars_are_durable_before_deb_link(self):
        fsync, link = os.fsync, os.link
        synced_files = set()
        sidecars_synced = False
        def record_sync(fd):
            nonlocal sidecars_synced
            path = pathlib.Path(os.readlink(f'/proc/self/fd/{fd}'))
            if path.parent == self.output / publisher.TRANSACTION and path.name in self.names:
                self.assertEqual(path.read_bytes(), (self.source / path.name).read_bytes())
                synced_files.add(path.name)
            fsync(fd)
            if path == self.output and not (path / self.deb).exists():
                sidecars_synced |= all((path / name).exists() for name in self.names[:-1])
        def checked_link(source, destination):
            self.assertEqual(synced_files, set(self.names))
            if destination.name == self.deb:
                self.assertTrue(sidecars_synced)
            link(source, destination)
        with mock.patch.object(os, 'fsync', side_effect=record_sync), mock.patch.object(os, 'link', side_effect=checked_link):
            publisher.publish(self.output, self.deb, self.source)
        self.assert_publication()

    def test_recovery_at_each_link_boundary(self):
        for name in self.names:
            with self.subTest(interrupted_after=name):
                link = os.link
                def die_after_link(source, destination):
                    link(source, destination)
                    if destination.name == name:
                        os._exit(42)
                pid = os.fork()
                if pid == 0:
                    try:
                        with mock.patch.object(publisher.os, 'link', side_effect=die_after_link):
                            publisher.publish(self.output, self.deb, self.source)
                    finally:
                        os._exit(99)
                self.assertEqual(os.waitpid(pid, 0)[1], 42 << 8)
                self.assertEqual((self.output / self.deb).exists(), name == self.deb)
                if name == self.deb:
                    with self.assertRaises(FileExistsError):
                        publisher.publish(self.output, self.deb)
                else:
                    publisher.publish(self.output, self.deb)
                    self.assertEqual(list(self.output.iterdir()), [self.unrelated])
                    publisher.publish(self.output, self.deb, self.source)
                self.assert_publication()
                for member in self.names:
                    (self.output / member).unlink()

def create_fixture(destination):
    destination.mkdir(mode=0o755, parents=True, exist_ok=True)
    destination.chmod(0o755)
    context = H.Context('1', 'arm64', P.approved_version(), REPOSITORY, COMMIT, RUN_ID, RUN_ATTEMPT, '', '', '')
    names = (context.deb_name, H.CHECKSUM_NAME, H.MANIFEST_NAME, R.RELEASE_REPORT)
    if any((destination / name).exists() or (destination / name).is_symlink() for name in names):
        raise RuntimeError('fixture refuses to replace an existing camera asset')
    with tempfile.TemporaryDirectory(prefix='tb321fu-camera-publication-fixture-') as temporary:
        producer = pathlib.Path(temporary) / 'producer'
        producer.mkdir(mode=0o755)
        producer.chmod(0o755)
        deb = b'synthetic camera publication protocol fixture'
        digest = hashlib.sha256(deb).hexdigest()
        (producer / context.deb_name).write_bytes(deb)
        (producer / H.CHECKSUM_NAME).write_text(digest + '  ' + context.deb_name + chr(10))
        lines = ['TB321FU_CAMERA_STACK_DEB_BUILD=PASS', 'version=' + context.version,
            'arch=arm64', 'camera_input_kind=repository', 'deb=' + context.deb_name,
            'camera_source_sha256=' + '2'*64, 'camera_producer_manifest_sha256=' + '3'*64,
            'camera_toolchain_sha256=' + '4'*64, 'camera_link_build_id=' + '5'*40,
            'camera_overlay_manifest_sha256=' + '6'*64, 'camera_plugin_sha256=' + '7'*64,
            digest + '  ' + context.deb_name, '',
            'libcamera_runtime_manifest_sha256=' + '8'*64,
            '== complete runtime build provenance (public inputs only) ==',
            'synthetic opaque report body for handoff-format testing']
        (producer / H.REPORT_NAME).write_text(chr(10).join(lines) + chr(10))
        for path in producer.iterdir():
            path.chmod(0o644)
        H.create(producer, context)
        H.verify(producer, context)
        for name in (context.deb_name, H.CHECKSUM_NAME, H.MANIFEST_NAME, H.REPORT_NAME):
            target = R.RELEASE_REPORT if name == H.REPORT_NAME else name
            shutil.copyfile(producer / name, destination / target)
            (destination / target).chmod(0o644)
    return context

class CameraReleaseTests(unittest.TestCase):
    def test_actual_builder_report_framing_and_old_order_mutation(self):
        source = (HERE / 'build-tb321fu-camera-stack-deb.sh').read_text()
        start = '    echo "TB321FU_CAMERA_STACK_DEB_BUILD=PASS"'
        end = '    echo "== complete runtime build provenance (public inputs only) =="'
        self.assertEqual(source.count(start), 1)
        self.assertEqual(source.count(end), 1)
        prefix = source.split(start, 1)[1].split(end, 1)[0]
        prefix = start + prefix
        checksum = '    (cd "$OUTPUT_DIR" && sha256sum "$(basename -- "$deb")")\n    echo\n'
        self.assertEqual(prefix.count(checksum), 1)
        context = H.Context('1', 'arm64', P.approved_version(), REPOSITORY, COMMIT, RUN_ID, RUN_ATTEMPT, '', '', '')
        with tempfile.TemporaryDirectory(prefix='tb321fu-camera-report-framing-') as temporary:
            root = pathlib.Path(temporary)
            for name in ('source', 'plugin', 'overlay', 'SOURCE-MANIFEST.tsv', 'TOOLCHAIN.tsv',
                         'RUNTIME-MANIFEST.tsv', 'BUILD-PROVENANCE.json', context.deb_name):
                (root / name).write_bytes(b'synthetic report-framing input')
            environment = {'PATH': '/usr/bin:/bin', 'CAMERA_STACK_DEB_VERSION': context.version,
                'ARCH': context.arch, 'camera_input_kind': context.source_kind,
                'deb': str(root / context.deb_name), 'OUTPUT_DIR': str(root),
                'camera_verified_plugin_source': str(root / 'source'),
                'camera_verified_producer': str(root), 'camera_link_build_id': '5'*40,
                'camera_overlay_manifest': str(root / 'overlay'),
                'camera_built_plugin': str(root / 'plugin'), 'camera_runtime_output': str(root)}
            digest = hashlib.sha256((root / context.deb_name).read_bytes()).hexdigest()
            def render(fragment):
                return subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + fragment],
                    env=environment, text=True, capture_output=True, check=True, timeout=10).stdout
            H.parse_report(render(prefix), context, digest)
            # Recreate the real r2 defect: provenance precedes the DEB checksum.
            old_order = prefix.replace(checksum, '', 1) + checksum
            with self.assertRaises(RuntimeError):
                H.parse_report(render(old_order), context, digest)

    def verify(self, root, **overrides):
        arguments = dict(repository=REPOSITORY, commit=COMMIT, run_id=RUN_ID, run_attempt=RUN_ATTEMPT)
        arguments.update(overrides)
        R.verify(root, **arguments)

    def test_valid_publication_alias_and_other_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'assets'
            create_fixture(root)
            (root / 'rootfs.img.7z').write_bytes(b'other release asset')
            self.verify(root)

    def test_each_camera_asset_is_required(self):
        for name in (P.deb_name(), H.CHECKSUM_NAME, H.MANIFEST_NAME, R.RELEASE_REPORT):
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / 'assets'
                create_fixture(root)
                (root / name).unlink()
                with self.subTest(name=name), self.assertRaises((RuntimeError, OSError)):
                    self.verify(root)

    def test_context_must_match_exact_source_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'assets'
            create_fixture(root)
            for changes in ({'repository': 'other/repository'}, {'commit': 'f'*40},
                            {'run_id': '2'}, {'run_attempt': '2'}):
                with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                    self.verify(root, **changes)

    def test_payload_and_checksum_cannot_be_rebound(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'assets'
            create_fixture(root)
            changed = b'changed published package'
            (root / P.deb_name()).write_bytes(changed)
            (root / H.CHECKSUM_NAME).write_text(hashlib.sha256(changed).hexdigest() + '  ' + P.deb_name() + chr(10))
            with self.assertRaises(RuntimeError):
                self.verify(root)

    def test_report_body_and_manifest_tampering_fail(self):
        for name in (R.RELEASE_REPORT, H.MANIFEST_NAME):
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / 'assets'
                create_fixture(root)
                with (root / name).open('ab') as stream:
                    stream.write(b'changed')
                with self.subTest(name=name), self.assertRaises(RuntimeError):
                    self.verify(root)

    def test_aliases_and_bad_modes_fail(self):
        for kind in ('symlink', 'hardlink', 'mode'):
            with tempfile.TemporaryDirectory() as directory:
                parent = pathlib.Path(directory)
                root = parent / 'assets'
                create_fixture(root)
                selected = root / P.deb_name()
                if kind == 'mode':
                    selected.chmod(0o666)
                else:
                    saved = parent / 'package'
                    selected.rename(saved)
                    if kind == 'symlink':
                        selected.symlink_to(saved)
                    else:
                        os.link(saved, selected)
                with self.subTest(kind=kind), self.assertRaises((RuntimeError, OSError)):
                    self.verify(root)

    def test_version_policy_framing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'version'
            path.write_bytes(b'20260929.3' + bytes([10]))
            path.chmod(0o644)
            self.assertEqual(P.approved_version(path), '20260929.3')
            for data in (b'', b'v1'+bytes([10]), b'1-', b'1'+bytes([10,10]),
                         b'1/unsafe'+bytes([10]), b'1'+bytes([13,10]), b'1~test'+bytes([10])):
                path.write_bytes(data)
                with self.subTest(data=data), self.assertRaises(RuntimeError):
                    P.approved_version(path)

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--write-fixture':
        create_fixture(pathlib.Path(sys.argv[2]))
    else:
        unittest.main()
