#!/usr/bin/env python3
"""Semantic and hostile-fixture checks for the TB321FU release workflow."""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

import yaml


class WorkflowLoader(yaml.SafeLoader):
    pass


# GitHub treats "on" as a string; YAML 1.1 loaders otherwise coerce it to True.
for first, resolvers in list(WorkflowLoader.yaml_implicit_resolvers.items()):
    WorkflowLoader.yaml_implicit_resolvers[first] = [
        item for item in resolvers if item[0] != "tag:yaml.org,2002:bool"
    ]


PINNED_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")
SECRET_EXPR = re.compile(r"^\$\{\{\s*secrets\.([A-Z0-9_]+)\s*}}$")
FORBIDDEN_INPUT = re.compile(
    r"(?:^|_)(?:secret|token|authorized_keys|password|password_hash)$"
)


def fail(message: str) -> None:
    raise SystemExit(f"workflow semantic check failed: {message}")


def scalar_nodes(value: object, path: tuple[object, ...] = ()):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from scalar_nodes(child, path + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from scalar_nodes(child, path + (index,))
    elif isinstance(value, str):
        yield path, value


def load_workflow(path: pathlib.Path) -> dict:
    try:
        data = yaml.load(path.read_text(encoding="utf-8"), Loader=WorkflowLoader)
    except yaml.YAMLError as exc:
        fail(f"{path}: invalid YAML: {exc}")
    if not isinstance(data, dict):
        fail(f"{path}: top level must be a mapping")
    return data


def require_mapping(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label} must be a mapping")
    return value


def validate_structure(workflow: pathlib.Path, data: dict) -> None:
    dispatch = require_mapping(
        require_mapping(data.get("on"), "on").get("workflow_dispatch"),
        "on.workflow_dispatch",
    )
    inputs = require_mapping(dispatch.get("inputs"), "workflow_dispatch.inputs")
    for name in inputs:
        if not isinstance(name, str):
            fail("dispatch input names must be strings")
        if FORBIDDEN_INPUT.search(name):
            fail(f"credential material must not be a dispatch input: {name}")

    jobs = require_mapping(data.get("jobs"), "jobs")
    build = require_mapping(jobs.get("build"), "jobs.build")
    permissions = require_mapping(build.get("permissions"), "jobs.build.permissions")
    if permissions.get("contents") != "read":
        fail("build job must have contents: read")

    steps = build.get("steps")
    if not isinstance(steps, list) or not steps:
        fail("jobs.build.steps must be a non-empty list")

    checkout_seen = False
    rootfs_step = None
    for index, raw_step in enumerate(steps):
        step = require_mapping(raw_step, f"jobs.build.steps[{index}]")
        uses = step.get("uses")
        if uses is not None:
            if not isinstance(uses, str) or not PINNED_ACTION.fullmatch(uses):
                fail(f"step {index} action is not pinned to a 40-hex commit: {uses!r}")
            if uses.startswith("actions/checkout@"):
                checkout_seen = True
                options = require_mapping(step.get("with"), f"checkout step {index}.with")
                if str(options.get("persist-credentials", "")).lower() != "false":
                    fail("actions/checkout must set persist-credentials: false")
        run = step.get("run")
        if isinstance(run, str):
            if "${{ inputs." in run:
                fail(f"step {index} embeds a dispatch input directly in shell")
            if "build-rootfs-image.sh" in run or "build-arch-rootfs-image.sh" in run:
                rootfs_step = step

    if not checkout_seen:
        fail("pinned checkout step is missing")
    if rootfs_step is None:
        fail("rootfs build step is missing")

    secret_paths: list[tuple[tuple[object, ...], str]] = []
    for path, value in scalar_nodes(data):
        if "${{ secrets." not in value:
            continue
        match = SECRET_EXPR.fullmatch(value)
        if not match:
            fail(f"secret expression must occupy one complete env scalar at {path}")
        if len(path) < 2 or path[-2] != "env" or "steps" not in path:
            fail(f"secret expression is not step-scoped env at {path}")
        secret_paths.append((path, match.group(1)))

    rootfs_env = require_mapping(rootfs_step.get("env"), "rootfs build step env")
    required = {"DEFAULT_USER_PASSWORD_HASH", "ROOT_PASSWORD_HASH"}
    if not required.issubset(rootfs_env):
        fail(f"rootfs step is missing secret env keys: {sorted(required - rootfs_env.keys())}")
    for key in required:
        if rootfs_env[key] != f"${{{{ secrets.{key} }}}}":
            fail(f"{key} is not sourced directly from its repository secret")

    # GitHub renders an absent secret as an empty string. It must remain data,
    # never become shell syntax or a serialized workflow input.
    rendered = {}
    for key, value in rootfs_env.items():
        match = SECRET_EXPR.fullmatch(str(value))
        rendered[key] = "" if match else str(value)
    if any(rendered[key] for key in required):
        fail("absent-secret rendering did not produce empty values")

    if not secret_paths:
        fail("no step-scoped secret expressions were found")


def validate_rootfs_contract(rootfs: pathlib.Path) -> None:
    text = rootfs.read_text(encoding="utf-8")
    required = (
        "DEFAULT_USER_PASSWORD_HASH=${DEFAULT_USER_PASSWORD_HASH:-!}",
        "ROOT_PASSWORD_MODE=${ROOT_PASSWORD_MODE:-locked}",
        "ROOT_PASSWORD_HASH=${ROOT_PASSWORD_HASH:-}",
    )
    for token in required:
        if token not in text:
            fail(f"{rootfs}: missing locked absent-secret default: {token}")
def run_hostile_config_fixtures(apply_config: pathlib.Path) -> None:
    with tempfile.TemporaryDirectory(prefix="tb321fu-workflow-fixture.") as temp:
        root = pathlib.Path(temp)
        marker = root / "executed"
        config = root / "hostile.env"
        github_env = root / "github.env"
        literal = f"$(touch {marker})"
        config.write_text(f"OUTPUT_PREFIX={literal}\n", encoding="utf-8")
        result = subprocess.run(
            ["bash", str(apply_config), str(config)],
            env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(github_env)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode:
            fail(f"env-mediated hostile value was not handled as data: {result.stderr}")
        if marker.exists():
            fail("hostile dispatch/config value executed command substitution")
        if literal not in github_env.read_text(encoding="utf-8"):
            fail("hostile value was not preserved literally in GITHUB_ENV")

        secret_config = root / "secret.env"
        secret_output = root / "secret-github.env"
        secret_config.write_text(
            "DEFAULT_USER_PASSWORD_HASH=$6$forbidden$hash\n", encoding="utf-8"
        )
        result = subprocess.run(
            ["bash", str(apply_config), str(secret_config)],
            env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(secret_output)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode == 0:
            fail("workflow config accepted password hash material")
        if secret_output.exists() and secret_output.stat().st_size:
            fail("rejected password hash was partially serialized")


def self_test() -> None:
    if not FORBIDDEN_INPUT.search("default_user_password_hash"):
        fail("self-test did not reject credential dispatch input")
    if FORBIDDEN_INPUT.search("root_password_mode"):
        fail("self-test rejected a non-secret password mode")
    if PINNED_ACTION.fullmatch("actions/checkout@v4"):
        fail("self-test accepted a mutable action ref")
    if not PINNED_ACTION.fullmatch(
        "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5"
    ):
        fail("self-test rejected a commit-pinned action")
    print("workflow semantic self-test: PASS")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 4:
        fail(
            "usage: test-workflow-semantics.py "
            "WORKFLOW ROOTFS_SCRIPT APPLY_WORKFLOW_CONFIG|--self-test"
        )

    workflow, rootfs, apply_config = map(pathlib.Path, sys.argv[1:])
    validate_structure(workflow, load_workflow(workflow))
    validate_rootfs_contract(rootfs)
    run_hostile_config_fixtures(apply_config)
    print("WORKFLOW_SEMANTICS=PASS")


if __name__ == "__main__":
    main()
