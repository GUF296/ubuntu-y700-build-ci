#!/usr/bin/env python3
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEAL = HERE / "seal-machine-id.py"


class IdentityTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.root = self.base / "image"
        self.primary = self.root / "etc/machine-id"
        self.legacy = self.root / "var/lib/dbus/machine-id"
        self.primary.parent.mkdir(parents=True)
        self.legacy.parent.mkdir(parents=True)

    def invoke(self, ok=True, root=None):
        p = subprocess.run([sys.executable, "-IB", SEAL, root or self.root], capture_output=True)
        self.assertEqual(p.returncode == 0, ok, p.stderr)
        self.assertNotIn(b"synthetic", p.stderr + p.stdout)

    def primary_state(self):
        st = self.primary.lstat()
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual((stat.S_IMODE(st.st_mode), st.st_size), (0o644, 0))
        self.assertEqual(st.st_uid, os.geteuid())

    def test_regular_initial_and_repeat(self):
        outside = self.base / "sentinel"
        outside.write_bytes(b"synthetic fixture only")
        os.link(outside, self.primary)
        os.link(outside, self.legacy)
        for _ in range(2):
            self.invoke()
            self.primary_state()
            self.assertEqual(os.readlink(self.legacy), "../../../etc/machine-id")
            self.assertTrue(self.legacy.samefile(self.primary))
            self.assertEqual(outside.read_bytes(), b"synthetic fixture only")

    def test_prior_links(self):
        for target in ("/etc/machine-id", "../../../etc/machine-id", "./../../../etc/machine-id"):
            with self.subTest(target=target):
                self.legacy.symlink_to(target)
                self.invoke()
                self.primary_state()
                self.assertEqual(os.readlink(self.legacy), target)
                self.legacy.unlink()

    def test_absent_legacy(self):
        self.invoke()
        self.assertFalse(self.legacy.is_symlink())
        self.assertFalse(self.legacy.exists())
        self.legacy.parent.rmdir()
        self.invoke()
        self.primary_state()
        self.assertFalse(self.legacy.parent.exists())

    def test_reject_without_following(self):
        outside = self.base / "sentinel"
        outside.write_bytes(b"synthetic fixture only")
        self.primary.write_bytes(b"synthetic primary")
        for bad in (str(outside), "/etc/somewhere/../machine-id", "../../../etc/machine-id/"):
            self.legacy.symlink_to(bad)
            self.invoke(False)
            self.legacy.unlink()
        os.mkfifo(self.legacy)
        self.invoke(False)
        self.legacy.unlink()
        self.assertEqual(self.primary.read_bytes(), b"synthetic primary")
        self.primary.unlink()
        self.primary.symlink_to(outside)
        self.invoke(False)
        self.assertEqual(outside.read_bytes(), b"synthetic fixture only")

    def test_parent_policy(self):
        for parent in (self.primary.parent, self.root / "var", self.root / "var/lib", self.legacy.parent):
            parked = self.base / "parked"
            parent.rename(parked)
            parent.symlink_to(parked, target_is_directory=True)
            self.invoke(False)
            parent.unlink()
            parked.rename(parent)
        self.legacy.parent.chmod(0o777)
        self.invoke(False)
        self.assertFalse(self.primary.exists())
        self.invoke(False, "/")

    def test_final_order(self):
        script = (HERE / "build-rootfs-image.sh").read_text()
        marker = 'python3 -IB "$SCRIPT_DIR/seal-machine-id.py" "$rootfs_dir"'
        self.assertEqual(script.count(marker), 1)
        end = script.index(marker)
        for previous in ('rsync -aH --numeric-ids "$OVERLAY_DIR"', 'apply_tb321fu_gpu_sensor "$rootfs_dir"',
                         'ci_log "writing installed-package inventory"', 'ssh-policy-probe.sh'):
            self.assertLess(script.rindex(previous), end)
        self.assertLess(end, script.index('ci_log "writing manifest"'))
        self.assertNotIn("rm -f /etc/machine-id", script)


if __name__ == "__main__":
    unittest.main()
