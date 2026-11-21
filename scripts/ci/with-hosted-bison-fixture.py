"""Run the normal kernel policy fixture with the official Bison data modes.

Hosted images can change packaged permissions. Never repair the host or relax
the producer: present only the authenticated, byte-identical data in a private
read-only mount and drop privileges before executing any repository code.
"""
import hashlib
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess as sp
import sys
import tempfile


HOST = Path("/usr/share/bison")
FIXTURE = "scripts/ci/test-kernel-bootstrap-policy.sh"
PATH = "/usr/sbin:/usr/bin:/sbin:/bin"
LIMIT = 16 * 1024 * 1024


def need(ok, message):
    if not ok:
        raise ValueError(message)


def tree(root, canonical=False):
    """Collect small data-only trees without following links or logging contents."""
    need(root.is_absolute() and root.resolve(strict=True) == root, "non-canonical Bison root")
    entries, pending, size = {}, [root], 0
    while pending:
        p = pending.pop()
        rel = str(p.relative_to(root))
        need(re.fullmatch(r"[A-Za-z0-9_./+-]{1,255}", rel), "invalid Bison data name")
        st = p.lstat()
        mode = stat.S_IMODE(st.st_mode)
        need(len(entries) < 4096, "too many Bison data entries")
        if stat.S_ISDIR(st.st_mode):
            expected, digest = 0o755, None
            pending.extend(p.iterdir())
        else:
            need(stat.S_ISREG(st.st_mode) and st.st_nlink == 1, "unsupported Bison data entry")
            size += st.st_size
            need(size <= LIMIT, "oversize Bison data")
            with os.fdopen(os.open(p, os.O_RDONLY | os.O_NOFOLLOW), "rb") as f:
                opened = os.fstat(f.fileno())
                need((st.st_dev, st.st_ino, st.st_size) ==
                     (opened.st_dev, opened.st_ino, opened.st_size), "Bison data changed")
                block = f.read(st.st_size + 1)
                need(len(block) == st.st_size, "Bison data length changed")
            expected, digest = 0o644, hashlib.sha256(block).hexdigest()
        need(not canonical or mode == expected, "unexpected official Bison data mode")
        entries[rel] = (digest, mode)
    need(entries["."][0] is None and len(entries) >= 2 and size > 0, "empty Bison data")
    return entries


def compare(staged, host):
    need(staged.keys() == host.keys(), "installed Bison data membership differs from package")
    changed = []
    for name in sorted(staged):
        (expected, mode), (actual, installed) = staged[name], host[name]
        need(expected == actual, "installed Bison data type or bytes differ from package")
        if mode != installed:
            changed.append((name, installed, mode))
    return changed


def seal(entries):
    h = hashlib.sha256()
    for name, (content, mode) in sorted(entries.items()):
        # Names are restricted to the data-entry alphabet before reaching here.
        h.update(f"{name}\0{mode:04o}\0{content or 'directory'}\n".encode("ascii"))
    return h.hexdigest()


def package_ref():
    import apt  # System python3-apt, with the signed indexes from Install dependencies.
    arch = sp.check_output(["/usr/bin/dpkg", "--print-architecture"], text=True).strip()
    sites = {"arm64": {"ports.ubuntu.com"}, "amd64": {"archive.ubuntu.com", "security.ubuntu.com"}}
    need(arch in sites, "unsupported native Bison host")
    cache = apt.Cache()
    v = cache["bison:" + arch].installed
    need(v is not None and v.architecture == arch, "no installed native Bison")
    origins = [o for o in v.origins if o.site or o.archive != "now"]
    need(origins and all(o.trusted and o.origin == o.label == "Ubuntu" and
                         o.site in sites[arch] and o.component == "main" and
                         o.archive in {"noble", "noble-updates", "noble-security", "noble-backports"}
                         for o in origins), "Bison version not unambiguously from trusted Ubuntu Noble main")
    sha = v.record.get("SHA256", "")
    need(re.fullmatch(r"[0-9a-f]{64}", sha) and 0 < v.size <= 8 * 1024 * 1024,
         "missing bounded Bison package identity")
    return arch, v.version, v.size, sha


def checked_deb(tmp, arch, version, size, sha):
    items = list(tmp.iterdir())
    need(len(items) == 1 and items[0].is_file() and not items[0].is_symlink()
         and items[0].stat().st_size == size and hashlib.sha256(items[0].read_bytes()).hexdigest() == sha,
         "downloaded Bison package does not match authenticated index")
    deb = str(items[0])
    fields = sp.check_output(["/usr/bin/dpkg-deb", "--show", "--showformat",
                              "${Package}\t${Version}\t${Architecture}", deb], text=True).split("\t")
    need(fields == ["bison", version, arch], "wrong Bison package control identity")
    return deb


def stage(tmp):
    arch, version, size, sha = package_ref()
    sp.run(["/usr/bin/apt-get", "-o", "APT::Get::AllowUnauthenticated=false",
            "-o", "Acquire::AllowInsecureRepositories=false", "download",
            f"bison:{arch}={version}"], cwd=tmp, check=True, stdout=sp.DEVNULL)
    deb = checked_deb(tmp, arch, version, size, sha)
    dest = tmp / "official"
    sp.run(["/usr/bin/dpkg-deb", "--extract", deb, str(dest)], check=True)
    staged = dest / "usr/share/bison"
    official = tree(staged, canonical=True)
    delta = compare(official, tree(HOST))
    for name, installed, expected in delta[:32]:
        print(f"BISON_DATA_MODE {name} installed={installed:04o} official={expected:04o}")
    print(f"BISON_DATA_VERIFIED arch={arch} version={version} sha256={sha} "
          f"entries={len(official)} modes_differ={len(delta)}", flush=True)
    return staged, seal(official)


# Only these system commands run as root, in the new private mount namespace.
# No project or package script runs with elevated UID, including after an error.
MOUNT = """
set -eu
/usr/bin/mount --bind -- "$1" /usr/share/bison
/usr/bin/mount -o remount,bind,ro,nosuid,nodev,noexec -- /usr/share/bison
exec /usr/bin/setpriv --reuid "$2" --regid "$3" --groups "$4" --no-new-privs -- \
  /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME="$5" USER="$6" LOGNAME="$6" LANG=C LC_ALL=C TZ=UTC \
  /usr/bin/python3 -IB "$7" --mounted "$1" "$2" "$3" "$8"
"""


def namespace(staged, expected):
    uid, gid = os.getuid(), os.getgid()
    identity = pwd.getpwuid(uid)
    need(uid == os.geteuid() != 0 and gid == os.getegid() and Path.cwd().is_absolute()
         and os.environ.get("HOME") == identity.pw_dir, "runner identity or HOME mismatch")
    groups = ",".join(str(g) for g in sorted(set(os.getgroups()) | {gid}))
    return ["/usr/bin/sudo", "-n", "--", "/usr/bin/env", "-i", "PATH=" + PATH,
            "/usr/bin/unshare", "--mount", "--propagation", "private", "--",
            "/usr/bin/bash", "--noprofile", "--norc", "-c", MOUNT, "hosted-bison-fixture",
            str(staged), str(uid), str(gid), groups, identity.pw_dir, identity.pw_name,
            str(Path(__file__).resolve(strict=True)), expected]


def verify_mount(staged, uid, gid, expected):
    need(os.getuid() == os.geteuid() == int(uid) != 0 and os.getgid() == os.getegid() == int(gid)
         and os.environ.get("HOME") == pwd.getpwuid(os.getuid()).pw_dir, "fixture did not drop privileges")
    flags = os.ST_RDONLY | os.ST_NOSUID | os.ST_NODEV | os.ST_NOEXEC
    need(HOST.samefile(staged) and os.statvfs(HOST).f_flag & flags == flags,
         "official Bison tree is not mounted read-only")
    need("NoNewPrivs:\t1" in Path("/proc/self/status").read_text().splitlines(),
         "fixture may regain privileges")
    need(seal(tree(HOST, canonical=True)) == expected, "mounted Bison data differs from verified package")
    print("BISON_FIXTURE_MOUNT=readonly-nonroot", flush=True)


def main(argv):
    if len(argv) == 5 and argv[0] == "--mounted":
        verify_mount(Path(argv[1]), argv[2], argv[3], argv[4])
        os.execv("/usr/bin/bash", ["bash", FIXTURE])
    need(argv == ["--", "bash", FIXTURE] and os.geteuid() != 0, "invalid hosted fixture invocation")
    need(Path(FIXTURE).resolve(strict=True) == Path(__file__).resolve().with_name(Path(FIXTURE).name),
         "run from product repository root")
    with tempfile.TemporaryDirectory(prefix="tb321fu-bison-", dir="/tmp") as td:
        sp.run(namespace(*stage(Path(td))), check=True)


if __name__ == "__main__":
    main(sys.argv[1:])
