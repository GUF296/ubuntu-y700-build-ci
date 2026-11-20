#!/usr/bin/env python3
"""Hostile fixtures for the raw TB321FU kernel-modules DEB verifier."""

from __future__ import annotations

import dataclasses
import lzma
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
VERIFY = SCRIPT_DIR / "verify-kernel-modules-deb.py"
RELEASE = "7.1.1-fixture"
EPOCH = 1_784_752_597
AR_MAGIC = b"!<arch>\n"
GNU_MAGIC = b"ustar  \x00"
GNU_LONGNAME = "././@LongLink"
TAR_BLOCK = 512
TAR_RECORD = 10 * 1024
MODULE_METADATA = (
    "modules.alias",
    "modules.alias.bin",
    "modules.builtin",
    "modules.builtin.alias.bin",
    "modules.builtin.bin",
    "modules.builtin.modinfo",
    "modules.dep",
    "modules.dep.bin",
    "modules.devname",
    "modules.order",
    "modules.softdep",
    "modules.symbols",
    "modules.symbols.bin",
)


def control_bytes(*extra_fields: str) -> bytes:
    fields = [
        "Package: y700-daily-kernel-modules",
        f"Version: {RELEASE}",
        "Section: misc",
        "Priority: optional",
        "Architecture: arm64",
        "Depends: kmod",
        "Maintainer: TB321FU Linux build <noreply@localhost>",
        f"Description: Lenovo TB321FU kernel modules for {RELEASE}.",
    ]
    fields.extend(extra_fields)
    return ("\n".join(fields) + "\n").encode("ascii")


POSTINST = (
    "#!/bin/sh\n"
    "set -e\n"
    f"current_release='{RELEASE}'\n"
    "if command -v depmod >/dev/null 2>&1; then\n"
    "  depmod \"$current_release\"\n"
    "fi\n"
    "exit 0\n"
).encode("ascii")


@dataclasses.dataclass(frozen=True)
class TarEntry:
    name: str
    kind: bytes
    mode: int
    payload: bytes = b""
    uid: int = 0
    gid: int = 0
    mtime: int = EPOCH
    force_longname: bool = False


@dataclasses.dataclass(frozen=True)
class ArEntry:
    name: str
    payload: bytes
    mtime: int = EPOCH
    uid: int = 0
    gid: int = 0
    mode: int = 0o100644
    padding: bytes = b"\n"


def octal(value: int, width: int) -> bytes:
    return f"{value:0{width - 1}o}\x00".encode("ascii")


def tar_header(entry: TarEntry, raw_name: bytes | None = None) -> bytes:
    name = raw_name if raw_name is not None else entry.name.encode("ascii")
    if len(name) > 100:
        raise ValueError("raw tar header name exceeds 100 bytes")
    header = bytearray(TAR_BLOCK)
    header[0 : len(name)] = name
    header[100:108] = octal(entry.mode, 8)
    header[108:116] = octal(entry.uid, 8)
    header[116:124] = octal(entry.gid, 8)
    header[124:136] = octal(len(entry.payload), 12)
    header[136:148] = octal(entry.mtime, 12)
    header[148:156] = b" " * 8
    header[156:157] = entry.kind
    header[257:265] = GNU_MAGIC
    header[265:269] = b"root"
    header[297:301] = b"root"
    checksum = sum(header)
    header[148:156] = f"{checksum:06o}\x00 ".encode("ascii")
    return bytes(header)


def tar_entry_bytes(entry: TarEntry) -> bytes:
    encoded_name = entry.name.encode("ascii")
    result = bytearray()
    if len(encoded_name) > 100 or entry.force_longname:
        longname = TarEntry(
            GNU_LONGNAME,
            b"L",
            0o644,
            encoded_name + b"\x00",
            mtime=0,
        )
        result.extend(tar_header(longname))
        result.extend(longname.payload)
        result.extend(b"\x00" * ((-len(longname.payload)) % TAR_BLOCK))
        raw_name = encoded_name[:100]
    else:
        raw_name = encoded_name
    result.extend(tar_header(entry, raw_name))
    result.extend(entry.payload)
    result.extend(b"\x00" * ((-len(entry.payload)) % TAR_BLOCK))
    return bytes(result)


def make_tar(
    entries: list[TarEntry],
    *,
    end_blocks: int = 2,
    record_padding: bool = True,
    trailing: bytes = b"",
) -> bytes:
    raw = bytearray()
    for entry in entries:
        raw.extend(tar_entry_bytes(entry))
    raw.extend(b"\x00" * (end_blocks * TAR_BLOCK))
    if record_padding:
        raw.extend(b"\x00" * ((-len(raw)) % TAR_RECORD))
    raw.extend(trailing)
    return bytes(raw)


def control_entries(
    *,
    control: bytes | None = None,
    postinst: bytes = POSTINST,
) -> list[TarEntry]:
    return [
        TarEntry("./", b"5", 0o755),
        TarEntry("./control", b"0", 0o644, control_bytes() if control is None else control),
        TarEntry("./postinst", b"0", 0o755, postinst),
    ]


def data_entries() -> list[TarEntry]:
    root = f"./usr/lib/modules/{RELEASE}"
    long_component = "long-" + "x" * 60
    directories = [
        "./",
        "./usr/",
        "./usr/lib/",
        "./usr/lib/modules/",
        root + "/",
        root + "/kernel/",
        root + "/kernel/drivers/",
        root + f"/kernel/drivers/{long_component}/",
    ]
    entries = [TarEntry(name, b"5", 0o755) for name in directories]
    entries.extend(
        TarEntry(f"{root}/{name}", b"0", 0o644, (name + "\n").encode("ascii"))
        for name in MODULE_METADATA
    )
    entries.append(
        TarEntry(
            root + f"/kernel/drivers/{long_component}/fixture.ko",
            b"0",
            0o644,
            b"fixture kernel module\n",
        )
    )
    return entries


def compress(raw: bytes) -> bytes:
    return lzma.compress(raw, format=lzma.FORMAT_XZ, preset=6)


def ar_header(entry: ArEntry) -> bytes:
    name = entry.name.encode("ascii")
    if len(name) > 16:
        raise ValueError("fixture ar name exceeds 16 bytes")
    return b"".join(
        (
            name.ljust(16, b" "),
            str(entry.mtime).encode("ascii").ljust(12, b" "),
            str(entry.uid).encode("ascii").ljust(6, b" "),
            str(entry.gid).encode("ascii").ljust(6, b" "),
            f"{entry.mode:o}".encode("ascii").ljust(8, b" "),
            str(len(entry.payload)).encode("ascii").ljust(10, b" "),
            b"`\n",
        )
    )


def make_ar(entries: list[ArEntry]) -> bytes:
    raw = bytearray(AR_MAGIC)
    for entry in entries:
        raw.extend(ar_header(entry))
        raw.extend(entry.payload)
        if len(entry.payload) % 2:
            raw.extend(entry.padding)
    return bytes(raw)


GOOD_CONTROL_TAR = make_tar(control_entries())
GOOD_DATA_TAR = make_tar(data_entries())
GOOD_CONTROL_XZ = compress(GOOD_CONTROL_TAR)
GOOD_DATA_XZ = compress(GOOD_DATA_TAR)


def ar_entries(
    *,
    control_xz: bytes = GOOD_CONTROL_XZ,
    data_xz: bytes = GOOD_DATA_XZ,
) -> list[ArEntry]:
    return [
        ArEntry("debian-binary", b"2.0\n"),
        ArEntry("control.tar.xz", control_xz),
        ArEntry("data.tar.xz", data_xz),
    ]


def deb_with_control(entries: list[TarEntry], **tar_options) -> bytes:
    return make_ar(ar_entries(control_xz=compress(make_tar(entries, **tar_options))))


def deb_with_data(entries: list[TarEntry], **tar_options) -> bytes:
    return make_ar(ar_entries(data_xz=compress(make_tar(entries, **tar_options))))


def ar_header_offsets(raw: bytes) -> list[int]:
    offsets: list[int] = []
    offset = len(AR_MAGIC)
    while offset + 60 <= len(raw):
        offsets.append(offset)
        field = raw[offset + 48 : offset + 58].decode("ascii").strip()
        if not field.isdecimal():
            break
        size = int(field)
        offset += 60 + size + size % 2
    return offsets


def mutate(raw: bytes, offset: int, replacement: bytes) -> bytes:
    result = bytearray(raw)
    result[offset : offset + len(replacement)] = replacement
    return bytes(result)


def mutate_tar_checksum(raw: bytes, offset: int) -> bytes:
    result = bytearray(raw)
    result[offset] ^= 1
    return bytes(result)


def mutate_tar_header(
    raw: bytes, header_offset: int, field_offset: int, replacement: bytes
) -> bytes:
    result = bytearray(raw)
    start = header_offset + field_offset
    result[start : start + len(replacement)] = replacement
    result[header_offset + 148 : header_offset + 156] = b" " * 8
    checksum = sum(result[header_offset : header_offset + TAR_BLOCK])
    result[header_offset + 148 : header_offset + 156] = (
        f"{checksum:06o}\x00 ".encode("ascii")
    )
    return bytes(result)


def run(
    path: pathlib.Path, *extra: str, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    process_env = os.environ.copy()
    if env is not None:
        process_env.update(env)
    return subprocess.run(
        [
            sys.executable,
            str(VERIFY),
            "--deb",
            str(path),
            "--kernel-release",
            RELEASE,
            "--package-version",
            RELEASE,
            "--source-date-epoch",
            str(EPOCH),
            *extra,
        ],
        check=False,
        env=process_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="tb321fu-kernel-modules-deb.") as raw_root:
        root = pathlib.Path(raw_root)
        candidate = root / "candidate.deb"
        good = make_ar(ar_entries())
        candidate.write_bytes(good)
        result = run(candidate)
        if result.returncode or result.stdout.strip() != "KERNEL_MODULES_DEB=PASS":
            raise SystemExit(f"valid kernel modules DEB fixture failed: {result.stderr}")

        output_directory = root / "verified-tars"
        control_output = output_directory / "control.tar"
        data_output = output_directory / "data.tar"
        result = run(
            candidate,
            "--output-directory",
            str(output_directory),
        )
        if result.returncode or result.stdout.strip() != "KERNEL_MODULES_DEB=PASS":
            raise SystemExit(f"valid raw tar output fixture failed: {result.stderr}")
        if control_output.read_bytes() != GOOD_CONTROL_TAR:
            raise SystemExit("verified control tar output changed canonical bytes")
        if data_output.read_bytes() != GOOD_DATA_TAR:
            raise SystemExit("verified data tar output changed canonical bytes")
        shutil.rmtree(output_directory)

        output_file = root / "output-file"
        output_file.write_text("not a directory\n")
        result = run(candidate, "--output-directory", str(output_file))
        if result.returncode == 0:
            raise SystemExit("existing non-directory raw tar output was accepted")

        candidate.write_bytes(make_ar(ar_entries(control_xz=b"\xfd7zXZ\x00invalid")))
        failed_output = root / "failed-tars"
        result = run(
            candidate,
            "--output-directory",
            str(failed_output),
        )
        if result.returncode == 0 or failed_output.exists():
            raise SystemExit("failed raw tar verification promoted an output")
        if (root / ".failed-tars.transaction").exists():
            raise SystemExit("failed raw tar verification left a private partial")
        candidate.write_bytes(good)

        before_output = root / "interrupted-before"
        result = run(
            candidate,
            "--output-directory",
            str(before_output),
            env={"TB321FU_TEST_MODULE_PROMOTION_KILL": "before-rename"},
        )
        if result.returncode != -signal.SIGKILL or before_output.exists():
            raise SystemExit("pre-rename interruption exposed a partial final output")
        if not (root / ".interrupted-before.transaction").is_dir():
            raise SystemExit("pre-rename interruption did not preserve a recoverable transaction")
        result = run(candidate, "--output-directory", str(before_output))
        if result.returncode or {entry.name for entry in before_output.iterdir()} != {
            "control.tar",
            "data.tar",
        }:
            raise SystemExit(f"pre-rename interrupted transaction did not recover: {result.stderr}")
        if (root / ".interrupted-before.transaction").exists():
            raise SystemExit("recovered pre-rename transaction remains staged")

        after_output = root / "interrupted-after"
        result = run(
            candidate,
            "--output-directory",
            str(after_output),
            env={"TB321FU_TEST_MODULE_PROMOTION_KILL": "after-rename"},
        )
        if result.returncode != -signal.SIGKILL or {entry.name for entry in after_output.iterdir()} != {
            "control.tar",
            "data.tar",
        }:
            raise SystemExit("post-rename interruption did not expose the complete atomic directory")
        result = run(candidate, "--output-directory", str(after_output))
        if result.returncode:
            raise SystemExit(f"post-rename idempotent retry failed: {result.stderr}")

        rejected = 0

        def require_clean_rejection(
            result: subprocess.CompletedProcess[str], label: str
        ) -> None:
            if result.returncode == 0:
                raise SystemExit(f"unsafe kernel modules DEB fixture was accepted: {label}")
            if not result.stderr.startswith("kernel modules DEB rejected: ") or "Traceback" in result.stderr:
                raise SystemExit(
                    f"kernel modules DEB fixture did not fail cleanly: {label}: {result.stderr}"
                )

        def require_rejected(raw: bytes, label: str, *extra: str) -> None:
            nonlocal rejected
            candidate.write_bytes(raw)
            result = run(candidate, *extra)
            require_clean_rejection(result, label)
            rejected += 1

        result = run(candidate, "--package-version", "7.1.1-other")
        require_clean_rejection(result, "mismatched package version")
        rejected += 1

        link = root / "candidate-link.deb"
        link.symlink_to(candidate)
        require_clean_rejection(run(link), "symlink DEB input")
        rejected += 1
        fifo = root / "candidate.fifo"
        os.mkfifo(fifo)
        require_clean_rejection(run(fifo), "FIFO DEB input")
        rejected += 1
        require_clean_rejection(run(root), "directory DEB input")
        rejected += 1

        base_entries = ar_entries()
        require_rejected(make_ar(base_entries + [ArEntry("extra", b"x")]), "extra ar member")
        require_rejected(
            make_ar([base_entries[0], base_entries[1], base_entries[1]]),
            "duplicate ar member",
        )
        require_rejected(
            make_ar([base_entries[0], base_entries[2], base_entries[1]]),
            "reordered ar members",
        )
        require_rejected(
            make_ar([dataclasses.replace(base_entries[0], name="/"), *base_entries[1:]]),
            "GNU ar name extension",
        )
        require_rejected(
            make_ar([dataclasses.replace(base_entries[0], name="#1/4"), *base_entries[1:]]),
            "BSD ar name extension",
        )
        for field, changes in (
            ("mtime", {"mtime": EPOCH + 1}),
            ("uid", {"uid": 1}),
            ("gid", {"gid": 1}),
            ("mode", {"mode": 0o100600}),
        ):
            changed = list(base_entries)
            changed[1] = dataclasses.replace(changed[1], **changes)
            require_rejected(make_ar(changed), f"ar {field}")

        offsets = ar_header_offsets(good)
        require_rejected(mutate(good, offsets[0] + 48, b"04        "), "ar leading-zero size")
        require_rejected(good[:-1], "truncated ar payload")
        require_rejected(good + b"trailing", "ar trailing bytes")
        changed = list(base_entries)
        changed[0] = dataclasses.replace(changed[0], payload=b"2.1\n")
        require_rejected(make_ar(changed), "wrong debian-binary payload")
        changed = list(base_entries)
        changed[1] = dataclasses.replace(changed[1], name="control.tar.gz")
        require_rejected(make_ar(changed), "wrong control compression name")
        odd_data = GOOD_DATA_XZ + b"x"
        changed = ar_entries(data_xz=odd_data)
        changed[2] = dataclasses.replace(changed[2], padding=b"X")
        require_rejected(make_ar(changed), "non-canonical ar padding")

        require_rejected(
            make_ar(ar_entries(control_xz=b"\xfd7zXZ\x00invalid")),
            "invalid XZ stream",
        )
        require_rejected(
            make_ar(ar_entries(control_xz=GOOD_CONTROL_XZ[:-4])),
            "truncated XZ stream",
        )
        require_rejected(
            make_ar(ar_entries(control_xz=GOOD_CONTROL_XZ + compress(b"second stream"))),
            "concatenated XZ streams",
        )
        bomb = compress(b"\x00" * (4 * 1024 * 1024 + 1024))
        require_rejected(make_ar(ar_entries(control_xz=bomb)), "XZ decompression bomb")

        for field in (
            "Pre-Depends: malicious",
            "Conflicts: malicious",
            "Essential: yes",
        ):
            require_rejected(
                deb_with_control(control_entries(control=control_bytes(field))),
                f"extra control field {field.split(':', 1)[0]}",
            )
        require_rejected(
            deb_with_control(control_entries(postinst=POSTINST + b"echo changed\n")),
            "changed postinst bytes",
        )
        require_rejected(
            deb_with_control(control_entries(control=control_bytes().replace(b"Depends: kmod", b"Depends: kmod, bash"))),
            "changed control dependency",
        )

        extra_control = control_entries() + [TarEntry("./extra", b"0", 0o644, b"extra")]
        require_rejected(deb_with_control(extra_control), "extra control member")
        duplicate_control = control_entries() + [TarEntry("./control", b"0", 0o644, control_bytes())]
        require_rejected(deb_with_control(duplicate_control), "duplicate tar member")
        for kind, label in (
            (b"x", "PAX"),
            (b"g", "global PAX"),
            (b"K", "GNU long-link"),
            (b"S", "GNU sparse"),
            (b"1", "hardlink"),
            (b"2", "symlink"),
            (b"3", "character device"),
            (b"4", "block device"),
            (b"6", "FIFO"),
        ):
            entries = [control_entries()[0], TarEntry("./extension", kind, 0o644), *control_entries()[1:]]
            require_rejected(deb_with_control(entries), f"forbidden tar type {label}")

        unnecessary = control_entries()
        unnecessary[1] = dataclasses.replace(unnecessary[1], force_longname=True)
        require_rejected(deb_with_control(unnecessary), "unnecessary GNU LongLink")
        for unsafe_name in (
            "control",
            "./../control",
            "./a//control",
            "./a/./control",
            "./a\\control",
            "/control",
        ):
            entries = control_entries()
            entries[1] = dataclasses.replace(entries[1], name=unsafe_name)
            require_rejected(deb_with_control(entries), f"unsafe tar path {unsafe_name!r}")

        for field, changes in (
            ("uid", {"uid": 1}),
            ("gid", {"gid": 1}),
            ("mtime", {"mtime": EPOCH + 1}),
            ("file mode", {"mode": 0o666}),
        ):
            entries = control_entries()
            entries[1] = dataclasses.replace(entries[1], **changes)
            require_rejected(deb_with_control(entries), f"tar {field}")
        entries = control_entries()
        entries[0] = dataclasses.replace(entries[0], mode=0o777)
        require_rejected(deb_with_control(entries), "tar directory mode")
        entries = control_entries()
        entries[2] = dataclasses.replace(entries[2], mode=0o644)
        require_rejected(deb_with_control(entries), "postinst mode")

        bad_checksum = mutate_tar_checksum(GOOD_CONTROL_TAR, 0)
        require_rejected(
            make_ar(ar_entries(control_xz=compress(bad_checksum))),
            "tar checksum mismatch",
        )
        for label, field_offset, replacement in (
            ("base-256 tar mode", 100, b"\x80" + b"\x00" * 7),
            ("tar uname", 265, b"evil" + b"\x00" * 28),
            ("tar gname", 297, b"evil" + b"\x00" * 28),
            ("tar ustar prefix", 345, b"x"),
        ):
            changed_tar = mutate_tar_header(
                GOOD_CONTROL_TAR, 0, field_offset, replacement
            )
            require_rejected(
                make_ar(ar_entries(control_xz=compress(changed_tar))), label
            )
        longlink_offset = GOOD_DATA_TAR.find(GNU_LONGNAME.encode("ascii"))
        if longlink_offset < 0 or longlink_offset % TAR_BLOCK:
            raise SystemExit("valid fixture lacks an aligned GNU LongLink header")
        for label, field_offset, replacement in (
            ("GNU LongLink mode", 100, octal(0o600, 8)),
            ("GNU LongLink mtime", 136, octal(EPOCH, 12)),
        ):
            changed_tar = mutate_tar_header(
                GOOD_DATA_TAR, longlink_offset, field_offset, replacement
            )
            require_rejected(
                make_ar(ar_entries(data_xz=compress(changed_tar))), label
            )
        control_size = len(control_bytes())
        padding_offset = TAR_BLOCK * 2 + control_size
        bad_padding = mutate(GOOD_CONTROL_TAR, padding_offset, b"X")
        require_rejected(
            make_ar(ar_entries(control_xz=compress(bad_padding))),
            "non-zero tar member padding",
        )
        require_rejected(
            deb_with_control(control_entries(), end_blocks=1, record_padding=False),
            "single tar end marker",
        )
        require_rejected(
            deb_with_control(control_entries(), trailing=b"non-zero"),
            "non-zero bytes after tar end",
        )
        require_rejected(
            deb_with_control(control_entries()[1:]),
            "missing tar root",
        )
        entries = control_entries()
        entries[0] = dataclasses.replace(entries[0], name=".")
        require_rejected(deb_with_control(entries), "directory without canonical slash")
        entries = control_entries()
        entries[1] = dataclasses.replace(entries[1], name="./control/")
        require_rejected(deb_with_control(entries), "regular file with trailing slash")

        entries = data_entries()
        root = f"./usr/lib/modules/{RELEASE}"
        missing_parent = [
            entry
            for entry in entries
            if not (entry.kind == b"5" and "long-" in entry.name)
        ]
        require_rejected(deb_with_data(missing_parent), "missing explicit data parent")
        require_rejected(
            deb_with_data([*entries, TarEntry("./etc/", b"5", 0o755)]),
            "unexpected data directory",
        )
        require_rejected(
            deb_with_data(
                [*entries, TarEntry(root + "/kernel/unmanifested-empty/", b"5", 0o755)]
            ),
            "unmanifested empty module directory",
        )
        require_rejected(
            deb_with_data([*entries, TarEntry(root + "/unexpected", b"0", 0o644, b"x")]),
            "unexpected data file",
        )
        require_rejected(
            deb_with_data(
                [entry for entry in entries if not entry.name.endswith("/modules.dep")]
            ),
            "missing module metadata",
        )
        require_rejected(
            deb_with_data([entry for entry in entries if not entry.name.endswith(".ko")]),
            "missing kernel module",
        )
        empty_module = [
            dataclasses.replace(entry, payload=b"") if entry.name.endswith(".ko") else entry
            for entry in entries
        ]
        require_rejected(deb_with_data(empty_module), "empty kernel module")
        require_rejected(
            deb_with_data([*entries, TarEntry(root + "/link", b"2", 0o777)]),
            "data symlink",
        )

        long_component = "y" * 256
        require_rejected(
            deb_with_data([*entries, TarEntry(root + f"/kernel/{long_component}/", b"5", 0o755)]),
            "overlong path component",
        )
        overdeep = "./" + "/".join(["d"] * 129)
        require_rejected(
            deb_with_control([control_entries()[0], TarEntry(overdeep, b"0", 0o644, b"x")]),
            "overdeep GNU LongLink tar path",
        )
        overlong = "./" + "/".join(["z" * 200] * 22)
        require_rejected(
            deb_with_control([control_entries()[0], TarEntry(overlong, b"0", 0o644, b"x")]),
            "overlong tar path",
        )

        candidate.write_bytes(good)
        result = run(candidate)
        if result.returncode or result.stdout.strip() != "KERNEL_MODULES_DEB=PASS":
            raise SystemExit(f"valid fixture failed after hostile cases: {result.stderr}")
        print(f"KERNEL_MODULES_DEB_VERIFIER=PASS rejected={rejected}")


if __name__ == "__main__":
    main()
