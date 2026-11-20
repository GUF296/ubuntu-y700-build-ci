#!/usr/bin/env python3
"""Enforce the recorded libcamera build inputs on a trusted Ubuntu build host.

This checks exact installed package identities, selected command bytes and
pkg-config inputs. It is not a sandbox against an administrator or a release
approval, and never installs, downgrades or repairs host packages.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess

REFERENCE = pathlib.Path(__file__).with_name('LIBCAMERA-BUILD-ENVIRONMENT.json')
MODULES = {'libdw', 'libunwind', 'egl', 'glesv2', 'libudev', 'yaml-0.1',
           'gnutls', 'libevent_pthreads', 'glib-2.0',
           'gstreamer-video-1.0', 'gstreamer-allocators-1.0'}
REQUIRED_COMMANDS = {
    '/usr/bin/aarch64-linux-gnu-gcc-13', '/usr/bin/aarch64-linux-gnu-g++-13',
    '/usr/bin/aarch64-linux-gnu-ar', '/usr/bin/aarch64-linux-gnu-strip',
    '/usr/bin/aarch64-linux-gnu-readelf', '/usr/bin/meson', '/usr/bin/ninja',
    '/usr/bin/pkg-config', '/usr/bin/python3', '/usr/bin/openssl',
    '/usr/bin/qemu-aarch64-static', '/usr/bin/cc', '/usr/bin/c++',
    '/usr/bin/git', '/usr/bin/dpkg-deb', '/usr/bin/dpkg-query',
    '/usr/bin/rsync', '/usr/bin/install', '/usr/bin/cat', '/usr/bin/basename',
    '/usr/bin/dirname', '/usr/bin/tr', '/usr/bin/sha256sum', '/usr/bin/awk',
    '/bin/sh', '/bin/bash', '/usr/bin/env',
}
ENV = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C', 'TZ': 'UTC',
       'PKG_CONFIG_LIBDIR': '/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig'}

class EnvironmentError(RuntimeError):
    pass

def fail(message):
    raise EnvironmentError(message)

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            fail('duplicate environment reference field')
        value[key] = item
    return value

def package_name(value):
    return isinstance(value, str) and re.fullmatch(r'[a-z0-9][a-z0-9+.-]*(?::(?:amd64|arm64))?', value) is not None

def check_digest(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None

def validate_reference(value):
    fields = {'schema', 'reference_policy', 'host_architecture', 'roots', 'commands',
              'pkg_config', 'packages', 'dependency_edges'}
    if (not isinstance(value, dict) or set(value) != fields
            or value['schema'] != 'tb321fu-libcamera-build-environment-v1'
            or value['host_architecture'] != 'amd64'
            or not isinstance(value['reference_policy'], str)
            or not 1 <= len(value['reference_policy']) <= 512):
        fail('unsupported build-environment reference')
    packages = value['packages']
    if not isinstance(packages, list) or not 1 <= len(packages) <= 512:
        fail('invalid package closure size')
    by_name = {}
    for package in packages:
        if (not isinstance(package, dict) or set(package) != {'name', 'version', 'architecture'}
                or not package_name(package['name']) or package['name'] in by_name
                or not isinstance(package['architecture'], str)
                or package['architecture'] not in {'amd64', 'arm64', 'all'}
                or not isinstance(package['version'], str) or not re.fullmatch(r'[0-9][A-Za-z0-9.+:~_-]{0,255}', package['version'])):
            fail('invalid or duplicate package identity')
        if package['architecture'] == 'all':
            if ':' in package['name']:
                fail('architecture-independent package must have an unqualified name')
        elif not package['name'].endswith(':' + package['architecture']):
            fail('package name and architecture disagree')
        by_name[package['name']] = package
    roots = value['roots']
    if (not isinstance(roots, list) or not roots or any(not package_name(name) for name in roots)
            or len(set(roots)) != len(roots) or not set(roots) <= by_name.keys()):
        fail('invalid build package roots')
    edges = value['dependency_edges']
    if not isinstance(edges, list) or len(edges) > 4096:
        fail('invalid dependency edge set')
    graph, seen = {}, set()
    for edge in edges:
        if (not isinstance(edge, dict) or set(edge) != {'from', 'requirement', 'to'}
                or not package_name(edge['from']) or not package_name(edge['to'])
                or edge['from'] not in by_name or edge['to'] not in by_name
                or not isinstance(edge['requirement'], str) or not 1 <= len(edge['requirement']) <= 4096
                or any(ord(char) < 32 for char in edge['requirement'])):
            fail('invalid dependency edge')
        identity = (edge['from'], edge['requirement'], edge['to'])
        if identity in seen:
            fail('duplicate dependency edge')
        seen.add(identity)
        graph.setdefault(edge['from'], set()).add(edge['to'])
    reachable, queue = set(), list(roots)
    while queue:
        name = queue.pop()
        if name not in reachable:
            reachable.add(name)
            queue.extend(graph.get(name, ()))
    if reachable != by_name.keys():
        fail('package closure contains unreachable members')

    def check_owners(owners):
        if (not isinstance(owners, list) or not owners
                or any(not package_name(owner) for owner in owners)
                or len(set(owners)) != len(owners)):
            fail('invalid input package ownership set')
        for owner in owners:
            if not package_name(owner):
                fail('invalid input package owner')
            canonical = owner if owner in by_name else owner + ':amd64'
            if canonical not in roots:
                fail('input provider is not a declared package root')

    commands = value['commands']
    if not isinstance(commands, list) or len(commands) != len(REQUIRED_COMMANDS):
        fail('command provider set is incomplete')
    paths = set()
    for command in commands:
        if (not isinstance(command, dict) or set(command) != {'path', 'resolved', 'package_owners', 'sha256'}
                or not isinstance(command['path'], str)
                or command['path'] not in REQUIRED_COMMANDS or command['path'] in paths
                or not isinstance(command['resolved'], str) or not command['resolved'].startswith('/usr/bin/')
                or '..' in pathlib.PurePosixPath(command['resolved']).parts
                or not check_digest(command['sha256'])):
            fail('invalid command provider')
        paths.add(command['path'])
        check_owners(command['package_owners'])
    if paths != REQUIRED_COMMANDS:
        fail('command provider set differs from the build contract')
    modules = value['pkg_config']
    if not isinstance(modules, list) or len(modules) != len(MODULES):
        fail('ARM64 pkg-config input set is incomplete')
    names = set()
    for module in modules:
        if (not isinstance(module, dict) or set(module) != {'name', 'version', 'path', 'sha256', 'package_owners'}
                or not isinstance(module['name'], str)
                or module['name'] not in MODULES or module['name'] in names
                or module['path'] != '/usr/lib/aarch64-linux-gnu/pkgconfig/' + module['name'] + '.pc'
                or not isinstance(module['version'], str) or not 1 <= len(module['version']) <= 128
                or not check_digest(module['sha256'])):
            fail('invalid ARM64 pkg-config input')
        names.add(module['name'])
        check_owners(module['package_owners'])
    return by_name

def run(*arguments):
    result = subprocess.run(arguments, env=ENV, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=60, check=False)
    if result.returncode != 0:
        fail('build input query failed: ' + arguments[0])
    return result.stdout.decode('utf-8').strip()

def fingerprint(path):
    original = pathlib.Path(path)
    resolved = original.resolve(strict=True)
    descriptor = os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != 0
                or before.st_mode & 0o022 or not 0 < before.st_size <= 128 << 20):
            fail('build input is not a protected system file: ' + path)
        digest = hashlib.sha256()
        while chunk := stream.read(1 << 20):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
    identity = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    if identity(before) != identity(after) or original.resolve(strict=True) != resolved or identity(resolved.stat()) != identity(after):
        fail('build input changed during fingerprinting: ' + path)
    return str(resolved), digest.hexdigest()

def verify(reference=REFERENCE):
    raw = reference.read_bytes()
    if len(raw) > 2 << 20:
        fail('environment reference exceeds its size bound')
    value = json.loads(raw.decode(), object_pairs_hook=unique_object)
    packages = validate_reference(value)
    if run('/usr/bin/dpkg', '--print-architecture') != value['host_architecture']:
        fail('this producer requires the locked amd64 cross-build host')
    fields = '${binary:Package}' + chr(9) + '${Version}' + chr(9) + '${Architecture}' + chr(9) + '${Status}' + chr(10)
    actual = {}
    for line in run('/usr/bin/dpkg-query', '-W', '-f=' + fields, *sorted(packages)).splitlines():
        parts = line.split(chr(9))
        if len(parts) != 4 or parts[3] not in ('install ok installed', 'hold ok installed'):
            fail('build package is not in an installed steady state')
        name = parts[0].split(':', 1)[0]
        name = name if parts[2] == 'all' else name + ':' + parts[2]
        if name in actual:
            fail('duplicate installed package observation')
        actual[name] = {'name': name, 'version': parts[1], 'architecture': parts[2]}
    if actual != packages:
        changed = sorted(name for name in packages.keys() | actual.keys() if packages.get(name) != actual.get(name))
        fail('build package identity drift: ' + ', '.join(changed))
    for command in value['commands']:
        resolved, digest = fingerprint(command['path'])
        if resolved != command['resolved'] or digest != command['sha256']:
            fail('build command identity drift: ' + command['path'])
    for module in value['pkg_config']:
        _resolved, digest = fingerprint(module['path'])
        if (digest != module['sha256'] or run('/usr/bin/pkg-config', '--modversion', module['name']) != module['version']
                or run('/usr/bin/pkg-config', '--variable=pcfiledir', module['name']) != str(pathlib.Path(module['path']).parent)):
            fail('ARM64 pkg-config input drift: ' + module['name'])
    print('LIBCAMERA_BUILD_ENVIRONMENT=PASS packages=' + str(len(packages)) + ' commands=' + str(len(value['commands'])))
    print('reference_sha256=' + hashlib.sha256(raw).hexdigest())
    return value

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    verify()

if __name__ == '__main__':
    try:
        main()
    except (EnvironmentError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('LIBCAMERA_BUILD_ENVIRONMENT=FAIL: ' + str(error))
