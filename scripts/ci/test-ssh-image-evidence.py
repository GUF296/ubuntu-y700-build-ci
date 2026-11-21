"""Exercise the final ext4 SSH evidence using only a tiny unmounted fixture."""
import hashlib
import os
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec=importlib.util.spec_from_file_location("attest",Path(__file__).with_name("ssh-image-evidence.py"))
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)


class Evidence(unittest.TestCase):
    def test_final_ext4_and_lookup(self):
        with tempfile.TemporaryDirectory() as tmp:
            r=Path(tmp); directory=r/"source/etc/ssh"
            directory.mkdir(parents=True)
            (directory/"sshd_config").touch()
            image,manifest,info,raw=[r/("candidate-rootfs"+suffix) for suffix in (".img",".manifest",".BUILD-INFO.txt",".raw.sha256")]
            policy="default_user=fixture\nssh_host_identity=generated-on-device\n"+"".join(
                "ssh_policy["+u+"]."+k+"="+v+"\n" for u in ("root","fixture") for k,v in
                dict(authenticationmethods="any",kbdinteractiveauthentication="no",passwordauthentication="yes",
                     pubkeyauthentication="yes",permitrootlogin="prohibit-password").items())
            info.write_text(policy)
            row="f\troot\troot\t644\t0\t./etc/ssh/sshd_config\n"
            manifest.write_text(row)
            def make():
                with image.open("wb") as f: f.truncate(16<<20)
                subprocess.run(["mke2fs","-q","-t","ext4","-F","-d",r/"source",image],check=True)
                raw.write_text(mod.digest(image)+"  "+image.name+"\n")
            make()
            good=mod.capture(image,manifest,info,raw)
            self.assertEqual(good["entries"],["sshd_config"])
            import json
            evidence=r/"candidate-rootfs.ssh-identity.json"
            evidence.write_text(json.dumps(good))
            checks=r/"sums"
            checks.write_text("".join(mod.digest(p)+"  "+p.name+"\n" for p in (evidence,manifest,info))+
                              "a"*64+"  candidate-rootfs.img.7z\n")
            self.assertEqual(mod.bind(evidence,checks,"candidate-rootfs.img.7z")["archive_sha256"],"a"*64)
            info.write_text(policy.replace("generated-on-device","not-sealed"))
            with self.assertRaises(ValueError): mod.capture(image,manifest,info,raw)
            info.write_text(policy); (directory/"ssh_host_dummy_key").touch(); make()
            with self.assertRaises(ValueError): mod.capture(image,manifest,info,raw)
            manifest.write_text(row+row.replace("sshd_config","ssh_host_dummy_key"))
            with self.assertRaises(ValueError): mod.capture(image,manifest,info,raw)
            evidence.write_text("{}")
            with self.assertRaises(ValueError): mod.bind(evidence,checks,"candidate-rootfs.img.7z")


class FinalIdentityMetadata(unittest.TestCase):
    def test_unmounted_minimal_desktop_and_rejection(self):
        spec=importlib.util.spec_from_file_location("identity_metadata",Path(__file__).with_name("verify-final-identity-metadata.py"))
        identity=importlib.util.module_from_spec(spec); spec.loader.exec_module(identity)
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp); tree=d/"source"; tree.mkdir();image=d/"fixture.img";inventory=d/"installed.tsv"
            def node(name):
                p=tree/name.lstrip("/");p.parent.mkdir(parents=True,exist_ok=True);return p
            mid,dbus,unit,enabled,key,cert=map(node,(identity.MACHINE,identity.DBUS,identity.SERVICE,identity.ENABLED,identity.KEY,identity.CERT))
            mid.touch();mid.chmod(0o644)
            def pack():
                # No mount/root. Normalize only synthetic fixture inode owners,
                # since mke2fs -d otherwise imports the CI user's numeric uid.
                with image.open("wb") as stream:stream.truncate(8<<20)
                subprocess.run(["mke2fs","-q","-t","ext4","-F","-d",tree,image],check=True)
                directives=[]
                for p in (mid,dbus,unit,enabled,tree/"lib"):
                    if os.path.lexists(p):
                        path="/"+str(p.relative_to(tree))
                        directives.extend("set_inode_field "+path+" "+k+" 0" for k in ("uid","gid"))
                subprocess.run(["debugfs","-w",image],input="\n".join(directives)+"\n",text=True,capture_output=True,check=True)
            def check(message=None):
                pack()
                if message:
                    with self.assertRaisesRegex(ValueError,message):identity.verify(image,inventory)
                else:return identity.verify(image,inventory)
            inventory.write_text("base-files\t1\tarm64\n")
            self.assertEqual(check(),"desktop=other native_ssl_cert_unit=not-installed")
            dbus.symlink_to("../../../etc/machine-id");unit.write_text("[Service]\n");unit.chmod(0o644)
            enabled.symlink_to(identity.SERVICE)
            inventory.write_text("kubuntu-desktop\t1\tarm64\nssl-cert\t1\tall\n")
            self.assertEqual(check(),"desktop=kubuntu native_ssl_cert_unit=installed-verified")
            for target in (identity.MACHINE, "./../../../etc/machine-id", "/etc/./machine-id",
                           "/etc//machine-id", "/etc/"+("./"*40)+"machine-id"):
                with self.subTest(legacy=target):
                    dbus.unlink();dbus.symlink_to(target);self.assertIn("installed-verified",check())
            dbus.unlink();dbus.write_bytes(b"x"*33);check("D-Bus")
            for target in ("/etc/other-file","/etc/other/../machine-id","../../../etc/machine-id/",
                           "/etc/"+("./"*40)+"other/../machine-id"):
                with self.subTest(legacy=target):
                    dbus.unlink();dbus.symlink_to(target);check("D-Bus")
            dbus.unlink()
            key.touch();check("stock TLS");key.unlink();cert.touch();check("stock TLS");cert.unlink()
            for alias in (node(identity.KEY+".broken"),node(identity.CERT+".broken")):
                alias.touch();check("stock TLS");alias.unlink()
            enabled.unlink();enabled.symlink_to("/usr/lib/systemd/system/not-this.service");check("not enabled")
            enabled.unlink();enabled.symlink_to("../../../../usr/lib/systemd/system/ssl-cert.service");self.assertIn("installed-verified",check())
            for target in ("../../../../usr/lib/systemd/absent/../system/ssl-cert.service",identity.SERVICE+"/"):
                with self.subTest(enable=target):
                    enabled.unlink();enabled.symlink_to(target);check("not enabled")
            enabled.unlink();enabled.symlink_to("/lib/systemd/system/ssl-cert.service");check("not enabled")
            (tree/"lib").symlink_to("usr/lib");self.assertIn("installed-verified",check())
            enabled.unlink();enabled.symlink_to("./../../../../lib/systemd/./system/ssl-cert.service")
            self.assertIn("installed-verified",check())
            (tree/"lib").unlink();(tree/"lib").symlink_to("usr/unused/../lib");check("not enabled")
            unit.unlink();check("unit missing");inventory.write_text("base-files\t1\tarm64\n")
            mid.chmod(0o600);check("empty placeholder");mid.chmod(0o644);mid.write_bytes(b"x"*33);check("empty placeholder")
            mid.write_bytes(b"");pack()
            subprocess.run(["debugfs","-w","-R","set_inode_field /etc/machine-id uid 42",image],check=True,capture_output=True)
            with self.assertRaisesRegex(ValueError,"empty placeholder"):identity.verify(image,inventory)
            image.write_bytes(b"not-an-image")
            with self.assertRaises(ValueError):identity.verify(image,inventory)


if __name__=="__main__": unittest.main()
