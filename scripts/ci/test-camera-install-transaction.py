#!/usr/bin/env python3
"""Exercise manifest-valid policy failures and both sides of the commit boundary."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
from unittest import TestCase, main, mock


helper, verifier_path, overlay_source = map(Path, sys.argv[1:4])
del sys.argv[1:4]
spec = importlib.util.spec_from_file_location("camera_install_test_subject", helper)
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)
verifier = installer.load_verifier(verifier_path)
CAM = "opt/libcamera-y700/bin/cam"
TUNING = "opt/libcamera-y700/share/libcamera/ipa/simple/sc820cs.yaml"
GST = "usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"


class TransactionTest(TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="tb321fu-camera-commit-test-")
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)
        self.source = self.work / "source"
        self.target = self.work / "target"
        self.target.mkdir()
        self.manifest = self.work / "MANIFEST.tsv"
        shutil.copytree(overlay_source / "rootfs-overlay", self.source, symlinks=True)
        self.rehash()
        self.old_cam = self.target / CAM
        self.old_cam.parent.mkdir(parents=True)
        for directory in (self.target / "opt", self.target / "opt/libcamera-y700", self.old_cam.parent):
            directory.chmod(0o755)
        self.old_cam.write_bytes(b"original cam")
        self.old_cam.chmod(0o700)
        self.before = verifier.inspect_tree(self.target)[0]

    def rehash(self):
        members, _ = verifier.inspect_tree(self.source)
        with self.manifest.open("w", encoding="utf-8") as stream:
            print("path\ttype\tmode\tsize\tsha256\tlink_target", file=stream)
            for name in sorted(members):
                kind, mode, size, digest, link = members[name]
                print(name, kind, f"0{mode:03o}", size, digest, link, sep="\t", file=stream)
        self.manifest.chmod(0o644)

    def apply(self):
        with contextlib.redirect_stdout(io.StringIO()):
            installer.install(self.source, self.manifest, self.target, verifier_path, None)

    def assert_policy_rejection(self):
        self.rehash()
        # The generic closed-manifest verifier accepts the fixture. Rejection
        # must come from camera policy while all target bytes still match.
        with contextlib.redirect_stdout(io.StringIO()):
            verifier.verify(self.source, self.manifest, None)
        with self.assertRaises(installer.InstallError):
            self.apply()
        self.assertEqual(verifier.inspect_tree(self.target)[0], self.before)

    def test_marker(self):
        (self.source / CAM).write_bytes(b"camera: libcamera-y700-test")
        self.assert_policy_rejection()

    def test_strict_umask(self):
        prior = os.umask(0o077)
        try:
            self.apply()
        finally:
            os.umask(prior)
        self.assertEqual(verifier.inspect_tree(self.target)[0], verifier.inspect_tree(self.source)[0])

    def test_missing_tuning(self):
        (self.source / TUNING).unlink()
        self.assert_policy_rejection()

    def test_non_executable_cam(self):
        (self.source / CAM).chmod(0o644)
        self.assert_policy_rejection()

    def test_gstreamer_link(self):
        path = self.source / GST
        path.unlink()
        path.symlink_to("/opt/libcamera-y700/wrong-plugin")
        self.assert_policy_rejection()

    def test_commit_sync_failure_restores_target(self):
        real_fsync = os.fsync
        root = self.target.stat()
        def sync(fd):
            if os.path.samestat(root, os.fstat(fd)):
                raise OSError("target directory sync failed")
            real_fsync(fd)
        with mock.patch.object(os, "fsync", sync), self.assertRaisesRegex(OSError, "target directory sync"):
            self.apply()
        self.assertEqual(verifier.inspect_tree(self.target)[0], self.before)

    def test_cleanup_failure_reports_committed_result(self):
        real_rmtree = shutil.rmtree
        def cleanup(directory, *args, **kwargs):
            if Path(directory).name.startswith(".tb321fu-camera-committed."):
                raise OSError("injected retired cleanup failure")
            return real_rmtree(directory, *args, **kwargs)
        warnings = io.StringIO()
        with mock.patch.object(shutil, "rmtree", cleanup), contextlib.redirect_stderr(warnings):
            self.apply()
        retired, = self.target.glob(".tb321fu-camera-committed.*")
        self.assertIn(str(retired), warnings.getvalue())
        self.assertEqual(list(self.target.glob(".tb321fu-camera-txn.*")), [])
        self.assertEqual(self.old_cam.read_bytes(), (self.source / CAM).read_bytes())
        self.apply()
        self.assertEqual(self.old_cam.read_bytes(), (self.source / CAM).read_bytes())


if __name__ == "__main__":
    main()
