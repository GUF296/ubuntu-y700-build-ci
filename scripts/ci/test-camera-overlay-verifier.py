#!/usr/bin/env python3
"""Hostile fixtures for the closed camera overlay manifest."""

from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import sys
import tempfile


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
VERIFIER = SCRIPT_DIR / "verify-camera-overlay.py"
PLUGIN = pathlib.PurePosixPath(
    "usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so"
)


def load_verifier():
    spec = importlib.util.spec_from_file_location("camera_overlay_verifier", VERIFIER)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load camera overlay verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_manifest(root: pathlib.Path, manifest: pathlib.Path) -> None:
    records: list[str] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix().encode()):
        name = path.relative_to(root).as_posix()
        metadata = path.lstat()
        mode = metadata.st_mode & 0o7777
        if path.is_symlink():
            target = os.readlink(path)
            fields = (name, "symlink", f"0{mode:03o}", str(metadata.st_size), "-", target)
        elif path.is_dir():
            fields = (name, "directory", f"0{mode:03o}", "0", "-", "-")
        else:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            fields = (name, "file", f"0{mode:03o}", str(metadata.st_size), digest, "-")
        records.append("\t".join(fields))
    manifest.write_text(
        "path\ttype\tmode\tsize\tsha256\tlink_target\n" + "\n".join(records) + "\n",
        encoding="utf-8",
    )
    manifest.chmod(0o644)


def expect_failure(module, label: str, operation) -> None:
    try:
        operation()
    except (module.ContractError, OSError):
        return
    raise RuntimeError(f"hostile overlay fixture was accepted: {label}")


def main() -> int:
    module = load_verifier()
    with tempfile.TemporaryDirectory(prefix="camera-overlay-test.") as temporary:
        base = pathlib.Path(temporary)
        root = base / "root"
        plugin = root / PLUGIN
        plugin.parent.mkdir(parents=True, mode=0o755)
        plugin.write_bytes(b"old-camera-plugin\n")
        plugin.chmod(0o644)
        config = root / "etc/camera.conf"
        config.parent.mkdir(parents=True, mode=0o755)
        config.write_bytes(b"camera=tb321fu\n")
        config.chmod(0o644)
        library = root / "opt/lib/libcamera.so.1"
        library.parent.mkdir(parents=True, mode=0o755)
        library.write_bytes(b"camera-library\n")
        library.chmod(0o644)
        link = root / "opt/lib/libcamera.so"
        link.symlink_to(library.name)
        root.chmod(0o755)
        manifest = base / "OVERLAY-MANIFEST.tsv"
        write_manifest(root, manifest)

        module.verify(root, manifest, None)

        extra = root / "extra"
        extra.write_bytes(b"extra\n")
        extra.chmod(0o644)
        expect_failure(module, "extra member", lambda: module.verify(root, manifest, None))
        extra.unlink()

        original = config.read_bytes()
        config.write_bytes(b"camera=hostile\n")
        expect_failure(module, "content drift", lambda: module.verify(root, manifest, None))
        config.write_bytes(original)
        config.chmod(0o755)
        expect_failure(module, "mode drift", lambda: module.verify(root, manifest, None))
        config.chmod(0o644)

        link.unlink()
        link.symlink_to("hostile.so")
        expect_failure(module, "symlink retarget", lambda: module.verify(root, manifest, None))
        link.unlink()
        link.symlink_to(library.name)

        hardlink = root / "etc/camera-hardlink.conf"
        os.link(config, hardlink)
        expect_failure(module, "hardlink alias", lambda: module.verify(root, manifest, None))
        hardlink.unlink()

        replacement = base / "new-plugin.so"
        replacement.write_bytes(b"new-camera-plugin\n")
        replacement.chmod(0o755)
        expect_failure(
            module,
            "replacement plugin mode drift",
            lambda: module.verify(root, manifest, replacement),
        )
        plugin.write_bytes(replacement.read_bytes())
        plugin.chmod(0o644)
        replacement.chmod(0o644)
        module.verify(root, manifest, replacement)
        config.write_bytes(b"non-plugin-drift\n")
        expect_failure(
            module,
            "non-plugin drift with plugin override",
            lambda: module.verify(root, manifest, replacement),
        )

    print("CAMERA_OVERLAY_HOSTILE_FIXTURES=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
