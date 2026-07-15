#!/usr/bin/env python3
"""Hostile fixtures for the canonical TB321FU kernel bundle parser."""

from __future__ import annotations

import hashlib
import pathlib
import subprocess
import sys
import tempfile


SCRIPT = pathlib.Path(__file__).with_name("verify-kernel-bundle.py")


def make_bundle(**overrides: str) -> bytes:
    fields = [
        ("schema", "tb321fu.kernel-bundle/v1"),
        ("kernel-source-commit", "1" * 40),
        ("kernel-release", "7.1.1-g111111111111"),
        ("kernel-config-sha256", "2" * 64),
        ("source-date-epoch", "1784073600"),
        ("kbuild-build-timestamp", "2026-07-15 00:00:00 UTC"),
        ("kbuild-build-user", "tb321fu-ci"),
        ("kbuild-build-host", "tb321fu-builder"),
        ("kbuild-build-version", "1"),
    ]
    fields = [(key, overrides.get(key, value)) for key, value in fields]
    identity = "".join(f"{key}\t{value}\n" for key, value in fields).encode("ascii")
    bundle_id = overrides.get("kernel-bundle-id", hashlib.sha256(identity).hexdigest())
    return identity + f"kernel-bundle-id\t{bundle_id}\n".encode("ascii")


def run(bundle: pathlib.Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(bundle), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def require_failure(
    bundle: pathlib.Path, data: bytes, expected: bytes, *arguments: str
) -> None:
    bundle.write_bytes(data)
    result = run(bundle, *arguments)
    if result.returncode == 0 or expected not in result.stderr:
        raise SystemExit(
            f"fixture did not fail at {expected!r}: "
            f"status={result.returncode} stderr={result.stderr!r}"
        )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="tb321fu-kernel-bundle-metadata.") as temp:
        root = pathlib.Path(temp)
        bundle = root / "KERNEL-BUNDLE.tsv"
        identical = root / "identical.tsv"
        valid = make_bundle()
        bundle.write_bytes(valid)
        identical.write_bytes(valid)

        result = run(
            bundle,
            "--identical",
            str(identical),
            "--expect",
            "kernel-release=7.1.1-g111111111111",
            "--emit-tsv",
        )
        if result.returncode or result.stdout != valid:
            raise SystemExit(
                f"valid fixture failed: status={result.returncode} "
                f"stderr={result.stderr!r}"
            )

        require_failure(bundle, valid[:-1], b"must end with LF")
        require_failure(bundle, valid.replace(b"\n", b"\r\n"), b"contains CR")
        require_failure(
            bundle,
            valid.replace(b"schema\t", b"kernel-release\t", 1),
            b"field 1 must be schema",
        )
        require_failure(
            bundle,
            valid.replace(b"schema\t", b"schema\textra\t", 1),
            b"exactly one tab",
        )
        require_failure(
            bundle,
            make_bundle(**{"kbuild-build-timestamp": "$(touch owned)"}),
            b"invalid kbuild-build-timestamp",
        )
        require_failure(
            bundle,
            make_bundle(**{"kernel-bundle-id": "0" * 64}),
            b"kernel-bundle-id mismatch",
        )

        bundle.write_bytes(valid)
        identical.write_bytes(make_bundle(**{"source-date-epoch": "1784073601"}))
        result = run(bundle, "--identical", str(identical))
        if result.returncode == 0 or b"not byte-identical" not in result.stderr:
            raise SystemExit("non-identical valid bundle was accepted")

        result = run(bundle, "--expect", "kernel-release=7.1.1-wrong")
        if result.returncode == 0 or b"expectation mismatch" not in result.stderr:
            raise SystemExit("mismatched expectation was accepted")

    print("KERNEL_BUNDLE_METADATA=PASS")


if __name__ == "__main__":
    main()
