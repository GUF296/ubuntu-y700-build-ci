import importlib.util
import hashlib
from pathlib import Path
import os
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location("hosted_bison", Path(__file__).with_name("with-hosted-bison-fixture.py"))
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class BisonFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.official, self.host = (Path(self.tmp.name) / n for n in ("official", "installed"))
        for root in (self.official, self.host):
            root.mkdir()
            root.chmod(0o755)
            f = root / "c++.m4"
            f.write_bytes(b"ordinary fixture data")
            f.chmod(0o644)

    def test_matching_and_mode_only(self):
        expected = b.tree(self.official, True)
        self.assertEqual([], b.compare(expected, b.tree(self.host)))
        self.host.chmod(0o775)
        (self.host / "c++.m4").chmod(0o664)
        self.assertEqual([(".", 0o775, 0o755), ("c++.m4", 0o664, 0o644)],
                         b.compare(expected, b.tree(self.host)))
        self.assertEqual(0o775, stat.S_IMODE(self.host.stat().st_mode))
        with self.assertRaisesRegex(ValueError, "official Bison data mode"):
            b.tree(self.host, True)

    def test_changed_bytes_and_membership(self):
        expected = b.tree(self.official, True)
        self.assertEqual(b.seal(expected), b.seal(dict(reversed(list(expected.items())))))
        data = self.host / "c++.m4"
        data.write_bytes(b"changed")
        self.assertNotEqual(b.seal(expected), b.seal(b.tree(self.host)))
        with self.assertRaisesRegex(ValueError, "bytes"):
            b.compare(expected, b.tree(self.host))
        data.rename(self.host / "other")
        with self.assertRaisesRegex(ValueError, "membership"):
            b.compare(expected, b.tree(self.host))

    def test_links_and_nonfiles(self):
        path = self.host / "additional"
        path.symlink_to(self.host / "c++.m4")
        with self.assertRaisesRegex(ValueError, "unsupported"):
            b.tree(self.host)
        path.unlink()
        os.link(self.host / "c++.m4", path)
        with self.assertRaisesRegex(ValueError, "unsupported"):
            b.tree(self.host)
        path.unlink()
        os.mkfifo(path)
        with self.assertRaisesRegex(ValueError, "unsupported"):
            b.tree(self.host)

    def test_package_bytes_and_control_are_independent(self):
        t = Path(self.tmp.name)
        pkg, download = t / "pkg", t / "download"
        (pkg / "DEBIAN").mkdir(parents=True)
        download.mkdir()
        (pkg / "DEBIAN/control").write_text("Package: bison\nVersion: 1\nArchitecture: all\n"
                                            "Maintainer: Fixture <fixture@example.invalid>\nDescription: local test\n")
        deb = download / "sample.deb"
        subprocess.run(["/usr/bin/dpkg-deb", "--build", str(pkg), str(deb)],
                       check=True, stdout=subprocess.DEVNULL)
        data = deb.read_bytes()
        sha, size = hashlib.sha256(data).hexdigest(), len(data)
        self.assertEqual(str(deb), b.checked_deb(download, "all", "1", size, sha))
        for arch, version, n, digest in (("arm64", "1", size, sha), ("all", "2", size, sha),
                                         ("all", "1", size - 1, sha), ("all", "1", size, "0" * 64)):
            with self.assertRaises(ValueError):
                b.checked_deb(download, arch, version, n, digest)

    def test_incomplete_or_writable_view_not_accepted(self):
        owner = os.getuid()
        with mock.patch.object(b, "HOST", self.host):
            with self.assertRaises(ValueError):
                b.verify_mount(self.official, owner, os.getgid(), b.seal(b.tree(self.official)))
            with self.assertRaises(ValueError):
                b.verify_mount(self.host, owner, os.getgid(), b.seal(b.tree(self.host)))
        with self.assertRaises(ValueError):
            b.main(["--", "bash", "not-the-fixture.sh"])


if __name__ == "__main__":
    unittest.main()
