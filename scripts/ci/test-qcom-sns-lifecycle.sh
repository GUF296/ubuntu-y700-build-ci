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
  *) exit 9 ;;
esac
EOF_MOCK
chmod 0755 "$mock"

run_init() {
  QCOM_SNS_HEXAGONRPCD="$mock" \
  QCOM_SNS_DEVICE_ROOT="$root" \
  QCOM_SNS_STATE_ROOT="$state" \
  QCOM_SNS_FASTRPC_DEVICE="$device" \
  QCOM_SNS_LOG_DIR="$logs" \
  QCOM_SNS_INIT_TIMEOUT="${TEST_TIMEOUT:-2}" \
  QCOM_SNS_MIN_REGISTRY_FILES=3 \
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

[ "$(find "$state/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 2 ]
[ ! -e "$state/.legacy-registry.$$" ]

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
