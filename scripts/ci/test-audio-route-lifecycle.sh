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

printf 'AUDIO_ROUTE_LIFECYCLE=PASS\n'
