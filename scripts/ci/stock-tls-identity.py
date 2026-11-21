"""Build-time RAM guards for the two Debian ssl-cert default output paths."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


CERT = Path("etc/ssl/certs/ssl-cert-snakeoil.pem")
KEY = Path("etc/ssl/private/ssl-cert-snakeoil.key")
FILES = (KEY, CERT)
DIRS = tuple(map(Path, ("etc", "etc/ssl", "etc/ssl/private", "etc/ssl/certs")))
UNIT = "usr/lib/systemd/system/ssl-cert.service"
ENABLE = "etc/systemd/system/multi-user.target.wants/ssl-cert.service"
RAM = Path(".tb321fu-stock-tls")
GEN = "/usr/sbin/make-ssl-cert"
REAL = GEN + ".tb321fu-build-real"
OLD = Path("var/lib/dpkg/diversions-old")
BROKEN = tuple(p.with_suffix(p.suffix + ".broken") for p in FILES)
WRAPPER = b"""#!/bin/sh
set -eu
for arg do
  if [ "$arg" = generate-default-snakeoil ]; then
    for dir in /etc /etc/ssl /etc/ssl/private /etc/ssl/certs; do
      [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
    done
    for name in /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem; do
      dest=/.tb321fu-stock-tls/${name##*/}
      [ ! -L "$dest" ] && { [ ! -e "$dest" ] || [ -f "$dest" ]; } || exit 1
      if [ -L "$name" ]; then [ "$(readlink -- "$name")" = "$dest" ] || exit 1
      elif [ -e "$name" ]; then exit 1
      else rm -f -- "$dest"; ln -s -- "$dest" "$name"; fi
    done
    break
  fi
done
exec /usr/sbin/make-ssl-cert.tb321fu-build-real "$@"
"""


def check(ok, message):
    if not ok:
        raise ValueError(message)


def realdir(path):
    return stat.S_ISDIR(path.lstat().st_mode)


def rootdir(path):
    check(path.is_absolute() and path != Path("/") and path.resolve(strict=True) == path and realdir(path),
          "an absolute, nonsymlink, non-host build root is required")


def prepare(root):
    # Called before debootstrap and every APT transaction. The existing builder
    # EXIT trap owns partially or fully mounted subtrees on all failure paths.
    rootdir(root)
    ram = root / RAM
    ram.mkdir(mode=0o700)
    # Search-only for non-root: the original certificate mode and ssl-cert group
    # still govern access to the two individual files during package setup.
    subprocess.run(["mount", "-t", "tmpfs", "-o", "mode=0711,size=1m,nosuid,nodev,noexec",
                    "tmpfs", str(ram)], check=True)
    created = []
    for rel in DIRS:
        path = root / rel
        if not os.path.lexists(path):
            path.mkdir(mode=0o700 if rel == KEY.parent else 0o755)
            created.append(str(rel))
        check(realdir(path), "stock TLS guard parent must be a real directory")
    # update-ca-certificates removes dangling public .pem links on a fresh
    # install. Keep only its public target valid, never the private key: the
    # stock generator skips --no-overwrite only when *both* files exist.
    with (ram / CERT.name).open("xb") as public:
        os.fchmod(public.fileno(), 0o644)
    for rel in FILES:
        (root / rel).symlink_to("/" + str(RAM / rel.name))
    return {"dirs": created, "ram_dev": ram.stat().st_dev}


def verify(root, receipt, *, allow_absent=False):
    rootdir(root)
    ram = root / RAM
    fs = subprocess.check_output(["findmnt", "-n", "--mountpoint", str(ram), "-o", "FSTYPE"], text=True)
    check(fs.strip() == "tmpfs" and realdir(ram) and ram.stat().st_dev == receipt["ram_dev"] and
          ram.stat().st_uid == 0 and stat.S_IMODE(ram.stat().st_mode) == 0o711, "stock TLS RAM mount changed")
    for rel in DIRS:
        check(not os.path.lexists(root / rel) or realdir(root / rel), "stock TLS parent changed")
    for rel in FILES:
        path = root / rel
        if allow_absent and not os.path.lexists(path):
            continue  # a legitimate purge may have unlinked the original symlink
        actual = ram / rel.name
        check(all(realdir(root / x) for x in rel.parents if x != Path(".")) and path.is_symlink() and
              os.readlink(path) == "/" + str(RAM / rel.name) and
              (not os.path.lexists(actual) or stat.S_ISREG(actual.lstat().st_mode)),
              "stock TLS output is no longer guarded")


def divert(root, *args):
    return subprocess.check_output(["dpkg-divert", "--root", str(root), *args], text=True)


def snapshot(path):
    if not os.path.lexists(path):
        return None
    st = path.lstat()
    check(stat.S_ISREG(st.st_mode) and st.st_size <= 384 * 1024, "unexpected diversions history file")
    return {"data": base64.b64encode(path.read_bytes()).decode(), "mode": stat.S_IMODE(st.st_mode),
            "uid": st.st_uid, "gid": st.st_gid, "mtime": st.st_mtime_ns, "dev": st.st_dev, "ino": st.st_ino}


def stamp(state):
    if state is None:
        return None
    return [state[k] for k in ("dev", "ino", "mode", "mtime")] + [hashlib.sha256(state["data"].encode()).hexdigest()]


def strip_build_record(data):
    lines = data.splitlines(keepends=True)
    check(len(lines) % 3 == 0 and (not lines or lines[-1].endswith(b"\n")), "invalid diversion history records")
    record = [s.encode() + b"\n" for s in (GEN, REAL, ":")]
    rows = [lines[i:i+3] for i in range(0, len(lines), 3)]
    check(rows.count(record) <= 1, "duplicate stock TLS diversion history record")
    return b"".join(part for row in rows if row != record for part in row)


def write_history(path, state):
    if state is None:
        path.unlink(missing_ok=True)
        return
    # Replace one directory entry atomically; never rewrite another hard link
    # to an earlier dpkg history inode.
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".stock-tls-history-")
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(base64.b64decode(state["data"], validate=True))
            os.fchown(out.fileno(), state["uid"], state["gid"])
            os.fchmod(out.fileno(), state["mode"])
        os.utime(name, ns=(state["mtime"], state["mtime"]))
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def intercept(root, receipt):
    verify(root, receipt)
    gen, real = root / GEN[1:], root / REAL[1:]
    check(realdir(gen.parent) and not os.path.lexists(real) and
          (not os.path.lexists(gen) or stat.S_ISREG(gen.lstat().st_mode)) and
          divert(root, "--truename", GEN).strip() == GEN, "existing stock TLS diversion or nonregular generator")
    init = {"old": snapshot(root / OLD), "main_absent": not os.path.lexists(root / OLD.with_name("diversions"))}
    divert(root, "--local", "--rename", "--divert", REAL, "--add", GEN)
    init["after_add"] = stamp(snapshot(root / OLD))
    state = os.open(root / RAM / "dpkg-history", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(state, "w") as out:
        json.dump(init, out)
    with gen.open("xb") as out:
        out.write(WRAPPER)
    gen.chmod(0o755)


def check_overlay(root):
    # Inspect both optional overlay sources before any rsync writes temporary
    # files into the output. Even a dangling symlink counts as supplied.
    check(not root.is_symlink(), "overlay root cannot be a symlink")
    root = root.resolve(strict=True)
    rootdir(root)
    for rel in (*DIRS, Path("usr"), Path("usr/sbin"), Path("var"), Path("var/lib"), Path("var/lib/dpkg")):
        path = root / rel
        if os.path.lexists(path):
            check(realdir(path), "overlay may not replace a stock TLS parent")
    reserved = (*FILES, *BROKEN, RAM, GEN[1:], REAL[1:], "var/lib/dpkg/diversions", OLD)
    check(not any(os.path.lexists(root / rel) for rel in reserved), "overlay supplies a reserved stock TLS path")


def stock_service(root):
    db = root / "var/lib/dpkg"
    query = ["dpkg-query", "--admindir=" + str(db)]
    pkg = subprocess.run(query + ["--show", "--showformat=${db:Status-Abbrev}", "ssl-cert"],
                         capture_output=True, check=False)
    check(pkg.returncode in (0, 1) and (root / "var/lib/dpkg/status").is_file(),
          "cannot determine ssl-cert status")
    if pkg.returncode == 0 and pkg.stdout == b"ii ":
        unit, enable, gen = root / UNIT, root / ENABLE, root / "usr/sbin/make-ssl-cert"
        check(stat.S_ISREG(unit.lstat().st_mode) and stat.S_ISREG(gen.lstat().st_mode) and os.access(gen, os.X_OK),
              "installed ssl-cert lacks its native generator or unit")
        lines = unit.read_text(encoding="utf-8").splitlines()
        check("ConditionPathExists=!/" + str(KEY) in lines and
              "ExecStart=-/usr/sbin/make-ssl-cert generate-default-snakeoil --force-overwrite" in lines,
              "review changed ssl-cert native first-boot contract")
        link = os.readlink(enable)
        check(not link.endswith(("/", "/.")), "invalid stock TLS service link")
        dest = str(Path(link))  # remove '.' and redundant separators, never collapse '..'
        def spellings(path):
            return {path, os.path.relpath(path, "/" + str(Path(ENABLE).parent))}
        if dest not in spellings("/" + UNIT):
            check(dest in spellings("/" + UNIT.removeprefix("usr/")) and (root / "lib").is_symlink() and
                  str(Path(os.readlink(root / "lib"))) in ("usr/lib", "/usr/lib"), "stock TLS service is not enabled")
    return query


def restore(root):
    gen, real = root / GEN[1:], root / REAL[1:]
    check(stat.S_ISREG(gen.lstat().st_mode) and gen.read_bytes() == WRAPPER and
          divert(root, "--truename", GEN).strip() == REAL and
          (not os.path.lexists(real) or stat.S_ISREG(real.lstat().st_mode)), "temporary stock TLS diversion changed")
    backup = root / OLD
    init = json.loads((root / RAM / "dpkg-history").read_text())
    prior = snapshot(backup)
    untouched = stamp(prior) == init["after_add"]
    if untouched:
        restore_old = init["old"]
    else:
        # Preserve the latest genuine package transaction's prior history.
        restore_old = prior
        if restore_old is not None:
            data = base64.b64decode(restore_old["data"], validate=True)
            restore_old["data"] = base64.b64encode(strip_build_record(data)).decode()
    before_sha = hashlib.sha256(real.read_bytes()).digest() if real.exists() else None
    gen.unlink()
    divert(root, "--local", "--rename", "--divert", REAL, "--remove", GEN)
    check(divert(root, "--truename", GEN).strip() == GEN and not os.path.lexists(real), "diversion not restored")
    check((hashlib.sha256(gen.read_bytes()).digest() if gen.exists() else None) == before_sha,
          "stock generator not faithfully restored")
    write_history(backup, restore_old)
    main = root / OLD.with_name("diversions")
    if init["main_absent"] and untouched and main.exists() and main.stat().st_size == 0:
        main.unlink()


def seal(root, receipt):
    verify(root, receipt, allow_absent=True)
    restore(root)
    query = stock_service(root)
    # remove only stock links the upstream generator or openssl rehash creates.
    # Never renumber or rewrite another certificate's hash lookup.
    certs = root / CERT.parent
    links = {}
    for ent in certs.iterdir() if certs.is_dir() else ():
        hit = re.fullmatch(r"([0-9a-f]{8})\.([0-9]+)", ent.name)
        if hit:
            links[(hit[1], int(hit[2]))] = ent
    stock = {k for k, ent in links.items() if ent.is_symlink() and os.readlink(ent) == CERT.name}
    for h, n in stock:
        check(not any(k[0] == h and k[1] > n and k not in stock for k in links),
              "removing stock TLS hash would hide another certificate")
    for k in stock:
        links[k].unlink()
    for src, alias in zip(FILES, BROKEN, strict=True):
        p = root / alias
        if os.path.lexists(p):
            check(p.is_symlink() and str(Path(os.readlink(p))) in
                  (src.name, "/" + str(src), "/" + str(RAM / src.name)), "unexpected stock TLS backup file")
            p.unlink()
    for rel in FILES:
        (root / rel).unlink(missing_ok=True)
    subprocess.run(["umount", "--", str(root / RAM)], check=True)
    (root / RAM).rmdir()
    for rel in reversed(receipt["dirs"]):
        check(Path(rel) in DIRS, "unexpected stock TLS guard directory")
        path = root / rel
        if path.is_dir() and not any(path.iterdir()):
            owner = subprocess.run(query + ["--search", "/" + rel], capture_output=True, check=False)
            check(owner.returncode in (0, 1), "cannot determine ownership of TLS directory")
            if owner.returncode == 1:
                path.rmdir()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "overlay", "intercept", "seal"))
    parser.add_argument("root", type=Path)
    parser.add_argument("receipt", nargs="?")
    args = parser.parse_args()
    if args.action == "prepare":
        print(json.dumps(prepare(args.root)))
    elif args.action == "overlay":
        check_overlay(args.root)
    elif args.action == "intercept":
        intercept(args.root, json.loads(args.receipt))
    else:
        seal(args.root, json.loads(args.receipt))
