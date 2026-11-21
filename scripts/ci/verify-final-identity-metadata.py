"""Read final ext4 inode metadata only; do not read machine identifiers or TLS material."""
from functools import cache
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

MACHINE = "/etc/machine-id"
DBUS = "/var/lib/dbus/machine-id"
KEY = "/etc/ssl/private/ssl-cert-snakeoil.key"
CERT = "/etc/ssl/certs/ssl-cert-snakeoil.pem"
SERVICE = "/usr/lib/systemd/system/ssl-cert.service"
ENABLED = "/etc/systemd/system/multi-user.target.wants/ssl-cert.service"


def need(ok, reason):
    if not ok:
        raise ValueError(reason)


def verify(image, inventory):
    @cache
    def inode(path):
        # Only walk fixed paths from this module. Don't interpret ENOENT below
        # a non-directory or a symlink as proof that protected files are absent.
        parent = str(PurePosixPath(path).parent)
        if parent != "/":
            directory = inode(parent)
            if directory is None:
                return None
            need(directory[0] == "directory", "unexpected ext4 parent type: " + parent)
        env = {"LC_ALL": "C", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"}
        run = subprocess.run(["debugfs", "-R", "stat " + path, image], check=True, timeout=15,
                             capture_output=True, env=env)
        err = run.stderr.decode("ascii").strip().splitlines()
        need(err and re.fullmatch(r"debugfs [0-9.]+ \([^\r\n]+\)", err[0]), "unrecognized debugfs result")
        if not run.stdout and len(err) == 2 and err[1].strip() == path + ": File not found by ext2_lookup":
            return None
        need(len(err) == 1, "debugfs could not verify " + path)
        out = run.stdout.decode("ascii")
        kind = re.search(r"^Inode: (?P<ino>[1-9][0-9]*) +Type: (?P<type>\w+) +Mode: +(?P<mode>[0-7]{4}) +Flags:", out, re.M)
        meta = re.search(r"^User: +(\d+) +Group: +(\d+) +Project: +\d+ +Size: (\d+)$", out, re.M)
        need(kind and meta, "missing ext4 inode metadata: " + path)
        dest = re.findall(r'^Fast link dest: "([^"\r\n]+)"$', out, re.M)
        if path in (DBUS, ENABLED, "/lib") and kind["type"] == "symlink" and not dest:
            # Long links are stored in a block, not printed by stat. Address
            # only this stat-confirmed symlink inode, never open its pathname
            # or target; machine-id, key, certificate and unit data are not read.
            size = int(meta[3])
            need(0 < size < 4096, "invalid ext4 symlink size")
            link = subprocess.run(["debugfs", "-R", "cat <" + kind["ino"] + ">", image], check=True, timeout=15,
                                  capture_output=True, env=env)
            need(link.stderr.decode("ascii").strip().splitlines() == err and len(link.stdout) == size,
                 "could not verify ext4 symlink text")
            dest = [link.stdout.decode("ascii")]
        return (kind["type"], int(kind["mode"], 8), int(meta[1]), int(meta[2]), int(meta[3]), dest)

    # This is the installed-only list produced by the immediately preceding
    # dpkg-query; do not equate remaining config files with an installed package.
    names = set()
    with inventory.open(encoding="ascii") as stream:
        for line in stream:
            fields = line.rstrip("\n").split("\t")
            need(len(fields) == 3 and all(fields), "unrecognized installed-package inventory")
            names.add(fields[0].partition(":")[0])
    need(names, "empty installed-package inventory")
    need(inode(MACHINE) == ("regular", 0o644, 0, 0, 0, []), "system machine-id is not a root-owned empty placeholder")

    def link(row, accepted, basename):
        return (row is not None and row[:4] == ("symlink", 0o777, 0, 0) and
                len(row[5]) == 1 and row[4] == len(row[5][0]) and row[5][0].endswith("/" + basename) and
                str(PurePosixPath(row[5][0])) in accepted)

    old = inode(DBUS)
    need(old is None or link(old, {MACHINE, "../../../etc/machine-id"}, "machine-id"), "separate/incorrect D-Bus machine-id")
    need(all(inode(p) is None for p in (KEY, CERT, KEY + ".broken", CERT + ".broken")),
         "stock TLS identity present in final image")
    installed = "ssl-cert" in names
    if installed:
        unit = inode(SERVICE)
        need(unit and unit[:4] == ("regular", 0o644, 0, 0) and unit[4] > 0, "ssl-cert unit missing or wrong metadata")
        enable = inode(ENABLED)
        direct = {SERVICE, "../../../../usr/lib/systemd/system/ssl-cert.service"}
        merged = {"/lib/systemd/system/ssl-cert.service", "../../../../lib/systemd/system/ssl-cert.service"}
        need(link(enable, direct, "ssl-cert.service") or
             (link(enable, merged, "ssl-cert.service") and link(inode("/lib"), {"/usr/lib", "usr/lib"}, "lib")),
             "ssl-cert native first-boot service is not enabled")
    return ("desktop=" + ("kubuntu" if "kubuntu-desktop" in names else "other") +
            " native_ssl_cert_unit=" + ("installed-verified" if installed else "not-installed"))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify-final-identity-metadata.py EXT4 INSTALLED-PACKAGES.tsv")
    print("FINAL_EXT4_IDENTITY_METADATA=PASS", verify(Path(sys.argv[1]), Path(sys.argv[2])))
