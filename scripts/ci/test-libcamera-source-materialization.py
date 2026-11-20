#!/usr/bin/env python3
"""Validate the complete committed source package and its hostile boundaries."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "libcamera_source_materialization", SCRIPT_DIR / "materialize-libcamera-source.py"
)
assert spec is not None and spec.loader is not None
consumer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = consumer
spec.loader.exec_module(consumer)

class SourceMaterializationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tb321fu-libcamera-materialization-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.profile = self.root / "profile"
        shutil.copytree(consumer.PROFILE, self.profile)
        self.output = self.root / "source"

    def lock(self):
        return json.loads((self.profile / "SOURCE-LOCK.json").read_text())

    def write_lock(self, lock):
        (self.profile / "SOURCE-LOCK.json").write_text(json.dumps(lock, sort_keys=True) + chr(10))

    def reject(self):
        with self.assertRaises((consumer.SourceError, consumer.exporter.ExportError, OSError)):
            consumer.materialize(self.profile, self.output)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".libcamera-materialize.*")))

    def rewrite_archive(self, *, add=False, skip=False):
        archive = self.profile / "libcamera-source.tar.xz"
        source = archive.read_bytes()
        result = io.BytesIO()
        removed = False
        with tarfile.open(fileobj=io.BytesIO(source), mode="r:xz") as old:
            with tarfile.open(fileobj=result, mode="w:xz", format=tarfile.PAX_FORMAT) as new:
                for info in old:
                    if skip and info.isfile() and not removed:
                        removed = True
                        continue
                    if info.isfile():
                        with old.extractfile(info) as stream:
                            new.addfile(info, stream)
                    else:
                        new.addfile(info)
                if add:
                    member = tarfile.TarInfo("libcamera/UNREVIEWED")
                    member.mode, member.size = 0o644, 3
                    member.mtime = self.lock()["source_epoch"]
                    new.addfile(member, io.BytesIO(b"bad"))
        archive.write_bytes(result.getvalue())
        lock = self.lock()
        lock["archive_sha256"] = hashlib.sha256(result.getvalue()).hexdigest()
        lock["archive_bytes"] = len(result.getvalue())
        self.write_lock(lock)

    def test_actual_source_and_version_are_independent_of_git_and_clock(self):
        lock = consumer.materialize(self.profile, self.output)
        self.assertTrue((self.output / "src/libcamera/software_isp/swstats_cpu.cpp").is_file())
        self.assertTrue((self.output / "LICENSES/GPL-2.0.txt").is_symlink())
        self.assertFalse((self.output / ".git").exists())
        self.assertFalse(list(self.output.rglob("ipa-priv-key.pem")))
        expected = (lock["version"] + chr(10)).encode()
        for timezone in ("UTC", "Asia/Tokyo"):
            result = subprocess.run(
                ["/bin/sh", str(self.output / "utils/gen-version.sh"),
                 str(self.root / "no-build"), str(self.output)],
                cwd=self.output, env={"PATH": "/usr/bin:/bin", "TZ": timezone,
                                     "GIT_DIR": "/definitely-not-a-repository"},
                capture_output=True, check=True, timeout=5,
            )
            self.assertEqual(result.stdout, expected)
            self.assertEqual(result.stderr, b"")
        self.assertFalse(list(self.root.glob(".libcamera-materialize.*")))

    def test_archive_corruption_and_extra_profile_file_are_rejected(self):
        archive = self.profile / "libcamera-source.tar.xz"
        original = archive.read_bytes()
        archive.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
        self.reject()
        archive.write_bytes(original)
        (self.profile / "EXTRA").write_text("not a source input")
        self.reject()

    def test_private_caller_umask_preserves_canonical_source_modes(self):
        old = os.umask(0o077)
        try:
            consumer.materialize(self.profile, self.output)
        finally:
            os.umask(old)
        self.assertEqual((self.output / 'src').stat().st_mode & 0o7777, 0o755)
        self.assertEqual((self.output / 'meson.build').stat().st_mode & 0o7777, 0o644)
        self.assertEqual((self.output / 'utils/gen-version.sh').stat().st_mode & 0o7777, 0o755)
        self.assertEqual(self.root.stat().st_mode & 0o7777, 0o700)

    def test_duplicate_lock_fields_are_rejected(self):
        lock_file = self.profile / "SOURCE-LOCK.json"
        text = lock_file.read_text().rstrip()
        lock_file.write_text(text[:-1] + ',"version":"forged"}' + chr(10))
        self.reject()

    def test_self_consistent_archive_extra_member_is_rejected(self):
        self.rewrite_archive(add=True)
        self.reject()

    def test_self_consistent_archive_missing_member_is_rejected(self):
        self.rewrite_archive(skip=True)
        self.reject()

    def test_forged_source_version_and_count_are_rejected(self):
        original = self.lock()
        changed = dict(original, version="0.7.1+not-the-source")
        self.write_lock(changed)
        self.reject()
        self.write_lock(dict(original, members=original["members"] + 1))
        self.reject()

    def test_profile_links_are_rejected(self):
        lock_file = self.profile / "SOURCE-LOCK.json"
        original = lock_file.read_bytes()
        external = self.root / "external-lock"
        external.write_bytes(original)
        lock_file.unlink()
        lock_file.symlink_to(external)
        self.reject()
        lock_file.unlink()
        os.link(external, lock_file)
        self.reject()

    def test_existing_and_racing_output_are_preserved(self):
        self.output.mkdir()
        marker = self.output / "user-data"
        marker.write_text("preserve")
        with self.assertRaises(consumer.SourceError):
            consumer.materialize(self.profile, self.output)
        self.assertEqual(marker.read_text(), "preserve")
        marker.unlink()
        self.output.rmdir()
        promote = consumer.exporter.promote
        def race(source, output):
            output.mkdir()
            (output / "user-data").write_text("preserve")
            promote(source, output)
        with mock.patch.object(consumer.exporter, "promote", race):
            with self.assertRaises(consumer.exporter.ExportError):
                consumer.materialize(self.profile, self.output)
        self.assertEqual(marker.read_text(), "preserve")
        self.assertFalse(list(self.root.glob(".libcamera-materialize.*")))

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SourceMaterializationTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    print("LIBCAMERA_SOURCE_MATERIALIZATION_FIXTURES=PASS")
