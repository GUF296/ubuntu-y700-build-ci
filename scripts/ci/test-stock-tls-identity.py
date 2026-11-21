"""Run in a private mount namespace, as (possibly user-namespace) root."""
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest


P = runpy.run_path(str(Path(__file__).with_name("stock-tls-identity.py")))


class StockTLS(unittest.TestCase):
    def setUp(self):
        self.assertEqual(os.geteuid(), 0, "run inside a private root mount namespace")
        self.assertNotEqual(os.readlink("/proc/self/ns/mnt"), PARENT_NS)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for rel in ("usr/sbin", "var/lib/dpkg"):
            (self.root / rel).mkdir(parents=True)
        (self.root / "var/lib/dpkg/status").touch()
        self.addCleanup(self.clean_mount)

    def clean_mount(self):
        ram = self.root / P["RAM"]
        if ram.is_mount():
            subprocess.run(["umount", "--", str(ram)], check=True)

    def test_ca_refresh_keeps_public_link_but_first_generation_is_due(self):
        root = self.root
        receipt = P["prepare"](root)
        ram = root / P["RAM"]
        pem, key = (ram / P[k].name for k in ("CERT", "KEY"))
        self.assertEqual((pem.stat().st_mode & 0o777, pem.stat().st_size), (0o644, 0))
        self.assertEqual(pem.stat().st_dev, ram.stat().st_dev)
        self.assertNotEqual(ram.stat().st_dev, root.stat().st_dev)
        self.assertFalse(os.path.lexists(key))
        # Resolve absolute output links inside the build root, as package
        # scripts do. Reproduce only the updater's dangling-link decision.
        child = os.fork()
        if child == 0:
            try:
                os.chroot(root)
                os.chdir("/")
                cert, private = (Path("/") / P[k] for k in ("CERT", "KEY"))
                if cert.is_symlink() and not cert.exists():
                    cert.unlink()
                ok = cert.is_symlink() and cert.is_file() and private.is_symlink() and not private.exists()
                os._exit(0 if ok else 1)
            except BaseException:
                os._exit(2)
        self.assertEqual(os.waitstatus_to_exitcode(os.waitpid(child, 0)[1]), 0)
        P["intercept"](root, receipt)
        P["seal"](root, receipt)
        self.assertFalse(any(os.path.lexists(root / rel) for rel in (*P["FILES"], P["RAM"])))

    def test_minimal_without_ssl_cert(self):
        receipt = P["prepare"](self.root)
        P["intercept"](self.root, receipt)
        self.assertEqual((self.root / P["GEN"][1:]).read_bytes(), P["WRAPPER"])
        P["seal"](self.root, receipt)
        for rel in (*P["FILES"], P["RAM"], P["GEN"][1:], P["REAL"][1:], "etc/ssl"):
            self.assertFalse(os.path.lexists(self.root / rel))

    def test_installed_service_and_untouched_trust(self):
        root = self.root
        gen = root / P["GEN"][1:]
        stock = b"#!/bin/sh\nexit 0\n"
        gen.write_bytes(stock)
        gen.chmod(0o755)
        unit, enable = (root / P[k] for k in ("UNIT", "ENABLE"))
        unit.parent.mkdir(parents=True)
        unit.write_text("ConditionPathExists=!/etc/ssl/private/ssl-cert-snakeoil.key\n"
                        "ExecStart=-/usr/sbin/make-ssl-cert generate-default-snakeoil --force-overwrite\n")
        enable.parent.mkdir(parents=True)
        enable.symlink_to("/" + P["UNIT"])
        (root / "var/lib/dpkg/status").write_text("Package: ssl-cert\nStatus: install ok installed\n"
            "Architecture: all\nVersion: 1\nDescription: fixture\nMaintainer: fixture <test@example.invalid>\n")
        r = P["prepare"](root)
        P["intercept"](root, r)
        trust = root / P["CERT"].parent / "unrelated.pem"
        trust.write_bytes(b"unrelated fixture\n")
        other = trust.with_name("bada1234.0")
        other.symlink_to(trust.name)
        owned = trust.with_name("feed1234.0")
        owned.symlink_to(P["CERT"].name)
        for src, alias in zip(P["FILES"], P["BROKEN"], strict=True):
            (root / alias).symlink_to("/" + str(P["RAM"] / src.name))
        P["seal"](root, r)
        self.assertEqual(gen.read_bytes(), stock)
        self.assertEqual(trust.read_bytes(), b"unrelated fixture\n")
        self.assertEqual(os.readlink(other), trust.name)
        self.assertEqual(os.readlink(enable), "/" + P["UNIT"])
        self.assertFalse(os.path.lexists(owned))
        self.assertFalse(any(os.path.lexists(root / rel) for rel in P["FILES"]))
        self.assertFalse(any(os.path.lexists(root / rel) for rel in P["BROKEN"]))
        for db in (root / "var/lib/dpkg").glob("diversions*"):
            self.assertNotIn(P["REAL"].encode(), db.read_bytes())

    def test_package_purge_may_unlink_both_outputs(self):
        r = P["prepare"](self.root)
        P["intercept"](self.root, r)
        for rel in P["FILES"]:
            (self.root / rel).unlink()
        P["seal"](self.root, r)
        self.assertFalse((self.root / P["RAM"]).exists())

    def test_allow_ordinary_overlay_but_not_stock_output(self):
        certs = self.root / P["CERT"].parent
        certs.mkdir(parents=True)
        (certs / "local-extra.pem").touch()
        P["check_overlay"](self.root)
        (self.root / P["CERT"]).symlink_to("unused")
        with self.assertRaisesRegex(ValueError, "reserved stock TLS path"):
            P["check_overlay"](self.root)

    def test_preserve_diversions_history_without_other_transactions(self):
        root = self.root
        main = root / "var/lib/dpkg/diversions"
        old = root / P["OLD"]
        main.write_bytes(b"/usr/a\n/usr/a.original\n:\n")
        prior = b"/usr/z\n/usr/z.original\n:\n"
        old.write_bytes(prior)
        old.chmod(0o640)
        extra = root / "other-link"
        os.link(old, extra)
        r = P["prepare"](root)
        P["intercept"](root, r)
        P["seal"](root, r)
        self.assertEqual(main.read_bytes(), b"/usr/a\n/usr/a.original\n:\n")
        self.assertEqual(old.read_bytes(), prior)
        self.assertEqual(old.stat().st_mode & 0o777, 0o640)
        self.assertEqual(extra.read_bytes(), prior)

    def test_intervening_diversion_preserves_new_history(self):
        root = self.root
        main = root / "var/lib/dpkg/diversions"
        old = root / P["OLD"]
        before = b"/usr/a\n/usr/a.other\n:\n"
        main.write_bytes(before)
        old.write_bytes(b"/usr/z\n/usr/z.other\n:\n")
        r = P["prepare"](root)
        P["intercept"](root, r)
        P["divert"](root, "--local", "--no-rename", "--divert", "/usr/b.other", "--add", "/usr/b")
        P["seal"](root, r)
        self.assertEqual(old.read_bytes(), before)
        rows = main.read_bytes().splitlines()
        self.assertEqual({tuple(rows[i:i+3]) for i in range(0, len(rows), 3)},
                         {(b"/usr/a", b"/usr/a.other", b":"), (b"/usr/b", b"/usr/b.other", b":")})


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] != "--parent-mnt":
        user = [] if os.geteuid() == 0 else ["--user", "--map-root-user"]
        os.execvp("unshare", ["unshare", *user, "--mount", "--propagation", "private", "--", sys.executable,
                  "-IB", __file__, "--parent-mnt", os.readlink("/proc/self/ns/mnt"), *sys.argv[1:]])
    PARENT_NS = sys.argv[2]
    del sys.argv[1:3]
    unittest.main()
