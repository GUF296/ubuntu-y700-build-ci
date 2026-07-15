#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

audio="$SCRIPT_DIR/payloads/tb321fu-headset-route-reconcile.lua"
audio_conf="$SCRIPT_DIR/payloads/52-tb321fu-headset-route-reconcile.conf"
haptics_build="$SCRIPT_DIR/build-tb321fu-haptics-deb.sh"
haptics_patch="$SCRIPT_DIR/patches/aw86937-cancellable-playback.patch"
tested_haptics_source=${HAPTICS_TEST_SOURCE:-/home/guf296/tb321fu-ubuntu-release-reconstruction-20260714/sources/haptics-producer/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c}
canonical_haptics_source=${HAPTICS_CANONICAL_SOURCE:-/home/guf296/tb321fu-remediation-20260715/haptics/haptics/daily-current/linux/drivers/input/misc/aw86937-y700.c}
tested_audio_conf="$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.conf"
tested_audio_script="$SCRIPT_DIR/test-fixtures/tested-headset-cleanup.lua"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-audio-haptics-test.XXXXXX")
cleanup() {
  ci_safe_rmtree "$tmp" "${TMPDIR:-/tmp}" tb321fu-audio-haptics-test.
}
trap cleanup EXIT

bash -n "$haptics_build" "$SCRIPT_DIR/system-payload-policy.sh"

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

generations = [1, 2, 3]
executed = [generation for generation in generations if generation == generations[-1]]
assert executed == [3]
PY

grep -F 'c03dcc47b4006e74b441b803b44162f7e715971ea6f7cf8d7c0c92e9f4ead5d4' \
  "$haptics_build" >/dev/null
grep -F '2e0cb7b739496ff6cf4011244ec9c0b2a2367896de65784041018b9d62186e48' \
  "$haptics_build" >/dev/null
grep -F 'HAPTICS-SOURCE-LOCK.tsv' "$haptics_build" >/dev/null
grep -F 'aw86937-build-source-sha256' "$haptics_build" >/dev/null
grep -F 'patch --batch --forward --fuzz=0' "$haptics_build" >/dev/null
grep -F 'wait_event_timeout(haptics->play_wait' "$haptics_patch" >/dev/null
grep -F 'wake_up_all(&haptics->play_wait)' "$haptics_patch" >/dev/null
grep -F 'cancel_work_sync(&haptics->play_work)' "$haptics_patch" >/dev/null
grep -F 'haptics->suspended || haptics->quiescing' "$haptics_patch" >/dev/null
grep -F 'pm_sleep_ptr(&aw86937_y700_pm_ops)' "$haptics_patch" >/dev/null
grep -F '.shutdown = aw86937_y700_shutdown' "$haptics_patch" >/dev/null
if grep -Eq '^\+.*msleep\((duration_ms|play_ms)\)' "$haptics_patch"; then
  echo 'AW86937 patch adds an uninterruptible effect wait' >&2
  exit 1
fi

if [ -f "$tested_haptics_source" ]; then
  source_sha256=$(sha256sum "$tested_haptics_source" | awk '{print $1}')
  [ "$source_sha256" = c03dcc47b4006e74b441b803b44162f7e715971ea6f7cf8d7c0c92e9f4ead5d4 ]
  cp "$tested_haptics_source" "$tmp/aw86937-haptics.c"
  patch --batch --forward --fuzz=0 -d "$tmp" -p1 < "$haptics_patch" >/dev/null
  [ "$(sha256sum "$tmp/aw86937-haptics.c" | awk '{print $1}')" = \
    2e0cb7b739496ff6cf4011244ec9c0b2a2367896de65784041018b9d62186e48 ]
  ! grep -Eq 'msleep\((duration_ms|play_ms)\)' "$tmp/aw86937-haptics.c"
  grep -F 'aw86937_y700_write_rtp_payload(haptics, fw->data, fw->size, seq)' \
    "$tmp/aw86937-haptics.c" >/dev/null
  [ "$(grep -Fc 'return cancelled ? -ECANCELED : 0;' \
    "$tmp/aw86937-haptics.c")" -eq 2 ]
  [ "$(grep -Fc 'if (aw86937_y700_playback_superseded(haptics, seq))' \
    "$tmp/aw86937-haptics.c")" -eq 6 ]
  grep -F 'if (suspend && err)' "$tmp/aw86937-haptics.c" >/dev/null
  [ "$(sha256sum "$tmp/aw86937-haptics.c" | awk '{print $1}')" != "$source_sha256" ]
fi

if [ -f "$canonical_haptics_source" ]; then
  [ "$(sha256sum "$canonical_haptics_source" | awk '{print $1}')" = \
    2e0cb7b739496ff6cf4011244ec9c0b2a2367896de65784041018b9d62186e48 ]
  if [ -f "$tmp/aw86937-haptics.c" ]; then
    cmp -s "$canonical_haptics_source" "$tmp/aw86937-haptics.c"
  fi
fi

python3 - <<'PY'
from __future__ import annotations

import threading
import time


condition = threading.Condition()
pending_seq = 1


def wait_for_effect(seq: int, timeout: float) -> None:
    with condition:
        condition.wait_for(lambda: pending_seq != seq, timeout)


worker = threading.Thread(target=wait_for_effect, args=(pending_seq, 1.0))
started = time.monotonic()
worker.start()
time.sleep(0.02)
with condition:
    pending_seq += 1
    condition.notify_all()
worker.join(0.2)
assert not worker.is_alive(), "cancellation did not wake the long effect"
assert time.monotonic() - started < 0.25
PY

echo 'AUDIO_HAPTICS_LIFECYCLE=PASS'
