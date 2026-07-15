#!/usr/bin/env python3
"""Reject required systemd enable operations whose failures are ignored."""

from __future__ import annotations

import pathlib
import re
import sys

SWALLOWED_ENABLE = re.compile(r"\bsystemctl\b.*\benable\b.*\|\|\s*true(?:\s|$)")


def violations(text: str) -> list[int]:
    return [
        number
        for number, line in enumerate(text.splitlines(), 1)
        if SWALLOWED_ENABLE.search(line)
    ]


def self_test() -> None:
    safe = "systemctl enable required.service\nsystemctl is-enabled --quiet required.service"
    unsafe = "systemctl enable required.service >/dev/null 2>&1 || true"
    if violations(safe):
        raise SystemExit("service policy self-test rejected fail-closed enablement")
    if violations(unsafe) != [1]:
        raise SystemExit("service policy self-test missed swallowed enable failure")
    print("service enable policy self-test: PASS")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) < 2:
        raise SystemExit("usage: check-service-enable-policy.py FILE...|--self-test")
    failed = []
    for name in sys.argv[1:]:
        path = pathlib.Path(name)
        for line in violations(path.read_text(encoding="utf-8")):
            failed.append(f"{path}:{line}")
    if failed:
        raise SystemExit("required service enable failure is ignored: " + ", ".join(failed))
    print("service enable policy: PASS")


if __name__ == "__main__":
    main()
