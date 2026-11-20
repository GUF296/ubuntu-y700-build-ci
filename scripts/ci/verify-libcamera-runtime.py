#!/usr/bin/env python3
"""Authenticate a closed runtime from the repository's trusted build process.

Provenance is an auditable input/output binding, not a remote attestation or
proof against a malicious compiler/administrator. Hardware acceptance is separate.
"""
from __future__ import annotations
import argparse
import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tarfile
import io
import tempfile

HERE = pathlib.Path(__file__).resolve().parent

def load(name):
    spec = importlib.util.spec_from_file_location('runtime_' + name.replace('-', '_'), HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

overlay = load('verify-camera-overlay')
adapter = load('adapt-libcamera-build')
consumer = adapter.consumer
PREFIX = 'opt/libcamera-y700/'
LIB = PREFIX + 'lib/aarch64-linux-gnu/'
COMPILED = frozenset({PREFIX + 'bin/cam', LIB + 'libcamera-base.so.0.7.1',
    LIB + 'libcamera.so.0.7.1', LIB + 'libcamera/ipa/ipa_soft_simple.so',
    LIB + 'libcamera/ipa/ipa_soft_simple.so.sign',
    PREFIX + 'libexec/libcamera/soft_ipa_proxy', LIB + 'gstreamer-1.0/libgstlibcamera.so'})
INPUTS = ('build-tb321fu-libcamera-runtime.py', 'verify-libcamera-runtime.py',
          'verify-camera-overlay.py', 'verify-libcamera-build-environment.py',
          'LIBCAMERA-BUILD-ENVIRONMENT.json', 'LIBCAMERA-RUNTIME-REFERENCE.tsv',
          'materialize-libcamera-source.py', 'export-libcamera-source.py',
          'safe-extract-archive.py', 'adapt-libcamera-build.py',
          'libcamera-aarch64.cross', 'test-libcamera-ipa-isolation.py')
OPTIONS = ('--prefix=/opt/libcamera-y700', '--libdir=lib/aarch64-linux-gnu',
    '--buildtype=debugoptimized', '--wrap-mode=nodownload', '-Dpipelines=simple',
    '-Dipas=simple', '-Dcam=enabled', '-Dqcam=disabled', '-Dgstreamer=enabled',
    '-Dv4l2=disabled', '-Dtest=false', '-Dlc-compliance=disabled',
    '-Ddocumentation=disabled', '-Dtracing=disabled', '-Dpycamera=disabled',
    '-Dcam-jpeg=disabled', '-Dcam-output-kms=disabled', '-Dcam-output-sdl2=disabled',
    '-Dsoftisp-gpu=enabled', '-Dapps-output-dng=disabled', '-Dipa-force-isolation=true')

def fail(message):
    raise RuntimeError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def read_regular(path, limit=2 << 20):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_mode & 0o022 or not 0 < before.st_size <= limit):
            fail('unsafe or oversized input: ' + str(path))
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        if (len(data) != before.st_size or overlay.stat_identity(before) != overlay.stat_identity(after)
                or overlay.stat_identity(path.lstat()) != overlay.stat_identity(after)):
            fail('input changed while reading: ' + str(path))
    return data

def input_digests():
    return {name: sha(read_regular(HERE / name)) for name in INPUTS}

def manifest_bytes(records):
    lines = [consumer.HEADER]
    for name, row in sorted(records.items()):
        lines.append(chr(9).join((name, row[0], f'0{row[1]:o}', str(row[2]), row[3], row[4])))
    return (chr(10).join(lines) + chr(10)).encode()

def expected_source():
    profile = consumer.snapshot_profile(consumer.PROFILE)
    lock, entries, directories = consumer.validate_profile(profile)
    names = ('src/meson.build', 'meson_options.txt', 'src/libcamera/ipa_manager.cpp', '.tarball-version')
    with tarfile.open(fileobj=io.BytesIO(profile['libcamera-source.tar.xz']), mode='r:xz') as archive:
        original = {name: archive.extractfile('libcamera/' + name).read() for name in names}
    adapter_digest = sha(read_regular(HERE / 'adapt-libcamera-build.py'))
    changed, version = adapter.derive(original, lock['version'], adapter_digest)
    expected = dict(entries)
    for name, data in changed.items():
        expected[name] = ('file', 0o644, len(data), sha(data), '-')
    source = {'lock_sha256': sha(profile['SOURCE-LOCK.json']),
              'archive_sha256': lock['archive_sha256'],
              'manifest_sha256': lock['manifest_sha256'],
              'tree_sha256': lock['source_tree_sha256'],
              'epoch': lock['source_epoch'], 'version': version,
              'derived_manifest_sha256': sha(manifest_bytes(expected))}
    return source, expected, directories

def check_layout(records):
    reference, _ = overlay.parse_manifest(HERE / 'LIBCAMERA-RUNTIME-REFERENCE.tsv', require_plugin=False)
    if records.keys() != reference.keys() or not COMPILED <= records.keys():
        fail('runtime membership differs from the reviewed complete profile')
    for name, expected in reference.items():
        record = records[name]
        if name in COMPILED:
            if (record[0:2] != expected[0:2] or record[0] != 'file'
                    or record[2] <= 0 or record[4] != '-'):
                fail('compiled runtime member metadata mismatch: ' + name)
        elif record != expected:
            fail('unchanged header/data/link differs from reference: ' + name)

def verify_signature(runtime, public_der):
    with tempfile.TemporaryDirectory(prefix='tb321fu-libcamera-signature-') as directory:
        public = pathlib.Path(directory) / 'public.der'
        public.write_bytes(public_der)
        result = subprocess.run(['/usr/bin/openssl', 'dgst', '-sha256', '-keyform', 'DER',
            '-verify', str(public), '-signature', str(runtime / (LIB + 'libcamera/ipa/ipa_soft_simple.so.sign')),
            str(runtime / (LIB + 'libcamera/ipa/ipa_soft_simple.so'))],
            env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=30, check=False)
        if result.returncode != 0 or result.stdout.strip() != b'Verified OK':
            fail('runtime IPA signature does not authenticate with its recorded public key')

def verify(output_root: pathlib.Path):
    root = overlay.validate_root(output_root)
    if set(os.listdir(root)) != {'runtime', 'RUNTIME-MANIFEST.tsv', 'BUILD-PROVENANCE.json'}:
        fail('runtime output is not the closed publication set')
    runtime = overlay.validate_root(root / 'runtime')
    records, manifest = overlay.parse_manifest(root / 'RUNTIME-MANIFEST.tsv', require_plugin=False)
    if manifest != manifest_bytes(records):
        fail('runtime manifest framing is not canonical')
    actual, _ = overlay.inspect_tree(runtime)
    if records != actual:
        fail('runtime bytes or metadata differ from its manifest')
    check_layout(records)
    source, _expected, _directories = expected_source()
    value = json.loads(read_regular(root / 'BUILD-PROVENANCE.json').decode(), object_pairs_hook=consumer.unique_object)
    fields = {'schema', 'source', 'inputs', 'options', 'runtime_manifest_sha256',
              'replica_manifests', 'public_key_der_base64', 'public_key_sha256'}
    if (not isinstance(value, dict) or set(value) != fields
            or value['schema'] != 'tb321fu-libcamera-runtime-v1'
            or value['source'] != source or value['inputs'] != input_digests()
            or value['options'] != list(OPTIONS)
            or value['runtime_manifest_sha256'] != sha(manifest)
            or value['replica_manifests'] != [sha(manifest), sha(manifest)]):
        fail('runtime provenance does not bind the current source/producer/paired outputs')
    encoded = value['public_key_der_base64']
    if not isinstance(encoded, str) or not 200 <= len(encoded) <= 1024:
        fail('invalid public key framing')
    public_der = base64.b64decode(encoded, validate=True)
    if sha(public_der) != value['public_key_sha256']:
        fail('public key digest mismatch')
    verify_signature(runtime, public_der)
    # Re-read output after external validation; report no success on byte drift.
    if overlay.inspect_tree(runtime)[0] != records:
        fail('runtime changed during validation')
    return records

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output_root', type=pathlib.Path)
    try:
        records = verify(parser.parse_args().output_root)
        print('LIBCAMERA_RUNTIME_VERIFY=PASS members=' + str(len(records)))
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('LIBCAMERA_RUNTIME_VERIFY=FAIL: ' + str(error))
