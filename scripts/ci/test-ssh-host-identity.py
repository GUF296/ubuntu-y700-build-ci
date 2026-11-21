"""Real ephemeral keys, no daemon/network and no access to machine host keys."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("host_identity",Path(__file__).with_name("ssh-host-identity.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Image(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def fixture(self,root,mode="native"):
        v = root/"usr/lib/systemd/system"
        v.mkdir(parents=True)
        for name in mod.SSH_UNITS:
            (v/name).write_text("[Unit]\nDescription=fixture\n")
        if mode=="native":
            (v/"sshd-keygen.service").write_text("[Unit]\nConditionFirstBoot=yes\n[Service]\nType=oneshot\nExecStart=ssh-keygen -A\n")
        return mod.prepare(root)

    def generate(self,root):
        mod.initialize(root)
        mod.finish(root,lambda:"".join("hostkey /etc/ssh/"+n+"\n" for n in mod.PRIVATE))
        return [subprocess.check_output(["ssh-keygen","-E","sha256","-lf",root/"etc/ssh"/(name+".pub")]).split()[1]
                for name in mod.PRIVATE]

    def test_new_devices_unique_same_device_stable(self):
        pairs=[]
        for n,mode in enumerate(("native","compat")):
            target = self.root/str(n)
            ticket = self.fixture(target,mode)
            mod.seal(target,ticket)
            self.assertFalse(mod.names(target/"etc/ssh"))
            public = self.generate(target)
            self.assertEqual(self.generate(target),public)
            self.assertTrue(all(os.stat(target/"etc/ssh"/name).st_mode & 0o777 == 0o600 for name in mod.PRIVATE))
            pairs.append(public)
        self.assertTrue(all(a!=b for a,b in zip(*pairs)))

    def test_first_boot_repairs_missing_and_orphan_public_keys(self):
        ticket = self.fixture(self.root)
        mod.seal(self.root,ticket)
        public = self.generate(self.root)
        directory = self.root/"etc/ssh"
        (directory/mod.MARKER).unlink()  # interruption before the completion marker
        (directory/(mod.PRIVATE[0]+".pub")).unlink()
        (directory/mod.PRIVATE[1]).unlink()  # orphan public alone
        again = self.generate(self.root)
        self.assertEqual(public[0],again[0])
        self.assertNotEqual(public[1],again[1])
        self.assertEqual(public[2],again[2])

    def test_corrupt_private_never_replaced_and_has_local_recovery_message(self):
        ticket=self.fixture(self.root)
        mod.seal(self.root,ticket)
        key=self.root/"etc/ssh"/mod.PRIVATE[0]
        key.write_text("invalid fixture; never a private key")
        key.chmod(0o600)
        before=key.stat()
        with self.assertRaisesRegex(ValueError,"left untouched.*local console"):
            mod.initialize(self.root)
        self.assertEqual((key.stat().st_ino,key.stat().st_size),(before.st_ino,before.st_size))
        self.assertFalse((key.parent/mod.MARKER).exists())

    def test_completed_device_preserves_custom_identity_and_read_only_etc(self):
        ticket=self.fixture(self.root)
        mod.seal(self.root,ticket)
        self.generate(self.root)
        d=self.root/"etc/ssh"
        (d/mod.PRIVATE[0]).rename(d/"custom.identity")
        (d/(mod.PRIVATE[0]+".pub")).unlink()
        d.chmod(0o555)
        try:
            mod.initialize(self.root)
            mod.finish(self.root,lambda:self.fail("do not enforce factory paths/certificates on a configured system"))
            self.assertFalse((d/mod.PRIVATE[0]).exists())
            self.assertTrue((d/"custom.identity").is_file())
        finally:
            d.chmod(0o755)

    def test_build_custody(self):
        ticket = self.fixture(self.root)
        key = self.root/"etc/ssh"/mod.PRIVATE[0]
        key.write_bytes(b"fixture-not-a-key")
        with self.assertRaises(ValueError): mod.seal(self.root,ticket)
        self.assertEqual(key.stat().st_size,len(b"fixture-not-a-key"))
        key.write_bytes(b"")
        key.rename(key.with_name("owned-old-placeholder"))
        key.touch(mode=0o600)
        with self.assertRaisesRegex(ValueError,"placeholders replaced"): mod.seal(self.root,ticket)

    def test_runtime_symlink_hardlink_and_incomplete_pair_rejected(self):
        ticket = self.fixture(self.root)
        mod.seal(self.root,ticket)
        d = self.root/"etc/ssh"
        key = d/mod.PRIVATE[0]
        public = key.with_suffix(".pub")
        public.write_text("only public fixture")
        with self.assertRaises(ValueError): mod.runtime(self.root,False)
        key.symlink_to(public)
        with self.assertRaises(ValueError): mod.runtime(self.root,False)
        key.unlink()
        os.link(public,key)
        with self.assertRaises(ValueError): mod.runtime(self.root,False)
        key.unlink()
        key.write_text("not a key"); key.chmod(0o666)
        with self.assertRaises(ValueError): mod.runtime(self.root,False)

    def test_build_parent_symlink_untouched(self):
        outside = self.root/"other-dir"
        outside.mkdir()
        host = self.root/"etc"
        host.symlink_to(outside)
        with self.assertRaises(ValueError): mod.prepare(self.root)
        self.assertEqual(list(outside.iterdir()),[])

    def test_activation_contract(self):
        ticket = self.fixture(self.root)
        mod.seal(self.root,ticket)
        conf = self.root/"etc/systemd/system"
        for unit in mod.SSH_UNITS:
            self.assertEqual((conf/(unit+".d")/mod.DROPIN).read_text(),
                "[Unit]\nRequires=sshd-keygen.service\nAfter=sshd-keygen.service\n")
        generator = (conf/"sshd-keygen.service.d"/mod.DROPIN).read_text()
        for wanted in ("ConditionFirstBoot=", "DefaultDependencies=no",
                       "Requires=sysinit.target","After=sysinit.target", "Before=shutdown.target ssh.socket",
                       "ExecStartPost=/usr/sbin/sshd -t", "RuntimeDirectory=sshd",
                       "ExecStartPost=/usr/bin/python3 -IB /usr/libexec/tb321fu-ssh-host-identity.py finish"):
            self.assertIn(wanted,generator.splitlines())
        with self.assertRaises(ValueError): mod.runtime(self.root,True)
        data="".join("hostkey /etc/ssh/"+n+"\n" for n in mod.PRIVATE)
        mod.config(data)
        for wrong in (data.replace("rsa_key","other"), data+"hostkey /tmp/key\n", data+"hostcertificate /tmp/cert\n"):
            with self.assertRaises(ValueError): mod.config(wrong)

    def test_builder_seals_after_provision_before_manifest(self):
        script = Path(__file__).with_name("build-rootfs-image.sh").read_text()
        calls = ['" prepare "$rootfs_dir"', 'debootstrap "${debootstrap_args[@]}"',
                 'apply_tb321fu_gpu_sensor "$rootfs_dir"', '" seal "$rootfs_dir"',
                 '"$SCRIPT_DIR/ssh-policy-probe.sh" "$rootfs_dir" "$DEFAULT_USER_NAME"', 'ci_log "writing manifest"']
        points = [script.index(item) for item in calls]
        self.assertEqual(points,sorted(points))


if __name__ == "__main__":
    unittest.main()
