#!/usr/bin/env python3
"""Focused producer contracts; full compile/reproduction remains a separate gate."""
import importlib.util
import io
import os
import pathlib
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('runtime_builder_test', HERE / 'build-tb321fu-libcamera-runtime.py')
B = importlib.util.module_from_spec(spec)
spec.loader.exec_module(B)
V = B.contract

class RuntimeTests(unittest.TestCase):
    def test_source_derivation_matches_verified_recipe(self):
        source, expected, directories = V.expected_source()
        self.assertEqual(source['derived_manifest_sha256'],
                         '484eb6692d052ae97a2f1fb9fccf04b91a81fcd837762c41a313403b02345534')
        self.assertEqual(source['version'], '0.7.1+tb321fu.328f60d3a36125a8.p1929149ac62f4abd')
        self.assertEqual(len(expected), 1489)
        self.assertTrue(directories)

    def test_reviewed_runtime_profile(self):
        records, raw = V.overlay.parse_manifest(HERE / 'LIBCAMERA-RUNTIME-REFERENCE.tsv', False)
        self.assertEqual(len(records), 70)
        self.assertEqual(V.manifest_bytes(records), raw)
        V.check_layout(records)
        name = next(iter(V.COMPILED))
        row = records[name]
        changed = dict(records, **{name: (row[0], row[1], row[2] + 1, '0'*64, row[4])})
        V.check_layout(changed)

    def test_layout_rejects_mutations(self):
        records, _ = V.overlay.parse_manifest(HERE / 'LIBCAMERA-RUNTIME-REFERENCE.tsv', False)
        data = V.PREFIX + 'share/libcamera/ipa/simple/gc13a0.yaml'
        compiled = V.LIB + 'libcamera.so.0.7.1'
        mutations = [
            lambda x: x.pop(data),
            lambda x: x.update({'private-key.pem': ('file', 0o644, 10, '0'*64, '-')}),
            lambda x: x.update({compiled: ('symlink', 0o777, 3, '-', 'bad')}),
            lambda x: x.update({compiled: ('file', 0o644, 3, '0'*64, '-')}),
            lambda x: x.update({data: ('file', 0o644, 3, '0'*64, '-')}),
        ]
        for mutate in mutations:
            changed = dict(records)
            mutate(changed)
            with self.assertRaises(RuntimeError):
                V.check_layout(changed)

    def test_cross_file_maps_absolute_and_relative_paths(self):
        text = B.cross_file(pathlib.Path('/private/source-a'), pathlib.Path('/private/build-a'))
        self.assertIn('-ffile-prefix-map=../source-a=/usr/src/tb321fu-libcamera', text)
        self.assertIn('-fmacro-prefix-map=/private/build-a=/usr/src/tb321fu-libcamera/build', text)
        self.assertIn('\n[built-in options]\n', text)
        self.assertNotIn('\\n', text)

    def test_existing_output_rejected_before_build(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(B.environment, 'verify') as verify:
            with self.assertRaises(RuntimeError):
                B.build_runtime(pathlib.Path(directory), 2)
            verify.assert_not_called()

    def test_invalid_job_bounds(self):
        with patch.object(B.environment, 'verify') as verify:
            for jobs in (True, 0, 1, 33, -1):
                with self.assertRaises(RuntimeError):
                    B.build_runtime(pathlib.Path('/unused'), jobs)
            verify.assert_not_called()

    def test_timeout_is_bounded_and_reaped(self):
        B.STOP.clear()
        before = time.monotonic()
        with tempfile.TemporaryFile() as log, self.assertRaisesRegex(RuntimeError, 'timed out'):
            B.run(['/usr/bin/sleep', '30'], {'PATH': '/usr/bin:/bin'}, log, timeout=0.01)
        self.assertLess(time.monotonic() - before, 3)

    def test_real_ipa_signature_and_tamper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            module = root / (V.LIB + 'libcamera/ipa/ipa_soft_simple.so')
            module.parent.mkdir(parents=True)
            module.write_bytes(b'bounded synthetic IPA signature fixture')
            key, public = root / 'private.pem', root / 'public.der'
            subprocess.run(['/usr/bin/openssl', 'genrsa', '-out', str(key), '2048'],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['/usr/bin/openssl', 'pkey', '-in', str(key), '-pubout',
                            '-outform', 'DER', '-out', str(public)], check=True)
            subprocess.run(['/usr/bin/openssl', 'dgst', '-sha256', '-sign', str(key),
                            '-out', str(module) + '.sign', str(module)], check=True)
            V.verify_signature(root, public.read_bytes())
            module.write_bytes(b'tampered module bytes')
            with self.assertRaisesRegex(RuntimeError, 'signature'):
                V.verify_signature(root, public.read_bytes())

if __name__ == '__main__':
    unittest.main()
