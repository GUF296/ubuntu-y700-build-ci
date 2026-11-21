"""Seal the Ubuntu image without SSH host identity; verify native first-boot generation."""
import argparse
import ctypes
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

PRIVATE = tuple("ssh_host_"+kind+"_key" for kind in ("rsa","ecdsa","ed25519"))
PUBLIC = tuple(n+".pub" for n in PRIVATE)
HELPER = "usr/libexec/tb321fu-ssh-host-identity.py"
SSH_UNITS = ("ssh.service","ssh.socket","sshd@.service")
DROPIN = "40-tb321fu-host-identity.conf"
KEYGEN = """[Unit]
# The image has an empty (not absent) machine-id. Treat missing keys, not
# systemd's first-boot flag, as the trigger; a persisted marker prevents regeneration after administrator changes.
ConditionFirstBoot=
# A socket starts before basic.target. Do not inherit a service's implicit
# After=basic.target and introduce a sockets.target ordering cycle.
DefaultDependencies=no
Requires=sysinit.target
After=sysinit.target
RequiresMountsFor=/etc/ssh /usr
Conflicts=shutdown.target
Before=shutdown.target ssh.socket

[Service]
RuntimeDirectory=sshd
ExecStart=
ExecStart=/usr/bin/python3 -IB /usr/libexec/tb321fu-ssh-host-identity.py initialize
ExecStartPost=/usr/sbin/sshd -t
ExecStartPost=/usr/bin/python3 -IB /usr/libexec/tb321fu-ssh-host-identity.py finish
"""
REQUIRE_KEYS = """[Unit]
Requires=sshd-keygen.service
After=sshd-keygen.service
"""


def need(value, reason):
    if not value:
        raise ValueError(reason)


def trusted_dir(root, relative, create=False):
    # Build operations run on a private offline filesystem; never traverse an
    # overlay symlink. Runtime checks require root-owned, non-writable parents.
    path = root
    for node in ("", *Path(relative).parts):
        path /= node
        if node and create:
            path.mkdir(mode=0o755, exist_ok=True)
        st = path.lstat()
        need(stat.S_ISDIR(st.st_mode) and st.st_uid == os.geteuid() and not st.st_mode & 0o022,
             "unsafe directory "+str(path))
    return path


def names(path):
    return {n for n in os.listdir(path) if n.startswith("ssh_host_")}


def trusted_key(path, public, empty):
    st = path.lstat()
    modes = (0o600,0o644) if public else (0o600,)
    need(stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid() and st.st_nlink == 1
         and stat.S_IMODE(st.st_mode) in modes and ((st.st_size == 0) == empty),
         "unexpected type, owner, mode, links or size: "+path.name)
    return f"{st.st_dev}:{st.st_ino}"


def prepare(root):
    path = trusted_dir(root,"etc/ssh",True)
    need(not names(path),"unclean SSH key namespace before bootstrap")
    ids = []
    # Resolute's openssh-server.postinst creates default keys only if they
    # are not regular files. No secret bytes ever exist on the build image.
    for n in PRIVATE:
        with (path/n).open("xb") as f:
            os.fchmod(f.fileno(),0o600)
        ids.append(trusted_key(path/n,False,True))
    return ",".join(ids)


def install_exclusive(root, relative, data):
    dest = Path(relative)
    parent = trusted_dir(root,str(dest.parent),True)
    with (parent/dest.name).open("xb") as f:
        f.write(data)
        os.fchmod(f.fileno(),0o644)


def seal(root, ticket):
    path = trusted_dir(root,"etc/ssh")
    need(names(path) == set(PRIVATE), "extra, missing or generated keys before image seal")
    need(",".join(trusted_key(path/n,False,True) for n in PRIVATE) == ticket,"bootstrap placeholders replaced")
    vendor = trusted_dir(root,"usr/lib/systemd/system")
    native = vendor/"sshd-keygen.service"
    if os.path.lexists(native):
        need(stat.S_ISREG(native.lstat().st_mode), "unsafe native sshd-keygen.service")
        starts = [l.strip() for l in native.read_text().splitlines() if l.strip().startswith("ExecStart=")]
        need(starts in (["ExecStart=ssh-keygen -A"],["ExecStart=/usr/bin/ssh-keygen -A"]), "unsupported native key generator")
        generator = "sshd-keygen.service"
        install_exclusive(root,"etc/systemd/system/"+generator+".d/"+DROPIN,KEYGEN.encode())
    else:
        # Older Ubuntu builds (including the standalone Noble default) may
        # not ship sshd-keygen.service. Do not shadow a future vendor unit.
        generator = "tb321fu-ssh-host-identity.service"
        compat = KEYGEN.replace("ConditionFirstBoot=\n","").replace("[Service]\n",
                "Before=sshd-keygen.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n")
        install_exclusive(root,"etc/systemd/system/"+generator,compat.encode())
    selected = [n for n in SSH_UNITS if os.path.lexists(vendor/n)]
    need("ssh.service" in selected and all(stat.S_ISREG((vendor/n).lstat().st_mode) for n in selected),"missing/unsafe ssh service")
    install_exclusive(root,HELPER,Path(__file__).read_bytes())
    for unit in selected:
        rule = REQUIRE_KEYS.replace("sshd-keygen.service", generator)
        install_exclusive(root,"etc/systemd/system/"+unit+".d/"+DROPIN,rule.encode())
    for n in PRIVATE:
        (path/n).unlink()   # Only this run's empty placeholders, never a key.
    need(not names(path) and not os.path.lexists(path/MARKER),"SSH identity/marker remained after image seal")


def runtime(root, complete):
    path = trusted_dir(root,"etc/ssh")
    actual = names(path)
    need(actual <= set(PRIVATE+PUBLIC),"unrecognized SSH host key name")
    for n in PRIVATE:
        pair = {n,n+".pub"} & actual
        need(len(pair)==2 or (not complete and not pair), "incomplete SSH host key pair: "+n)
        if pair:
            trusted_key(path/n,False,False)
            trusted_key(path/(n+".pub"),True,False)


MARKER = ".tb321fu-host-identity-v1"


def initialized(directory):
    marker = directory/MARKER
    if not os.path.lexists(marker):
        return False
    st = marker.lstat()
    need(stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid() and st.st_nlink == 1
         and stat.S_IMODE(st.st_mode) == 0o600 and st.st_size == 0, "unsafe SSH initialization marker")
    return True


def sync(path):
    fd = os.open(path,os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish_private(src,dst):
    # renameat2 is atomic on the target ext4 filesystem and never replaces
    # even a concurrently created identity. No private key bytes are copied.
    rename = ctypes.CDLL(None,use_errno=True).renameat2
    if rename(-100,os.fsencode(src),-100,os.fsencode(dst),1) != 0:
        err = ctypes.get_errno()
        raise OSError(err,os.strerror(err),dst.name)


def initialize(root):
    directory = trusted_dir(root,"etc/ssh")
    if initialized(directory):
        return  # Do not touch custom keys, certificates or read-only /etc.
    with tempfile.TemporaryDirectory(dir=directory,prefix=".tb321fu-keygen-") as tmp:
        stage = Path(tmp)
        for name in PRIVATE:
            key,public = directory/name,directory/(name+".pub")
            if os.path.lexists(public):
                trusted_key(public,True,public.lstat().st_size==0)
            if os.path.lexists(key):
                st = key.lstat()
                trusted_key(key,False,st.st_size==0)
                if st.st_size==0:
                    key.unlink()  # no identity data to lose
            if not os.path.lexists(key):
                candidate=stage/"key"
                algorithm=name.removeprefix("ssh_host_").removesuffix("_key")
                subprocess.run(["/usr/bin/ssh-keygen","-q","-t",algorithm,"-N","","-f",candidate],check=True)
                trusted_key(candidate,False,False)
                sync(candidate)
                publish_private(candidate,key)
                candidate.with_suffix(".pub").unlink()
                sync(directory)
            # Derive only public data; a missing/stale .pub after power loss
            # is repairable. Never replace an existing nonempty private key.
            result=subprocess.run(["/usr/bin/ssh-keygen","-y","-P","","-f",key],capture_output=True)
            need(result.returncode==0 and 0<len(result.stdout)<=16384,
                 "unusable existing private host key (left untouched): "+name+
                 "; at the local console restore the key from your device backup, or move it aside before retrying SSH")
            out=stage/"public"
            with out.open("xb") as stream:
                stream.write(result.stdout)
                os.fchmod(stream.fileno(),0o644)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(out,public)
            sync(directory)
    runtime(root,True)


def finish(root, effective):
    directory=trusted_dir(root,"etc/ssh")
    if initialized(directory):
        return
    runtime(root,True)
    config(effective())
    fd=os.open(directory/MARKER,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    try:
        os.fchmod(fd,0o600)
        os.fsync(fd)
    finally:
        os.close(fd)
    sync(directory)


def config(data):
    # Parse the effective target sshd -G per account (actual Include/Match
    # semantics). Reject alternative host key files before publishing.
    values = [l.partition(" ")[2] for l in data.splitlines() if l.startswith("hostkey ")]
    need(sorted(values) == sorted("/etc/ssh/"+n for n in PRIVATE),"noncanonical effective SSH host keys")
    need(not any(l.startswith("hostcertificate ") and l != "hostcertificate none" for l in data.splitlines()),
         "external SSH host certificate in image")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode",choices=("prepare","seal","config","existing","initialize","finish"))
    p.add_argument("root",nargs="?",type=Path)
    p.add_argument("ticket",nargs="?")
    a = p.parse_args()
    if a.mode in ("prepare","seal"):
        if a.root is not None:
            a.root = a.root.absolute()
        need(a.root is not None and a.root.resolve() != Path("/") and a.root == a.root.resolve(),
             "build mode requires a private, absolute, non-symlink offline root")
        if a.mode == "prepare":
            print(prepare(a.root))
        else:
            seal(a.root,a.ticket)
    elif a.mode == "config":
        config(sys.stdin.read())
    else:
        need(a.root is None and a.ticket is None,"unexpected runtime argument")
        if a.mode=="initialize":
            initialize(Path("/"))
        elif a.mode=="finish":
            finish(Path("/"),lambda:subprocess.check_output(["/usr/sbin/sshd","-T"],text=True))
        else:
            runtime(Path("/"),False)


if __name__ == "__main__":
    try:
        main()
    except (OSError,ValueError,subprocess.CalledProcessError) as exc:
        sys.exit("SSH host identity: "+str(exc))
