#!/usr/bin/env python3
"""Bind the published camera assets to their exact producer handoff context."""
import argparse
import importlib.util
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent

def load(name):
    spec = importlib.util.spec_from_file_location('camera_release_' + name.replace('-', '_'), HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

handoff = load('camera-artifact-handoff')
policy = load('camera-package-policy')
RELEASE_REPORT = 'CAMERA-BUILD-REPORT.txt'

def verify(directory, repository, commit, run_id, run_attempt):
    context = handoff.Context('1', 'arm64', policy.approved_version(), repository, commit,
                              run_id, run_attempt, '', '', '')
    handoff.validate_context(context)
    _, descriptor, root_info = handoff.open_root(directory)
    try:
        before = handoff.directory_binding(root_info)
        manifest = handoff.read_member(descriptor, root_info, handoff.MANIFEST_NAME,
                                       handoff.MAX_MANIFEST_BYTES, collect=True)
        actual = handoff.parse_manifest(handoff.decode(manifest, 'camera release handoff'))
        expected, _ = handoff.inspect_payload(descriptor, root_info, context, RELEASE_REPORT)
        # The artifact report is intentionally renamed for the public release;
        # its exact bytes, size and digest must still match the original handoff.
        expected = [(kind, handoff.REPORT_NAME if kind == 'file' and name == RELEASE_REPORT else name, value, digest)
                    for kind, name, value, digest in expected]
        metadata = [row for row in expected if row[0] != 'file']
        files = sorted((row for row in expected if row[0] == 'file'), key=lambda row: row[1])
        if actual != metadata + files:
            raise RuntimeError('published camera assets differ from the exact producer context or payload')
        after_manifest = handoff.read_member(descriptor, root_info, handoff.MANIFEST_NAME,
                                             handoff.MAX_MANIFEST_BYTES, collect=True)
        if (after_manifest != manifest or handoff.directory_binding(os.fstat(descriptor)) != before):
            raise RuntimeError('camera release assets changed during validation')
    finally:
        os.close(descriptor)
    print('CAMERA_RELEASE_ASSETS=PASS source_context=exact files=4')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    for name in ('repository', 'commit', 'run-id', 'run-attempt'):
        parser.add_argument('--' + name, required=True)
    try:
        args = parser.parse_args()
        verify(args.directory, args.repository, args.commit, args.run_id, args.run_attempt)
    except (RuntimeError, OSError, ValueError) as error:
        raise SystemExit('CAMERA_RELEASE_ASSETS=FAIL: ' + str(error))
