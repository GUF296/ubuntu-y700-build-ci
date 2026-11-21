"""Exercise the final ext4 SSH evidence using only a tiny unmounted fixture."""
import hashlib
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


if __name__=="__main__": unittest.main()
