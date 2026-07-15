#!/usr/bin/env python3
"""Reject GitHub input expressions embedded directly in workflow shell blocks."""

from __future__ import annotations

import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"workflow input boundary check failed: {message}")


def direct_input_lines(lines: list[str]) -> list[int]:
    direct_inputs: list[int] = []

    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^(\s*)run:\s*[|>]", line)
        if not match:
            index += 1
            continue

        block_indent = len(match.group(1))
        index += 1
        while index < len(lines):
            body = lines[index]
            if body.strip() and len(body) - len(body.lstrip()) <= block_indent:
                break
            if "${{ inputs." in body:
                direct_inputs.append(index + 1)
            index += 1
    return direct_inputs


def self_test() -> None:
    safe = [
        "jobs:",
        "  build:",
        "    env:",
        "      INPUT_VALUE: ${{ inputs.value }}",
        "    run: |",
        '      printf "%s\\n" "$INPUT_VALUE"',
    ]
    unsafe = ["jobs:", "  build:", "    run: |", "      echo '${{ inputs.value }}'"]
    if direct_input_lines(safe):
        fail("self-test rejected an env-mediated input")
    if direct_input_lines(unsafe) != [4]:
        fail("self-test did not detect a direct input expression")
    print("workflow input boundary self-test: PASS")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 2:
        fail("usage: check-workflow-input-boundaries.py WORKFLOW|--self-test")

    workflow = pathlib.Path(sys.argv[1])
    lines = workflow.read_text(encoding="utf-8").splitlines()
    direct_inputs = direct_input_lines(lines)

    if direct_inputs:
        fail(f"direct input expression in run block at lines {direct_inputs}")

    text = "\n".join(lines)
    required = (
        "INPUT_OUTPUT_PREFIX: ${{ inputs.output_prefix }}",
        'ci_validate_output_prefix "$INPUT_OUTPUT_PREFIX"',
        "printf 'OUTPUT_PREFIX=%s\\n' \"$INPUT_OUTPUT_PREFIX\"",
    )
    for token in required:
        if token not in text:
            fail(f"missing required boundary token: {token}")

    print("workflow input boundary check: PASS")


if __name__ == "__main__":
    main()
