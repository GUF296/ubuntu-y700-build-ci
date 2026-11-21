"""Offline regression for sshd option semantics and tmpfs-only probe identity."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROBE=Path(__file__).with_name("ssh-policy-probe.sh").resolve()
SOURCE=r"""
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>
int main(int argc,char **argv) {
    struct stat st; struct statfs fs;
    if(statfs("/run",&fs) || (unsigned long)fs.f_type!=0x01021994 || access("/run/preserved",F_OK)==0) return 2;
    if(argc==2 && !strcmp(argv[1],"-G")) {
        puts("hostkey /etc/ssh/ssh_host_rsa_key\nhostkey /etc/ssh/ssh_host_ecdsa_key\nhostkey /etc/ssh/ssh_host_ed25519_key");
        return 0;
    }
    if(argc!=6 || strcmp(argv[1],"-T") || strcmp(argv[2],"-h") || strcmp(argv[4],"-C") ||
       strcmp(argv[3],"/run/tb321fu-policy/identity") || stat(argv[3],&st) || !S_ISREG(st.st_mode) ||
       (st.st_mode&0777)!=0600 || st.st_size<=0 || statfs(argv[3],&fs) || (unsigned long)fs.f_type!=0x01021994) return 3;
    int root=!strncmp(argv[5],"user=root,",10);
    if(root && access("/deny",F_OK)==0) return 4;
    puts(root?"passwordauthentication no":"passwordauthentication yes");
    puts("pubkeyauthentication yes\nkbdinteractiveauthentication no\nauthenticationmethods any\npermitrootlogin prohibit-password");
    return 0;
}
"""


class Policy(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)/"root"
        for n in ("etc/ssh","run","usr/sbin"): (self.root/n).mkdir(parents=True)
        (self.root/"run/preserved").touch()
        source=Path(self.tmp.name)/"sshd.c";source.write_text(SOURCE)
        subprocess.run(["cc","-static","-O1",source,"-o",self.root/"usr/sbin/sshd"],check=True)
        self.prefix=[]
        if os.geteuid()!=0:
            self.prefix=["unshare","--user","--map-root-user"]
            if subprocess.run([*self.prefix,"unshare","--mount","--propagation","private","true"],capture_output=True).returncode:
                if shutil.which("sudo") and not subprocess.run(["sudo","-n","true"],capture_output=True).returncode:
                    self.prefix=["sudo","-n"]
                elif os.environ.get("GITHUB_ACTIONS")=="true":
                    self.fail("CI cannot exercise the mount boundary")
                else:
                    self.skipTest("mount namespace unavailable on this host")

    def call(self):
        result=subprocess.run([*self.prefix,"bash",PROBE,self.root,"GUF296"],capture_output=True,text=True,timeout=30)
        self.assertEqual({p.name for p in (self.root/"run").iterdir()},{"preserved"})
        self.assertFalse(any((self.root/"etc/ssh").iterdir()))
        self.assertNotIn("PRIVATE KEY",result.stdout+result.stderr)
        return result

    def test_real_mount_match_and_error_cleanup(self):
        out=self.call()
        self.assertEqual(out.returncode,0,out.stderr)
        records=out.stdout.splitlines()
        self.assertEqual(len(records),10)
        self.assertIn("ssh_policy[root].passwordauthentication=no",records)
        self.assertIn("ssh_policy[GUF296].passwordauthentication=yes",records)
        self.assertTrue(all(s.startswith("ssh_policy[") for s in records))
        (self.root/"deny").touch()
        self.assertNotEqual(self.call().returncode,0)


if __name__=="__main__": unittest.main()
