"""Record SSH directory metadata from the final, unmounted ext4 image. Never read key contents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

MARKER=".tb321fu-host-identity-v1"


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def digest(path):
    val=hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda:stream.read(1<<20),b""):
            val.update(block)
    return val.hexdigest()


def sums(path):
    out={}
    for line in path.read_text("ascii").splitlines():
        match=re.fullmatch(r"([a-f0-9]{64}) [ *]([A-Za-z0-9._+-]+)",line)
        need(match and match[2] not in out,"invalid/duplicate producer checksum record")
        out[match[2]]=match[1]
    return out


def capture(image,manifest,info,raw):
    # debugfs works read-only by default. ls -p returns inode metadata; unlike
    # a mounted path walk it examines the exact post-e2fsck source of compression.
    run=subprocess.run(["debugfs","-R","ls -p /etc/ssh",image],capture_output=True,check=True,
                       env=dict(os.environ,LC_ALL="C"))
    disk=set()
    for line in run.stdout.decode("ascii").splitlines():
        if not line:
            continue
        row=line.split("/")
        need(len(row)==8 and row[0]==row[-1]=="" and row[1].isdecimal() and int(row[1])>0 and
             re.fullmatch("[0-7]{5,6}",row[2]) and re.fullmatch(r"[a-zA-Z0-9_.+\-]+",row[5]),"invalid ext4 SSH directory entry")
        name=row[5]
        need(name not in disk,"duplicate ext4 SSH entry")
        disk.add(name)
    need({".","..","sshd_config"}<=disk,"cannot read final ext4 SSH directory")
    disk-={".",".."}
    declared=set()
    with manifest.open("rb") as data:
        for line in data:
            cells=line.rstrip(b"\n").split(b"\t",5)
            if len(cells)==6 and cells[5].startswith(b"./etc/ssh/"):
                tail=cells[5][len(b"./etc/ssh/"):]
                if b"/" not in tail:
                    name=tail.decode("ascii")
                    need(name not in declared,"duplicate manifest SSH entry")
                    declared.add(name)
    need(disk==declared and not any(n.startswith(("ssh_host_",".tb321fu-")) for n in disk),
         "SSH namespace not pristine or disagrees with filesystem manifest")
    policy={}
    for line in info.read_text().splitlines():
        k,sep,v=line.partition("=")
        if k in ("default_user","ssh_host_identity") or k.startswith("ssh_policy["):
            need(sep and k not in policy and re.fullmatch("[A-Za-z0-9_,.@:+-]{1,256}",v),"invalid SSH policy")
            policy[k]=v
    user=policy.get("default_user")
    fields=("authenticationmethods","passwordauthentication","kbdinteractiveauthentication","pubkeyauthentication","permitrootlogin")
    need(user and set(policy)=={"default_user","ssh_host_identity"} | {"ssh_policy["+u+"]."+f for u in (user,"root") for f in fields},
         "incomplete host identity/authentication metadata")
    need(policy["ssh_host_identity"]=="generated-on-device","wrong SSH identity build marker")
    raw_values=sums(raw)
    need(set(raw_values)=={image.name},"invalid raw ext4 digest inventory")
    return dict(schema="tb321fu.ssh-image/v1",entries=sorted(disk),policy=policy,
                raw_sha256=raw_values[image.name],build_info_sha256=digest(info),manifest_sha256=digest(manifest))


def bind(evidence,checks,archive_name):
    data=json.loads(evidence.read_text())
    values=sums(checks)
    prefix=evidence.name.removesuffix(".ssh-identity.json")
    need(evidence.name==prefix+".ssh-identity.json" and values.get(evidence.name)==digest(evidence) and
         values.get(prefix+".BUILD-INFO.txt")==data["build_info_sha256"] and
         values.get(prefix+".manifest")==data["manifest_sha256"] and
         re.fullmatch(r"[a-zA-Z0-9._+-]+",archive_name) and archive_name in values,"unbound SSH image evidence")
    data["archive_sha256"]=values[archive_name]
    return data


if __name__=="__main__":
    p=argparse.ArgumentParser()
    sub=p.add_subparsers(dest="mode",required=True)
    c=sub.add_parser("capture")
    for x in ("image","manifest","info","raw"):
        c.add_argument(x,type=Path)
    b=sub.add_parser("bind")
    b.add_argument("evidence",type=Path); b.add_argument("checks",type=Path); b.add_argument("archive_name")
    a=p.parse_args()
    result=capture(a.image,a.manifest,a.info,a.raw) if a.mode=="capture" else bind(a.evidence,a.checks,a.archive_name)
    print(json.dumps(result,separators=(",",":"),sort_keys=True))
