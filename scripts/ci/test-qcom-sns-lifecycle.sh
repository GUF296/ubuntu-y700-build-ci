#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
init="$SCRIPT_DIR/payloads/qcom-sns-init"
service="$SCRIPT_DIR/payloads/qcom-sns-init.service"
dropin="$SCRIPT_DIR/payloads/99-qcom-sns.conf"
rules="$SCRIPT_DIR/payloads/80-tb321fu-qcom-sns.rules"
resume="$SCRIPT_DIR/payloads/qcom-sns-resume"
builder="$SCRIPT_DIR/build-y700-sensor-debs.sh"
hexagon_patch="$SCRIPT_DIR/patches/hexagonrpc-qcom-sns-generation.patch"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-qcom-sns.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

root="$tmp/root"
state="$tmp/state"
logs="$tmp/logs"
device="$tmp/fastrpc-adsp"
mock="$tmp/hexagonrpcd"
registry="$state/persist/sensors/registry/registry"

mkdir -p "$root/sensors/registry" "$root/sensors/config" \
  "$root/.tb321fu-manifests" "$logs" "$registry"
printf 'source-a\n' >"$root/sensors/registry/a"
printf 'source-b\n' >"$root/sensors/registry/b"
printf 'config\n' >"$root/sensors/config/device.conf"
(cd "$root" && sha256sum sensors/registry/a sensors/registry/b \
  >.tb321fu-manifests/registry.sha256)
(cd "$root" && sha256sum sensors/config/device.conf \
  >.tb321fu-manifests/config.sha256)
: >"$device"

cat >"$mock" <<'EOF_MOCK'
#!/bin/sh
set -eu
target=${QCOM_SNS_REGISTRY_ROOT:?}
mkdir -p "$target"
printf 'calibration\n' >"$target/calibration"
printf 'one\n' >"$target/generated-1"
printf 'two\n' >"$target/generated-2"
case ${MOCK_MODE:-success} in
  success)
    echo QCOM_SNS_REGISTRY_ACCESS >&2
    ;;
  fail)
    echo QCOM_SNS_REGISTRY_ACCESS >&2
    exit 7
    ;;
  no-marker)
    ;;
  timeout)
    echo QCOM_SNS_REGISTRY_ACCESS >&2
    sleep 5
    ;;
  flood)
    dd if=/dev/zero bs=65536 count=64 2>/dev/null
    ;;
  *) exit 9 ;;
esac
EOF_MOCK
chmod 0755 "$mock"

shim_bin="$tmp/bin"
mkdir -p "$shim_bin"
cat >"$shim_bin/mv" <<'EOF_MV_SHIM'
#!/bin/sh
set -eu
last=
for argument do
  last=$argument
done
/usr/bin/mv "$@"
case ${MV_SIGNAL_MODE:-} in
  registry)
    [ "$last" != "${MV_SIGNAL_DESTINATION:-}" ] || kill -TERM "$PPID"
    ;;
  legacy)
    case $last in
      "${MV_SIGNAL_LEGACY_PREFIX:-}"*) kill -TERM "$PPID" ;;
    esac
    ;;
esac
EOF_MV_SHIM
chmod 0755 "$shim_bin/mv"

run_init() {
  PATH="$shim_bin:/usr/bin:/bin" \
  QCOM_SNS_HEXAGONRPCD="$mock" \
  QCOM_SNS_DEVICE_ROOT="$root" \
  QCOM_SNS_STATE_ROOT="$state" \
  QCOM_SNS_FASTRPC_DEVICE="$device" \
  QCOM_SNS_LOG_DIR="$logs" \
  QCOM_SNS_INIT_TIMEOUT="${TEST_TIMEOUT:-2}" \
  QCOM_SNS_MIN_REGISTRY_FILES=3 \
  MV_SIGNAL_MODE="${MV_SIGNAL_MODE:-}" \
  MV_SIGNAL_DESTINATION="$registry" \
  MV_SIGNAL_LEGACY_PREFIX="$state/.legacy-registry." \
  MOCK_MODE="${MOCK_MODE:-success}" \
    "$init"
}

# A complete legacy directory is migrated, but only after this run succeeds.
printf 'legacy\n' >"$registry/legacy-calibration"
run_init
[ -L "$registry" ]
first_target=$(readlink "$registry")
[ -f "$registry/calibration" ]
[ -s "$state/current.ready" ]
first_manifest=$(sha256sum "$(dirname "$(readlink -f "$registry")")/manifest.sha256")

# Old files and a current-run marker cannot mask a failing hexagonrpcd.
if MOCK_MODE=fail run_init; then
  echo 'failing hexagonrpcd unexpectedly committed a generation' >&2
  exit 1
fi
[ "$(readlink "$registry")" = "$first_target" ]
[ "$(sha256sum "$(dirname "$(readlink -f "$registry")")/manifest.sha256")" = "$first_manifest" ]

# A zero exit without evidence of registry access is not readiness.
if MOCK_MODE=no-marker run_init; then
  echo 'marker-free hexagonrpcd unexpectedly committed a generation' >&2
  exit 1
fi
[ "$(readlink "$registry")" = "$first_target" ]

# A readiness publication failure happens before the registry commit and must
# leave the accepted generation intact.
rm -f -- "$state/current.ready"
mkdir "$state/current.ready"
if MOCK_MODE=success run_init; then
  echo 'invalid readiness path unexpectedly allowed a generation commit' >&2
  exit 1
fi
[ "$(readlink "$registry")" = "$first_target" ]
rmdir "$state/current.ready"

# A repeated successful generation switches slots and preserves calibration.
MOCK_MODE=success run_init
second_target=$(readlink "$registry")
[ "$second_target" != "$first_target" ]
[ "$(cat "$registry/calibration")" = calibration ]
[ "$(readlink "$state/current.ready")" = 'persist/sensors/registry/registry/../ready.env' ]
[ -s "$state/current.ready" ]
(cd "$(dirname "$(readlink -f "$registry")")" && sha256sum -c manifest.sha256 >/dev/null)

# A stop/SSR signal delivered immediately after the atomic registry rename must
# never make cleanup delete the generation that just became visible.
if MV_SIGNAL_MODE=registry run_init; then
  echo 'post-publication TERM unexpectedly reported success' >&2
  exit 1
fi
[ -L "$registry" ]
signalled_target=$(readlink -f "$registry")
[ -d "$signalled_target" ]
[ -f "$registry/calibration" ]
run_init
[ -d "$(readlink -f "$registry")" ]

# A listener that remains healthy until the bounded timeout is also accepted.
MOCK_MODE=timeout TEST_TIMEOUT=1 run_init
[ -f "$registry/generated-2" ]
grep -q '^hexagonrpcd_rc=124$' "$state/current.ready"

# Source payload drift fails before replacing the accepted generation.
accepted_target=$(readlink "$registry")
printf 'tampered\n' >"$root/sensors/config/device.conf"
if run_init; then
  echo 'tampered source manifest unexpectedly passed' >&2
  exit 1
fi
[ "$(readlink "$registry")" = "$accepted_target" ]
printf 'config\n' >"$root/sensors/config/device.conf"

# A signal between moving a legacy directory aside and publishing the managed
# symlink must restore the legacy directory. A later run then migrates it.
rm -rf -- "$state"
mkdir -p "$registry"
printf 'legacy-after-signal\n' >"$registry/legacy-after-signal"
if MV_SIGNAL_MODE=legacy run_init; then
  echo 'legacy pre-publication TERM unexpectedly reported success' >&2
  exit 1
fi
[ -d "$registry" ] && [ ! -L "$registry" ]
[ -f "$registry/legacy-after-signal" ]
run_init
[ -L "$registry" ] && [ -d "$(readlink -f "$registry")" ]

# The legacy branch has a second signal window after publishing the managed
# symlink but before the parent shell records publication. Cleanup must detect
# the visible target, preserve it and remove the moved legacy backup.
rm -rf -- "$state"
mkdir -p "$registry"
printf 'legacy-published-before-term\n' >"$registry/legacy-published-before-term"
if MV_SIGNAL_MODE=registry run_init; then
  echo 'legacy post-publication TERM unexpectedly reported success' >&2
  exit 1
fi
[ -L "$registry" ]
[ -d "$(readlink -f "$registry")" ]
[ -f "$registry/legacy-published-before-term" ]
[ -z "$(find "$state" -maxdepth 1 -name '.legacy-registry.*' -print -quit)" ]
run_init
[ -L "$registry" ] && [ -d "$(readlink -f "$registry")" ]

# Repeated SSR/resume must not grow the private diagnostic log without bound.
truncate -s 2097152 "$logs/hexagonrpcd-init.log"
run_init
[ "$(stat -c '%s' "$logs/hexagonrpcd-init.log")" -lt 600000 ]
[ "$(stat -c '%a' "$logs/hexagonrpcd-init.log")" = 640 ]
flood_target=$(readlink "$registry")
if MOCK_MODE=flood run_init; then
  echo 'unbounded hexagonrpcd output unexpectedly passed' >&2
  exit 1
fi
[ "$(readlink "$registry")" = "$flood_target" ]
[ "$(stat -c '%s' "$logs/hexagonrpcd-init.log")" -lt 600000 ]

# A broken link is recoverable only when its literal target is one of the two
# managed slots; arbitrary symlink targets remain fatal.
rm -rf -- "$state"
mkdir -p "$state/persist/sensors/registry" "$state/generations"
ln -s ../../../generations/slot-a/registry "$registry"
run_init
[ -L "$registry" ] && [ -d "$(readlink -f "$registry")" ]

rm -f -- "$registry"
ln -s /tmp/unmanaged-qcom-sns-registry "$registry"
if run_init; then
  echo 'unmanaged qcom-sns registry symlink unexpectedly passed' >&2
  exit 1
fi
rm -f -- "$registry"
run_init
[ -L "$registry" ] && [ -d "$(readlink -f "$registry")" ]

# A power loss after moving the legacy directory can leave the process-PID
# backup behind. Exactly one regular orphan is recovered; ambiguous state is
# rejected instead of silently choosing calibration data.
rm -rf -- "$state"
mkdir -p "$registry"
printf 'orphaned-calibration\n' >"$registry/orphaned-calibration"
mv -T -- "$registry" "$state/.legacy-registry.4242"
run_init
[ -L "$registry" ] && [ -f "$registry/orphaned-calibration" ]
[ -z "$(find "$state" -maxdepth 1 -name '.legacy-registry.*' -print -quit)" ]

# If an active managed slot exists but its manifest is incomplete after power
# loss, the unique legacy orphan must win instead of being deleted early.
rm -rf -- "$state"
mkdir -p \
  "$state/generations/slot-a/registry" \
  "$state/persist/sensors/registry" \
  "$state/.legacy-registry.4343"
printf 'incomplete-active\n' >"$state/generations/slot-a/registry/incomplete"
printf 'recoverable-calibration\n' > \
  "$state/.legacy-registry.4343/recoverable-calibration"
ln -s ../../../generations/slot-a/registry "$registry"
run_init
[ -L "$registry" ] && [ -f "$registry/recoverable-calibration" ]
[ -z "$(find "$state" -maxdepth 1 -name '.legacy-registry.*' -print -quit)" ]

rm -rf -- "$state"
mkdir -p "$state"
ln -s /tmp "$state/.legacy-registry.4444"
if run_init; then
  echo 'symlinked legacy orphan unexpectedly passed' >&2
  exit 1
fi

rm -rf -- "$state"
mkdir -p "$state/.legacy-registry.1" "$state/.legacy-registry.2"
if run_init; then
  echo 'multiple legacy orphans unexpectedly passed' >&2
  exit 1
fi
rm -rf -- "$state"
run_init
[ -L "$registry" ] && [ -d "$(readlink -f "$registry")" ]

[ "$(find "$state/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 2 ]
[ -z "$(find "$state" -maxdepth 1 -name '.legacy-registry.*' -print -quit)" ]

grep -Fq 'BindsTo=dev-fastrpc\x2dadsp.device' "$service"
grep -Fq 'PartOf=qrtr-ns.service' "$service"
grep -Fq 'BindsTo=qcom-sns-init.service' "$dropin"
grep -Fq 'PartOf=qcom-sns-init.service' "$dropin"
grep -Fq 'qcom-sns-init.service iio-sensor-proxy.service' "$rules"
grep -Fq 'systemctl --no-block restart qcom-sns-init.service iio-sensor-proxy.service' "$resume"
! grep -R -E 'y700-sns-init\.sh|y700-iio-sensor-proxy|80-y700-iio' \
  "$SCRIPT_DIR/payloads"
grep -Fq "'Conflicts: iio-sensor-proxy'" "$builder"
grep -Fq "'Conflicts: y700-sensors'" "$builder"
grep -Fq 'remove|deconfigure)' "$builder"
grep -Fq 'multi-user.target.wants/qcom-sns-init.service' "$builder"
grep -Fq '(uintmax_t)stats.st_size > UINT32_MAX' "$hexagon_patch"
grep -Fq 'bytes_read < (size_t)stats.st_size' "$hexagon_patch"
grep -Fq 'contents[bytes_read] = '\''\0'\''' "$hexagon_patch"
grep -Fq 'goto next_compatible' "$hexagon_patch"

echo 'QCOM_SNS_LIFECYCLE=PASS'
