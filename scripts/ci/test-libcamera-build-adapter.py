#!/usr/bin/env python3
"""Check the explicit build-only adapter and its source identity receipt."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('libcamera_build_adapter', SCRIPT_DIR / 'adapt-libcamera-build.py')
assert spec is not None and spec.loader is not None
adapter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = adapter
spec.loader.exec_module(adapter)

class BuildAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tb321fu-libcamera-adapter-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.source = self.root / 'source'
        self.lock = adapter.consumer.materialize(adapter.consumer.PROFILE, self.source)
        self.receipt = self.root / 'BUILD-INPUTS.json'
        self.paths = ('src/meson.build', 'meson_options.txt',
                      'src/libcamera/ipa_manager.cpp', '.tarball-version')
        self.original = {name: (self.source / name).read_bytes() for name in self.paths}

    def test_derivation_is_deterministic_and_preserves_defaults(self):
        first = adapter.derive(self.original, self.lock['version'], 'a' * 64)
        second = adapter.derive(self.original, self.lock['version'], 'a' * 64)
        self.assertEqual(first, second)
        changed, version = first
        self.assertEqual(set(changed), set(self.paths))
        self.assertIn(b"value : ''", changed['meson_options.txt'])
        self.assertIn(b'value : false', changed['meson_options.txt'])
        self.assertIn(b"input : files(ipa_signing_key)", changed['src/meson.build'])
        self.assertIn(b"'/usr/bin/install', '-m', '0600'", changed['src/meson.build'])
        self.assertIn(b"config_h.set10('IPA_FORCE_ISOLATION'", changed['src/meson.build'])
        self.assertIn(b'forceIsolation_ = IPA_FORCE_ISOLATION ||', changed['src/libcamera/ipa_manager.cpp'])
        self.assertEqual(version, self.lock['version'] + '.p' + 'a' * 16)
        self.assertEqual(changed['.tarball-version'], (version + chr(10)).encode())

    def test_receipt_binds_each_changed_byte(self):
        result = adapter.adapt(self.source, self.receipt)
        self.assertEqual(result, json.loads(self.receipt.read_text()))
        self.assertEqual({item['path'] for item in result['changes']}, set(self.paths))
        for item in result['changes']:
            self.assertEqual(item['old_sha256'], hashlib.sha256(self.original[item['path']]).hexdigest())
            actual = (self.source / item['path']).read_bytes()
            self.assertEqual(item['new_sha256'], hashlib.sha256(actual).hexdigest())
            self.assertEqual(item['bytes'], len(actual))
        self.assertFalse(list(self.source.rglob('.tb321fu-adapt.*')))
        with self.assertRaises((RuntimeError, adapter.consumer.SourceError, adapter.consumer.exporter.ExportError)):
            adapter.adapt(self.source, self.root / 'SECOND.json')

    def test_existing_receipt_and_git_tree_are_rejected_before_writes(self):
        self.receipt.write_text('preserve')
        with self.assertRaises(RuntimeError):
            adapter.adapt(self.source, self.receipt)
        self.assertEqual(self.receipt.read_text(), 'preserve')
        self.receipt.unlink()
        (self.source / '.git').mkdir()
        with self.assertRaises(RuntimeError):
            adapter.adapt(self.source, self.receipt)
        for name, value in self.original.items():
            self.assertEqual((self.source / name).read_bytes(), value)

    def test_source_drift_and_changed_anchors_are_rejected(self):
        damaged = dict(self.original)
        damaged['src/meson.build'] = damaged['src/meson.build'].replace(b"custom_target('ipa-priv-key'", b"custom_target('changed-key'")
        with self.assertRaises(RuntimeError):
            adapter.derive(damaged, self.lock['version'], 'b' * 64)
        (self.source / 'meson_options.txt').write_text('unexpected source change')
        with self.assertRaises((RuntimeError, adapter.consumer.SourceError, adapter.consumer.exporter.ExportError)):
            adapter.adapt(self.source, self.receipt)
        self.assertFalse(self.receipt.exists())
        for name in self.paths:
            if name != 'meson_options.txt':
                self.assertEqual((self.source / name).read_bytes(), self.original[name])

if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BuildAdapterTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    print('LIBCAMERA_BUILD_ADAPTER_FIXTURES=PASS')
