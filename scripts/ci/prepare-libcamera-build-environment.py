#!/usr/bin/env python3
"""Emit the exact combined libcamera/SPA package plan without changing the host."""
import importlib.util
import json
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('camera_environment_plan', HERE / 'verify-libcamera-build-environment.py')
environment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(environment)
SPA_LOCK = HERE.parent.parent / 'source/tb321fu-camera-rootfs-overlay/source/spa-libcamera-producer/TOOLCHAIN.tsv'

def package_plan(reference=environment.REFERENCE, spa_lock=SPA_LOCK):
    value = json.loads(reference.read_text(), object_pairs_hook=environment.unique_object)
    packages = environment.validate_reference(value)
    wanted = {name: entry['version'] for name, entry in packages.items()}
    lines = spa_lock.read_text().splitlines()
    if not lines or lines[0] != 'kind\tname\tversion\tsha256':
        raise RuntimeError('SPA toolchain lock header mismatch')
    seen = set()
    for line in lines[1:]:
        fields = line.split('\t')
        if len(fields) != 4:
            raise RuntimeError('malformed SPA toolchain lock')
        kind, name, version, _digest = fields
        if kind != 'package':
            continue
        if (not environment.package_name(name)
                or not re.fullmatch(r'[0-9][A-Za-z0-9.+:~_-]{0,255}', version) or name in seen):
            raise RuntimeError('invalid duplicate SPA package identity')
        seen.add(name)
        matches = [key for key in wanted if key == name or key == name + ':amd64']
        if len(matches) > 1:
            raise RuntimeError('ambiguous SPA package architecture')
        canonical = matches[0] if matches else name
        if canonical in wanted and wanted[canonical] != version:
            raise RuntimeError('runtime/SPA package version conflict: ' + name)
        wanted[canonical] = version
    if not seen:
        raise RuntimeError('SPA package plan is empty')
    return [name + '=' + version for name, version in sorted(wanted.items())]

if __name__ == '__main__':
    try:
        print('\n'.join(package_plan()))
    except (RuntimeError, OSError, ValueError) as error:
        raise SystemExit('LIBCAMERA_ENVIRONMENT_PLAN=FAIL: ' + str(error))
