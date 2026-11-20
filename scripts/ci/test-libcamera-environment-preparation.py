#!/usr/bin/env python3
"""Read-only plan and CI-only provisioning boundaries; never invoke real APT."""
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('camera_environment_preparation', HERE / 'prepare-libcamera-build-environment.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)

class PreparationTests(unittest.TestCase):
    def test_exact_merged_plan(self):
        result = M.package_plan()
        self.assertEqual(len(result), len(set(result)))
        self.assertEqual(result, sorted(result))
        self.assertIn('libspa-0.2-dev:amd64=1.0.5-1ubuntu3.3', result)
        self.assertTrue(any(x.startswith('libgnutls28-dev:arm64=') for x in result))
        self.assertGreater(len(result), 318)
        self.assertFalse(any(x.startswith('-') or ' ' in x for x in result))

    def test_malformed_or_conflicting_spa_identity(self):
        header = 'kind\tname\tversion\tsha256\n'
        entries = ('package\tdpkg\t0+wrong\t-\n',
                   'package\t--danger\t1\t-\n',
                   'package\texample\t1;touch\t-\n',
                   'package\texample\t1\t-\npackage\texample\t1\t-\n',
                   'malformed\n')
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'TOOLCHAIN.tsv'
            for entry in entries:
                path.write_text(header + entry)
                with self.subTest(entry=entry), self.assertRaises(RuntimeError):
                    M.package_plan(spa_lock=path)

    def test_installer_refuses_local_invocation(self):
        script = HERE / 'install-libcamera-build-environment.sh'
        for arguments in ([], ['--install']):
            result = subprocess.run(['/bin/bash', str(script), *arguments],
                env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'},
                stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(b'usage:' in result.stderr or b'refusing dependency' in result.stderr)

    def test_installer_preserves_failure_policy(self):
        source = (HERE / 'install-libcamera-build-environment.sh').read_text()
        for token in ('--no-remove', '--no-install-recommends', 'Signed-By:',
                      'Dir::Etc::sourcelist=/dev/null', 'Dir::State::lists=',
                      'verify-libcamera-build-environment.py', 'GITHUB_ACTIONS',
                      'RUNNER_ARCH', 'prepare-libcamera-build-environment.py'):
            self.assertIn(token, source)
        self.assertNotIn('--allow-downgrades', source)
        self.assertNotIn('--allow-unauthenticated', source)
        self.assertNotIn('apt-key', source)

    def test_snapshot_and_container_boundaries(self):
        installer = (HERE / 'install-libcamera-build-environment.sh').read_text()
        runner = (HERE / 'camera-producer-container.sh').read_text()
        for token in ('https://snapshot.ubuntu.com/ubuntu/20260913T000000Z/',
                      'Architectures: amd64 arm64', 'Check-Valid-Until: no',
                      'APT::Update::Error-Mode=any', 'sha256sum --strict -c',
                      '61e29c7504f020539b7d6112302b66e8ea5b6da00eb8b685dace384715fb11eb',
                      '17000967a1fae30c8dbb92b2183ec6e245c6d802aacf2c2945a20ee89298b8e9'):
            self.assertIn(token, installer)
        self.assertNotIn('trusted=yes', installer)
        self.assertRegex(runner, r"image='ubuntu@sha256:[0-9a-f]{64}'")
        for token in ('--platform linux/amd64', 'target=$workspace,readonly',
                      'target=/run/tb321fu-camera-inputs,readonly', '--user "$(id -u):$(id -g)"',
                      'bash scripts/ci/install-libcamera-build-environment.sh --install',
                      'bash scripts/ci/build-tb321fu-camera-stack-deb.sh'):
            self.assertIn(token, runner)
        for token in ('--privileged', '/var/run/docker.sock', '--env-file', '--env GITHUB_TOKEN'):
            self.assertNotIn(token, runner)

if __name__ == '__main__':
    unittest.main()
