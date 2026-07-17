#!/usr/bin/env python3
"""Verify the exact package payload contract of the TB321FU sensor DEBs."""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import resource
import struct
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path


AR_MAGIC = b"!<arch>\n"
AR_HEADER_BYTES = 60
AR_TRAILER = b"`\n"
ARCHIVE_MEMBER_RE = re.compile(r"^(control|data)\.tar\.(gz|xz|zst)$")
MANIFEST_LINE_RE = re.compile(rb"([0-9a-f]{64})  \./([-A-Za-z0-9._+/]+)")
INTERNAL_MANIFEST_LINE_RE = re.compile(rb"([0-9a-f]{64})  ([-A-Za-z0-9._+/]+)")
MAX_DEB_BYTES = 64 * 1024 * 1024
MAX_TAR_BYTES = 128 * 1024 * 1024
DEVICE_RECORDS = 541
EXPECTED_CONTROL_FIELDS = {
    "qcom-sns-libssc": {
        "Package": "qcom-sns-libssc",
        "Section": "libs",
        "Priority": "optional",
        "Architecture": "arm64",
        "Maintainer": "GUF296 <guf296@users.noreply.github.com>",
        "Provides": "libssc",
        "Depends": "libc6, libglib2.0-0, libprotobuf-c1, libqmi-glib5",
        "Description": (
            "Qualcomm SSC userspace library\n"
            "Source-built libssc and ssccli for Qualcomm Sensor Core devices."
        ),
    },
    "qcom-sns-hexagonrpc": {
        "Package": "qcom-sns-hexagonrpc",
        "Section": "libs",
        "Priority": "optional",
        "Architecture": "arm64",
        "Maintainer": "GUF296 <guf296@users.noreply.github.com>",
        "Provides": "hexagonrpcd",
        "Depends": "libc6",
        "Description": (
            "Qualcomm HexagonRPC userspace daemon\n"
            "Source-built hexagonrpcd with generic qcom-sns persistent registry mapping."
        ),
    },
    "qcom-sns-iio-sensor-proxy": {
        "Package": "qcom-sns-iio-sensor-proxy",
        "Section": "misc",
        "Priority": "optional",
        "Architecture": "arm64",
        "Maintainer": "GUF296 <guf296@users.noreply.github.com>",
        "Provides": "iio-sensor-proxy",
        "Depends": "libc6, dbus, libglib2.0-0, libgudev-1.0-0, libpolkit-gobject-1-0, qcom-sns-libssc",
        "Conflicts": "iio-sensor-proxy",
        "Replaces": "iio-sensor-proxy",
        "Description": (
            "IIO Sensor Proxy with Qualcomm SSC support\n"
            "Source-built iio-sensor-proxy with Qualcomm SSC drivers enabled."
        ),
    },
    "tb321fu-sensors": {
        "Package": "tb321fu-sensors",
        "Section": "misc",
        "Priority": "optional",
        "Architecture": "arm64",
        "Maintainer": "GUF296 <guf296@users.noreply.github.com>",
        "Depends": "qcom-sns-hexagonrpc, qcom-sns-iio-sensor-proxy, qcom-sns-libssc, systemd, coreutils, findutils, util-linux",
        "Conflicts": "y700-sensors",
        "Replaces": "y700-sensors",
        "Description": (
            "Sensor files for Lenovo Legion Y700 TB321FU\n"
            "Verified TB321FU Qualcomm SNS device data and cold-boot initialization glue."
        ),
    },
}
EXPECTED_MAINTAINER_SCRIPT_SHA256 = {
    "qcom-sns-libssc": {
        "postinst": "52bc98ffb417c2f4ab1ed0096cc1b918c6295da675602e9a9a4ec6f83b0951a4",
        "postrm": "52bc98ffb417c2f4ab1ed0096cc1b918c6295da675602e9a9a4ec6f83b0951a4",
    },
    "qcom-sns-hexagonrpc": {
        "postinst": "52bc98ffb417c2f4ab1ed0096cc1b918c6295da675602e9a9a4ec6f83b0951a4",
        "postrm": "52bc98ffb417c2f4ab1ed0096cc1b918c6295da675602e9a9a4ec6f83b0951a4",
    },
    "qcom-sns-iio-sensor-proxy": {
        "postinst": "f600a8a4d2ab2e178c89348b9071d99788ab50233267ac8b0d1b95b2bb0fd878",
        "postrm": "e9e56ffd41cb794e00641b4f9f210c930a0b17796b4c09304017846671b18559",
    },
    "tb321fu-sensors": {
        "postinst": "f48ac7c619077bc2e030b283d2bb913a7b55603e7819689e5d66c892b1be32a5",
        "postrm": "e9e56ffd41cb794e00641b4f9f210c930a0b17796b4c09304017846671b18559",
        "prerm": "21823b166ef264f797a4cad3e72ebc259d9d7b4d89873c6906aefe3275c50521",
    },
}
EXPECTED_RUNTIME_FILE_SHA256 = {
    "qcom-sns-libssc": {},
    "qcom-sns-hexagonrpc": {},
    "qcom-sns-iio-sensor-proxy": {
        "usr/lib/systemd/system/iio-sensor-proxy.service": "c95c921c82fffbd340fa68f2c32c7959b0b7fb0ad2a3ca6e5d9978958ba04922",
        "usr/lib/udev/rules.d/80-iio-sensor-proxy.rules": "3d50c919f17e5140921fd6629f7d51ed89daef3a345e6ebaf70610c6299397d6",
        "usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf": "33c9d5ee47c839a640ce549c57ef91b85ccab7dd4a8097c3225662655030fb25",
        "usr/share/dbus-1/system-services/net.hadess.SensorProxy.service": "563750af5136988426bb3b615fbc91d57b712c4638b6b160338bbc92498ec11a",
        "usr/share/polkit-1/actions/net.hadess.SensorProxy.policy": "035194978c2d9f3ca53af81e1936334ffd97f6efeabdf44420f52e74dc8fcea9",
    },
    "tb321fu-sensors": {
        "etc/systemd/system/iio-sensor-proxy.service.d/99-qcom-sns.conf": "8966c01164af7e6ee1ccd32ec4c47ac40b1ea12e9b674ad8794a229fd2ff5760",
        "usr/lib/systemd/system/qcom-sns-init.service": "6147a022ba2f6fd70272eac871e5d7ab3e65227849472ef99e6e015968f12596",
        "usr/lib/systemd/system-sleep/qcom-sns-resume": "e1452887841672c8c145742a8abf09d005d071cb06d56ae97e14cdfddf4238d6",
        "usr/lib/udev/rules.d/80-tb321fu-qcom-sns.rules": "4b9059b9a52d6046bf437c6104b2f1deab94f991d0caf742db0b2c302040b02d",
        "usr/libexec/qcom-sns/qcom-sns-init": "e9501c10601f9777d511df51e3548baefdf2aeec6cb3c5739d03c819c1a7059f",
        "usr/share/qcom/conf.d/tb321fu.yaml": "a115fdc23e7bebd69b7255e10a95470d27c3ad3cc7e16c53d7a73a8397f342ea",
    },
}
EXPECTED_ELF_PATHS = {
    "qcom-sns-libssc": {
        "usr/bin/ssccli",
        "usr/lib/aarch64-linux-gnu/libssc.so.2",
    },
    "qcom-sns-hexagonrpc": {
        "usr/bin/hexagonrpcd",
        "usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4",
    },
    "qcom-sns-iio-sensor-proxy": {
        "usr/bin/monitor-sensor",
        "usr/libexec/iio-sensor-proxy",
    },
    "tb321fu-sensors": set(),
}


@dataclass(frozen=True)
class ArMember:
    name: str
    mtime: int
    uid: int
    gid: int
    mode: int
    payload: bytes


def parse_decimal(raw: bytes, label: str) -> int:
    text = raw.decode("ascii").strip()
    if not text or not text.isdecimal():
        raise ValueError(f"invalid ar {label}: {text!r}")
    return int(text, 10)


def parse_octal(raw: bytes, label: str) -> int:
    text = raw.decode("ascii").strip()
    if not text or any(char not in "01234567" for char in text):
        raise ValueError(f"invalid ar {label}: {text!r}")
    return int(text, 8)


def read_ar(path: Path) -> list[ArMember]:
    with path.open("rb") as handle:
        data = handle.read(MAX_DEB_BYTES + 1)
    if len(data) > MAX_DEB_BYTES:
        raise ValueError(f"sensor DEB exceeds size limit: {path}")
    if not data.startswith(AR_MAGIC):
        raise ValueError(f"sensor DEB lacks the ar archive magic: {path}")
    offset = len(AR_MAGIC)
    members: list[ArMember] = []
    while offset < len(data):
        if len(data) - offset < AR_HEADER_BYTES:
            raise ValueError("truncated ar member header")
        header = data[offset : offset + AR_HEADER_BYTES]
        offset += AR_HEADER_BYTES
        if header[58:60] != AR_TRAILER:
            raise ValueError("invalid ar member trailer")
        raw_name = header[0:16].decode("ascii").strip()
        if raw_name.startswith(("/", "#1/")):
            raise ValueError(f"extended ar member names are forbidden: {raw_name!r}")
        name = raw_name.removesuffix("/")
        size = parse_decimal(header[48:58], "size")
        end = offset + size
        if end > len(data):
            raise ValueError(f"truncated ar member payload: {name}")
        members.append(
            ArMember(
                name=name,
                mtime=parse_decimal(header[16:28], "mtime"),
                uid=parse_decimal(header[28:34], "uid"),
                gid=parse_decimal(header[34:40], "gid"),
                mode=parse_octal(header[40:48], "mode"),
                payload=data[offset:end],
            )
        )
        if size % 2 and data[end : end + 1] != b"\n":
            raise ValueError(f"invalid ar member padding: {name}")
        offset = end + (size % 2)
    if offset != len(data):
        raise ValueError("ar archive has trailing bytes")
    return members


def normalize_tar_name(raw: str) -> str:
    if raw in (".", "./"):
        return ""
    if not raw.startswith("./"):
        raise ValueError(f"tar member must use a ./ relative path: {raw!r}")
    name = raw[2:].rstrip("/")
    if not name or "\\" in name or "\x00" in name:
        raise ValueError(f"unsafe tar member path: {raw!r}")
    parts = name.split("/")
    if any(part in ("", ".", "..") or len(part.encode()) > 255 for part in parts):
        raise ValueError(f"unsafe tar member path: {raw!r}")
    if len(name.encode()) >= 4096:
        raise ValueError(f"overlong tar member path: {raw!r}")
    return name


def parse_device_manifest(path: Path) -> dict[str, str]:
    raw = path.read_bytes()
    if b"\x00" in raw:
        raise ValueError("device-data manifest contains NUL")
    if not raw or len(raw) > 1024 * 1024 or not raw.endswith(b"\n"):
        raise ValueError("device-data manifest has invalid size or termination")
    records: dict[str, str] = {}
    previous = ""
    for raw_line in raw.splitlines():
        if b"\r" in raw_line:
            raise ValueError("device-data manifest contains CR")
        match = MANIFEST_LINE_RE.fullmatch(raw_line)
        if not match:
            raise ValueError("device-data manifest has a malformed record")
        digest = match.group(1).decode("ascii")
        device_path = match.group(2).decode("ascii")
        parts = device_path.split("/")
        if (
            device_path.startswith("/")
            or device_path.endswith("/")
            or "//" in device_path
            or len(device_path.encode()) >= 4096
            or any(part in ("", ".", "..") or len(part.encode()) > 255 for part in parts)
        ):
            raise ValueError("device-data manifest has an unsafe path")
        if device_path == ".tb321fu-manifests" or device_path.startswith(
            ".tb321fu-manifests/"
        ):
            raise ValueError("device-data manifest uses a verifier-owned subtree")
        if previous and previous >= device_path:
            raise ValueError("device-data manifest paths are not strictly ordered")
        previous = device_path
        records[device_path] = digest
    if len(records) != DEVICE_RECORDS:
        raise ValueError(
            f"device-data manifest must contain exactly {DEVICE_RECORDS} records"
        )
    return records


def verify_internal_manifest(
    raw: bytes,
    label: str,
    prefix: str,
    device_records: dict[str, str],
) -> None:
    if b"\x00" in raw or not raw or not raw.endswith(b"\n"):
        raise ValueError(f"{label} has invalid bytes or termination")
    actual: dict[str, str] = {}
    previous = ""
    for line in raw.splitlines():
        match = INTERNAL_MANIFEST_LINE_RE.fullmatch(line)
        if not match:
            raise ValueError(f"{label} has a malformed record")
        digest = match.group(1).decode("ascii")
        path = match.group(2).decode("ascii")
        if previous and previous >= path:
            raise ValueError(f"{label} paths are not strictly ordered")
        previous = path
        actual[path] = digest
    expected = {
        path: digest for path, digest in device_records.items() if path.startswith(prefix)
    }
    if actual != expected:
        raise ValueError(f"{label} does not match the packaged {prefix} subtree")


def run_dpkg_tar(deb: Path, option: str) -> bytes:
    def limit_child_files() -> None:
        resource.setrlimit(
            resource.RLIMIT_FSIZE, (MAX_TAR_BYTES + 1, MAX_TAR_BYTES + 1)
        )

    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        try:
            subprocess.run(
                ["dpkg-deb", option, str(deb)],
                check=True,
                stdout=stdout,
                stderr=stderr,
                timeout=30,
                preexec_fn=limit_child_files,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            if stdout.tell() > MAX_TAR_BYTES:
                raise ValueError(f"decompressed tar exceeds size limit: {deb.name}") from error
            stderr.seek(0)
            diagnostic = stderr.read(512)
            raise ValueError(
                f"dpkg-deb failed for {deb.name}: {diagnostic.decode(errors='replace')}"
            ) from error
        if stdout.tell() > MAX_TAR_BYTES:
            raise ValueError(f"decompressed tar exceeds size limit: {deb.name}")
        stdout.seek(0)
        return stdout.read(MAX_TAR_BYTES + 1)


def add_parent_directories(
    expected: dict[str, tuple[str, int, str | None]], path: str
) -> None:
    parts = path.split("/")[:-1]
    expected.setdefault("", ("dir", 0o755, None))
    for count in range(1, len(parts) + 1):
        expected.setdefault("/".join(parts[:count]), ("dir", 0o755, None))


def expected_tree(
    files: dict[str, int], links: dict[str, str] | None = None
) -> dict[str, tuple[str, int, str | None]]:
    result: dict[str, tuple[str, int, str | None]] = {"": ("dir", 0o755, None)}
    for path, mode in files.items():
        add_parent_directories(result, path)
        result[path] = ("file", mode, None)
    for path, target in (links or {}).items():
        add_parent_directories(result, path)
        result[path] = ("link", 0o777, target)
    for path in result:
        parts = path.split("/")
        for count in range(1, len(parts)):
            ancestor = "/".join(parts[:count])
            if ancestor in result and result[ancestor][0] != "dir":
                raise ValueError(
                    f"package contract has a non-directory ancestor: {ancestor} -> {path}"
                )
    return result


def control_contract(package: str) -> dict[str, tuple[str, int, str | None]]:
    files = {"control": 0o644, "postinst": 0o755, "postrm": 0o755}
    if package == "tb321fu-sensors":
        files["prerm"] = 0o755
    return expected_tree(files)


def verify_control_fields(raw: bytes, package: str) -> None:
    if b"\x00" in raw or b"\r" in raw or not raw.endswith(b"\n"):
        raise ValueError(f"{package} control has invalid bytes or termination")
    fields: dict[str, str] = {}
    current = ""
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValueError(f"{package} control is not UTF-8") from error
    for line in lines:
        if line.startswith((" ", "\t")):
            if current != "Description" or not line.startswith(" ") or line.startswith("  "):
                raise ValueError(
                    f"{package} control has an unexpected continuation: {current or '<none>'}"
                )
            fields[current] += "\n" + line[1:]
            continue
        key, separator, value = line.partition(":")
        if not separator or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", key):
            raise ValueError(f"{package} control has a malformed field")
        if key in fields:
            raise ValueError(f"{package} control has a duplicate field: {key}")
        if not value.startswith(" ") or value.startswith("  "):
            raise ValueError(f"{package} control field has non-canonical spacing: {key}")
        fields[key] = value[1:]
        current = key
    version = fields.get("Version", "")
    if not re.fullmatch(r"[0-9][0-9A-Za-z.+~_-]{0,63}", version):
        raise ValueError(f"{package} control version is unsafe")
    expected = EXPECTED_CONTROL_FIELDS[package]
    expected_names = set(expected) | {"Version"}
    if set(fields) != expected_names:
        missing = sorted(expected_names - set(fields))
        extra = sorted(set(fields) - expected_names)
        raise ValueError(
            f"{package} control field set mismatch; missing={missing!r} extra={extra!r}"
        )
    for field, value in expected.items():
        if fields[field] != value:
            raise ValueError(f"{package} control {field} mismatch")


def verify_aarch64_elf(raw: bytes, package: str, path: str) -> None:
    def integer(offset: int, size: int) -> int:
        return int.from_bytes(raw[offset : offset + size], "little")

    if (
        len(raw) < 64
        or raw[:4] != b"\x7fELF"
        or raw[4] != 2
        or raw[5] != 1
        or raw[6] != 1
        or integer(16, 2) not in (2, 3)
        or integer(18, 2) != 183
        or integer(20, 4) != 1
        or integer(52, 2) != 64
    ):
        raise ValueError(f"{package} payload is not AArch64 ELF: {path}")
    program_offset = integer(32, 8)
    section_offset = integer(40, 8)
    program_entry_size = integer(54, 2)
    program_count = integer(56, 2)
    section_entry_size = integer(58, 2)
    section_count = integer(60, 2)
    if (
        program_offset < 64
        or program_entry_size != 56
        or program_count < 1
        or program_count > 256
        or program_offset + program_entry_size * program_count > len(raw)
    ):
        raise ValueError(f"{package} payload has invalid ELF program headers: {path}")
    if section_offset:
        if (
            section_entry_size != 64
            or section_count < 1
            or section_count > 65534
            or section_offset + section_entry_size * section_count > len(raw)
        ):
            raise ValueError(f"{package} payload has invalid ELF section headers: {path}")
    elif section_entry_size or section_count or integer(62, 2):
        raise ValueError(f"{package} payload has inconsistent ELF section metadata: {path}")
    loadable = False
    substantive_load = False
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        if integer(offset, 4) != 1:
            continue
        file_offset = integer(offset + 8, 8)
        virtual_address = integer(offset + 16, 8)
        file_size = integer(offset + 32, 8)
        memory_size = integer(offset + 40, 8)
        alignment = integer(offset + 48, 8)
        if (
            file_offset > len(raw)
            or file_size > len(raw) - file_offset
            or memory_size == 0
            or file_size > memory_size
            or (alignment not in (0, 1) and alignment & (alignment - 1))
            or (
                alignment not in (0, 1)
                and virtual_address % alignment != file_offset % alignment
            )
        ):
            raise ValueError(f"{package} payload has invalid ELF load segment: {path}")
        loadable = True
        substantive_load = substantive_load or file_size > 0
    if not loadable:
        raise ValueError(f"{package} payload has no ELF load segment: {path}")
    if not substantive_load:
        raise ValueError(f"{package} payload has no file-backed ELF load segment: {path}")


def libssc_contract() -> dict[str, tuple[str, int, str | None]]:
    headers = [
        "libssc-sensor-accelerometer.h",
        "libssc-sensor-compass.h",
        "libssc-sensor-gyroscope.h",
        "libssc-sensor-light.h",
        "libssc-sensor-magnetometer.h",
        "libssc-sensor-proximity.h",
        "libssc-sensor.h",
        "libssc-version-private.h",
        "libssc.h",
        "ssc-common.pb-c.h",
        "ssc-sensor-accelerometer.pb-c.h",
        "ssc-sensor-gyroscope.pb-c.h",
        "ssc-sensor-light.pb-c.h",
        "ssc-sensor-magnetometer.pb-c.h",
        "ssc-sensor-proximity.pb-c.h",
        "ssc-sensor-rotationvector.pb-c.h",
        "ssc-sensor-suid.pb-c.h",
    ]
    files = {f"usr/include/libssc/{name}": 0o644 for name in headers}
    files.update(
        {
            "usr/bin/ssccli": 0o755,
            "usr/lib/aarch64-linux-gnu/libssc.so.2": 0o644,
            "usr/lib/aarch64-linux-gnu/pkgconfig/libssc.pc": 0o644,
        }
    )
    return expected_tree(
        files, {"usr/lib/aarch64-linux-gnu/libssc.so": "libssc.so.2"}
    )


def data_contract(
    package: str, device_records: dict[str, str]
) -> dict[str, tuple[str, int, str | None]]:
    if package == "qcom-sns-libssc":
        return libssc_contract()
    if package == "qcom-sns-hexagonrpc":
        return expected_tree(
            {
                "usr/bin/hexagonrpcd": 0o755,
                "usr/lib/aarch64-linux-gnu/libhexagonrpc.so.0.4": 0o644,
            },
            {"usr/lib/aarch64-linux-gnu/libhexagonrpc.so": "libhexagonrpc.so.0.4"},
        )
    if package == "qcom-sns-iio-sensor-proxy":
        return expected_tree(
            {
                "usr/bin/monitor-sensor": 0o755,
                "usr/lib/systemd/system/iio-sensor-proxy.service": 0o644,
                "usr/lib/udev/rules.d/80-iio-sensor-proxy.rules": 0o644,
                "usr/libexec/iio-sensor-proxy": 0o755,
                "usr/share/dbus-1/system-services/net.hadess.SensorProxy.service": 0o644,
                "usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf": 0o644,
                "usr/share/polkit-1/actions/net.hadess.SensorProxy.policy": 0o644,
            }
        )
    if package != "tb321fu-sensors":
        raise ValueError(f"unsupported sensor package contract: {package}")
    files = {
        "etc/systemd/system/iio-sensor-proxy.service.d/99-qcom-sns.conf": 0o644,
        "usr/lib/systemd/system/qcom-sns-init.service": 0o644,
        "usr/lib/systemd/system-sleep/qcom-sns-resume": 0o755,
        "usr/lib/udev/rules.d/80-tb321fu-qcom-sns.rules": 0o644,
        "usr/libexec/qcom-sns/qcom-sns-init": 0o755,
        "usr/share/qcom/conf.d/tb321fu.yaml": 0o644,
        "usr/share/qcom/sm8650/Lenovo/tb321fu/.tb321fu-manifests/config.sha256": 0o644,
        "usr/share/qcom/sm8650/Lenovo/tb321fu/.tb321fu-manifests/registry.sha256": 0o644,
    }
    prefix = "usr/share/qcom/sm8650/Lenovo/tb321fu/"
    files.update({prefix + path: 0o644 for path in device_records})
    return expected_tree(files)


def verify_tar(
    raw: bytes,
    label: str,
    expected: dict[str, tuple[str, int, str | None]],
    epoch: int,
    content_hashes: dict[str, str] | None = None,
) -> dict[str, bytes]:
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        if archive.pax_headers:
            raise ValueError(f"{label} tar contains global PAX metadata")
        members = archive.getmembers()
        actual: dict[str, tarfile.TarInfo] = {}
        contents: dict[str, bytes] = {}
        for member in members:
            if member.pax_headers:
                raise ValueError(f"{label} tar contains per-member PAX metadata")
            if member.sparse is not None:
                raise ValueError(f"{label} tar contains a sparse member")
            if member.name.endswith("/") and not member.isdir():
                raise ValueError(
                    f"{label} non-directory member has a trailing slash: {member.name!r}"
                )
            name = normalize_tar_name(member.name)
            if name in actual:
                raise ValueError(f"{label} tar contains duplicate member: {name or '.'}")
            actual[name] = member
            if member.isreg():
                handle = archive.extractfile(member)
                if handle is None:
                    raise ValueError(f"{label} cannot read regular member: {name}")
                contents[name] = handle.read()
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        raise ValueError(
            f"{label} tar member set mismatch; missing={missing!r} extra={extra!r}"
        )
    for name, (kind, mode, target) in expected.items():
        member = actual[name]
        valid_type = {
            "dir": member.isdir(),
            "file": member.isreg(),
            "link": member.issym(),
        }[kind]
        if not valid_type:
            raise ValueError(f"{label} member has wrong type: {name or '.'}")
        if member.mode & 0o7777 != mode:
            raise ValueError(
                f"{label} member has wrong mode: {name or '.'}: "
                f"expected {mode:04o}, got {member.mode & 0o7777:04o}"
            )
        if member.uid != 0 or member.gid != 0:
            raise ValueError(
                f"{label} member is not owned by root:root: {name or '.'}"
            )
        if member.mtime != epoch:
            raise ValueError(
                f"{label} member mtime mismatch: {name or '.'}: "
                f"expected {epoch}, got {member.mtime}"
            )
        if kind == "link" and member.linkname != target:
            raise ValueError(
                f"{label} symlink target mismatch: {name}: "
                f"expected {target!r}, got {member.linkname!r}"
            )
        if kind == "file" and name not in (content_hashes or {}) and not contents[name]:
            raise ValueError(f"{label} required file is empty: {name}")
    for name, digest in (content_hashes or {}).items():
        if hashlib.sha256(contents[name]).hexdigest() != digest:
            raise ValueError(f"{label} device-data checksum mismatch: {name}")
    return contents


def verify_deb(
    deb: Path,
    package: str,
    device_records: dict[str, str],
    expected_epoch: int | None,
) -> int:
    if not deb.is_file() or deb.is_symlink():
        raise ValueError(f"sensor DEB is not a regular file: {deb}")
    members = read_ar(deb)
    if len(members) != 3:
        raise ValueError(f"sensor DEB must contain exactly three ar members: {deb.name}")
    if members[0].name != "debian-binary" or members[0].payload != b"2.0\n":
        raise ValueError(f"sensor DEB has an invalid debian-binary member: {deb.name}")
    if not ARCHIVE_MEMBER_RE.fullmatch(members[1].name) or not members[1].name.startswith("control.tar."):
        raise ValueError(f"unexpected sensor control member: {members[1].name}")
    if not ARCHIVE_MEMBER_RE.fullmatch(members[2].name) or not members[2].name.startswith("data.tar."):
        raise ValueError(f"unexpected sensor data member: {members[2].name}")
    epoch = members[0].mtime
    if expected_epoch is not None and epoch != expected_epoch:
        raise ValueError(f"sensor DEB source epoch mismatch: {deb.name}")
    for member in members:
        if member.uid != 0 or member.gid != 0 or member.mode & 0o7777 != 0o644:
            raise ValueError(
                f"sensor ar member metadata mismatch: {deb.name}:{member.name}"
            )
        if member.mtime != epoch:
            raise ValueError(f"sensor ar member mtime mismatch: {deb.name}:{member.name}")
    control_tar = run_dpkg_tar(deb, "--ctrl-tarfile")
    data_tar = run_dpkg_tar(deb, "--fsys-tarfile")
    control_contents = verify_tar(
        control_tar, f"{package} control", control_contract(package), epoch
    )
    verify_control_fields(control_contents["control"], package)
    for script, digest in EXPECTED_MAINTAINER_SCRIPT_SHA256[package].items():
        if hashlib.sha256(control_contents[script]).hexdigest() != digest:
            raise ValueError(f"{package} maintainer script digest mismatch: {script}")
    contract = data_contract(package, device_records)
    content_hashes = None
    if package == "tb321fu-sensors":
        prefix = "usr/share/qcom/sm8650/Lenovo/tb321fu/"
        content_hashes = {prefix + path: digest for path, digest in device_records.items()}
    contents = verify_tar(data_tar, f"{package} data", contract, epoch, content_hashes)
    for path, digest in EXPECTED_RUNTIME_FILE_SHA256[package].items():
        if hashlib.sha256(contents[path]).hexdigest() != digest:
            raise ValueError(f"{package} runtime payload digest mismatch: {path}")
    for path in EXPECTED_ELF_PATHS[package]:
        verify_aarch64_elf(contents[path], package, path)
    if package == "tb321fu-sensors":
        manifest_prefix = "usr/share/qcom/sm8650/Lenovo/tb321fu/.tb321fu-manifests/"
        verify_internal_manifest(
            contents[manifest_prefix + "config.sha256"],
            "tb321fu config manifest",
            "sensors/config/",
            device_records,
        )
        verify_internal_manifest(
            contents[manifest_prefix + "registry.sha256"],
            "tb321fu registry manifest",
            "sensors/registry/",
            device_records,
        )
    return epoch


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--libssc-deb", required=True, type=Path)
    parser.add_argument("--hexagonrpc-deb", required=True, type=Path)
    parser.add_argument("--iio-sensor-proxy-deb", required=True, type=Path)
    parser.add_argument("--tb321fu-sensors-deb", required=True, type=Path)
    parser.add_argument("--device-data-manifest", required=True, type=Path)
    return parser.parse_args()


def self_test() -> None:
    try:
        expected_tree({"usr/share/conflict": 0o644, "usr/share/conflict/child": 0o644})
    except ValueError as error:
        if "non-directory ancestor" not in str(error):
            raise
    else:
        raise ValueError("self-test accepted a non-directory package-tree ancestor")

    expected = expected_tree({"usr/bin/tool": 0o755})
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for path, (kind, mode, _) in expected.items():
            name = "./" if not path else f"./{path}"
            if kind == "dir" and path:
                name += "/"
            elif path == "usr/bin/tool":
                name += "/"
            member = tarfile.TarInfo(name)
            member.type = tarfile.DIRTYPE if kind == "dir" else tarfile.REGTYPE
            member.mode = mode
            member.uid = 0
            member.gid = 0
            member.mtime = 0
            if kind == "file":
                member.size = 1
                archive.addfile(member, io.BytesIO(b"x"))
            else:
                archive.addfile(member)
    try:
        verify_tar(tar_buffer.getvalue(), "self-test", expected, 0)
    except ValueError as error:
        if "trailing slash" not in str(error):
            raise
    else:
        raise ValueError("self-test accepted a trailing-slash regular tar member")

    ident = b"\x7fELF" + bytes((2, 1, 1, 0)) + bytes(8)
    header = struct.pack(
        "<16sHHIQQQIHHHHHH",
        ident,
        3,
        183,
        1,
        0,
        64,
        0,
        0,
        64,
        56,
        1,
        0,
        0,
        0,
    )
    program = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 120, 120, 0x1000)
    verify_aarch64_elf(header + program, "self-test", "valid")
    for label, payload in (
        ("truncated", (header + program)[:20]),
        ("no-load", header + bytes(56)),
        (
            "zero-load",
            header
            + struct.pack(
                "<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 0, 0, 0x1000
            ),
        ),
        (
            "misaligned-load",
            header
            + struct.pack(
                "<IIQQQQQQ", 1, 5, 1, 0x400000, 0x400000, 119, 119, 0x1000
            ),
        ),
    ):
        try:
            verify_aarch64_elf(payload, "self-test", label)
        except ValueError:
            pass
        else:
            raise ValueError(f"self-test accepted invalid ELF: {label}")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        print("SENSOR_DEB_STRUCTURE_SELF_TEST=PASS")
        return 0
    args = parse_args()
    device_records = parse_device_manifest(args.device_data_manifest)
    packages = [
        ("qcom-sns-libssc", args.libssc_deb),
        ("qcom-sns-hexagonrpc", args.hexagonrpc_deb),
        ("qcom-sns-iio-sensor-proxy", args.iio_sensor_proxy_deb),
        ("tb321fu-sensors", args.tb321fu_sensors_deb),
    ]
    epoch: int | None = None
    for package, deb in packages:
        epoch = verify_deb(deb, package, device_records, epoch)
    print(f"SENSOR_DEB_STRUCTURE=PASS files={DEVICE_RECORDS} epoch={epoch}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        OSError,
        UnicodeError,
        ValueError,
        subprocess.SubprocessError,
        tarfile.TarError,
    ) as error:
        print(f"sensor DEB rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
