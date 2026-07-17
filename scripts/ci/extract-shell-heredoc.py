#!/usr/bin/env python3
"""Extract one uniquely named literal shell heredoc from a reviewed source file."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: extract-shell-heredoc.py SOURCE MARKER OUTPUT", file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    marker = sys.argv[2]
    output = Path(sys.argv[3])
    if not re.fullmatch(r"EOF_[A-Z0-9_]{1,64}", marker):
        raise ValueError(f"unsafe heredoc marker: {marker!r}")
    lines = source.read_bytes().splitlines(keepends=True)
    opener = re.compile(rb"<<'?" + re.escape(marker.encode("ascii")) + rb"'?\s*$")
    starts = [index for index, line in enumerate(lines) if opener.search(line.rstrip(b"\r\n"))]
    if len(starts) != 1:
        raise ValueError(f"heredoc marker must have one opener: {marker}: {len(starts)}")
    start = starts[0] + 1
    terminators = [
        index
        for index in range(start, len(lines))
        if lines[index].rstrip(b"\r\n") == marker.encode("ascii")
    ]
    if len(terminators) != 1:
        raise ValueError(
            f"heredoc marker must have one terminator after its opener: {marker}: {len(terminators)}"
        )
    output.write_bytes(b"".join(lines[start : terminators[0]]))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValueError) as error:
        print(f"heredoc extraction failed: {error}", file=sys.stderr)
        raise SystemExit(1)
