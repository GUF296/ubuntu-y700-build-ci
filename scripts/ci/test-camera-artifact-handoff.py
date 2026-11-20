#!/usr/bin/env python3
"""Hostile fixtures for the cross-job Camera artifact handoff."""

from __future__ import annotations

import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
VERIFIER = SCRIPT_DIR / "camera-artifact-handoff.py"
REPOSITORY = "GUF296/ubuntu-y700-build-ci"
COMMIT = "1" * 40
RUN_ID = "123456789"
RUN_ATTEMPT = "2"
VERSION = "20260831.2"
ARCH = "arm64"
DEB_NAME = f"tb321fu-camera-stack_{VERSION}_{ARCH}.deb"
REPORT_NAME = "tb321fu-camera-stack-build-report.txt"
CHECKSUM_NAME = "SHA256SUMS-tb321fu-camera-stack-debs.txt"
MANIFEST_NAME = "CAMERA-HANDOFF.tsv"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def command(mode: str, directory: pathlib.Path, *, enabled: str = "1") -> list[str]:
    return [
        sys.executable,
        str(VERIFIER),
        mode,
        str(directory),
        "--enabled",
        enabled,
        "--arch",
        ARCH,
        "--version",
        VERSION,
        "--repository",
        REPOSITORY,
        "--commit",
        COMMIT,
        "--run-id",
        RUN_ID,
        "--run-attempt",
        RUN_ATTEMPT,
    ]


def run(mode: str, directory: pathlib.Path, *, enabled: str = "1") -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return subprocess.run(
        command(mode, directory, enabled=enabled),
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def expect_success(mode: str, directory: pathlib.Path, *, enabled: str = "1") -> None:
    result = run(mode, directory, enabled=enabled)
    if result.returncode:
        raise RuntimeError(f"handoff {mode} failed: {result.stderr}")


def expect_failure(label: str, directory: pathlib.Path, *, enabled: str = "1") -> None:
    result = run("verify", directory, enabled=enabled)
    if result.returncode == 0:
        raise RuntimeError(f"hostile handoff fixture was accepted: {label}")


def write_enabled_fixture(directory: pathlib.Path) -> None:
    directory.mkdir(mode=0o755)
    deb = b"fixture camera deb\n"
    deb_sha256 = digest(deb)
    (directory / DEB_NAME).write_bytes(deb)
    (directory / CHECKSUM_NAME).write_text(
        f"{deb_sha256}  {DEB_NAME}\n", encoding="utf-8"
    )
    report_lines = [
        "TB321FU_CAMERA_STACK_DEB_BUILD=PASS",
        f"version={VERSION}",
        f"arch={ARCH}",
        "camera_input_kind=repository",
        f"deb={DEB_NAME}",
        f"camera_source_sha256={'2' * 64}",
        f"camera_producer_manifest_sha256={'3' * 64}",
        f"camera_toolchain_sha256={'4' * 64}",
        f"camera_link_build_id={'5' * 40}",
        f"camera_overlay_manifest_sha256={'6' * 64}",
        f"camera_plugin_sha256={'7' * 64}",
        f"{deb_sha256}  {DEB_NAME}",
        "",
        "== package control ==",
        "fixture report body",
    ]
    (directory / REPORT_NAME).write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    for path in directory.iterdir():
        path.chmod(0o644)


def clone(source: pathlib.Path, destination: pathlib.Path) -> pathlib.Path:
    shutil.copytree(source, destination)
    return destination


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="camera-handoff-test.") as temporary:
        root = pathlib.Path(temporary)
        good = root / "good"
        write_enabled_fixture(good)
        expect_success("create", good)
        expect_success("verify", good)

        extra = clone(good, root / "extra")
        (extra / "unexpected.bin").write_bytes(b"extra\n")
        (extra / "unexpected.bin").chmod(0o644)
        expect_failure("extra member", extra)

        changed = clone(good, root / "changed")
        with (changed / REPORT_NAME).open("ab") as stream:
            stream.write(b"changed\n")
        expect_failure("report content mutation", changed)

        wrong_context = run("verify", good, enabled="0")
        if wrong_context.returncode == 0:
            raise RuntimeError("handoff accepted a different enabled context")

        symlinked = clone(good, root / "symlinked")
        outside_report = root / "outside-report"
        outside_report.write_bytes((symlinked / REPORT_NAME).read_bytes())
        outside_report.chmod(0o644)
        (symlinked / REPORT_NAME).unlink()
        (symlinked / REPORT_NAME).symlink_to(outside_report)
        expect_failure("symlinked member", symlinked)

        hardlinked = clone(good, root / "hardlinked")
        outside_checksum = root / "outside-checksum"
        outside_checksum.write_bytes((hardlinked / CHECKSUM_NAME).read_bytes())
        outside_checksum.chmod(0o644)
        (hardlinked / CHECKSUM_NAME).unlink()
        os.link(outside_checksum, hardlinked / CHECKSUM_NAME)
        expect_failure("hardlinked member", hardlinked)

        manifest_mutation = clone(good, root / "manifest-mutation")
        manifest = manifest_mutation / MANIFEST_NAME
        text = manifest.read_text(encoding="utf-8")
        manifest.write_text(text.replace(COMMIT, "8" * 40, 1), encoding="utf-8")
        manifest.chmod(0o644)
        expect_failure("manifest context mutation", manifest_mutation)

        disabled = root / "disabled"
        disabled.mkdir(mode=0o755)
        expect_success("create", disabled, enabled="0")
        expect_success("verify", disabled, enabled="0")
        (disabled / "unexpected.deb").write_bytes(b"unexpected\n")
        (disabled / "unexpected.deb").chmod(0o644)
        expect_failure("disabled handoff with payload", disabled, enabled="0")

    print("CAMERA_HANDOFF_HOSTILE_FIXTURES=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
