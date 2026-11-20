#!/usr/bin/env python3
"""Build the complete paired TB321FU runtime without publishing private inputs."""
from __future__ import annotations
import argparse
import base64
import concurrent.futures
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import importlib.util
import sys

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('tb321fu_runtime_contract', HERE / 'verify-libcamera-runtime.py')
contract = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = contract
spec.loader.exec_module(contract)
environment = contract.load('verify-libcamera-build-environment')
STOP = threading.Event()

def run(arguments, env, log, timeout=180):
    if STOP.is_set():
        raise RuntimeError('runtime build cancelled')
    process = subprocess.Popen([str(x) for x in arguments], env=env, stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + timeout
    reaped = False
    try:
        while True:
            try:
                status = process.wait(timeout=0.2)
                reaped = True
                if status:
                    raise RuntimeError('runtime build command failed: ' + str(arguments[0]) + ' rc=' + str(status))
                return
            except subprocess.TimeoutExpired:
                if STOP.is_set() or time.monotonic() >= deadline:
                    raise RuntimeError('runtime build cancelled or timed out: ' + str(arguments[0]))
    finally:
        if not reaped:
            # This group was created here and the unreaped child still owns its
            # PID. No arbitrary discovered PID/process-group is signalled.
            try:
                # All writes are private disposable build state. Kill the
                # group before reaping its leader, including TERM-resistant
                # descendants, rather than waiting on a now-reusable PGID.
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            except ProcessLookupError:
                process.wait(timeout=5)

def clean_environment(work, label, epoch):
    home, temporary = work / ('home-' + label), work / ('tmp-' + label)
    home.mkdir(mode=0o700)
    temporary.mkdir(mode=0o700)
    return {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'TMPDIR': str(temporary),
            'LC_ALL': 'C', 'LANG': 'C', 'TZ': 'UTC', 'SOURCE_DATE_EPOCH': str(epoch),
            'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONNOUSERSITE': '1'}

def cross_file(source, build):
    flags = []
    for original, canonical in ((str(source), '/usr/src/tb321fu-libcamera'),
                                (str(build), '/usr/src/tb321fu-libcamera/build'),
                                (os.path.relpath(source, build), '/usr/src/tb321fu-libcamera')):
        for kind in ('file', 'debug', 'macro'):
            flags.append('-f' + kind + '-prefix-map=' + original + '=' + canonical)
    return ((HERE / 'libcamera-aarch64.cross').read_text() + '\n[built-in options]\n'
            + 'c_args = ' + repr(flags) + '\ncpp_args = ' + repr(flags) + '\n')

def replica(work, label, jobs, source_contract, expected, directories):
    source, build, runtime = (work / (x + '-' + label) for x in ('source', 'build', 'runtime'))
    env = clean_environment(work, label, source_contract['epoch'])
    logfile = work / ('replica-' + label + '.log')
    with logfile.open('wb') as log:
        try:
            run(['/usr/bin/python3', '-I', '-B', HERE / 'materialize-libcamera-source.py',
                 '--output', source], env, log)
            receipt = work / ('adapter-' + label + '.json')
            run(['/usr/bin/python3', '-I', '-B', HERE / 'adapt-libcamera-build.py',
                 '--source-root', source, '--receipt', receipt], env, log)
            adapted = json.loads(receipt.read_text())
            if (adapted['derived_manifest_sha256'] != source_contract['derived_manifest_sha256']
                    or adapted['version'] != source_contract['version']):
                raise RuntimeError('adapter receipt differs from expected source identity')
            cross = work / ('cross-' + label + '.ini')
            cross.write_text(cross_file(source, build))
            run(['/usr/bin/meson', 'setup', build, source, '--cross-file', cross,
                 *contract.OPTIONS, '-Dipa-signing-key=' + str(work / 'ipa-private.pem')], env, log)
            run(['/usr/bin/ninja', '-C', build, '-j' + str(jobs)], env, log, timeout=1800)
            runtime.mkdir(mode=0o755)
            run(['/usr/bin/meson', 'install', '-C', build, '--no-rebuild',
                 '--destdir', runtime, '--strip'], env, log)
            run(['/usr/bin/python3', '-I', '-B', HERE / 'test-libcamera-ipa-isolation.py',
                 '--source-root', source, '--build-root', build,
                 '--runtime-root', runtime, '--forced-build'], env, log)
            contract.consumer.verify_tree(source, expected, directories)
            records, _ = contract.overlay.inspect_tree(runtime)
            contract.check_layout(records)
            print('LIBCAMERA_REPLICA_' + label.upper() + '=PASS', flush=True)
            return records
        except BaseException:
            STOP.set()
            log.flush()
            # Logs never contain the signing input contents; retain only a
            # bounded diagnostic tail in the caller log before scratch cleanup.
            tail = logfile.read_bytes()[-16000:].decode('utf-8', errors='replace')
            print('Replica ' + label + ' diagnostic tail:\n' + tail, file=sys.stderr, flush=True)
            raise

def build_runtime(output, jobs):
    if type(jobs) is not int or not 2 <= jobs <= 32:
        raise RuntimeError('jobs must be between 2 and 32 (shared by both replicas)')
    output = output.absolute()
    output = output.parent.resolve(strict=True) / output.name
    if output.exists() or output.is_symlink():
        raise RuntimeError('runtime output already exists; it will not be overwritten')
    if output.is_relative_to(HERE.parent.parent):
        # An out directory is permitted, but never a source or script subtree.
        if not output.is_relative_to(HERE.parent.parent / 'out'):
            raise RuntimeError('runtime output must be outside repository inputs')
    STOP.clear()
    inputs = contract.input_digests()
    environment.verify()
    source_contract, expected, directories = contract.expected_source()
    with tempfile.TemporaryDirectory(prefix='.tb321fu-libcamera-build-', dir=output.parent) as temporary:
        work = pathlib.Path(temporary)
        env = clean_environment(work, 'key', source_contract['epoch'])
        key = work / 'ipa-private.pem'
        with (work / 'signing.log').open('wb') as log:
            run(['/usr/bin/openssl', 'genrsa', '-out', key, '2048'], env, log)
            key.chmod(0o400)
            public = work / 'public.der'
            run(['/usr/bin/openssl', 'pkey', '-in', key, '-pubout', '-outform', 'DER', '-out', public], env, log)
        public_der = public.read_bytes()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(replica, work, label, count, source_contract, expected, directories)
                       for label, count in (('a', jobs // 2), ('b', jobs - jobs // 2))]
            try:
                first, second = [future.result() for future in futures]
            except BaseException:
                STOP.set()
                raise
        if first != second:
            changed = sorted(name for name in first.keys() | second.keys() if first.get(name) != second.get(name))
            raise RuntimeError('complete runtime replicas differ: ' + ', '.join(changed))
        environment.verify()
        if inputs != contract.input_digests() or source_contract != contract.expected_source()[0]:
            raise RuntimeError('source or producer inputs changed during build')
        stage = work / 'publication'
        stage.mkdir(mode=0o755)
        os.rename(work / 'runtime-a', stage / 'runtime')
        manifest = contract.manifest_bytes(first)
        (stage / 'RUNTIME-MANIFEST.tsv').write_bytes(manifest)
        provenance = {'schema': 'tb321fu-libcamera-runtime-v1', 'source': source_contract,
            'inputs': inputs, 'options': list(contract.OPTIONS),
            'runtime_manifest_sha256': contract.sha(manifest),
            'replica_manifests': [contract.sha(manifest), contract.sha(manifest)],
            'public_key_der_base64': base64.b64encode(public_der).decode('ascii'),
            'public_key_sha256': contract.sha(public_der)}
        (stage / 'BUILD-PROVENANCE.json').write_text(json.dumps(provenance, sort_keys=True, indent=2) + '\n')
        for name in ('RUNTIME-MANIFEST.tsv', 'BUILD-PROVENANCE.json'):
            (stage / name).chmod(0o644)
        contract.verify(stage)
        contract.consumer.exporter.promote(stage, output)
    print('LIBCAMERA_RUNTIME_BUILD=PASS members=' + str(len(first)), flush=True)

def stop(signum, _frame):
    STOP.set()
    raise KeyboardInterrupt('runtime producer received signal ' + str(signum))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-root', required=True, type=pathlib.Path)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    # Directories and tools are deterministic under any invoking shell umask;
    # the TemporaryDirectory parent protects all private work including keys.
    os.umask(0o022)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    build_runtime(args.output_root, args.jobs)

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyboardInterrupt, subprocess.SubprocessError) as error:
        raise SystemExit('LIBCAMERA_RUNTIME_BUILD=FAIL: ' + str(error))
