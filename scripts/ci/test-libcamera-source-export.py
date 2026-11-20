#!/usr/bin/env python3
"""Hostile and reproducibility fixtures for the operator-side source exporter."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "libcamera_source_export", SCRIPT_DIR / "export-libcamera-source.py"
)
assert spec is not None and spec.loader is not None
exporter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = exporter
spec.loader.exec_module(exporter)

class SourceExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tb321fu-libcamera-export-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.write("meson.build", b"project('libcamera', 'cpp', version : '0.7.1')\n")
        self.write("src/basic.cpp", b"// baseline\n")
        self.write("utils/version.sh", b"#!/bin/sh\nexit 0\n", 0o755)
        self.write("LICENSES/GPL-2.0-only.txt", b"fixture license\n")
        (self.source / "LICENSES/GPL-2.0.txt").symlink_to("GPL-2.0-only.txt")
        self.write(".gitignore", b"/build/\n")
        self.git("init", "-q", "--object-format=sha1")
        self.git("add", ".")
        self.git("-c", "user.name=Source Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-qm", "fixture baseline")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        for name in exporter.EXTRA_FILES:
            self.write(name, b"fixture extra source\n")
        self.write("src/basic.cpp", b"// reviewed working-tree repair\n")
        self.write("build/src/ipa-priv-key.pem", b"DO-NOT-EXPORT fixture private input\n", 0o600)

    def git(self, *arguments):
        env = dict(exporter.GIT_ENV, GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000",
                   GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000")
        return subprocess.check_output(["/usr/bin/git", "-C", str(self.source), *arguments],
                                       env=env, stderr=subprocess.PIPE, timeout=10)

    def write(self, name, data, mode=0o644):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)

    def run_export(self, name="output"):
        return exporter.export_source(self.source, self.root / name, self.commit)

    def test_reproducible_complete_source_and_stable_version(self):
        first = self.run_export("one")
        os.utime(self.source / "src/basic.cpp", (1234567890, 1234567890))
        second = self.run_export("two")
        self.assertEqual(first, second)
        for name in ("libcamera-source.tar.xz", "SOURCE-MANIFEST.tsv", "SOURCE-LOCK.json"):
            self.assertEqual((self.root / "one" / name).read_bytes(),
                             (self.root / "two" / name).read_bytes())
        with tarfile.open(self.root / "one/libcamera-source.tar.xz") as bundle:
            names = bundle.getnames()
            self.assertNotIn("libcamera/.git/config", names)
            self.assertFalse(any("ipa-priv-key.pem" in name or "/build/" in name for name in names))
            self.assertEqual(bundle.extractfile("libcamera/src/basic.cpp").read(),
                             b"// reviewed working-tree repair\n")
            self.assertEqual(bundle.extractfile("libcamera/.tarball-version").read().decode(),
                             first["version"] + "\n")
            self.assertTrue(bundle.getmember("libcamera/LICENSES/GPL-2.0.txt").issym())
            self.assertEqual(bundle.getmember("libcamera/utils/version.sh").mode, 0o755)
            for member in bundle.getmembers():
                self.assertEqual((member.uid, member.gid, member.mtime), (0, 0, 946684800))
        self.assertEqual(hashlib.sha256((self.root / "one/libcamera-source.tar.xz").read_bytes()).hexdigest(),
                         first["archive_sha256"])
        self.assertFalse((self.source / ".tarball-version").exists())

    def test_content_change_changes_identity(self):
        first = self.run_export("one")
        self.write("src/basic.cpp", b"// another reviewed repair\n")
        second = self.run_export("two")
        self.assertNotEqual(first["source_tree_sha256"], second["source_tree_sha256"])
        self.assertNotEqual(first["version"], second["version"])
        self.assertNotEqual(first["archive_sha256"], second["archive_sha256"])

    def test_existing_output_is_not_overwritten(self):
        output = self.root / "output"
        output.mkdir()
        marker = output / "user-data"
        marker.write_text("preserve")
        with self.assertRaises(exporter.ExportError):
            self.run_export()
        self.assertEqual(marker.read_text(), "preserve")

    def test_racing_output_is_not_overwritten(self):
        promote = exporter.promote
        def race(staging, output):
            output.mkdir()
            (output / "user-data").write_text("preserve")
            promote(staging, output)
        with mock.patch.object(exporter, "promote", race):
            with self.assertRaises(exporter.ExportError):
                self.run_export()
        self.assertEqual((self.root / "output/user-data").read_text(), "preserve")
        self.assertFalse(list(self.root.glob(".libcamera-source-export.*")))

    def test_wrong_commit_and_staged_change_are_rejected(self):
        with self.assertRaises(exporter.ExportError):
            exporter.export_source(self.source, self.root / "wrong", "0" * 40)
        self.git("add", "src/basic.cpp")
        with self.assertRaises(exporter.ExportError):
            self.run_export()
        self.assertFalse((self.root / "output").exists())

    def test_external_link_is_rejected(self):
        link = self.source / "LICENSES/GPL-2.0.txt"
        link.unlink()
        link.symlink_to("../../outside")
        with self.assertRaises(exporter.ExportError):
            self.run_export()

    def test_symlink_parent_and_hardlink_are_rejected(self):
        (self.source / "src").rename(self.source / "real-src")
        (self.source / "src").symlink_to("real-src", target_is_directory=True)
        with self.assertRaises((exporter.ExportError, OSError)):
            self.run_export()
        (self.source / "src").unlink()
        (self.source / "real-src").rename(self.source / "src")
        os.link(self.source / "src/basic.cpp", self.root / "outside-link")
        with self.assertRaises(exporter.ExportError):
            self.run_export()

    def test_input_version_override_is_rejected(self):
        self.write(".tarball-version", b"misleading-version\n")
        with self.assertRaises(exporter.ExportError):
            self.run_export()

    def test_source_change_during_capture_is_rejected(self):
        original = exporter.read_member
        changed = False
        def capture(*args):
            nonlocal changed
            member = original(*args)
            if member.path != ".gitignore" and not changed:
                self.write(".gitignore", b"/build/\n# changed during snapshot\n")
                changed = True
            return member
        with mock.patch.object(exporter, "read_member", capture):
            with self.assertRaises(exporter.ExportError):
                self.run_export()
        self.assertTrue(changed)
        self.assertFalse((self.root / "output").exists())

    def test_output_alias_into_source_is_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(exporter.ExportError):
            exporter.export_source(self.source, alias / "output", self.commit)
        self.assertFalse((self.source / "output").exists())

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SourceExportTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    print("LIBCAMERA_SOURCE_EXPORT_FIXTURES=PASS")
