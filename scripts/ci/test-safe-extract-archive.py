#!/usr/bin/env python3
"""Regression tests for extraction containment and resource budgets."""

from __future__ import annotations

import io
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import zipfile


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


def main() -> None:
    helper = pathlib.Path(__file__).with_name("safe-extract-archive.py")
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

        many = root / "many.zip"
        with zipfile.ZipFile(many, "w") as archive:
            for index in range(3):
                archive.writestr(f"{index}.txt", "x")
        require_rejected(
            run(helper, many, root / "many-out", SAFE_EXTRACT_MAX_MEMBERS="2"),
            "member limit",
        )

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
