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


def run_verified_rootfs_fixtures(rootfs_run: str) -> None:
    with tempfile.TemporaryDirectory(prefix="tb321fu-verified-rootfs.") as temp:
        root = pathlib.Path(temp)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        fake_sudo = fake_bin / "sudo"
        fake_sudo.write_text(
            "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$SUDO_LOG\"\n",
            encoding="utf-8",
        )
        fake_sudo.chmod(0o755)

        base_env = {
            "PATH": f"{fake_bin}:/usr/bin:/bin",
            "USER": "fixture",
            "OUTPUT_DIR_ROOTFS": str(root / "rootfs-output"),
            "VERIFIED_KERNEL_BUNDLE_DIR": "/verified",
            "SENSOR_DEB_ARCHIVE": "/verified/sensor.tar.gz",
            "SENSOR_DEB_DIR": "/unverified/sensor-dir",
            "Y700_SENSOR_DEB_DIR": "/rebuilt/sensor-dir",
            "TB321FU_HAPTICS_DEB_DIR": "/rebuilt/haptics-dir",
        }

        def execute(label: str, haptics_archive: str, haptics_dir: str):
            sudo_log = root / f"sudo-{label}.log"
            env = {
                **base_env,
                "SUDO_LOG": str(sudo_log),
                "HAPTICS_DEB_ARCHIVE": haptics_archive,
                "HAPTICS_DEB_DIR": haptics_dir,
            }
            result = subprocess.run(
                ["bash", "-c", rootfs_run],
                cwd=root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            return result, sudo_log

        archive_result, archive_log = execute(
            "archive", "/verified/haptics.tar.gz", "/unverified/haptics-dir"
        )
        if archive_result.returncode:
            fail(f"verified archive handoff failed: {archive_result.stderr}")
        archive_args = archive_log.read_text(encoding="utf-8").splitlines()[0].split()
        if "SENSOR_DEB_DIR=" not in archive_args or "HAPTICS_DEB_DIR=" not in archive_args:
            fail("verified archive handoff retained a source-built package directory")
        if any("/unverified/" in arg or "/rebuilt/" in arg for arg in archive_args):
            fail("verified archive handoff exposed an unverified package directory")

        directory_result, directory_log = execute("directory", "", "/verified/haptics-dir")
        if directory_result.returncode:
            fail(f"verified haptics directory handoff regressed: {directory_result.stderr}")
        directory_args = directory_log.read_text(encoding="utf-8").splitlines()[0].split()
        if "SENSOR_DEB_DIR=" not in directory_args:
            fail("verified directory handoff retained a source-built sensor directory")
        if "HAPTICS_DEB_DIR=/verified/haptics-dir" not in directory_args:
            fail("verified haptics directory was not passed to the rootfs builder")

        missing_result, missing_log = execute("missing", "", "")
        if missing_result.returncode == 0:
            fail("verified handoff accepted a missing haptics input")
        if missing_log.exists() and missing_log.stat().st_size:
            fail("missing verified haptics input reached sudo/rootfs execution")


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
    step_scripts: dict[str, str] = {}
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
            name = step.get("name")
            if isinstance(name, str):
                step_scripts[name] = run
            if "${{ inputs." in run:
                fail(f"step {index} embeds a dispatch input directly in shell")
            if "build-rootfs-image.sh" in run or "build-arch-rootfs-image.sh" in run:
                rootfs_step = step

    if not checkout_seen:
        fail("pinned checkout step is missing")
    if rootfs_step is None:
        fail("rootfs build step is missing")

    for name in ("Build source sensor debs", "Build source haptics deb"):
        if name in step_scripts:
            fail(f"unverified inline package producer remains reachable: {name}")
    for builder in (
        "bash scripts/ci/build-y700-sensor-debs.sh",
        "bash scripts/ci/build-tb321fu-haptics-deb.sh",
    ):
        if any(builder in script for script in step_scripts.values()):
            fail(f"unverified inline package producer remains reachable: {builder}")

    rootfs_run = rootfs_step.get("run")
    if not isinstance(rootfs_run, str):
        fail("rootfs build step has no shell body")
    verified_guard = 'if [ -n "${VERIFIED_KERNEL_BUNDLE_DIR:-}" ]; then'
    rootfs_call = "bash scripts/ci/build-rootfs-image.sh"
    required_handoff = (
        verified_guard,
        "sensor_deb_dir=",
        "haptics_deb_dir=",
        'SENSOR_DEB_DIR="$sensor_deb_dir"',
        'HAPTICS_DEB_DIR="$haptics_deb_dir"',
    )
    for token in required_handoff:
        if token not in rootfs_run:
            fail(f"rootfs build step is missing verified package isolation: {token}")
    if rootfs_run.index(verified_guard) > rootfs_run.index(rootfs_call):
        fail("verified package isolation runs after the rootfs builder")
    run_verified_rootfs_fixtures(rootfs_run)

    release_run = step_scripts.get("Upload release assets")
    if release_run is None:
        fail("release asset staging step is missing")
    package_inventory = (
        'install -m 0644 "$OUTPUT_DIR_ROOTFS/'
        '${OUTPUT_PREFIX}-rootfs.packages.tsv"'
    )
    release_checksums = '(cd "$release_dir" && sha256sum * > SHA256SUMS.txt)'
    for token in (package_inventory, '"$release_dir/ROOTFS-PACKAGES.tsv"'):
        if token not in release_run:
            fail(f"release staging is missing the rootfs package inventory: {token}")
    if release_run.index(package_inventory) > release_run.index(release_checksums):
        fail("rootfs package inventory is staged after release checksums")

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
        'set only one of SENSOR_DEB_ARCHIVE and SENSOR_DEB_DIR',
        'set only one of HAPTICS_DEB_ARCHIVE and HAPTICS_DEB_DIR',
        'dpkg-query -W',
        '${db:Status-Abbrev}',
        '$1 == "ii "',
        '"$(basename "$package_inventory")"',
        'ci_e2fsck_repair "$rootfs_img" 0',
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

        proxy_config = root / "credentialed-proxy.env"
        proxy_output = root / "credentialed-proxy-github.env"
        proxy_config.write_text(
            "APT_HTTP_PROXY=http://user:password@proxy.invalid:8080\n",
            encoding="utf-8",
        )
        result = subprocess.run(
            ["bash", str(apply_config), str(proxy_config)],
            env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(proxy_output)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode == 0:
            fail("workflow config accepted credentials in a public proxy URL")
        if proxy_output.exists() and proxy_output.stat().st_size:
            fail("rejected proxy credentials were partially serialized")

        for key in (
            "BUILD_Y700_SENSOR_DEBS",
            "SENSOR_SOURCE_DIR",
            "SENSOR_DEB_DIR",
            "BUILD_TB321FU_HAPTICS_DEB",
            "HAPTICS_SOURCE_DIR",
            "KERNEL_SOURCE_DIR",
        ):
            deprecated_config = root / f"deprecated-{key}.env"
            deprecated_output = root / f"deprecated-{key}-github.env"
            deprecated_config.write_text(f"{key}=unused\n", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(apply_config), str(deprecated_config)],
                env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(deprecated_output)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode == 0:
                fail(f"workflow config accepted dead inline-producer key: {key}")
            if deprecated_output.exists() and deprecated_output.stat().st_size:
                fail(f"rejected inline-producer key was partially serialized: {key}")


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
