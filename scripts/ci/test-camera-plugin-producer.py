#!/usr/bin/env python3
"""Hostile fixtures for the camera SPA producer verifier."""

from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import stat
import sys
import tempfile


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
VERIFIER = SCRIPT_DIR / "verify-camera-plugin-producer.py"
BUILDER = SCRIPT_DIR / "build-tb321fu-camera-stack-deb.sh"
MESON_BUILD = SCRIPT_DIR.parent.parent / "source/tb321fu-camera-rootfs-overlay/source/spa-libcamera-producer/meson.build"
TOOLCHAIN = MESON_BUILD.parent / "TOOLCHAIN.tsv"


def validate_builder_contract(builder: str) -> None:
    for token in (
        "for digest_input in",
        "sha256sum \"$digest_input\" | cut -d ' ' -f 1",
        "done | sha256sum | cut -c 1-40",
        "[[ $camera_link_build_id =~ ^[0-9a-f]{40}$ ]]",
        "pkg-config = '/usr/bin/pkg-config'",
        "-ffile-prefix-map=$work_dir/producer-a=/usr/src/tb321fu-camera-plugin",
        "-ffile-prefix-map=$work_dir/producer-b=/usr/src/tb321fu-camera-plugin",
        "-fdebug-prefix-map=$work_dir/producer-a=/usr/src/tb321fu-camera-plugin",
        "-fdebug-prefix-map=$work_dir/producer-b=/usr/src/tb321fu-camera-plugin",
        "-fmacro-prefix-map=$work_dir/producer-a=/usr/src/tb321fu-camera-plugin",
        "-fmacro-prefix-map=$work_dir/producer-b=/usr/src/tb321fu-camera-plugin",
        "-ffile-prefix-map=$work_dir/build-a=/usr/src/tb321fu-camera-plugin-build",
        "-ffile-prefix-map=$work_dir/build-b=/usr/src/tb321fu-camera-plugin-build",
        "-fdebug-prefix-map=$work_dir/build-a=/usr/src/tb321fu-camera-plugin-build",
        "-fdebug-prefix-map=$work_dir/build-b=/usr/src/tb321fu-camera-plugin-build",
        "-fmacro-prefix-map=$work_dir/build-a=/usr/src/tb321fu-camera-plugin-build",
        "-fmacro-prefix-map=$work_dir/build-b=/usr/src/tb321fu-camera-plugin-build",
        "-ffile-prefix-map=../producer-a=/usr/src/tb321fu-camera-plugin",
        "-ffile-prefix-map=../producer-b=/usr/src/tb321fu-camera-plugin",
        "-fdebug-prefix-map=../producer-a=/usr/src/tb321fu-camera-plugin",
        "-fdebug-prefix-map=../producer-b=/usr/src/tb321fu-camera-plugin",
        "-fmacro-prefix-map=../producer-a=/usr/src/tb321fu-camera-plugin",
        "-fmacro-prefix-map=../producer-b=/usr/src/tb321fu-camera-plugin",
        "cpp_link_args = ['-Wl,--build-id=0x${camera_link_build_id}']",
        "--werror",
        "actual_build_id=$(sed -n",
        "[ \"$actual_build_id\" = \"$camera_link_build_id\" ]",
        "cmp -s -- \"$camera_built_plugin\" \"$camera_second_plugin\"",
        'aarch64-linux-gnu-strings "$plugin" "$cam" "$soft_ipa" "$soft_proxy" "$gst_plugin"',
        'aarch64-linux-gnu-strings -a "$plugin"',
    ):
        if token not in builder:
            raise RuntimeError(f"camera builder contract is missing: {token}")
    if "pkgconfig =" in builder or "--build-id=sha1" in builder:
        raise RuntimeError("camera builder retains a path-sensitive/deprecated link contract")
    for line in builder.splitlines():
        command = line.lstrip()
        if command.startswith("strings ") or command.startswith("if strings "):
            raise RuntimeError("camera builder uses the unlocked host strings command")


def validate_meson_contract(meson_build: str) -> None:
    for token in (
        "link_args : [",
        "'-L' + libcamera_lib_dir",
        "'-l:libcamera.so'",
        "'-l:libcamera-base.so'",
        "link_args : ['-Wl,-z,nodelete']",
    ):
        if token not in meson_build:
            raise RuntimeError(f"camera Meson contract is missing: {token}")
    if "find_library('camera'" in meson_build or "find_library('camera-base'" in meson_build:
        raise RuntimeError("camera Meson contract still resolves staging libraries by absolute path")


def validate_meson_mutations(meson_build: str) -> None:
    mutations = {
        "absolute camera library lookup": meson_build.replace(
            "'-l:libcamera.so'", "cpp.find_library('camera', dirs : libcamera_lib_dir)", 1
        ),
        "camera-base link removed": meson_build.replace("      '-l:libcamera-base.so',\n", "", 1),
    }
    for label, mutation in mutations.items():
        if mutation == meson_build:
            raise RuntimeError(f"camera Meson mutation anchor disappeared: {label}")
        try:
            validate_meson_contract(mutation)
        except RuntimeError:
            continue
        raise RuntimeError(f"camera Meson contract accepted mutation: {label}")


def validate_builder_mutations(builder: str) -> None:
    mutations = {
        "implicit path-sensitive build-id": builder.replace(
            "-Wl,--build-id=0x${camera_link_build_id}", "-Wl,--build-id=sha1", 1
        ),
        "path-bearing build-id input": builder.replace(
            "sha256sum \"$digest_input\" | cut -d ' ' -f 1",
            "sha256sum \"$digest_input\"",
            1,
        ),
        "build-id verification bypass": builder.replace(
            "[ \"$actual_build_id\" = \"$camera_link_build_id\" ]",
            "[ -n \"$actual_build_id\" ]",
            1,
        ),
        "compiler warnings accepted": builder.replace("--werror", "--warnlevel=3", 1),
        "producer path mapping removed": builder.replace(
            '      "-ffile-prefix-map=$work_dir/producer-b=/usr/src/tb321fu-camera-plugin" \\\n',
            "",
            1,
        ),
        "relative producer path mapping removed": builder.replace(
            '      "-fmacro-prefix-map=../producer-b=/usr/src/tb321fu-camera-plugin" \\\n',
            "",
            1,
        ),
        "locked target strings replaced by host command": builder.replace(
            'aarch64-linux-gnu-strings -a "$plugin"',
            'strings -a "$plugin"',
            1,
        ),
    }
    for label, mutation in mutations.items():
        if mutation == builder:
            raise RuntimeError(f"camera builder mutation anchor disappeared: {label}")
        try:
            validate_builder_contract(mutation)
        except RuntimeError:
            continue
        raise RuntimeError(f"camera builder contract accepted mutation: {label}")


def load_verifier():
    spec = importlib.util.spec_from_file_location("camera_plugin_producer_verifier", VERIFIER)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load camera producer verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def expect_failure(module, label: str, operation) -> None:
    try:
        operation()
    except (module.ContractError, OSError):
        return
    raise RuntimeError(f"hostile producer fixture was accepted: {label}")


def main() -> int:
    builder = BUILDER.read_text(encoding="utf-8")
    meson_build = MESON_BUILD.read_text(encoding="utf-8")
    validate_builder_contract(builder)
    validate_builder_mutations(builder)
    validate_meson_contract(meson_build)
    validate_meson_mutations(meson_build)
    module = load_verifier()
    toolchain_text = TOOLCHAIN.read_text(encoding="utf-8")
    uid = os.getuid()
    gid = os.getgid()
    with tempfile.TemporaryDirectory(prefix="camera-producer-test.") as temporary:
        base = pathlib.Path(temporary)
        incomplete_toolchain = base / "TOOLCHAIN.tsv"
        missing_command = (
            "command\t/usr/bin/aarch64-linux-gnu-strings\t2.42\t"
            "680fafea052b7e54bee2d8caef7a45fbbd2381a221d59c10e848608d16810dd6\n"
        )
        if toolchain_text.count(missing_command) != 1:
            raise RuntimeError("camera toolchain mutation anchor disappeared")
        incomplete_toolchain.write_text(
            toolchain_text.replace(missing_command, "", 1), encoding="utf-8"
        )
        incomplete_toolchain.chmod(0o644)
        expect_failure(
            module,
            "required toolchain command omitted",
            lambda: module.parse_toolchain(incomplete_toolchain),
        )

        tools = base / "tools"
        tools.mkdir(mode=0o755)
        target_a = tools / "tool-a"
        target_b = tools / "tool-b"
        target_a.write_bytes(b"camera-tool-a\n")
        target_b.write_bytes(b"camera-tool-b\n")
        target_a.chmod(0o755)
        target_b.chmod(0o755)
        alias = tools / "tool"
        alias.symlink_to(target_a.name)
        digest_a = hashlib.sha256(target_a.read_bytes()).hexdigest()

        module.verify_command_identity(
            alias,
            digest_a,
            "1.0",
            expected_uid=uid,
            expected_gid=gid,
            required_parent=tools,
            version_probe=lambda _: "camera-tool 1.0",
        )

        def retarget_probe(_: str) -> str:
            alias.unlink()
            alias.symlink_to(target_b.name)
            return "camera-tool 1.0"

        expect_failure(
            module,
            "symlink retarget during version probe",
            lambda: module.verify_command_identity(
                alias,
                digest_a,
                "1.0",
                expected_uid=uid,
                expected_gid=gid,
                required_parent=tools,
                version_probe=retarget_probe,
            ),
        )
        alias.unlink()
        alias.symlink_to(target_a.name)

        def mutate_probe(_: str) -> str:
            target_a.write_bytes(b"camera-tool-z\n")
            target_a.chmod(0o755)
            return "camera-tool 1.0"

        expect_failure(
            module,
            "command content mutation during version probe",
            lambda: module.verify_command_identity(
                alias,
                digest_a,
                "1.0",
                expected_uid=uid,
                expected_gid=gid,
                required_parent=tools,
                version_probe=mutate_probe,
            ),
        )
        target_a.write_bytes(b"camera-tool-a\n")
        target_a.chmod(0o755)

        outside = base / "outside"
        outside.write_bytes(target_a.read_bytes())
        outside.chmod(0o755)
        alias.unlink()
        alias.symlink_to("../outside")
        expect_failure(
            module,
            "symlink target escapes locked directory",
            lambda: module.verify_command_identity(
                alias,
                digest_a,
                "1.0",
                expected_uid=uid,
                expected_gid=gid,
                required_parent=tools,
                version_probe=lambda _: "camera-tool 1.0",
            ),
        )

        producer = base / "producer"
        producer.mkdir(mode=0o755)
        producer_link = base / "producer-link"
        producer_link.symlink_to(producer.name)
        expect_failure(
            module,
            "symlink producer root",
            lambda: module.validate_producer_root(producer_link),
        )

        parent = base / "parent"
        parent.mkdir(mode=0o755)
        nested = parent / "nested"
        nested.mkdir(mode=0o755)
        parent_link = base / "parent-link"
        parent_link.symlink_to(parent.name)
        expect_failure(
            module,
            "producer root through symlink parent",
            lambda: module.validate_producer_root(parent_link / nested.name),
        )

        alias.unlink(missing_ok=True)
        target_a.chmod(0o775)
        alias.symlink_to(target_a.name)
        expect_failure(
            module,
            "writable command target",
            lambda: module.verify_command_identity(
                alias,
                digest_a,
                "1.0",
                expected_uid=uid,
                expected_gid=gid,
                required_parent=tools,
                version_probe=lambda _: "camera-tool 1.0",
            ),
        )

    print("CAMERA_PRODUCER_HOSTILE_FIXTURES=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
