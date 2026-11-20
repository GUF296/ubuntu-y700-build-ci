#!/usr/bin/env python3
"""Closed-reference and live-query fault gates; never change host packages."""
import copy
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'camera_environment', pathlib.Path(__file__).with_name('verify-libcamera-build-environment.py'))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
REFERENCE = json.loads(M.REFERENCE.read_text())

class EnvironmentTests(unittest.TestCase):
    def test_actual_reference_closes(self):
        packages = M.validate_reference(REFERENCE)
        self.assertEqual(len(packages), 318)

    def test_malformed_field_types_fail_closed(self):
        mutations = [
            lambda x: x.update(reference_policy=[]),
            lambda x: x['packages'][0].update(name=[]),
            lambda x: x['packages'][0].update(architecture={}),
            lambda x: x['packages'][0].update(version=True),
            lambda x: x.update(roots=[[]]),
            lambda x: x['commands'][0].update(path=[]),
            lambda x: x['commands'][0].update(package_owners=[{}]),
            lambda x: x['commands'][0].update(resolved='/usr/bin/../tmp/untrusted'),
            lambda x: x['pkg_config'][0].update(name=[]),
            lambda x: x['dependency_edges'][0].update(to=[]),
            lambda x: x['dependency_edges'][0].update(requirement='bad\nedge'),
        ]
        for mutate in mutations:
            candidate = copy.deepcopy(REFERENCE)
            mutate(candidate)
            with self.subTest(mutation=mutate), self.assertRaises(M.EnvironmentError):
                M.validate_reference(candidate)

    def test_reference_set_mutations_fail(self):
        mutations = [
            lambda x: x['packages'].append(x['packages'][0]),
            lambda x: x['roots'].append(x['roots'][0]),
            lambda x: x['commands'].pop(),
            lambda x: x['commands'].__setitem__(0, x['commands'][1]),
            lambda x: x['pkg_config'].__setitem__(0, x['pkg_config'][1]),
            lambda x: x['dependency_edges'].append(x['dependency_edges'][0]),
            lambda x: x.update(dependency_edges=[]),
            lambda x: x['commands'][0].update(sha256='0'*63),
            lambda x: x['packages'][0].update(architecture='all'),
        ]
        for mutate in mutations:
            candidate = copy.deepcopy(REFERENCE)
            mutate(candidate)
            with self.subTest(mutation=mutate), self.assertRaises(M.EnvironmentError):
                M.validate_reference(candidate)

    def test_duplicate_json_keys_fail(self):
        with self.assertRaises(M.EnvironmentError):
            json.loads('{"x":1,"x":2}', object_pairs_hook=M.unique_object)

    def fake_query(self, *args):
        if args[0] == '/usr/bin/dpkg':
            return 'amd64'
        if args[0] == '/usr/bin/dpkg-query':
            return '\n'.join('\t'.join((p['name'], p['version'], p['architecture'],
                                       'install ok installed')) for p in REFERENCE['packages'])
        module = next(x for x in REFERENCE['pkg_config'] if x['name'] == args[-1])
        return module['version'] if args[1] == '--modversion' else str(pathlib.Path(module['path']).parent)

    def fake_fingerprint(self, path):
        for item in REFERENCE['commands'] + REFERENCE['pkg_config']:
            if item['path'] == path:
                return item.get('resolved', path), item['sha256']
        self.fail('unexpected fingerprint query: ' + path)

    def test_mocked_exact_host_and_drift(self):
        with patch.object(M, 'run', side_effect=self.fake_query), \
             patch.object(M, 'fingerprint', side_effect=self.fake_fingerprint), redirect_stdout(io.StringIO()):
            self.assertEqual(M.verify(), REFERENCE)
        for kind in ('architecture', 'version', 'status', 'missing', 'command', 'pkgconfig'):
            def query(*args):
                value = self.fake_query(*args)
                if args[0] == '/usr/bin/dpkg' and kind == 'architecture':
                    return 'arm64'
                if args[0] == '/usr/bin/dpkg-query':
                    if kind == 'version':
                        value = value.replace(REFERENCE['packages'][0]['version'], '0+wrong', 1)
                    if kind == 'status':
                        value = value.replace('install ok installed', 'install ok unpacked', 1)
                    if kind == 'missing':
                        value = value.split('\n', 1)[1]
                if args[0] == '/usr/bin/pkg-config' and kind == 'pkgconfig':
                    return '/tmp/host-pkgconfig'
                return value
            def fingerprint(path):
                resolved, digest = self.fake_fingerprint(path)
                return resolved, '0'*64 if kind == 'command' else digest
            with self.subTest(kind=kind), patch.object(M, 'run', side_effect=query), \
                 patch.object(M, 'fingerprint', side_effect=fingerprint), self.assertRaises(M.EnvironmentError):
                M.verify()

    def test_world_writable_input_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'tool'
            path.write_bytes(b'not a trusted system input')
            path.chmod(0o666)
            with self.assertRaises(M.EnvironmentError):
                M.fingerprint(str(path))

if __name__ == '__main__':
    unittest.main()
