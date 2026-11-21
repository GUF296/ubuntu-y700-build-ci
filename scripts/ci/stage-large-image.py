"""Stage verified large image parts from one read-only source, with no complete staging copy."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import tempfile

PART=1900 << 20
BLOCK=1 << 20


def need(value, message):
    if not value: raise ValueError(message)


def safe_path(path):
    path=path.absolute()
    need(path==path.resolve(strict=True),"symlink or unsafe path: "+path.name)
    return path


def expected_hash(checks, source):
    safe_path(checks)
    st=checks.stat()
    need(stat.S_ISREG(st.st_mode) and 0<st.st_size<=2<<20,"invalid producer checksums")
    rows=[]
    for line in checks.read_text("ascii").splitlines():
        m=re.fullmatch(r"([a-f0-9]{64}) [ *]([A-Za-z0-9._+-]+)",line)
        need(m,"invalid producer checksum record")
        if m[2]==source.name: rows.append(m[1])
    need(len(rows)==1,"source missing or duplicated in producer checksums")
    return rows[0]


def identity(st):
    return (st.st_dev,st.st_ino,st.st_size,st.st_ctime_ns,st.st_mtime_ns)


def part_count(size,part=PART):
    need(0<part<size and (size+part-1)//part<=1000,"source outside three-digit split range")
    return (size+part-1)//part


def stage(src,dest,sums,part=PART,observe=None):
    src=safe_path(src); parent=safe_path(dest.parent)
    need(stat.S_ISDIR(parent.stat().st_mode) and dest.name in ("rootfs.img.7z","grub.img.7z"),
         "unapproved release stream")
    stem=dest.name; target=parent/stem
    need(not os.path.lexists(target) and not any(parent.glob(stem+".*")),"existing release stream")
    want=expected_hash(sums,src)
    # One immutable source descriptor. Do not follow its last component or
    # ever create an intermediate, complete compressed copy.
    fd=os.open(src,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,"rb") as source:
        st=os.fstat(fd)
        need(stat.S_ISREG(st.st_mode),"invalid split input type")
        expected_parts=part_count(st.st_size,part)
        digest=hashlib.sha256()
        remaining=st.st_size
        # All output parts are private until size, complete-stream SHA and
        # source file identity have been checked. No release/job write here.
        with tempfile.TemporaryDirectory(prefix=".tb321fu-split-",dir=parent) as work:
            staged=[]
            while remaining:
                path=Path(work)/(stem+".%03d"%len(staged))
                count=min(part,remaining)
                with path.open("xb") as out:
                    while count:
                        block=source.read(min(BLOCK,count))
                        need(block,"source truncated while staging")
                        digest.update(block); out.write(block)
                        count-=len(block); remaining-=len(block)
                    os.fchmod(out.fileno(),0o644)
                staged.append(path)
                if observe: observe()
            need(len(staged)==expected_parts and not source.read(1) and identity(os.fstat(fd))==identity(st)==identity(src.lstat()),
                 "source replaced or modified while staging")
            need(digest.hexdigest()==want,"whole source differs from producer checksum")
            published=[]
            try:
                for path in staged:
                    final=parent/path.name
                    # Same filesystem. Fail if a file appeared; never replace
                    # another writer's data or modify the source inode.
                    os.link(path,final,follow_symlinks=False)
                    published.append((path,final))
            except BaseException:
                for path,final in reversed(published):
                    try:
                        if os.path.samestat(path.lstat(),final.lstat()): final.unlink()
                    except FileNotFoundError: pass
                raise


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("source",type=Path); p.add_argument("destination",type=Path); p.add_argument("producer_sha256s",type=Path)
    a=p.parse_args()
    stage(a.source,a.destination,a.producer_sha256s)
