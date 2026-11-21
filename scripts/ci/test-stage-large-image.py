"""Real disk/byte parity with the former copy-then-split path; unprivileged."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("stage",Path(__file__).with_name("stage-large-image.py"))
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)


class Split(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root=Path(tmp.name)
        self.src=self.root/"fixture-rootfs.img.7z"
        self.payload=os.urandom(11<<20)
        self.src.write_bytes(self.payload)
        self.sha=hashlib.sha256(self.payload).hexdigest()
        self.sums=self.root/"fixture-rootfs.SHA256SUMS"
        self.sums.write_text(self.sha+"  "+self.src.name+"\n")
        self.out=self.root/"stage"; self.out.mkdir()
        self.dest=self.out/"rootfs.img.7z"; self.part=4<<20

    def sample(self):
        seen={}
        for f in self.root.rglob("*"):
            if f.is_file() and f!=self.sums:
                st=f.stat(); seen[(st.st_dev,st.st_ino)]=512*st.st_blocks
        return sum(seen.values())

    def test_parity_peak_and_input_unchanged(self):
        before=self.src.stat()
        shutil.copyfile(self.src,self.dest)
        subprocess.run(["split","-b",str(self.part),"-d","-a","3",self.dest,str(self.dest)+"."],check=True)
        a=self.sample()
        self.dest.unlink()
        old={f.name:(len(f.read_bytes()),hashlib.sha256(f.read_bytes()).digest()) for f in self.out.iterdir()}
        for f in self.out.iterdir(): f.unlink()
        peaks=[]
        mod.stage(self.src,self.dest,self.sums,self.part,lambda:peaks.append(self.sample()))
        b=max(peaks)
        new={f.name:(len(f.read_bytes()),hashlib.sha256(f.read_bytes()).digest()) for f in self.out.iterdir()}
        self.assertEqual(sorted(old),["rootfs.img.7z.%03d"%i for i in range(3)])
        self.assertEqual(old,new)
        self.assertTrue(all(f.stat().st_nlink==1 and f.stat().st_mode & 0o777==0o644 for f in self.out.iterdir()))
        self.assertEqual(mod.identity(self.src.stat()),mod.identity(before))
        self.assertGreaterEqual(a-b,len(self.payload)-4096)
        print(f"REAL_FILE_PEAK source={len(self.payload)} old={a} direct={b} saved={a-b}")

    def test_bad_sha_symlinks_collision_and_mid_commit(self):
        for data in ("0"*64+"  "+self.src.name+"\n",self.sums.read_text()*2):
            self.sums.write_text(data)
            with self.assertRaises(ValueError): mod.stage(self.src,self.dest,self.sums,self.part)
            self.assertEqual(list(self.out.iterdir()),[])
        self.sums.write_text(self.sha+"  "+self.src.name+"\n")
        link=self.root/"link"; link.symlink_to(self.src)
        with self.assertRaises(ValueError): mod.stage(link,self.dest,self.sums,self.part)
        concurrent=self.out/"rootfs.img.7z.001"
        call=os.link
        def conflict(old,path,**kwargs):
            if path==concurrent: path.write_text("not ours")
            return call(old,path,**kwargs)
        with patch.object(mod.os,"link",side_effect=conflict),self.assertRaises(FileExistsError):
            mod.stage(self.src,self.dest,self.sums,self.part)
        self.assertEqual(list(self.out.iterdir()),[concurrent])
        self.assertEqual(concurrent.read_text(),"not ours")
        with self.assertRaises(ValueError): mod.stage(self.src,self.dest,self.sums,self.part)

    def test_unscaled_three_digit_range(self):
        for size,count in ((mod.PART+1,2),(16<<30,9),((16<<30)+1,9),(999*mod.PART+1,1000),(1000*mod.PART,1000)):
            self.assertEqual(mod.part_count(size),count)
        for size in (0,mod.PART,1000*mod.PART+1):
            with self.assertRaises(ValueError): mod.part_count(size)

    def test_actual_workflow_sizing_and_source_sha_selection(self):
        # Use the YAML's actual stage selector and real stat() on sparse
        # logical boundary files. Stub data movement only; no giant I/O.
        root=Path(__file__).resolve().parents[2]
        yaml=(root/".github/workflows/build-rootfs-and-grub.yml").read_text()
        start=yaml.index("          select_release_asset() {")
        fn=yaml[start:yaml.index("\n          }\n",start)+len("\n          }")]
        harness=("set -euo pipefail\nrelease_dir=$1\nassert_no_symlink_component(){ :; }\n"
                 "stage_release_file(){ printf 'small\\t%s\\t%s\\n' \"$1\" \"$2\"; }\n"
                 "python3(){ printf 'direct\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$@\"; }\n"+
                 fn+"\nselect_release_asset \"$2\" fixture-rootfs.img rootfs 7z ''\n")
        for size,kind in ((mod.PART-1,"small"),(mod.PART,"small"),(mod.PART+1,"direct"),
                          ((16<<30)+1,"direct"),(1000*mod.PART,"direct")):
            with self.src.open("wb") as f: f.truncate(size)
            out=subprocess.check_output(["bash","-c",harness,"test",self.out,self.root],text=True).strip().split("\t")
            self.assertEqual(out,([kind,str(self.src),str(self.dest)] if kind=="small" else
                                  [kind,"-IB","scripts/ci/stage-large-image.py",str(self.src),str(self.dest),str(self.sums)]))
            self.assertLess(self.src.stat().st_blocks*512,1<<20)

    def test_exact_boundary_real_parts_and_source_checksum(self):
        scale=4096
        for size in (scale+1,2*scale,2*scale+1):
            with self.subTest(size=size):
                self.src.write_bytes(os.urandom(size))
                self.sums.write_text(hashlib.sha256(self.src.read_bytes()).hexdigest()+"  "+self.src.name+"\n")
                mod.stage(self.src,self.dest,self.sums,scale)
                vols=sorted(self.out.iterdir())
                self.assertEqual([p.stat().st_size for p in vols],[scale]*(size//scale)+([size%scale] if size%scale else []))
                self.assertEqual(b"".join(p.read_bytes() for p in vols),self.src.read_bytes())
                for f in vols: f.unlink()
                self.sums.write_text("f"*64+"  "+self.src.name+"\n")
                with self.assertRaisesRegex(ValueError,"producer checksum"):
                    mod.stage(self.src,self.dest,self.sums,scale)
                self.assertFalse(any(self.out.iterdir()))

    def test_source_changes_midstream(self):
        def mutate():
            with self.src.open("ab") as stream: stream.write(b"!")
        with self.assertRaises(ValueError):
            mod.stage(self.src,self.dest,self.sums,self.part,mutate)
        self.assertFalse(any(self.out.iterdir()))


if __name__=="__main__": unittest.main()
