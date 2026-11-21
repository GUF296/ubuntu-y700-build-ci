"""Check the reviewed June daily -> current camera handoff; never modify either tree."""

import csv
import hashlib
import os
from pathlib import Path
import stat
import sys


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate(daily, camera, rows):
    expected = {row["path"] for row in rows}
    if len(rows) != 26 or len(expected) != len(rows):
        raise ValueError("invalid reviewed camera inventory")
    directories = {p for name in expected for p in Path(name).parents}
    # Also visit links to directories and special leaves; never follow them.
    seen = set()

    def walk(directory):
        if (directory.relative_to(camera) not in directories
                or stat.S_IMODE(directory.lstat().st_mode) != 0o755):
            raise ValueError("unreviewed canonical camera directory or mode")
        with os.scandir(directory) as entries:
            for entry in entries:
                path = Path(entry.path)
                if entry.is_dir(follow_symlinks=False):
                    walk(path)
                else:
                    seen.add(path.relative_to(camera).as_posix())

    walk(camera)
    if seen != expected:
        raise ValueError("canonical camera file/link inventory changed")
    for row in rows:
        relative, policy = row["path"], row["new_policy"]
        old, new = daily / relative, camera / relative
        want = row["old_sha256_or_target"]
        kind = stat.S_ISLNK if policy == "link" else stat.S_ISREG
        for member, key in ((old, "old_mode"), (new, "new_mode")):
            mode = member.lstat().st_mode
            if not kind(mode) or stat.S_IMODE(mode) != int(row[key], 8):
                raise ValueError(f"{key}/type differs: /{relative}")
        if policy == "link":
            if os.readlink(old) != want or os.readlink(new) != want:
                raise ValueError(f"link target differs: /{relative}")
        else:
            if digest(old) != want:
                raise ValueError(f"old fingerprint differs: /{relative}")
            # Only the eight rebuilt binaries/signature use the same-run
            # producer DEB digest as their new content identity.
            if policy != "producer" and digest(new) != (want if policy == "same" else policy):
                raise ValueError(f"fixed new fingerprint differs: /{relative}")


def main():
    manifest = Path(__file__).with_name("payloads") / "june-camera-transition.tsv"
    with manifest.open(encoding="ascii", newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    validate(Path(sys.argv[1]), Path(sys.argv[2]), rows)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(f"June camera migration: {error}")
