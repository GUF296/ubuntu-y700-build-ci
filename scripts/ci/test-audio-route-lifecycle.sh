#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
audio="$SCRIPT_DIR/payloads/tb321fu-headset-route-reconcile.lua"
audio_conf="$SCRIPT_DIR/payloads/52-tb321fu-headset-route-reconcile.conf"
tested_audio_conf="$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.conf"
tested_audio_script="$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.lua"

[ "$(sha256sum "$tested_audio_conf" | awk '{print $1}')" = \
  5ea413266962a5bec45b6e287dc7e5bd6ab45112f4c2fd23810004e32b6328b2 ]
[ "$(sha256sum "$tested_audio_script" | awk '{print $1}')" = \
  6da046508f8965e05d9ec2d2b9e8b7bb7d556924f21f671b41b2451714f988c9 ]

grep -F 'name = tb321fu/headset-route-reconcile.lua' "$audio_conf" >/dev/null
grep -F 'hooks.device.routes.tb321fu-headset-route-reconcile' "$audio_conf" >/dev/null
grep -F 'device:iterate_params ("Profile")' "$audio" >/dev/null
grep -F 'device:iterate_params ("Route")' "$audio" >/dev/null
grep -F 'route.available ~= "no"' "$audio" >/dev/null
grep -F 'local debounce_ms = 250' "$audio" >/dev/null
grep -F 'pending_timeout:destroy ()' "$audio" >/dev/null
grep -F 'device ["bound-id"]' "$audio" >/dev/null
grep -F 'nodes [mode].stale [name]' "$audio" >/dev/null
if grep -Eq 'current_mode|has_node|cleanup_now_and_soon' "$audio"; then
  echo 'node-presence route guessing remains in the TB321FU audio reconciler' >&2
  exit 1
fi
if grep -Eiq 'y700' "$audio" "$audio_conf"; then
  echo 'new TB321FU audio policy reintroduced a legacy y700 identifier' >&2
  exit 1
fi

python3 - "$audio" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path


text = Path(sys.argv[1]).read_text()
node_names = set(re.findall(r'\["(alsa_(?:input|output)\.platform-sound\.HiFi__[^"]+)"\]', text))
expected_nodes = {
    "alsa_output.platform-sound.HiFi__Speaker__sink",
    "alsa_output.platform-sound.HiFi__Headphones__sink",
    "alsa_input.platform-sound.HiFi__Mic1__source",
    "alsa_input.platform-sound.HiFi__Headset__source",
}
assert node_names == expected_nodes


def classify(name: str) -> str | None:
    name = name.lower()
    speaker = "speaker" in name or "mic1" in name
    headset = "headphone" in name or "headset" in name
    if speaker and not headset:
        return "speaker"
    if headset and not speaker:
        return "headset"
    return None


stale = {
    "speaker": {
        "alsa_output.platform-sound.HiFi__Headphones__sink",
        "alsa_input.platform-sound.HiFi__Headset__source",
    },
    "headset": {
        "alsa_output.platform-sound.HiFi__Speaker__sink",
        "alsa_input.platform-sound.HiFi__Mic1__source",
    },
}


def mode(profile: str, routes: list[str]) -> str | None:
    if "hifi" not in profile.lower():
        return None
    profile_mode = classify(profile)
    route_modes = {candidate for route in routes if (candidate := classify(route))}
    if len(route_modes) != 1:
        return None
    route_mode = route_modes.pop()
    if profile_mode and profile_mode != route_mode:
        return None
    return route_mode


def reconcile(profile: str, routes: list[str], nodes: list[tuple[str, int]], device_id: int) -> set[str]:
    active = mode(profile, routes)
    if not active:
        return set()
    return {name for name, owner in nodes if owner == device_id and name in stale[active]}


all_nodes = [(name, 42) for name in sorted(expected_nodes)] + [
    ("alsa_output.platform-sound.HiFi__Headphones__sink", 99),
]
assert reconcile("HiFi", ["[Out] Speaker", "[In] Mic1"], all_nodes, 42) == stale["speaker"]
assert reconcile("HiFi", ["[Out] Headphones", "[In] Headset"], all_nodes, 42) == stale["headset"]
assert not reconcile("HiFi", ["[Out] Speaker", "[In] Headset"], all_nodes, 42)
assert not reconcile("HiFi (Headphones, Headset)", ["[Out] Speaker"], all_nodes, 42)
assert not reconcile("Pro Audio", ["[Out] Speaker"], all_nodes, 42)
assert not reconcile("HiFi", [], all_nodes, 42)

remaining = [item for item in all_nodes if item[0] not in reconcile(
    "HiFi", ["[Out] Speaker", "[In] Mic1"], all_nodes, 42
) or item[1] != 42]
assert not reconcile("HiFi", ["[Out] Speaker", "[In] Mic1"], remaining, 42)
PY

# Run the accepted helper itself for both outcomes with an already-present
# card. For absence/bind cases only, map the single absolute sysfs directory
# to a temporary ordinary directory; no test reads or writes a real driver.
python3 - "$SCRIPT_DIR/payloads" <<'PY'
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile

payload = Path(sys.argv[1])
helper = payload / 'tb321fu-audio-card-guard.sh'
unit = payload / 'tb321fu-audio-card-guard.service'
assert hashlib.sha256(unit.read_bytes()).hexdigest() == 'e0c6034915659fc8465b1a106ffcb48e4e90e4d02a9e84921bc9782b0f126301'
assert hashlib.sha256(helper.read_bytes()).hexdigest() == '29fe2db28a7e049e58f9d0fcd6c2487c92bb1c758c09fa3733990f7b9bc33f67'
for line in ['Type=oneshot','Restart=on-failure','RestartSec=10s','TimeoutStartSec=15s',
             'WantedBy=multi-user.target','ExecStart=/usr/local/sbin/y700-audio-card-guard.sh']:
    assert unit.read_text().splitlines().count(line) == 1
shell = '''
grep() { [ "$*" = '-q LenovoY700TB321 /proc/asound/cards' ] && [ "$CARD" = present ]; }
alsaucm() {
  [ "$*" = '-c LenovoY700TB321 set _verb HiFi set _enadev Speaker set _enadev Mic1' ] || exit 31
  printf 'fixture UCM result %s\\n' "$UCM"; return "$UCM"
}
logger() { :; }
sleep() { [ "$1" = 1 ] || exit 32; }
. "$1"
'''
with tempfile.TemporaryDirectory() as td:
    base = Path(td)
    def run(script, card, ucm, rc, text):
        env = dict(PATH='/usr/bin:/bin', LC_ALL='C', CARD=card, UCM=str(ucm), Y700_AUDIO_UCM_LOG=str(base/'ucm.log'))
        out = subprocess.run(['/bin/sh','-c',shell,'isolated-fixture',str(script)], cwd=base, env=env,
                             capture_output=True, text=True, timeout=5, check=False)
        assert out.returncode == rc and text in out.stdout, (out.returncode, out.stdout, out.stderr)
    run(helper, 'present', 0, 0, 'audio UCM initialized: HiFi Speaker Mic1')
    run(helper, 'present', 7, 7, 'audio UCM init failed ret=7 err=fixture UCM result 7')
    original = 'driver_dir="/sys/bus/platform/drivers/snd-sc8280xp"'
    assert helper.read_text().count(original) == 1
    mapped = base / 'mapped-guard.sh'
    mapped.write_text(helper.read_text().replace(original, 'driver_dir="./driver"'))
    run(mapped, 'absent', 0, 1, 'audio card is not ready; systemd will retry')
    driver = base / 'driver'
    driver.mkdir(); (driver/'bind').touch()
    run(mapped, 'absent', 0, 1, 'audio card missing; requested platform bind')
    assert (driver/'bind').read_text() == 'sound\n'
PY

printf 'AUDIO_ROUTE_LIFECYCLE=PASS\n'
