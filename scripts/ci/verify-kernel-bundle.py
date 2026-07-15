#!/usr/bin/env python3
"""Validate canonical TB321FU kernel bundle metadata."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys


FIELD_VALIDATORS = (
    ("schema", re.compile(r"tb321fu\.kernel-bundle/v1")),
    ("kernel-source-commit", re.compile(r"[0-9a-f]{40}")),
    ("kernel-release", re.compile(r"[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}")),
    ("kernel-config-sha256", re.compile(r"[0-9a-f]{64}")),
    ("source-date-epoch", re.compile(r"[0-9]{1,12}")),
    (
        "kbuild-build-timestamp",
        re.compile(r"[0-9A-Za-z][0-9A-Za-z,:+._ -]{0,95}"),
    ),
    ("kbuild-build-user", re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")),
    ("kbuild-build-host", re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")),
    ("kbuild-build-version", re.compile(r"[1-9][0-9]{0,8}")),
    ("kernel-bundle-id", re.compile(r"[0-9a-f]{64}")),
)


class BundleError(ValueError):
    """Raised when bundle metadata violates the canonical contract."""


def parse_bundle(path: pathlib.Path) -> tuple[dict[str, str], bytes]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise BundleError(f"cannot read {path}: {exc}") from exc

    if not raw.endswith(b"\n"):
        raise BundleError(f"bundle must end with LF: {path}")
    if b"\r" in raw:
        raise BundleError(f"bundle contains CR: {path}")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise BundleError(f"bundle must contain ASCII only: {path}") from exc

    lines = text.splitlines()
    if len(lines) != len(FIELD_VALIDATORS):
        raise BundleError(
            f"bundle has {len(lines)} fields, expected {len(FIELD_VALIDATORS)}: {path}"
        )

    values: dict[str, str] = {}
    for index, ((expected_key, validator), line) in enumerate(
        zip(FIELD_VALIDATORS, lines, strict=True), start=1
    ):
        if line.count("\t") != 1:
            raise BundleError(f"field {index} must contain exactly one tab: {path}")
        key, value = line.split("\t", 1)
        if key != expected_key:
            raise BundleError(
                f"field {index} must be {expected_key}, found {key or '<empty>'}: {path}"
            )
        if validator.fullmatch(value) is None:
            raise BundleError(f"invalid {key}: {path}")
        values[key] = value

    identity = "".join(f"{line}\n" for line in lines[:-1]).encode("ascii")
    actual_id = hashlib.sha256(identity).hexdigest()
    if values["kernel-bundle-id"] != actual_id:
        raise BundleError(
            "kernel-bundle-id mismatch: "
            f"expected {actual_id}, found {values['kernel-bundle-id']}: {path}"
        )
    return values, raw


def parse_expectation(argument: str) -> tuple[str, str]:
    if "=" not in argument:
        raise BundleError(f"expectation must be KEY=VALUE: {argument}")
    key, value = argument.split("=", 1)
    known = {name for name, _ in FIELD_VALIDATORS}
    if key not in known or not value:
        raise BundleError(f"invalid expectation: {argument}")
    return key, value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate canonical TB321FU KERNEL-BUNDLE.tsv metadata."
    )
    parser.add_argument("bundle", type=pathlib.Path)
    parser.add_argument(
        "--identical",
        action="append",
        default=[],
        type=pathlib.Path,
        help="also validate this bundle and require byte identity",
    )
    parser.add_argument(
        "--expect",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="require one exact canonical field value",
    )
    parser.add_argument(
        "--emit-tsv",
        action="store_true",
        help="write the validated canonical TSV bytes to stdout",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        values, raw = parse_bundle(args.bundle)
        for other_path in args.identical:
            _, other_raw = parse_bundle(other_path)
            if other_raw != raw:
                raise BundleError(
                    f"bundle metadata is not byte-identical: {args.bundle} != {other_path}"
                )
        seen: set[str] = set()
        for argument in args.expect:
            key, expected = parse_expectation(argument)
            if key in seen:
                raise BundleError(f"duplicate expectation for {key}")
            seen.add(key)
            if values[key] != expected:
                raise BundleError(
                    f"expectation mismatch for {key}: "
                    f"expected {expected}, found {values[key]}"
                )
    except BundleError as exc:
        print(f"kernel bundle metadata verification failed: {exc}", file=sys.stderr)
        return 1

    if args.emit_tsv:
        sys.stdout.buffer.write(raw)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
