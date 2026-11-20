#!/usr/bin/env python3
"""Regression tests for extraction containment and resource budgets."""

from __future__ import annotations

import importlib.util
import io
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import struct


def run(helper: pathlib.Path, archive: pathlib.Path, destination: pathlib.Path, **limits: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(limits)
    return subprocess.run(
        [sys.executable, str(helper), str(archive), str(destination)],
        check=False,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def require_rejected(result: subprocess.CompletedProcess[str], reason: str) -> None:
    if result.returncode == 0:
        raise SystemExit(f"unsafe archive was accepted: {reason}")


def require_preflight_rejected(helper: pathlib.Path, archive: pathlib.Path, reason: str) -> None:
    spec = importlib.util.spec_from_file_location("safe_extract_fixture", helper)
    if spec is None or spec.loader is None:
        raise SystemExit("unable to import safe extractor for preflight fixture")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.MAX_MEMBERS = 2
    try:
        with archive.open("rb") as source:
            module.validate_zip_directory_budget(source, archive.stat().st_size)
    except (ValueError, zipfile.BadZipFile):
        return
    raise SystemExit(f"unsafe archive passed ZIP preflight: {reason}")


def require_preflight_accepted(helper: pathlib.Path, archive: pathlib.Path, reason: str) -> None:
    spec = importlib.util.spec_from_file_location("safe_extract_fixture_accept", helper)
    if spec is None or spec.loader is None:
        raise SystemExit("unable to import safe extractor for ZIP64 fixture")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.MAX_MEMBERS = 2
    try:
        with archive.open("rb") as source:
            module.validate_zip_directory_budget(source, archive.stat().st_size)
    except (ValueError, zipfile.BadZipFile) as error:
        raise SystemExit(f"valid archive failed ZIP preflight ({reason}): {error}") from error


def main() -> None:
    helper = pathlib.Path(__file__).with_name("safe-extract-archive.py")
    helper_source = helper.read_text()
    if helper_source.index("validate_zip_directory_budget(archive_file, archive_bytes)") > helper_source.index(
        "with zipfile.ZipFile(archive_file)"
    ):
        raise SystemExit("ZIP metadata budget is checked after ZipFile construction")
    with tempfile.TemporaryDirectory(prefix="tb321fu-extract-test.") as raw:
        root = pathlib.Path(raw)

        good = root / "good.zip"
        with zipfile.ZipFile(good, "w") as archive:
            archive.writestr("payload/file.txt", "known-good\n")
        result = run(helper, good, root / "good-out")
        if result.returncode != 0:
            raise SystemExit(result.stderr)
        if (root / "good-out/payload/file.txt").read_text() != "known-good\n":
            raise SystemExit("valid ZIP payload changed")

        # Replacing the pathname immediately after O_NOFOLLOW open must not
        # change the authenticated inode consumed by format preflight or extraction.
        swap_original = root / "swap.zip"
        swap_replacement = root / "swap-replacement.zip"
        with zipfile.ZipFile(swap_original, "w") as archive:
            archive.writestr("payload/identity.txt", "opened inode\n")
        with zipfile.ZipFile(swap_replacement, "w") as archive:
            archive.writestr("payload/identity.txt", "replacement path\n")
        spec = importlib.util.spec_from_file_location("safe_extract_path_swap", helper)
        if spec is None or spec.loader is None:
            raise SystemExit("unable to import safe extractor for path-swap fixture")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_open = module.os.open
        swapped = False

        def swap_after_open(path, flags, *args):
            nonlocal swapped
            descriptor = real_open(path, flags, *args)
            if pathlib.Path(path) == swap_original:
                os.replace(swap_replacement, swap_original)
                swapped = True
            return descriptor

        old_argv = module.sys.argv
        module.os.open = swap_after_open
        module.sys.argv = [str(helper), str(swap_original), str(root / "swap-out")]
        try:
            if module.main() != 0:
                raise SystemExit("path-swap fixture did not complete")
        finally:
            module.os.open = real_open
            module.sys.argv = old_argv
        if not swapped:
            raise SystemExit("path-swap fixture did not replace the archive pathname")
        if (root / "swap-out/payload/identity.txt").read_text() != "opened inode\n":
            raise SystemExit("archive pathname replacement changed extracted bytes")

        destination_link = root / "destination-link"
        destination_link.symlink_to(root / "outside-destination", target_is_directory=True)
        require_rejected(
            run(helper, good, destination_link),
            "destination root symlink",
        )
        if (root / "outside-destination").exists():
            raise SystemExit("destination symlink was followed")

        outside = root / "outside"
        outside.mkdir()
        destination = root / "symlink-out"
        destination.mkdir()
        (destination / "escape").symlink_to(outside, target_is_directory=True)
        hostile = root / "hostile-parent.zip"
        with zipfile.ZipFile(hostile, "w") as archive:
            archive.writestr("escape/created/file.txt", "must-not-exist")
        require_rejected(run(helper, hostile, destination), "pre-existing escaping symlink")
        if (outside / "created").exists():
            raise SystemExit("extractor created an external directory before containment validation")

        hostile_link = root / "hostile-link-target.zip"
        with zipfile.ZipFile(hostile_link, "w") as archive:
            info = zipfile.ZipInfo("created-link")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, "escape/created")
        require_rejected(
            run(helper, hostile_link, destination),
            "symlink target through pre-existing escaping symlink",
        )
        if (destination / "created-link").exists() or (destination / "created-link").is_symlink():
            raise SystemExit("extractor created a link through an escaping existing symlink")

        # Validate the complete in-archive link graph before writing links.  A
        # forward edge can become escaping only after another archive member is
        # installed: B -> A/../outside followed by A -> . must be rejected.
        graph_escape = root / "graph-escape.zip"
        with zipfile.ZipFile(graph_escape, "w") as archive:
            for name, target in (("B", "A/../outside"), ("A", ".")):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (0o120777 << 16)
                archive.writestr(info, target)
        graph_destination = root / "graph-escape-out"
        require_rejected(
            run(helper, graph_escape, graph_destination),
            "forward ZIP symlink graph escape",
        )
        if (graph_destination / "A").exists() or (graph_destination / "A").is_symlink():
            raise SystemExit("graph escape fixture wrote links before graph validation")

        outside_alias = root / "outside-alias.txt"
        outside_alias.write_text("outside must remain unchanged\n")
        zip_alias_out = root / "zip-alias-out"
        (zip_alias_out / "payload").mkdir(parents=True)
        os.link(outside_alias, zip_alias_out / "payload/file.txt")
        require_rejected(
            run(helper, good, zip_alias_out),
            "pre-existing ZIP destination hardlink alias",
        )
        if outside_alias.read_text() != "outside must remain unchanged\n":
            raise SystemExit("ZIP extraction modified a pre-existing hardlink alias")

        control_name = root / "control-name.zip"
        with zipfile.ZipFile(control_name, "w") as archive:
            archive.writestr("safe\nINJECTED=value", "must-not-be-exported")
        require_rejected(
            run(helper, control_name, root / "control-name-out"),
            "archive member control character",
        )

        control_target = root / "control-target.zip"
        with zipfile.ZipFile(control_target, "w") as archive:
            info = zipfile.ZipInfo("safe-link")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, "target\r\n")
        require_rejected(
            run(helper, control_target, root / "control-target-out"),
            "archive link target control character",
        )

        many = root / "many.zip"
        with zipfile.ZipFile(many, "w") as archive:
            for index in range(3):
                archive.writestr(f"{index}.txt", "x")
        require_rejected(
            run(helper, many, root / "many-out", SAFE_EXTRACT_MAX_MEMBERS="2"),
            "member limit",
        )

        # A tiny archive whose EOCD claims an oversized entry count must be
        # rejected by the bounded preflight before ZipFile builds its member
        # table.  This keeps the test small while exercising the hostile
        # central-directory boundary.
        declared_many = root / "declared-many.zip"
        with zipfile.ZipFile(declared_many, "w") as archive:
            archive.writestr("one.txt", "x")
        encoded = bytearray(declared_many.read_bytes())
        end = encoded.rfind(b"PK\x05\x06")
        if end < 0:
            raise SystemExit("test ZIP has no EOCD")
        encoded[end + 10 : end + 12] = (3).to_bytes(2, "little")
        declared_many.write_bytes(encoded)
        require_rejected(
            run(
                helper,
                declared_many,
                root / "declared-many-out",
                SAFE_EXTRACT_MAX_MEMBERS="2",
            ),
            "preflight central-directory member count",
        )

        forged_eocd = root / "forged-eocd.zip"
        with zipfile.ZipFile(forged_eocd, "w") as archive:
            for index in range(10):
                archive.writestr(f"member-{index}.txt", "x")
        encoded = bytearray(forged_eocd.read_bytes())
        end = encoded.rfind(b"PK\x05\x06")
        directory_size = int.from_bytes(encoded[end + 12 : end + 16], "little")
        directory_offset = int.from_bytes(encoded[end + 16 : end + 20], "little")
        central = encoded[directory_offset : directory_offset + directory_size]
        forged = bytearray(encoded[end : end + 22])
        forged[8:10] = (1).to_bytes(2, "little")
        forged[10:12] = (1).to_bytes(2, "little")
        forged_eocd.write_bytes(encoded + central + forged)
        require_preflight_rejected(helper, forged_eocd, "forged final EOCD")

        ambiguous_comment = root / "ambiguous-eocd-comment.zip"
        fake_comment_eocd = bytearray(22)
        fake_comment_eocd[:4] = b"PK\x05\x06"
        with zipfile.ZipFile(ambiguous_comment, "w") as archive:
            archive.writestr("payload", "x")
            archive.comment = bytes(fake_comment_eocd)
        require_preflight_rejected(helper, ambiguous_comment, "ambiguous EOCD comment")

        malformed_zip64 = root / "malformed-zip64.zip"
        malformed = bytearray(good.read_bytes())
        malformed_end = malformed.rfind(b"PK\x05\x06")
        malformed[malformed_end + 10 : malformed_end + 12] = (0xFFFF).to_bytes(2, "little")
        malformed_zip64.write_bytes(malformed)
        require_preflight_rejected(helper, malformed_zip64, "missing ZIP64 locator")

        zip64 = root / "minimal-zip64.zip"
        zip64_source = root / "zip64-source.zip"
        with zipfile.ZipFile(zip64_source, "w") as archive:
            archive.writestr("payload", "x")
        source = zip64_source.read_bytes()
        source_end = source.rfind(b"PK\x05\x06")
        source_size = int.from_bytes(source[source_end + 12 : source_end + 16], "little")
        source_offset = int.from_bytes(source[source_end + 16 : source_end + 20], "little")
        payload = source[:source_end]
        zip64_offset = len(payload)
        zip64_record = struct.pack(
            "<4sQHHIIQQQQ", b"PK\x06\x06", 44, 45, 45, 0, 0, 1, 1, source_size, source_offset
        )
        locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, zip64_offset, 1)
        saturated_eocd = struct.pack(
            "<4sHHHHIIH", b"PK\x05\x06", 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
        )
        zip64.write_bytes(payload + zip64_record + locator + saturated_eocd)
        require_preflight_accepted(helper, zip64, "minimal ZIP64")

        require_rejected(
            run(
                helper,
                good,
                root / "archive-bytes-out",
                SAFE_EXTRACT_MAX_ARCHIVE_BYTES=str(good.stat().st_size - 1),
            ),
            "compressed archive byte limit",
        )

        many_tar = root / "many.tar"
        with tarfile.open(many_tar, "w") as archive:
            for index in range(3):
                info = tarfile.TarInfo(f"member-{index}")
                info.size = 1
                archive.addfile(info, io.BytesIO(b"x"))
        require_rejected(
            run(helper, many_tar, root / "many-tar-out", SAFE_EXTRACT_MAX_MEMBERS="2"),
            "streamed tar member limit",
        )

        bounded_longname = root / "bounded-gnu-longname.tar"
        bounded_name = "payload/" + "x" * 120
        with tarfile.open(
            bounded_longname, "w", format=tarfile.GNU_FORMAT
        ) as archive:
            info = tarfile.TarInfo(bounded_name)
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
        bounded_result = run(
            helper, bounded_longname, root / "bounded-gnu-longname-out"
        )
        if bounded_result.returncode != 0:
            raise SystemExit(
                "bounded GNU longname fixture failed: " + bounded_result.stderr
            )
        if (root / "bounded-gnu-longname-out" / bounded_name).read_bytes() != b"x":
            raise SystemExit("bounded GNU longname payload changed")
        oversized_extension_result = run(
            helper,
            bounded_longname,
            root / "oversized-gnu-extension-out",
            SAFE_EXTRACT_MAX_EXTENSION_BYTES="64",
        )
        require_rejected(
            oversized_extension_result, "oversized GNU longname extension record"
        )
        if "extension record exceeds" not in oversized_extension_result.stderr:
            raise SystemExit(
                "oversized GNU extension was not rejected before expansion: "
                + oversized_extension_result.stderr
            )

        overdeep_link = root / "overdeep-link-target.tar"
        with tarfile.open(overdeep_link, "w", format=tarfile.GNU_FORMAT) as archive:
            info = tarfile.TarInfo("/".join(["d"] * 127 + ["link"]))
            info.type = tarfile.SYMTYPE
            info.linkname = "target/child"
            archive.addfile(info)
        require_rejected(
            run(helper, overdeep_link, root / "overdeep-link-target-out"),
            "combined TAR link path depth",
        )

        compatible_pax = root / "compatible-pax.tar"
        with tarfile.open(
            compatible_pax, "w", format=tarfile.PAX_FORMAT
        ) as archive:
            info = tarfile.TarInfo("payload/pax-file")
            info.size = 1
            info.pax_headers = {"comment": "bounded metadata"}
            archive.addfile(info, io.BytesIO(b"p"))
        pax_result = run(helper, compatible_pax, root / "compatible-pax-out")
        if pax_result.returncode != 0:
            raise SystemExit("bounded compatible PAX fixture failed: " + pax_result.stderr)

        old_sparse = root / "old-gnu-sparse.tar"
        sparse = tarfile.TarInfo("payload/sparse")
        sparse.type = tarfile.GNUTYPE_SPARSE
        sparse.size = 1
        sparse._sparse_structs = ([(0, 1)], False, 1)
        with tarfile.open(old_sparse, "w", format=tarfile.GNU_FORMAT) as archive:
            archive.addfile(sparse, io.BytesIO(b"s"))
        require_rejected(
            run(helper, old_sparse, root / "old-gnu-sparse-out"),
            "GNU sparse extension",
        )

        pax_sparse = root / "pax-sparse.tar"
        with tarfile.open(pax_sparse, "w", format=tarfile.PAX_FORMAT) as archive:
            info = tarfile.TarInfo("payload/pax-sparse")
            info.size = 1
            info.pax_headers = {"GNU.sparse.map": "0,1"}
            archive.addfile(info, io.BytesIO(b"s"))
        require_rejected(
            run(helper, pax_sparse, root / "pax-sparse-out"),
            "PAX sparse metadata",
        )

        hardlinks = root / "hardlinks.tar"
        with tarfile.open(hardlinks, "w") as archive:
            data = b"canonical\n"
            regular = tarfile.TarInfo("payload/original")
            regular.size = len(data)
            archive.addfile(regular, io.BytesIO(data))
            first = tarfile.TarInfo("payload/first-link")
            first.type = tarfile.LNKTYPE
            first.linkname = "payload/original"
            archive.addfile(first)
            second = tarfile.TarInfo("payload/second-link")
            second.type = tarfile.LNKTYPE
            second.linkname = "payload/first-link"
            archive.addfile(second)
        require_rejected(
            run(helper, hardlinks, root / "hardlinks-out"),
            "contained tar hardlink chain",
        )

        tar_alias = root / "alias.tar"
        with tarfile.open(tar_alias, "w") as archive:
            data = b"archive replacement\n"
            member = tarfile.TarInfo("payload/file.txt")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        tar_alias_out = root / "tar-alias-out"
        (tar_alias_out / "payload").mkdir(parents=True)
        os.link(outside_alias, tar_alias_out / "payload/file.txt")
        require_rejected(
            run(helper, tar_alias, tar_alias_out),
            "pre-existing tar destination hardlink alias",
        )
        if outside_alias.read_text() != "outside must remain unchanged\n":
            raise SystemExit("tar extraction modified a pre-existing hardlink alias")

        large_tar = root / "large.tar"
        with tarfile.open(large_tar, "w") as archive:
            data = b"x" * 32
            info = tarfile.TarInfo("large.bin")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        require_rejected(
            run(
                helper,
                large_tar,
                root / "large-out",
                SAFE_EXTRACT_MAX_FILE_BYTES="16",
                SAFE_EXTRACT_MAX_TOTAL_BYTES="16",
            ),
            "tar file/total size limit",
        )

        ratio = root / "ratio.zip"
        with zipfile.ZipFile(ratio, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("zeros.bin", bytes(1024 * 1024))
        require_rejected(
            run(helper, ratio, root / "ratio-out", SAFE_EXTRACT_MAX_COMPRESSION_RATIO="2"),
            "compression ratio limit",
        )

    print("safe archive extraction regressions: PASS")


if __name__ == "__main__":
    main()
