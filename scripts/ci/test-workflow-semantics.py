#!/usr/bin/env python3
"""Semantic and hostile-fixture checks for the TB321FU release workflow."""

from __future__ import annotations

import pathlib
import importlib.util
import re
import subprocess
import sys
import tempfile

import yaml

_camera_policy_spec = importlib.util.spec_from_file_location(
    "workflow_camera_version_policy", pathlib.Path(__file__).with_name("camera-package-policy.py"))
_camera_policy = importlib.util.module_from_spec(_camera_policy_spec)
_camera_policy_spec.loader.exec_module(_camera_policy)
APPROVED_CAMERA_VERSION = _camera_policy.approved_version()
CAMERA_VERSION_DEFAULT_COMMAND = 'python3 -I -B scripts/ci/camera-package-policy.py rootfs-default >> "$RUNNER_TEMP/rootfs.env"'


class WorkflowLoader(yaml.SafeLoader):
    pass


def has_validation_tools(script: str) -> bool:
    required = set("python3-yaml g++ git openssl shellcheck openssh-client gnupg rsync e2fsprogs dosfstools mtools".split())
    # Only the literal package arguments in the early apt install count.
    return any(words[:4] == ["sudo", "apt-get", "install", "-y"]
               and all(re.fullmatch(r"[a-z0-9][a-z0-9+.:-]*", pkg) for pkg in words[4:])
               and required <= set(words[4:])
               for line in script.replace("\\\n", " ").splitlines()
               if (words := line.partition("#")[0].split()))


# GitHub treats "on" as a string; YAML 1.1 loaders otherwise coerce it to True.
for first, resolvers in list(WorkflowLoader.yaml_implicit_resolvers.items()):
    WorkflowLoader.yaml_implicit_resolvers[first] = [
        item for item in resolvers if item[0] != "tag:yaml.org,2002:bool"
    ]


PINNED_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")
CHECKOUT_ACTION = "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5"
UPLOAD_ACTION = "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
DOWNLOAD_ACTION = "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"
EXACT_WORKFLOW_SHA = "$" + "{{ github.sha }}"
CAMERA_ARTIFACT_NAME = (
    "camera-stack-" + "$" + "{{ github.run_id }}-" + "$" + "{{ github.run_attempt }}"
)
CAMERA_ARTIFACT_DIGEST = (
    "$" + "{{ needs.camera-producer.outputs.artifact_digest }}"
)
CAMERA_ARTIFACT_ID = "$" + "{{ needs.camera-producer.outputs.artifact_id }}"
SECRET_EXPR = re.compile(r"^\$\{\{\s*secrets\.([A-Z0-9_]+)\s*}}$")
FORBIDDEN_INPUT = re.compile(
    r"(?:^|_)(?:secret|token|authorized_keys|password|password_hash)$"
)
MAX_WORKFLOW_DISPATCH_INPUTS = 10
APPROVED_KERNEL_SOURCE_PROFILE = {
    "KERNEL_ARTIFACT_ARCHIVE": (
        "https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/"
        "tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/"
        "tb321fu-kernel-artifacts-7.1.1-00011-g11bbf0262857.tar.gz"
    ),
    "KERNEL_ARTIFACT_ARCHIVE_SHA256": (
        "ab71b3335e8a535a3e7f50dfc2c97f8932c1cddd91ec79a16188be8f08c6ce3b"
    ),
    "KERNEL_BUILD_ARCHIVE": (
        "https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/"
        "tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/"
        "tb321fu-kernel-build-sdk-7.1.1-00011-g11bbf0262857.tar.gz"
    ),
    "KERNEL_BUILD_ARCHIVE_SHA256": (
        "0b84cd9bec6c41d7c55c143cd7e945820971e4267aed66728126e6b96f753e87"
    ),
    "KERNEL_BOOTSTRAP_PRODUCER_COMMIT": (
        "cbc1b36c37c140271bb688c5b1a79b10e669ba2c"
    ),
    "KERNEL_BOOTSTRAP_PRODUCER_TREE": (
        "0d84ed4c3d8cd13b70624e47800ae932cb80acac"
    ),
    "KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256": (
        "f554dc63a60a8a5c31f7acac67ca654596d7ff006cdb6845be940e03ac0c3e90"
    ),
}
APPROVED_DEVICE_PROFILE = {
    "DEB_ARCHIVE": (
        "https://github.com/GUF296/ubuntu-y700-build-ci/releases/download/"
        "tb321fu-kernel-bootstrap-11bbf0262857-20261120.1/"
        "tb321fu-device-debs-7.1.1-00011-g11bbf0262857.tar.gz"
    ),
    "DEB_ARCHIVE_SHA256": (
        "16f905295d9c5644f3621e7c864da0e4653d724a4a8fe189aaaf5d302ce54490"
    ),
    "BUILD_TB321FU_CAMERA_STACK": "1",
    "CAMERA_STACK_ARCHIVE": "",
    "CAMERA_STACK_ARCHIVE_SHA256": "",
    "CAMERA_STACK_DIR": "",
    "CAMERA_STACK_DEB_VERSION": APPROVED_CAMERA_VERSION,
}
APPROVED_CAMERA_PROFILE = {
    "ARCH": "arm64",
    "BUILD_TB321FU_CAMERA_STACK": "1",
    "CAMERA_STACK_ARCHIVE": "",
    "CAMERA_STACK_ARCHIVE_SHA256": "",
    "CAMERA_STACK_DIR": "",
    "CAMERA_STACK_DEB_VERSION": APPROVED_CAMERA_VERSION,
}


def fail(message: str) -> None:
    raise SystemExit(f"workflow semantic check failed: {message}")


def validate_camera_version_default(run: str) -> None:
    if run.splitlines().count(CAMERA_VERSION_DEFAULT_COMMAND) != 1:
        fail("camera defaults must read the committed version policy exactly once")
    if re.search(r"(?m)^\s*CAMERA_STACK_DEB_VERSION=", run):
        fail("camera default version must not be duplicated as a literal")
    root_open = 'cat > "$RUNNER_TEMP/rootfs.env" <<' + chr(39) + 'CONFIG_EOF' + chr(39)
    start = run.find(root_open)
    end = run.find(chr(10) + 'CONFIG_EOF', start)
    command = run.find(CAMERA_VERSION_DEFAULT_COMMAND)
    override = run.find('if [ -n "$INPUT_ROOTFS_CONFIG" ]')
    if start < 0 or end < 0 or not end < command or (override >= 0 and command >= override):
        fail("camera version default must follow rootfs defaults and precede user overrides")


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


def dispatch_input_count_is_supported(inputs: dict) -> bool:
    return len(inputs) <= MAX_WORKFLOW_DISPATCH_INPUTS


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


def run_tagged_haptics_policy_fixtures(handoff_run: str) -> None:
    guard_prefix, separator, _ = handoff_run.partition("verified_dir=")
    if not separator:
        fail("kernel bundle handoff has no verified directory assignment")

    base_env = {
        "PATH": "/usr/bin:/bin",
        "RELEASE_TAG": "",
        "PRERELEASE": "1",
        "DEB_ARCHIVE": "https://example.invalid/device.tar.gz",
        "DEB_ARCHIVE_SHA256": "a" * 64,
        "HAPTICS_DEB_ARCHIVE": "",
        "HAPTICS_DEB_ARCHIVE_SHA256": "",
        "HAPTICS_DEB_DIR": "",
    }
    archive = "https://example.invalid/haptics.tar.gz"
    digest = "a" * 64
    cases = (
        (
            "tagged archive",
            {
                "RELEASE_TAG": "test-20260723",
                "HAPTICS_DEB_ARCHIVE": archive,
                "HAPTICS_DEB_ARCHIVE_SHA256": digest,
            },
            True,
        ),
        (
            "tagged directory",
            {
                "RELEASE_TAG": "test-20260723",
                "HAPTICS_DEB_ARCHIVE": archive,
                "HAPTICS_DEB_ARCHIVE_SHA256": digest,
                "HAPTICS_DEB_DIR": "/verified/haptics-dir",
            },
            False,
        ),
        (
            "tagged device directory",
            {
                "RELEASE_TAG": "test-20260723",
                "DEB_ARCHIVE": archive,
                "DEB_ARCHIVE_SHA256": digest,
                "HAPTICS_DEB_ARCHIVE": archive,
                "HAPTICS_DEB_ARCHIVE_SHA256": digest,
                "DEB_DIR": "/unverified/device-dir",
            },
            False,
        ),
        (
            "tagged sensor directory",
            {
                "RELEASE_TAG": "test-20260723",
                "DEB_ARCHIVE": archive,
                "DEB_ARCHIVE_SHA256": digest,
                "HAPTICS_DEB_ARCHIVE": archive,
                "HAPTICS_DEB_ARCHIVE_SHA256": digest,
                "SENSOR_DEB_DIR": "/unverified/sensor-dir",
            },
            False,
        ),
        (
            "tagged missing archive",
            {"RELEASE_TAG": "test-20260723"},
            False,
        ),
        (
            "tagged missing archive digest",
            {
                "RELEASE_TAG": "test-20260723",
                "HAPTICS_DEB_ARCHIVE": archive,
            },
            False,
        ),
        (
            "artifact-only directory",
            {"HAPTICS_DEB_DIR": "/verified/haptics-dir", "PRERELEASE": "0"},
            True,
        ),
    )
    for label, updates, should_pass in cases:
        result = subprocess.run(
            ["bash", "-c", guard_prefix],
            env={**base_env, **updates},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if (result.returncode == 0) != should_pass:
            fail(
                f"{label} tagged-release haptics policy result was "
                f"{result.returncode}: {result.stderr}"
            )


def validate_structure(workflow: pathlib.Path, data: dict) -> None:
    dispatch = require_mapping(
        require_mapping(data.get("on"), "on").get("workflow_dispatch"),
        "on.workflow_dispatch",
    )
    inputs = require_mapping(dispatch.get("inputs"), "workflow_dispatch.inputs")
    if not dispatch_input_count_is_supported(inputs):
        fail(
            "workflow_dispatch exceeds GitHub's 10-input limit: "
            f"{len(inputs)}"
        )
    source_config = require_mapping(
        inputs.get("source_config"), "workflow_dispatch.inputs.source_config"
    )
    if source_config.get("type") != "string":
        fail("source_config must remain the single advanced source-profile input")
    for name in inputs:
        if not isinstance(name, str):
            fail("dispatch input names must be strings")
        if FORBIDDEN_INPUT.search(name):
            fail(f"credential material must not be a dispatch input: {name}")
    ubuntu_mirror = require_mapping(
        inputs.get("ubuntu_mirror"), "workflow_dispatch.inputs.ubuntu_mirror"
    )
    expected_mirror = "https://ports.ubuntu.com/ubuntu-ports"
    if ubuntu_mirror.get("default") != expected_mirror:
        fail("ubuntu_mirror must default to the pinned HTTPS ports mirror")
    if ubuntu_mirror.get("options") != [expected_mirror]:
        fail("ubuntu_mirror may offer only the pinned HTTPS ports mirror")

    jobs = require_mapping(data.get("jobs"), "jobs")
    camera = require_mapping(jobs.get("camera-producer"), "jobs.camera-producer")
    build = require_mapping(jobs.get("build"), "jobs.build")
    if camera.get("runs-on") != "ubuntu-24.04":
        fail("camera producer must run on the amd64 ubuntu-24.04 runner")
    if build.get("runs-on") != "ubuntu-24.04-arm":
        fail("rootfs build must remain on ubuntu-24.04-arm")
    if build.get("needs") != "camera-producer":
        fail("rootfs build must depend directly on the camera producer")
    camera_permissions = require_mapping(
        camera.get("permissions"), "jobs.camera-producer.permissions"
    )
    if camera_permissions != {"contents": "read"}:
        fail("camera producer must have only contents: read")
    camera_outputs = require_mapping(
        camera.get("outputs"), "jobs.camera-producer.outputs"
    )
    if camera_outputs != {
        "artifact_id": "$" + "{{ steps.upload_camera.outputs.artifact-id }}",
        "artifact_digest": "$" + "{{ steps.upload_camera.outputs.artifact-digest }}"
    }:
        fail("camera producer does not expose the upload action identity exactly")
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

    # The validators import PyYAML and run before the large build-tool install.
    # Make that dependency an explicit, ordered workflow contract so a runner
    # image change cannot turn the first validation step into an import failure.
    validation_indexes = [
        index
        for index, raw_step in enumerate(steps)
        if isinstance(raw_step, dict)
        and raw_step.get("name") == "Validate workflow input boundaries"
    ]
    if len(validation_indexes) != 1:
        fail("workflow must contain exactly one validation step")
    validation_index = validation_indexes[0]
    validation_step = require_mapping(
        steps[validation_index], "workflow validation step"
    )
    validation_run = validation_step.get("run")
    if not isinstance(validation_run, str):
        fail("workflow validation step must have a shell body")
    dependency_indexes = [
        index
        for index, raw_step in enumerate(steps)
        if isinstance(raw_step, dict)
        and raw_step.get("name") == "Install validation dependencies"
    ]
    if len(dependency_indexes) != 1:
        fail("workflow must install validation dependencies exactly once")
    dependency_index = dependency_indexes[0]
    dependency_step = require_mapping(
        steps[dependency_index], "validation dependency step"
    )
    dependency_run = dependency_step.get("run")
    if not isinstance(dependency_run, str) or not has_validation_tools(dependency_run):
        fail("install all validation tools, including ShellCheck and real ext4/FAT tools, before running the fixtures")
    if dependency_index >= validation_index:
        fail("python3-yaml must be installed before workflow validation")

    required_camera_gates = (
        "python3 -B scripts/ci/test-camera-artifact-handoff.py",
        "python3 -B scripts/ci/test-camera-release-assets.py",
        "python3 -B scripts/ci/test-camera-overlay-verifier.py",
        "python3 -B scripts/ci/test-camera-plugin-producer.py",
        "python3 -B scripts/ci/test-libcamera-source-export.py",
        "python3 -B scripts/ci/test-libcamera-source-materialization.py",
        "python3 -B scripts/ci/test-libcamera-build-adapter.py",
        "python3 -B scripts/ci/test-libcamera-build-environment.py",
        "python3 -B scripts/ci/test-libcamera-environment-preparation.py",
        "python3 -B scripts/ci/test-libcamera-runtime.py",
        "python3 -B scripts/ci/test-camera-runtime-dependencies.py",
        "python3 -B scripts/ci/test-camera-runtime-loader.py",
        "python3 -B scripts/ci/test-camera-source-contract.py",
        "bash scripts/ci/test-camera-overlay-installer.sh",
    )
    for gate in required_camera_gates:
        if validation_run.count(gate) != 1:
            fail(f"workflow must run the camera gate exactly once: {gate}")
    if validation_run.count("python3 -B scripts/ci/test-camera-data-loop.py") != 1:
        fail("workflow must run the native camera data-loop regression exactly once")
    if "export PYTHONDONTWRITEBYTECODE=1" not in validation_run:
        fail("workflow validation must disable Python bytecode residue")

    apply_config_run = step_scripts.get("Apply workflow configuration")
    if apply_config_run is None:
        fail("workflow configuration step is missing")
    validate_camera_version_default(apply_config_run)
    for domain in ("rootfs", "boot", "source"):
        call_head = (
            f'scripts/ci/apply-workflow-config.sh "$RUNNER_TEMP/{domain}.env"'
        )
        notes_argument = f'"$config_notes_dir/{domain}.env"'
        if apply_config_run.count(call_head) != 1 or apply_config_run.count(
            notes_argument
        ) != 1:
            fail(f"{domain} configuration does not produce validated canonical notes")
        call_index = apply_config_run.index(call_head)
        notes_index = apply_config_run.index(notes_argument)
        if not call_index < notes_index <= call_index + len(call_head) + 32:
            fail(f"{domain} canonical notes path is detached from its validator call")
        raw_copy = (
            f'cp "$RUNNER_TEMP/{domain}.env" "$config_notes_dir/{domain}.env"'
        )
        if raw_copy in apply_config_run:
            fail(f"{domain} raw configuration is copied into public notes")

    build_dependency_indexes = [
        index
        for index, raw_step in enumerate(steps)
        if isinstance(raw_step, dict) and raw_step.get("name") == "Install dependencies"
    ]
    if len(build_dependency_indexes) != 1:
        fail("workflow must contain one ARM build dependency step")
    build_dependency_run = require_mapping(
        steps[build_dependency_indexes[0]], "build dependency step"
    ).get("run")
    if not isinstance(build_dependency_run, str):
        fail("ARM build dependency step must have a shell body")

    camera_steps = camera.get("steps")
    if not isinstance(camera_steps, list) or not camera_steps:
        fail("jobs.camera-producer.steps must be a non-empty list")
    camera_named: dict[str, tuple[int, dict]] = {}
    for index, raw_step in enumerate(camera_steps):
        step = require_mapping(raw_step, f"jobs.camera-producer.steps[{index}]")
        name = step.get("name")
        if isinstance(name, str):
            if name in camera_named:
                fail(f"camera producer has a duplicate step name: {name}")
            camera_named[name] = index, step
        uses = step.get("uses")
        if uses is not None and (
            not isinstance(uses, str) or not PINNED_ACTION.fullmatch(uses)
        ):
            fail(f"camera step {index} action is not commit-pinned: {uses!r}")

    expected_camera_steps = (
        "Checkout exact camera source",
        "Apply camera build configuration",
        "Install locked camera producer dependencies",
        "Validate camera producer contracts",
        "Build camera artifact handoff",
        "Upload camera artifact handoff",
    )
    for name in expected_camera_steps:
        if name not in camera_named:
            fail(f"camera producer step is missing: {name}")

    _, camera_checkout = camera_named["Checkout exact camera source"]
    if camera_checkout.get("uses") != CHECKOUT_ACTION:
        fail("camera producer checkout is not pinned to the approved action")
    camera_checkout_with = require_mapping(
        camera_checkout.get("with"), "camera checkout.with"
    )
    if camera_checkout_with != {
        "ref": EXACT_WORKFLOW_SHA,
        "persist-credentials": "false",
    }:
        fail("camera producer must checkout github.sha without persisted credentials")

    config_index, camera_config = camera_named["Apply camera build configuration"]
    config_env = require_mapping(camera_config.get("env"), "camera config env")
    if config_env != {"INPUT_ROOTFS_CONFIG": "$" + "{{ inputs.rootfs_config }}"}:
        fail("camera producer config must receive only rootfs_config through env")
    config_run = camera_config.get("run")
    if not isinstance(config_run, str):
        fail("camera producer config step has no shell body")
    for key, expected in APPROVED_CAMERA_PROFILE.items():
        if key == "CAMERA_STACK_DEB_VERSION":
            validate_camera_version_default(config_run)
            continue
        token = f"{key}={expected}"
        if token not in config_run:
            fail(f"camera producer default config is missing: {token}")
    if 'scripts/ci/apply-workflow-config.sh "$RUNNER_TEMP/rootfs.env"' not in config_run:
        fail("camera producer bypasses the shared workflow config validator")

    dependency_index, camera_dependency = camera_named[
        "Install locked camera producer dependencies"
    ]
    camera_dependency_run = camera_dependency.get("run")
    if not isinstance(camera_dependency_run, str):
        fail("camera dependency step has no shell body")
    expected_provisioning = chr(10).join((
        "set -euo pipefail",
        "bash scripts/ci/camera-producer-container.sh prepare",
    ))
    if camera_dependency_run.strip() != expected_provisioning:
        fail("camera dependency step must use the exact locked full-runtime installer")
    camera_toolchain_lock = (
        workflow.parent.parent.parent
        / "source/tb321fu-camera-rootfs-overlay/source/"
        "spa-libcamera-producer/TOOLCHAIN.tsv"
    )
    try:
        toolchain_lines = camera_toolchain_lock.read_text(encoding="utf-8").splitlines()
    except OSError:
        fail("camera toolchain lock is missing")
    if not toolchain_lines or toolchain_lines[0] != "kind\tname\tversion\tsha256":
        fail("camera toolchain lock header mismatch")
    locked_camera_packages: list[tuple[str, str]] = []
    for line in toolchain_lines[1:]:
        fields = line.split("\t")
        if len(fields) != 4:
            fail("camera toolchain lock row is malformed")
        if fields[0] == "package":
            locked_camera_packages.append((fields[1], fields[2]))
    if not locked_camera_packages:
        fail("camera toolchain lock has no package closure")
    planner_spec = importlib.util.spec_from_file_location(
        "workflow_camera_package_plan",
        pathlib.Path(__file__).with_name("prepare-libcamera-build-environment.py"),
    )
    planner = importlib.util.module_from_spec(planner_spec)
    planner_spec.loader.exec_module(planner)
    plan = set(planner.package_plan(spa_lock=camera_toolchain_lock))
    for package, version in locked_camera_packages:
        if f"{package}={version}" not in plan and f"{package}:amd64={version}" not in plan:
            fail(f"camera dependency step omits locked package/version: {package}")
        if f"{package}={version}" in build_dependency_run:
            fail(f"amd64 camera package leaked into the ARM dependency step: {package}")
    if "libspa-0.2-dev:amd64" in build_dependency_run:
        fail("ARM build dependency step requests an amd64 Camera header package")

    validation_index_camera, camera_validation = camera_named[
        "Validate camera producer contracts"
    ]
    camera_validation_run = camera_validation.get("run")
    if not isinstance(camera_validation_run, str):
        fail("camera producer validation step has no shell body")
    for gate in required_camera_gates:
        if camera_validation_run.count(gate) != 1:
            fail(f"camera producer must run its gate exactly once: {gate}")

    camera_build_index, camera_build = camera_named["Build camera artifact handoff"]
    camera_build_run = camera_build.get("run")
    if not isinstance(camera_build_run, str):
        fail("camera producer build step has no shell body")
    for token in (
        "bash scripts/ci/camera-producer-container.sh build",
        "scripts/ci/camera-artifact-handoff.py create",
        "scripts/ci/camera-artifact-handoff.py verify",
        '--repository="$GITHUB_REPOSITORY"',
        '--commit="$GITHUB_SHA"',
        '--run-id="$GITHUB_RUN_ID"',
        '--run-attempt="$GITHUB_RUN_ATTEMPT"',
    ):
        if camera_build_run.count(token) != 1:
            fail(f"camera producer build/handoff contract is missing: {token}")
    if not config_index < dependency_index < validation_index_camera < camera_build_index:
        fail("camera configuration, dependencies, validation, and build are misordered")

    upload_index, camera_upload = camera_named["Upload camera artifact handoff"]
    if camera_upload.get("id") != "upload_camera":
        fail("camera upload step must retain the output-producing id")
    if camera_upload.get("uses") != UPLOAD_ACTION:
        fail("camera handoff upload action is not pinned to the approved commit")
    camera_upload_with = require_mapping(camera_upload.get("with"), "camera upload.with")
    if camera_upload_with != {
        "name": CAMERA_ARTIFACT_NAME,
        "path": "out/tb321fu-camera-stack-debs",
        "if-no-files-found": "error",
        "retention-days": 3,
        "compression-level": 0,
    }:
        fail("camera handoff upload does not have the exact bounded artifact contract")
    stop = camera_named.get("Stop isolated camera producer")
    if (stop is None or not camera_build_index < stop[0] < upload_index
            or stop[1].get("if") != "always()"
            or stop[1].get("run") != "bash scripts/ci/camera-producer-container.sh stop"):
        fail("camera container must stop after the build before artifact upload")

    build_named = {
        step.get("name"): (index, step)
        for index, step in enumerate(steps)
        if isinstance(step, dict) and isinstance(step.get("name"), str)
    }
    if "Build verified camera stack deb" in build_named:
        fail("ARM rootfs job still builds the amd64-hosted Camera producer")
    try:
        download_index, camera_download = build_named[
            "Download camera artifact handoff"
        ]
        verify_index, camera_verify = build_named["Verify camera artifact handoff"]
    except KeyError:
        fail("ARM rootfs job is missing the Camera artifact consumer")
    if camera_download.get("uses") != DOWNLOAD_ACTION:
        fail("camera handoff download action is not pinned to the approved commit")
    if require_mapping(camera_download.get("with"), "camera download.with") != {
        "artifact-ids": CAMERA_ARTIFACT_ID,
        "path": "out/tb321fu-camera-stack-debs",
        "merge-multiple": "true",
    }:
        fail("ARM job downloads an unexpected Camera artifact")
    camera_verify_env = require_mapping(camera_verify.get("env"), "camera verify env")
    if camera_verify_env != {
        "CAMERA_ARTIFACT_ID": CAMERA_ARTIFACT_ID,
        "CAMERA_ARTIFACT_DIGEST": CAMERA_ARTIFACT_DIGEST,
    }:
        fail("ARM Camera consumer does not receive the producer artifact identity")
    camera_verify_run = camera_verify.get("run")
    if not isinstance(camera_verify_run, str):
        fail("ARM Camera consumer has no shell body")
    for token in (
        "scripts/ci/camera-artifact-handoff.py verify",
        '[[ $CAMERA_ARTIFACT_ID =~ ^[1-9][0-9]*$ ]]',
        'CAMERA_PRODUCER_ARTIFACT_ID=%s',
        'ci_assert_tb321fu_camera_stack_deb "$camera_deb" "$camera_policy_stage"',
        'TB321FU_CAMERA_STACK_DEB_DIR=out/tb321fu-camera-stack-debs',
    ):
        if camera_verify_run.count(token) != 1:
            fail(f"ARM Camera consumer is missing its verification contract: {token}")
    apply_index = build_named["Apply workflow configuration"][0]
    rootfs_index = build_named["Build rootfs image"][0]
    if not apply_index < download_index < verify_index < rootfs_index:
        fail("Camera artifact is not configured, downloaded, verified, then consumed")

    grub_integrity_indexes = [
        index
        for index, raw_step in enumerate(steps)
        if isinstance(raw_step, dict)
        and raw_step.get("name") == "Validate GRUB image integrity"
    ]
    if len(grub_integrity_indexes) != 1:
        fail("workflow must contain exactly one GRUB image integrity step")
    grub_integrity_run = require_mapping(
        steps[grub_integrity_indexes[0]], "GRUB image integrity step"
    ).get("run")
    if not isinstance(grub_integrity_run, str) or grub_integrity_run.count(
        "bash scripts/ci/test-grub-image-integrity.sh"
    ) != 1:
        fail("GRUB image integrity step must run its real-FAT fixture exactly once")
    if build_dependency_indexes[0] >= grub_integrity_indexes[0]:
        fail("dosfstools and mtools must be installed before the GRUB integrity fixture")

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

    handoff_run = step_scripts.get("Verify kernel bundle handoff")
    if handoff_run is None:
        fail("kernel bundle handoff step is missing")
    tagged_haptics_guard = (
        'if [ -n "$RELEASE_TAG" ] && { [ -n "${DEB_DIR:-}" ] || '
        '[ -n "${HAPTICS_DEB_DIR:-}" ] || [ -n "${SENSOR_DEB_DIR:-}" ] || '
        '[ -z "${DEB_ARCHIVE:-}" ] || [ -z "${DEB_ARCHIVE_SHA256:-}" ] || '
        '[ -z "${HAPTICS_DEB_ARCHIVE:-}" ] || '
        '[ -z "${HAPTICS_DEB_ARCHIVE_SHA256:-}" ]; }; then'
    )
    haptics_policy_message = (
        "Tagged releases require pinned DEB_ARCHIVE/HAPTICS_DEB_ARCHIVE inputs; "
        "local DEB_DIR, SENSOR_DEB_DIR, and HAPTICS_DEB_DIR are artifact-only."
    )
    handoff_call = "bash scripts/ci/verify-kernel-bundle.sh"
    release_provenance_call = "bash scripts/ci/validate-release-input-provenance.sh"
    for token in (tagged_haptics_guard, haptics_policy_message):
        if token not in handoff_run:
            fail(f"tagged release haptics policy is missing: {token}")
    if handoff_run.index(tagged_haptics_guard) > handoff_run.index(handoff_call):
        fail("tagged release haptics policy runs after bundle verification")
    if release_provenance_call not in handoff_run:
        fail("tagged release input provenance gate is missing")
    if handoff_run.index(release_provenance_call) > handoff_run.index(handoff_call):
        fail("tagged release input provenance gate runs after bundle verification")
    kernel_source_handoff = (
        'KERNEL_BUILD_ARCHIVE="$KERNEL_BUILD_ARCHIVE"',
        'KERNEL_BUILD_ARCHIVE_SHA256="$KERNEL_BUILD_ARCHIVE_SHA256"',
        'KERNEL_BOOTSTRAP_PRODUCER_COMMIT="$KERNEL_BOOTSTRAP_PRODUCER_COMMIT"',
        'KERNEL_BOOTSTRAP_PRODUCER_TREE="$KERNEL_BOOTSTRAP_PRODUCER_TREE"',
        (
            'KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256='
            '"$KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256"'
        ),
    )
    for token in kernel_source_handoff:
        if token not in handoff_run:
            fail(f"kernel source-profile handoff is missing: {token}")
        if handoff_run.index(token) > handoff_run.index(handoff_call):
            fail(f"kernel source-profile input is assigned after verifier: {token}")
    run_tagged_haptics_policy_fixtures(handoff_run)

    release_run = step_scripts.get("Upload release assets")
    if release_run is None:
        fail("release asset staging step is missing")
    package_inventory = (
        'stage_release_file "$OUTPUT_DIR_ROOTFS/'
        '${OUTPUT_PREFIX}-rootfs.packages.tsv"'
    )
    release_notes = 'notes="$release_dir/BUILD-PARAMETERS.md"'
    camera_artifact_id_note = "Camera producer artifact ID:"
    camera_artifact_digest_note = "Camera producer artifact SHA-256:"
    release_staging_validator = 'bash scripts/ci/validate-release-staging.sh "$release_stage"'
    release_checksums = 'bash scripts/ci/write-release-manifest.sh "$release_stage"'
    apt_provenance = (
        'stage_release_file "$OUTPUT_DIR_ROOTFS/'
        '${OUTPUT_PREFIX}-rootfs.apt-provenance.tsv"'
    )
    apt_bootstrap = (
        'stage_release_file "$OUTPUT_DIR_ROOTFS/'
        '${OUTPUT_PREFIX}-rootfs.apt-bootstrap.tsv"'
    )
    apt_sources = (
        'stage_release_file "$OUTPUT_DIR_ROOTFS/'
        '${OUTPUT_PREFIX}-rootfs.apt-sources.txt"'
    )
    kernel_evidence = (
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/KERNEL-SOURCE-LOCK.tsv"',
        '"$release_dir/KERNEL-SOURCE-LOCK.tsv"',
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/SENSOR-SOURCE-LOCK.tsv"',
        '"$release_dir/SENSOR-SOURCE-LOCK.tsv"',
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/HAPTICS-SOURCE-LOCK.tsv"',
        '"$release_dir/HAPTICS-SOURCE-LOCK.tsv"',
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/HAPTICS-BUILD-TOOLS.tsv"',
        '"$release_dir/HAPTICS-BUILD-TOOLS.tsv"',
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/MODULES.sha256"',
        '"$release_dir/MODULES.sha256"',
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/KERNEL-SDK-MANIFEST.tsv"',
        '"$release_dir/KERNEL-SDK-MANIFEST.tsv"',
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/KERNEL-TOOLCHAIN.tsv"',
        '"$release_dir/KERNEL-TOOLCHAIN.tsv"',
        'stage_release_file "$VERIFIED_KERNEL_BUNDLE_DIR/KBUILD-FLAGS.tsv"',
        '"$release_dir/KBUILD-FLAGS.tsv"',
    )
    camera_evidence = (
        'stage_release_file out/tb321fu-camera-stack-debs/CAMERA-HANDOFF.tsv',
        '"$release_dir/CAMERA-HANDOFF.tsv"',
        (
            "stage_release_file out/tb321fu-camera-stack-debs/"
            "tb321fu-camera-stack-build-report.txt"
        ),
        '"$release_dir/CAMERA-BUILD-REPORT.txt"',
        'camera_release_deb=$(python3 -I -B scripts/ci/camera-package-policy.py deb-name)',
        'stage_release_file "out/tb321fu-camera-stack-debs/$camera_release_deb"',
        '"$release_dir/$camera_release_deb"',
        'stage_release_file out/tb321fu-camera-stack-debs/SHA256SUMS-tb321fu-camera-stack-debs.txt',
        '"$release_dir/SHA256SUMS-tb321fu-camera-stack-debs.txt"',
        'python3 -I -B scripts/ci/verify-camera-release-assets.py "$release_dir"',
    )
    for token in (
        package_inventory,
        '"$release_dir/ROOTFS-PACKAGES.tsv"',
        apt_provenance,
        '"$release_dir/APT-PROVENANCE.tsv"',
        apt_bootstrap,
        '"$release_dir/APT-BOOTSTRAP.tsv"',
        apt_sources,
        '"$release_dir/APT-SOURCES.txt"',
        release_notes,
        camera_artifact_id_note,
        camera_artifact_digest_note,
        release_staging_validator,
        release_checksums,
        *kernel_evidence,
        *camera_evidence,
    ):
        if token not in release_run:
            fail(f"release staging is missing rooted provenance evidence: {token}")
    for token in (
        package_inventory,
        apt_provenance,
        apt_bootstrap,
        apt_sources,
        *kernel_evidence,
        *camera_evidence,
    ):
        if release_run.index(token) > release_run.index(release_checksums):
            fail("rootfs provenance evidence is staged after release checksums")
    if release_run.index(release_notes) > release_run.index(release_checksums):
        fail("release notes are staged after release checksums")
    first_boot_notice = (
        "echo 'If using a shared test account, keep first boot offline or on an isolated network "
        "and change its password locally with passwd before joining a trusted LAN.'"
    )
    notes_output = '} > "$notes"'
    if (release_run.count(first_boot_notice) != 1 or release_run.count(notes_output) != 1
            or not release_run.index(release_notes) < release_run.index(first_boot_notice) < release_run.index(notes_output)):
        fail("the staged release notes must contain the first-boot test-account notice")
    if release_run.count(release_staging_validator) != 2:
        fail("release staging must be validated before and after manifest generation")

    combined_checksums_run = step_scripts.get("Write combined checksums")
    if combined_checksums_run is None:
        fail("combined checksum step is missing")
    if "out/ci-release/APT-BOOTSTRAP.tsv" not in combined_checksums_run:
        fail("combined checksum manifest omits APT bootstrap evidence")
    for token in (
        "out/tb321fu-camera-stack-debs/CAMERA-HANDOFF.tsv",
        "out/ci-release/CAMERA-HANDOFF.tsv",
        "checksum_dirs+=(out/tb321fu-camera-stack-debs)",
    ):
        if token not in combined_checksums_run:
            fail(f"combined checksum manifest omits Camera evidence: {token}")

    release_lines = [
        line.strip() for step in steps for line in str(step.get("run", "")).splitlines()
        if "Release image streams:" in line
    ]
    if len(release_lines) != 1:
        fail("release notes must describe the two archive streams")
    stream_note = subprocess.run(
        ["bash", "-euc", 'rootfs_stream_name=rootfs.img.7z; grub_stream_name=grub.img.7z; ' + release_lines[0]],
        capture_output=True, text=True, check=False,
    )
    expected = "Release image streams: `rootfs.img.7z` and `grub.img.7z`; large streams may have contiguous `.NNN` parts.\n"
    if stream_note.returncode or stream_note.stderr or stream_note.stdout != expected:
        fail("release notes did not preserve the image stream names and split suffix")

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
    required = {
        "DEFAULT_USER_PASSWORD_HASH": "TB321FU_NOV2026_TEST_USER_PASSWORD_HASH",
        "ROOT_PASSWORD_HASH": "ROOT_PASSWORD_HASH",
    }
    for key, secret_name in required.items():
        if rootfs_env.get(key) != f"${{{{ secrets.{secret_name} }}}}":
            fail(f"{key} must use the approved secret in the rootfs step")
        if sum(name == secret_name for _, name in secret_paths) != 1:
            fail(f"{secret_name} must only be exposed at the rootfs step")

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


SUDO_HASH_GUARD = 'ci_require_sudo_password_hash "$USER_SUDO_MODE" "$DEFAULT_USER_PASSWORD_HASH"'
FIRST_IMAGE_WORK = 'work_dir=$(make_rootfs_work_dir "$OUTPUT_DIR")'


def validate_password_before_image_work(text: str, context: str) -> None:
    # Match the two top-level calls, not comments or the mkdir inside the helper.
    lines = text.splitlines()
    for call in (SUDO_HASH_GUARD, FIRST_IMAGE_WORK):
        if lines.count(call) != 1:
            fail(f"{context}: expected exactly one top-level call: {call}")
    if lines.index(SUDO_HASH_GUARD) > lines.index(FIRST_IMAGE_WORK):
        fail(f"{context}: password sudo hash validation runs after image work")


def validate_rootfs_contract(rootfs: pathlib.Path) -> None:
    text = rootfs.read_text(encoding="utf-8")
    loader_block = chr(10).join((
        'if [ -n "${CAMERA_STACK_DEB_DIR:-}" ] || [ -f "$rootfs_dir/opt/libcamera-y700/lib/aarch64-linux-gnu/libcamera.so.0.7.1" ]; then',
        '  ci_log "validating camera dependencies with the target dynamic loader"',
        '  python3 -I -B "$SCRIPT_DIR/verify-camera-runtime-loader.py" --rootfs "$rootfs_dir"',
        'fi',
    ))
    if text.count(loader_block) != 1:
        fail(f"{rootfs}: final camera loader gate is missing or bypassed")
    if not (text.index('ci_assert_privileged_payload_security "$rootfs_dir"')
            < text.index(loader_block) < text.index('cat > "$build_info" <<INFO')):
        fail(f"{rootfs}: camera loader gate must follow payload checks and precede output metadata")
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
        '"$(basename "$apt_provenance")"',
        '"$(basename "$apt_sources")"',
        '"$(basename "$apt_bootstrap")"',
        'ci_validate_https_apt_uri "$MIRROR"',
        'ci_validate_apt_proxy "$APT_HTTP_PROXY"',
        'ci_validate_apt_proxy "$APT_HTTPS_PROXY"',
        'ci_validate_resolv_conf_content "$RESOLV_CONF_CONTENT"',
        'ci_validate_locales "$LOCALES"',
        'ci_validate_locale_name "$LANG_NAME"',
        'ci_validate_lang_name_in_locales "$LANG_NAME" "$LOCALES"',
        'ci_validate_account_name "$DEFAULT_USER_NAME"',
        'ci_validate_timezone "$TZ_REGION"',
        'ci_validate_root_password_mode "$ROOT_PASSWORD_MODE"',
        'ci_validate_password_hash "$ROOT_PASSWORD_HASH"',
        'ci_validate_bool "$SDDM_AUTOLOGIN" SDDM_AUTOLOGIN',
        'ci_validate_sddm_session "$SDDM_AUTOLOGIN_SESSION"',
        'ci_validate_distro_name "$DISTRO"',
        'ci_validate_arch_name "$ARCH"',
        'ci_validate_debootstrap_variant "$DEBOOTSTRAP_VARIANT"',
        'ci_validate_uuid "$ROOTFS_UUID" ROOTFS_UUID',
        'ci_validate_partlabel "$ROOTFS_PARTLABEL" ROOTFS_PARTLABEL',
        'ci_validate_compression "$COMPRESS"',
        'ci_validate_volume_size "$CHUNK_SIZE" CHUNK_SIZE',
        'ci_validate_https_apt_sources_list "$APT_SOURCES_LIST"',
        '. /root/ci-apt-common.sh',
        'enable_locale_record()',
        'awk -v target_locale="$locale" -v target_charset="$charset"',
        'match_file=$(mktemp /etc/locale.gen.match.XXXXXX)',
        "locale_mode=$(stat -c '%a' /etc/locale.gen)",
        "locale_uid=$(stat -c '%u' /etc/locale.gen)",
        "locale_gid=$(stat -c '%g' /etc/locale.gen)",
        'chown -- "$locale_uid:$locale_gid" "$tmp"',
        'chmod -- "$locale_mode" "$tmp"',
        'mv -f -- "$tmp" /etc/locale.gen',
        'locale is not present in /etc/locale.gen',
        'locale-gen\nupdate-locale LANG="$LANG_NAME"',
        'install -m 0755 "$SCRIPT_DIR/apt-transaction-provenance.sh"',
        'APT_PROVENANCE_PHASE=rootfs-provision',
        'APT_PROVENANCE_PHASE=gpu-build',
        '/root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build install -y -- "$package_deb"',
        '/root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build autoremove -y --purge',
        'bash "$SCRIPT_DIR/write-apt-provenance.sh"',
        'ci_e2fsck_repair "$rootfs_img" 0',
    )
    for token in required:
        if token not in text:
            fail(f"{rootfs}: missing locked absent-secret default: {token}")
    if 'cp --preserve=mode,ownership -- "$tmp" /etc/locale.gen' in text:
        fail(f"{rootfs}: locale replacement can inherit mktemp's restrictive mode")
    metadata_probe = "locale_mode=$(stat -c '%a' /etc/locale.gen)"
    temp_probe = 'tmp=$(mktemp /etc/locale.gen.XXXXXX)'
    if text.find(metadata_probe) < 0 or text.find(metadata_probe) > text.find(temp_probe):
        fail(f"{rootfs}: locale metadata is not captured before temporary replacement")

    validate_password_before_image_work(text, str(rootfs))


def run_provision_env_fixture(rootfs: pathlib.Path) -> None:
    """Exercise the actual clean-env handoff and pre-APT validators without a chroot."""
    text = rootfs.read_text(encoding="utf-8")
    # Replace only the root switch and script location. Keep env -i, all its
    # original assignments and quoting, and the target's validation code.
    def section(source: str, begin: str, end: str, name: str) -> str:
        if source.count(begin) != 1 or source.count(end) != 1:
            fail(f"{rootfs}: expected unique start and end markers for {name}")
        region, found, _ = source.partition(begin)[2].partition(end)
        if not found or not region.strip():
            fail(f"{rootfs}: empty or misordered {name}")
        return region

    # Capture only the real bootstrap argv in a shell with no external tools.
    # A supplied key selects a package, never a key value in process arguments.
    begin = 'debootstrap_args=(--arch="$ARCH")\n'
    end = '\ndebootstrap "${debootstrap_args[@]}" "$DISTRO" "$rootfs_dir" "$MIRROR"\n'
    bootstrap = begin + section(text, begin, end, "bootstrap argv") + end
    for variant in ("", "minbase"):
        for keys in ("", "fixture-key-not-for-bootstrap-argv"):
            argv = subprocess.run(["/bin/bash", "-euc", 'debootstrap() { printf "%s\\0" "$@"; }\n' + bootstrap],
                                  env=dict(PATH="/nonexistent", ARCH="arm64", DISTRO="resolute", rootfs_dir="/target",
                                           MIRROR="https://example.invalid", DEBOOTSTRAP_VARIANT=variant,
                                           DEFAULT_USER_AUTHORIZED_KEYS=keys),
                                  capture_output=True, timeout=5)
            expected = (["--arch=arm64"] + (["--variant=minbase"] if variant else []) +
                        (["--include=python3"] if keys else []) + ["resolute", "/target", "https://example.invalid"])
            if argv.returncode or argv.stderr or argv.stdout.split(b"\0") != [v.encode() for v in expected] + [b""]:
                fail(f"{rootfs}: incorrect public-key bootstrap arguments")

    launcher = section(text, 'ci_log "provisioning rootfs"\n',
                       '\n  bash /root/ci-provision.sh\n', "chroot provision launcher")
    leading = 'chroot "$rootfs_dir" '
    if not launcher.startswith(leading + "env -i "):
        fail(f"{rootfs}: expected a clean environment in the provision launcher")
    launcher = launcher[len(leading):] + '\n  bash -s -- "$1"'
    body = section(text, "<<'PROVISION'\n", "\nPROVISION\n", "provision script")
    validations = section(body, "\n. /root/ci-apt-common.sh\n", "\nci_bool_chroot()\n",
                          "pre-APT provision validators")
    probe = ('set -euo pipefail\n. "$1"\n' + validations +
             '\n[[ ! -v OUTSIDE_PROVISION ]]\n' +
             'printf "%s\\n" "$SDDM_AUTOLOGIN" "$SDDM_AUTOLOGIN_SESSION"\n'
             'case "$DEFAULT_USER_PASSWORD_HASH" in "") echo empty;; "!") echo locked;; *) echo present;; esac\n')
    env = dict.fromkeys(re.findall(r'="\$([a-zA-Z_][a-zA-Z_0-9]*)"', launcher), "")
    env.update(PATH="/usr/bin:/bin", OUTSIDE_PROVISION="not forwarded", ROOT_PASSWORD_MODE="locked",
               USER_SUDO_MODE="password", INSTALL_FCITX5_CHINESE="1", INSTALL_FIREFOX="1",
               DISABLE_SNAPD="1", CLEAN_APT_CACHE="1", LOCALES="en_US.UTF-8 UTF-8", LANG_NAME="en_US.UTF-8")
    # Synthetic only. The real release uses password sudo: an empty value
    # skips the entire target crypt validator and falsely exercises neither
    # the setting nor its implementation. Never log any probe value/stderr.
    encoded = subprocess.run(["/usr/bin/openssl", "passwd", "-6", "-salt", "fixture", "-stdin"],
                             input="disposable-workflow-fixture\n", text=True, capture_output=True, timeout=5)
    if encoded.returncode or not re.fullmatch(r"\$6\$fixture\$[./0-9A-Za-z]{86}\n", encoded.stdout):
        fail("could not generate a synthetic provision input")
    for enabled, session, sudo, setting, error in (
            ("1", "plasma", "password", encoded.stdout.rstrip("\n"), ""),
            ("0", "custom.desktop", "none", "!", ""), ("0", "custom.desktop", "none", "", ""),
            ("1", "plasma", "password", "invalid-fixture", "not a supported crypt(3) hash"),
            ("invalid", "plasma", "none", "", "SDDM_AUTOLOGIN must"),
            ("1", "invalid session", "none", "", "SDDM_AUTOLOGIN_SESSION must")):
        result = subprocess.run(["/bin/bash", "-eu", "-c", launcher, "fixture",
                                 str(rootfs.with_name("common.sh").resolve())],
                                env=dict(env, SDDM_AUTOLOGIN=enabled, SDDM_AUTOLOGIN_SESSION=session,
                                         USER_SUDO_MODE=sudo, DEFAULT_USER_PASSWORD_HASH=setting),
                                input=probe, text=True, capture_output=True, timeout=15)
        if error:
            if result.returncode == 0 or error not in result.stderr:
                fail("invalid provision input not rejected at its validator")
        elif (result.returncode or result.stdout.splitlines() !=
              [enabled, session, {"": "empty", "!": "locked"}.get(setting, "present")]):
            fail("clean provision environment or pre-APT target validation failed")


def run_builtin_config_fixtures(
    workflow: pathlib.Path, apply_config: pathlib.Path, data: dict
) -> None:
    jobs = require_mapping(data.get("jobs"), "jobs")
    build = require_mapping(jobs.get("build"), "jobs.build")
    steps = build.get("steps")
    if not isinstance(steps, list):
        fail("jobs.build.steps must be a list")
    config_bodies = [
        step.get("run")
        for step in steps
        if isinstance(step, dict)
        and step.get("name") == "Apply workflow configuration"
        and isinstance(step.get("run"), str)
    ]
    if len(config_bodies) != 1:
        fail("ARM build must contain exactly one workflow configuration body")
    config_body = config_bodies[0]
    with tempfile.TemporaryDirectory(prefix="tb321fu-workflow-default-config.") as temp:
        root = pathlib.Path(temp)
        for domain in ("rootfs", "boot", "source"):
            opening = f'cat > "$RUNNER_TEMP/{domain}.env" <<\'CONFIG_EOF\''
            start = config_body.find(opening)
            if start < 0:
                fail(f"{workflow}: missing built-in {domain} config block")
            if config_body.find(opening, start + len(opening)) >= 0:
                fail(f"{workflow}: duplicate built-in {domain} config block")
            start = config_body.find("\n", start)
            if start < 0:
                fail(f"{workflow}: malformed built-in {domain} config block")
            start += 1
            end = config_body.find("\nCONFIG_EOF", start)
            if end < 0:
                fail(f"{workflow}: unterminated built-in {domain} config block")
            config_text = config_body[start:end]
            if domain == "rootfs":
                config_text += chr(10) + 'CAMERA_STACK_DEB_VERSION=' + APPROVED_CAMERA_VERSION
            if domain in {"rootfs", "source"}:
                profile: dict[str, str] = {}
                for line in config_text.splitlines():
                    if not line or line.startswith("#"):
                        continue
                    key, separator, value = line.partition("=")
                    if not separator:
                        fail(f"{workflow}: malformed built-in {domain} profile: {line}")
                    profile[key] = value
                approved_profile = (
                    APPROVED_KERNEL_SOURCE_PROFILE if domain == "source" else APPROVED_DEVICE_PROFILE
                )
                for key, expected in approved_profile.items():
                    if profile.get(key) != expected:
                        fail(
                            f"{workflow}: built-in {domain} profile does not lock "
                            f"approved {key}"
                        )
            config = root / f"{domain}.env"
            github_env = root / f"{domain}.github.env"
            config.write_text(f"{config_text}\n", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(apply_config), str(config)],
                env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(github_env)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode:
                fail(
                    f"built-in {domain} config no longer matches its allowlist: "
                    f"{result.stderr}"
                )


def run_hostile_config_fixtures(apply_config: pathlib.Path) -> None:
    with tempfile.TemporaryDirectory(prefix="tb321fu-workflow-fixture.") as temp:
        root = pathlib.Path(temp)
        marker = root / "executed"
        config = root / "rootfs.env"
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

        secret_config = root / "rootfs.env"
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

        proxy_config = root / "rootfs.env"
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

        injection_cases = {
            "proxy-apt-syntax": (
                'APT_HTTP_PROXY=http://127.0.0.1:9"; '
                'APT::Update::Pre-Invoke {"printf PWNED";}; //\n'
            ),
            "proxy-newline": (
                "APT_HTTPS_PROXY=http://proxy.invalid:8080\n"
                'APT::Update::Pre-Invoke {"id";};\n'
            ),
            "locales-sed-program": (
                r"LOCALES=\)/\1/;e printf PWNED;#\n"
            ),
            "locales-extra-field": "LOCALES=en_US.UTF-8 UTF-8 extra\n",
            "timezone-traversal": "TZ_REGION=../../etc/passwd\n",
            "config-nul": "ROOTFS_LABEL=Ubuntu\x00ROOT_PASSWORD_MODE=empty\n",
            "scalar-cr": "ROOTFS_LABEL=Ubuntu\rROOT_PASSWORD_MODE=empty\n",
            "locale-lang-mismatch": (
                "LOCALES=en_US.UTF-8 UTF-8\n"
                "LANG_NAME=zh_CN.UTF-8\n"
            ),
        }
        for label, contents in injection_cases.items():
            injection_config = root / "rootfs.env"
            injection_output = root / f"injection-{label}-github.env"
            injection_config.write_text(contents, encoding="utf-8")
            result = subprocess.run(
                ["bash", str(apply_config), str(injection_config)],
                env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(injection_output)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode == 0:
                fail(f"workflow config accepted hostile {label} input")
            if injection_output.exists() and injection_output.stat().st_size:
                fail(f"rejected hostile {label} input was partially serialized")

        invalid_source_values = {
            "KERNEL_BUILD_ARCHIVE_SHA256": "f" * 63,
            "KERNEL_BOOTSTRAP_PRODUCER_COMMIT": "A" * 40,
            "KERNEL_BOOTSTRAP_PRODUCER_TREE": "0" * 39,
            "KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256": "B" * 64,
        }
        for key, value in invalid_source_values.items():
            invalid_config = root / "source.env"
            invalid_output = root / f"invalid-{key}-github.env"
            invalid_config.write_text(f"{key}={value}\n", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(apply_config), str(invalid_config)],
                env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(invalid_output)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode == 0:
                fail(f"workflow config accepted malformed source identity: {key}")
            if invalid_output.exists() and invalid_output.stat().st_size:
                fail(f"rejected source identity was partially serialized: {key}")

        for key in (
            "BUILD_Y700_SENSOR_DEBS",
            "SENSOR_SOURCE_DIR",
            "SENSOR_DEB_DIR",
            "BUILD_TB321FU_HAPTICS_DEB",
            "HAPTICS_SOURCE_DIR",
            "KERNEL_SOURCE_DIR",
        ):
            deprecated_config = root / "rootfs.env"
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

        source_commit = "a" * 40
        source_tree = "b" * 40
        source_sha = "c" * 64
        allowed_configs = (
            (
                "rootfs.env",
                "DEFAULT_USER_NAME=GUF296\n"
                "USER_SUDO_MODE=password\n"
                "SDDM_AUTOLOGIN=1\n"
                "DESKTOP_ENV=kubuntu-desktop\n"
                "PACKAGE_LIST=\n",
                (
                    "DEFAULT_USER_NAME",
                    "USER_SUDO_MODE",
                    "SDDM_AUTOLOGIN",
                    "DESKTOP_ENV",
                    "PACKAGE_LIST",
                ),
            ),
            (
                "boot.env",
                "BOOT_IMAGE_SIZE=256M\n",
                ("BOOT_IMAGE_SIZE",),
            ),
            (
                "source.env",
                "KERNEL_ARTIFACT_ARCHIVE=https://example.invalid/kernel.tar.gz\n"
                "KERNEL_BUILD_ARCHIVE=https://example.invalid/kernel-sdk.tar.gz\n"
                f"KERNEL_BUILD_ARCHIVE_SHA256={source_sha}\n"
                f"KERNEL_BOOTSTRAP_PRODUCER_COMMIT={source_commit}\n"
                f"KERNEL_BOOTSTRAP_PRODUCER_TREE={source_tree}\n"
                f"KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256={source_sha}\n",
                (
                    "KERNEL_ARTIFACT_ARCHIVE",
                    "KERNEL_BUILD_ARCHIVE",
                    "KERNEL_BUILD_ARCHIVE_SHA256",
                    "KERNEL_BOOTSTRAP_PRODUCER_COMMIT",
                    "KERNEL_BOOTSTRAP_PRODUCER_TREE",
                    "KERNEL_BOOTSTRAP_PRODUCER_TREE_SHA256",
                ),
            ),
        )
        for config_name, content, expected_keys in allowed_configs:
            allowed_config = root / config_name
            allowed_output = root / f"{config_name}.github.env"
            allowed_config.write_text(content, encoding="utf-8")
            result = subprocess.run(
                ["bash", str(apply_config), str(allowed_config)],
                env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(allowed_output)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode:
                fail(
                    f"legal {config_name} values were rejected: {result.stderr}"
                )
            exported = allowed_output.read_text(encoding="utf-8")
            for key in expected_keys:
                if f"{key}<<" not in exported:
                    fail(f"legal {config_name} value was not exported: {key}")

        # The workflow concatenates built-in defaults, an advanced config
        # block, and dedicated UI controls before this parser sees the file.
        # Repeated keys are therefore intentional: the final declaration
        # must win and each key must be emitted exactly once.
        precedence_configs = (
            (
                "rootfs.env",
                "MIRROR=https://mirror.example.invalid/ubuntu\n"
                "ROOTFS_IMAGE_SIZE=99G\n"
                "ROOTFS_LABEL=Other\n"
                "HOSTNAME_NAME=custom\n"
                "MIRROR=https://ports.ubuntu.com/ubuntu-ports\n"
                "ROOTFS_IMAGE_SIZE=20G\n"
                "ROOTFS_LABEL=Ubuntu\n"
                "HOSTNAME_NAME=y700\n",
                {
                    "MIRROR": "https://ports.ubuntu.com/ubuntu-ports",
                    "ROOTFS_IMAGE_SIZE": "20G",
                    "ROOTFS_LABEL": "Ubuntu",
                    "HOSTNAME_NAME": "y700",
                },
            ),
            (
                "boot.env",
                "BOOT_IMAGE_SIZE=256M\n"
                "BOOT_COMPRESS=7z\n"
                "BOOT_IMAGE_SIZE=512M\n",
                {"BOOT_IMAGE_SIZE": "512M"},
            ),
            (
                "source.env",
                "DTB_NAME=sm8650-lenovo-tb321fu.dtb\n"
                "DTB_NAME=alternate.dtb\n",
                {"DTB_NAME": "alternate.dtb"},
            ),
        )
        for config_name, content, expected_values in precedence_configs:
            precedence_config = root / config_name
            precedence_output = root / f"precedence-{config_name}.github.env"
            precedence_config.write_text(content, encoding="utf-8")
            result = subprocess.run(
                ["bash", str(apply_config), str(precedence_config)],
                env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(precedence_output)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode:
                fail(
                    f"documented {config_name} override precedence was rejected: "
                    f"{result.stderr}"
                )
            exported = precedence_output.read_text(encoding="utf-8")
            for key, expected_value in expected_values.items():
                if exported.count(f"{key}<<") != 1:
                    fail(
                        f"{config_name} did not export exactly one final value "
                        f"for repeated key: {key}"
                    )
                if f"\n{expected_value}\n" not in exported:
                    fail(
                        f"{config_name} did not preserve the final override "
                        f"for {key}"
                    )

        rootfs_ui_controls = {
            "DEFAULT_USER_NAME": "outside",
            "USER_SUDO_MODE": "nopasswd",
            "SDDM_AUTOLOGIN": "1",
            "SDDM_AUTOLOGIN_SESSION": "plasma",
            "DESKTOP_ENV": "plasma-desktop",
            "PACKAGE_LIST": "unexpected-package",
        }
        for config_name, legal_line in (
            ("boot.env", "BOOT_IMAGE_SIZE=256M"),
            (
                "source.env",
                "KERNEL_ARTIFACT_ARCHIVE=https://example.invalid/kernel.tar.gz",
            ),
        ):
            for key, value in rootfs_ui_controls.items():
                cross_domain_config = root / config_name
                cross_domain_output = root / f"{config_name}-{key}.github.env"
                cross_domain_config.write_text(
                    f"{legal_line}\n{key}={value}\n", encoding="utf-8"
                )
                result = subprocess.run(
                    ["bash", str(apply_config), str(cross_domain_config)],
                    env={
                        "PATH": "/usr/bin:/bin",
                        "GITHUB_ENV": str(cross_domain_output),
                    },
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                if result.returncode == 0:
                    fail(
                        f"{config_name} accepted a rootfs UI/profile override: {key}"
                    )
                if cross_domain_output.exists() and cross_domain_output.stat().st_size:
                    fail(
                        f"rejected {config_name} override partially serialized: {key}"
                    )


def run_local_qcomramp_propagation_fixture(
    workflow: pathlib.Path, apply_config: pathlib.Path
) -> None:
    """Exercise the local direct-GRUB EFI handoff across workflow steps.

    ``sudo`` is used only by the rootfs step; GitHub carries values written to
    ``GITHUB_ENV`` into the later GRUB step.  A tiny fake ``bash`` executable
    lets this fixture execute the exact GRUB-step shell without running a
    build, while still proving that the local EFI path arrives at the builder.
    """

    workflow_data = load_workflow(workflow)
    steps = require_mapping(workflow_data.get("jobs"), "jobs").get("build", {}).get(
        "steps", []
    )
    if not isinstance(steps, list):
        fail("workflow build steps are not a list")
    grub_run = next(
        (
            step.get("run")
            for step in steps
            if isinstance(step, dict) and step.get("name") == "Build GRUB boot image"
        ),
        None,
    )
    if not isinstance(grub_run, str):
        fail("Build GRUB boot image step has no shell body")
    for token in (
        'QCOMRAMP_EFI="${QCOMRAMP_EFI:-}"',
        'QCOMRAMP_EFI_URL="$QCOMRAMP_EFI_URL"',
        "bash scripts/ci/build-grub-image.sh",
    ):
        if token not in grub_run:
            fail(f"GRUB step does not forward local QCOMRAMP input: {token}")

    with tempfile.TemporaryDirectory(prefix="tb321fu-qcomramp-propagation.") as temp:
        root = pathlib.Path(temp)
        qcomramp = root / "QCOMRAMP.EFI"
        qcomramp.write_bytes(b"fixture direct grub efi\n")
        source_config = root / "source.env"
        github_env = root / "github.env"
        source_config.write_text(
            f"QCOMRAMP_EFI={qcomramp}\nQCOMRAMP_EFI_URL=\n",
            encoding="utf-8",
        )
        result = subprocess.run(
            ["bash", str(apply_config), str(source_config)],
            env={"PATH": "/usr/bin:/bin", "GITHUB_ENV": str(github_env)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode:
            fail(f"local QCOMRAMP source config was rejected: {result.stderr}")
        exported = github_env.read_text(encoding="utf-8")
        if f"QCOMRAMP_EFI<<" not in exported or f"\n{qcomramp}\n" not in exported:
            fail("local QCOMRAMP EFI was not serialized as a literal GITHUB_ENV value")

        fake_bin = root / "bin"
        fake_bin.mkdir()
        capture = root / "builder-env.txt"
        fake_bash = fake_bin / "bash"
        fake_bash.write_text(
            "#!/bin/sh\n"
            ": \"${QCOMRAMP_CAPTURE:?}\"\n"
            "printf '%s\\n' \"${QCOMRAMP_EFI-}\" > \"$QCOMRAMP_CAPTURE\"\n"
            "printf '%s\\n' \"${QCOMRAMP_EFI_URL-}\" >> \"$QCOMRAMP_CAPTURE\"\n",
            encoding="utf-8",
        )
        fake_bash.chmod(0o755)

        # These are the values consumed by the exact workflow shell fragment.
        # The fake builder exits before any image/tool lookup, so no build is run.
        env = {
            "PATH": f"{fake_bin}:/usr/bin:/bin",
            "QCOMRAMP_CAPTURE": str(capture),
            "QCOMRAMP_EFI": str(qcomramp),
            "QCOMRAMP_EFI_URL": "",
            "OUTPUT_DIR_GRUB": str(root / "out"),
            "OUTPUT_PREFIX": "fixture",
            "BOOT_TEMPLATE_IMAGE": "",
            "BOOT_TEMPLATE_IMAGE_URL": "",
            "BOOT_TEMPLATE_IMAGE_SHA256": "",
            "BOOT_IMAGE_SIZE": "256M",
            "BOOT_FAT_BITS": "32",
            "BOOT_FAT_LABEL": "Y700GRUB",
            "BOOT_FAT_VOLUME_ID": "00000000",
            "BOOT_SECTOR_SIZE": "512",
            "BOOT_CLUSTER_SECTORS": "",
            "GRUB_TIMEOUT": "3",
            "KERNEL_ARTIFACT_ARCHIVE": "",
            "KERNEL_ARTIFACT_ARCHIVE_SHA256": "",
            "BOOTAA64_EFI_URL": "",
            "BOOTAA64_EFI_SHA256": "",
            "QCOMRAMP_EFI_SHA256": "",
            "QCOMRAMP_CFG_NAME": "qcomramp.cfg",
            "DTB_NAME": "sm8650-lenovo-tb321fu.dtb",
            "ROOT_SELECTOR": "partlabel",
            "ROOT_PARTLABEL": "userdata",
            "ROOT_UUID": "",
            "ROOTARGS": "",
            "ROOTARGS_EXTRA": "",
            "STABLEARGS": "drm_client_lib.active=none",
            "BOOT_COMPRESS": "none",
            "BOOT_CHUNK_SIZE": "",
            "KEEP_BOOT_IMAGE": "1",
            "Y700_GRUB_BUILD_DIR": "",
        }
        result = subprocess.run(
            ["/bin/bash", "-c", grub_run],
            cwd=root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode:
            fail(f"local QCOMRAMP did not reach the GRUB builder: {result.stderr}")
        if capture.read_text(encoding="utf-8").split("\n") != [str(qcomramp), "", ""]:
            fail("GRUB builder received a different or missing local QCOMRAMP EFI path")


def self_test() -> None:
    before, work = SUDO_HASH_GUARD, FIRST_IMAGE_WORK
    helper = 'make_rootfs_work_dir() {\n  mkdir -p -- "$output"\n}'
    validate_password_before_image_work("\n".join((helper, before, work)), "self-test")
    for case, commands, diagnostic in (
        ("missing guard", [work], "expected exactly one top-level call"),
        ("missing work", [before, helper, "# " + work], "expected exactly one top-level call"),
        ("duplicate guard", [before, before, work], "expected exactly one top-level call"),
        ("duplicate work", [before, work, work], "expected exactly one top-level call"),
        ("late guard", ["# " + before, work, before], "runs after image work"),
    ):
        try:
            validate_password_before_image_work("\n".join(commands), case)
        except SystemExit as exc:
            if diagnostic not in str(exc):
                raise
        else:
            fail(f"self-test accepted {case}")
    tools = "sudo apt-get install -y python3-yaml g++ git openssl shellcheck openssh-client gnupg rsync e2fsprogs dosfstools mtools"
    if not has_validation_tools(tools) or has_validation_tools(tools.replace(" mtools", " # mtools")):
        fail("self-test failed to distinguish an installed FAT reader from a comment")
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
    if not dispatch_input_count_is_supported(dict.fromkeys(range(10))):
        fail("self-test rejected the supported 10-input workflow boundary")
    if dispatch_input_count_is_supported(dict.fromkeys(range(11))):
        fail("self-test accepted a workflow with more than 10 dispatch inputs")
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
    data = load_workflow(workflow)
    validate_structure(workflow, data)
    validate_rootfs_contract(rootfs)
    run_provision_env_fixture(rootfs)
    run_builtin_config_fixtures(workflow, apply_config, data)
    run_hostile_config_fixtures(apply_config)
    run_local_qcomramp_propagation_fixture(workflow, apply_config)
    print("WORKFLOW_SEMANTICS=PASS")


if __name__ == "__main__":
    main()
