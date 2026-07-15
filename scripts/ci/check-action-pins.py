#!/usr/bin/env python3
"""Require third-party GitHub Actions to use immutable commit SHAs."""

from __future__ import annotations

import pathlib
import re
import sys

USES = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)")
FULL_SHA = re.compile(r"^[^/@\s]+/[^/@\s]+@[0-9a-fA-F]{40}$")


def invalid_uses(lines: list[str]) -> list[tuple[int, str]]:
    invalid: list[tuple[int, str]] = []
    for number, line in enumerate(lines, 1):
        match = USES.match(line)
        if not match:
            continue
        value = match.group(1)
        if value.startswith("./") or value.startswith("docker://"):
            continue
        if not FULL_SHA.fullmatch(value):
            invalid.append((number, value))
    return invalid


def self_test() -> None:
    safe = [
        "- uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4",
        "- uses: ./local-action",
        "- uses: docker://alpine:3.22",
    ]
    unsafe = ["- uses: actions/checkout@v4", "uses: owner/repo@main"]
    if invalid_uses(safe):
        raise SystemExit("action pin self-test rejected an immutable or local action")
    if invalid_uses(unsafe) != [(1, "actions/checkout@v4"), (2, "owner/repo@main")]:
        raise SystemExit("action pin self-test did not reject mutable refs")
    print("action pin self-test: PASS")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-action-pins.py WORKFLOW|--self-test")
    workflow = pathlib.Path(sys.argv[1])
    invalid = invalid_uses(workflow.read_text(encoding="utf-8").splitlines())
    if invalid:
        details = ", ".join(f"line {line}: {value}" for line, value in invalid)
        raise SystemExit(f"mutable third-party action reference: {details}")
    print("action pin check: PASS")


if __name__ == "__main__":
    main()
