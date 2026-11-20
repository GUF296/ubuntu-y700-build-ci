#!/usr/bin/env python3
"""Apply the explicit TB321FU build policy to a verified private source tree.

The canonical source archive is not modified. This derived build source gains
an optional external IPA key for same-input rebuilds, and an optional forced
isolation policy. Both upstream defaults are preserved unless the producer
selects those options. A receipt binds every changed source byte.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "libcamera_materializer_for_adapter", SCRIPT_DIR / "materialize-libcamera-source.py"
)
assert spec is not None and spec.loader is not None
consumer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = consumer
spec.loader.exec_module(consumer)

OPTIONS = """
# TB321FU producer: keep signing integrity separate from IPA execution policy.
option('ipa-signing-key',
       type : 'string',
       value : '',
       description : 'Existing build-private IPA signing key; empty generates a key')

option('ipa-force-isolation',
       type : 'boolean',
       value : false,
       description : 'Force isolated IPA execution even for valid signed modules')
"""
KEY_BLOCK = """    ipa_signing_key = get_option('ipa-signing-key')
    if ipa_signing_key != ''
        ipa_priv_key = custom_target('ipa-priv-key',
                                     input : files(ipa_signing_key),
                                     output : ['ipa-priv-key.pem'],
                                     command : ['/usr/bin/install', '-m', '0600', '@INPUT@', '@OUTPUT@'])
    else
        ipa_priv_key = custom_target('ipa-priv-key',
                                     output : ['ipa-priv-key.pem'],
                                     command : [gen_ipa_priv_key, '@OUTPUT@'])
    endif"""

def sha(data):
    return hashlib.sha256(data).hexdigest()

def derive(original: dict[str, bytes], version: str, adapter_digest: str):
    changed = {}
    src = original['src/meson.build'].decode('utf-8')
    key_pattern = (r"    ipa_priv_key = custom_target\('ipa-priv-key',\n"
                   r"[ \t]*output : \['ipa-priv-key.pem'\],\n"
                   r"[ \t]*command : \[gen_ipa_priv_key, '@OUTPUT@'\]\)")
    src, count = re.subn(key_pattern, lambda _match: KEY_BLOCK, src)
    if count != 1:
        raise RuntimeError('IPA key-generation source anchor is not unique')
    marker = '# libyuv, used by the Android adaptation layer and the virtual pipeline handler.'
    if src.count(marker) != 1:
        raise RuntimeError('IPA signing section boundary changed')
    src = src.replace(marker,
                      "config_h.set10('IPA_FORCE_ISOLATION', get_option('ipa-force-isolation'))\n\n"
                      + marker, 1)
    changed['src/meson.build'] = src.encode()
    options = original['meson_options.txt'].decode('utf-8')
    if 'ipa-signing-key' in options or 'ipa-force-isolation' in options:
        raise RuntimeError('IPA build options already exist')
    changed['meson_options.txt'] = (options.rstrip() + '\n' + OPTIONS).encode()
    manager = original['src/libcamera/ipa_manager.cpp'].decode('utf-8')
    force_pattern = (r'forceIsolation_ = configuration\.option<bool>\(\{ "ipa", "force_isolation" \}\)'
                     r'\s*\.value_or\(false\);')
    manager, count = re.subn(
        force_pattern,
        'forceIsolation_ = IPA_FORCE_ISOLATION ||\n'
        '\t\tconfiguration.option<bool>({ "ipa", "force_isolation" }).value_or(false);',
        manager,
    )
    if count != 1:
        raise RuntimeError('IPA isolation source anchor is not unique')
    changed['src/libcamera/ipa_manager.cpp'] = manager.encode()
    if original['.tarball-version'] != (version + '\n').encode():
        raise RuntimeError('source version changed before build adaptation')
    derived_version = version + '.p' + adapter_digest[:16]
    changed['.tarball-version'] = (derived_version + '\n').encode()
    return changed, derived_version

def write_source(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix='.tb321fu-adapt.', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def adapt(source: pathlib.Path, receipt: pathlib.Path):
    source = source.resolve(strict=True)
    receipt = receipt.absolute()
    receipt = receipt.parent.resolve(strict=True) / receipt.name
    if ((source / '.git').exists() or (source / '.git').is_symlink()
            or receipt.is_relative_to(source) or receipt.exists() or receipt.is_symlink()):
        raise RuntimeError('adapt only a private unpacked tree with an unused external receipt path')
    lock, entries, directories = consumer.validate_profile(consumer.snapshot_profile(consumer.PROFILE))
    consumer.verify_tree(source, entries, directories)
    paths = ('src/meson.build', 'meson_options.txt',
             'src/libcamera/ipa_manager.cpp', '.tarball-version')
    original = {name: (source / name).read_bytes() for name in paths}
    for name, data in original.items():
        if sha(data) != entries[name][3]:
            raise RuntimeError('source changed before adaptation: ' + name)
    adapter_digest = sha(pathlib.Path(__file__).read_bytes())
    changed, version = derive(original, lock['version'], adapter_digest)
    expected = dict(entries)
    for name, data in changed.items():
        expected[name] = ('file', 0o644, len(data), sha(data), '-')
    for name, data in changed.items():
        if (source / name).read_bytes() != original[name]:
            raise RuntimeError('private build source was modified concurrently')
        write_source(source / name, data)
    consumer.verify_tree(source, expected, directories)
    lines = [consumer.HEADER]
    for name, row in expected.items():
        lines.append(chr(9).join((name, row[0], f'0{row[1]:o}', str(row[2]), row[3], row[4])))
    derived_manifest = (chr(10).join(lines) + chr(10)).encode()
    value = {
        'schema': 'tb321fu-libcamera-build-adapter-v1',
        'source_archive_sha256': lock['archive_sha256'],
        'input_manifest_sha256': lock['manifest_sha256'],
        'adapter_sha256': adapter_digest, 'version': version,
        'derived_manifest_sha256': sha(derived_manifest),
        'changes': [{'path': name, 'old_sha256': sha(original[name]),
                     'new_sha256': sha(data), 'bytes': len(data)}
                    for name, data in changed.items()],
    }
    with receipt.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(value, sort_keys=True, indent=2) + chr(10))
    return value

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=pathlib.Path)
    parser.add_argument('--receipt', required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    print(json.dumps(adapt(arguments.source_root, arguments.receipt), sort_keys=True))
    print('LIBCAMERA_BUILD_ADAPTER=PASS')

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, consumer.SourceError, consumer.exporter.ExportError) as error:
        raise SystemExit('LIBCAMERA_BUILD_ADAPTER=FAIL: ' + str(error))
