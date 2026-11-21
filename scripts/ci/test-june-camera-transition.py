"""Exercise the checked-in historical migration shape without carrying June binaries."""
import csv
import hashlib
from pathlib import Path
import runpy
import tempfile


ci = Path(__file__).resolve().parent
validate = runpy.run_path(str(ci / "check-june-camera-transition.py"))["validate"]
with (ci / "payloads/june-camera-transition.tsv").open(encoding="ascii", newline="") as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))
with tempfile.TemporaryDirectory(prefix="june-camera-fixture.") as td:
    daily, camera = Path(td) / "daily", Path(td) / "camera"
    sample = b"fixture June content"
    new_config = b"fixture new config"
    producer = next(r["path"] for r in rows if r["new_policy"] == "producer")
    config = next(r["path"] for r in rows if len(r["new_policy"]) == 64)
    link = next(r for r in rows if r["new_policy"] == "link")
    if sum(r["new_policy"] == "producer" for r in rows) != 8:
        raise AssertionError("review changes to producer-controlled paths explicitly")
    for r in rows:
        rule = r["new_policy"]
        for root, key in ((daily, "old_mode"), (camera, "new_mode")):
            path = root / r["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            if rule == "link":
                path.symlink_to(r["old_sha256_or_target"])
            else:
                path.write_bytes(sample if root == daily or rule == "same" else new_config)
                path.chmod(int(r[key], 8))
        if rule != "link":
            r["old_sha256_or_target"] = hashlib.sha256(sample).hexdigest()
        if len(rule) == 64:
            r["new_policy"] = hashlib.sha256(new_config).hexdigest()
    for directory in (camera, *[p for p in camera.rglob("*") if not p.is_symlink() and p.is_dir()]):
        directory.chmod(0o755)

    def rejects():
        try:
            validate(daily, camera, rows)
        except (ValueError, OSError):
            return
        raise AssertionError("unexpectedly accepted changed migration contract")

    validate(daily, camera, rows)
    (daily / producer).write_bytes(new_config)
    rejects()
    (daily / producer).write_bytes(sample)
    (camera / config).write_bytes(sample)
    rejects()
    (camera / config).write_bytes(new_config)
    (camera / config).chmod(0o755)
    rejects()
    (camera / config).chmod(0o644)
    extra = camera / "extra-directory"
    extra.mkdir()
    rejects()
    extra.rmdir()
    extra.write_bytes(sample)
    rejects()
    extra.unlink()
    path = camera / link["path"]
    path.unlink()
    rejects()
    path.write_bytes(sample)
    rejects()
    path.unlink()
    path.symlink_to("different-target")
    rejects()
    path.unlink()
    path.symlink_to(link["old_sha256_or_target"])
    validate(daily, camera, rows)
print("JUNE_CAMERA_TRANSITION_FIXTURES=PASS")
