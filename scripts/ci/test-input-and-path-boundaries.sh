#!/usr/bin/env bash
set -euo pipefail
# Report silent assertion failures without echoing the command, environment
# or fixture data; the hosted/local aggregate can then identify the boundary.
trap 'case $- in *e*) printf "input boundary fixture failed: line=%d status=%d\n" "$LINENO" "$?" >&2 ;; esac' ERR

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

ci_validate_output_dir out/ci-rootfs
for hostile_output in /tmp/out ../escape 'out/with space' 'out/with;command' 'out/..'; do
  if (ci_validate_output_dir "$hostile_output") >/dev/null 2>&1; then
    printf 'accepted hostile OUTPUT_DIR: %s\n' "$hostile_output" >&2
    exit 1
  fi
done
grep -Fq 'ci_validate_output_dir "$OUTPUT_DIR"' "$SCRIPT_DIR/build-rootfs-image.sh" || {
  echo 'rootfs builder does not validate OUTPUT_DIR before creating output files' >&2
  exit 1
}
grep -Fq 'ci_validate_resolv_conf_content "$RESOLV_CONF_CONTENT"' \
  "$SCRIPT_DIR/build-rootfs-image.sh" || {
  echo 'rootfs builder does not bound resolv.conf content before image work' >&2
  exit 1
}
grep -Fq 'ci_validate_volume_size "$BOOT_CHUNK_SIZE" BOOT_CHUNK_SIZE' \
  "$SCRIPT_DIR/build-grub-image.sh" || {
  echo 'GRUB builder does not bound 7-Zip volume size before image work' >&2
  exit 1
}
grep -Fq "unsupported .tar.zst device overlay (no bounded decoder)" \
  "$SCRIPT_DIR/build-rootfs-image.sh"
if [ "$(grep -Fc -- "-name '*.tar.zst'" "$SCRIPT_DIR/build-rootfs-image.sh")" -ne 1 ]; then
  echo 'rootfs builder still advertises .tar.zst as an extractable device overlay' >&2
  exit 1
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

expected=$'base\nlibfoo:arm64\npkg=1.2-3'
actual=$(ci_normalize_package_list $'base libfoo:arm64\npkg=1.2-3')
[ "$actual" = "$expected" ]
for hostile in '--config' 'lib*' '$(touch /tmp/not-run)' 'bad/token'; do
  if (ci_normalize_package_list "$hostile") >/dev/null 2>&1; then
    printf 'accepted hostile package token: %s\n' "$hostile" >&2
    exit 1
  fi
done

touch "$scratch/boot.img" "$scratch/rootfs.img"
ci_require_distinct_paths BOOT "$scratch/boot.img" ROOTFS "$scratch/rootfs.img" OUTPUT "$scratch/disk.img"
if (ci_require_distinct_paths BOOT "$scratch/boot.img" OUTPUT "$scratch/./boot.img") >/dev/null 2>&1; then
  echo 'accepted canonically identical paths' >&2
  exit 1
fi
ln "$scratch/boot.img" "$scratch/boot-hardlink.img"
if (ci_require_distinct_paths BOOT "$scratch/boot.img" OUTPUT "$scratch/boot-hardlink.img") >/dev/null 2>&1; then
  echo 'accepted hard-linked paths' >&2
  exit 1
fi

mkdir -p "$scratch/cleanup/.rootfs-build.target/child"
cleanup_target=$(realpath -e "$scratch/cleanup/.rootfs-build.target")
FAKE_MOUNTS=$cleanup_target
findmnt() {
  python3 -IB -c 'import json,sys; print(json.dumps({"filesystems":[{"target":p} for p in ("/",*sys.argv[1:]) if p]}))' \
    "$FAKE_MOUNTS"
}
if ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .rootfs-build. >/dev/null 2>&1; then
  echo 'deleted a target that is itself a mount root' >&2
  exit 1
fi
test -d "$cleanup_target"
FAKE_MOUNTS=$cleanup_target/child
if ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .rootfs-build. >/dev/null 2>&1; then
  echo 'deleted a target containing a descendant mount' >&2
  exit 1
fi
mkdir "$cleanup_target/space sample"
FAKE_MOUNTS="$cleanup_target/space sample"
[[ $(cd "$scratch/cleanup" && ci_mount_targets_below .rootfs-build.target) == "$FAKE_MOUNTS" ]] ||
  { echo 'relative root or literal space in mount target was lost' >&2; exit 1; }
FAKE_MOUNTS=
ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .rootfs-build.
test ! -e "$cleanup_target"

download_fixture="$scratch/download"
mkdir -p "$download_fixture"
printf 'complete pinned SDK bytes\n' > "$download_fixture/payload"
printf 'wrong bytes\n' > "$download_fixture/wrong-payload"
download_sha256=$(sha256sum "$download_fixture/payload" | awk '{print $1}')
cat > "$download_fixture/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_CURL_ARGS:?}"
: "${FAKE_CURL_COUNT:?}"
: "${FAKE_CURL_MODE:?}"
: "${FAKE_CURL_PAYLOAD:?}"
: "${FAKE_CURL_WRONG_PAYLOAD:?}"
count=0
if [ -f "$FAKE_CURL_COUNT" ]; then
  read -r count < "$FAKE_CURL_COUNT"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CURL_COUNT"
printf '%s\n' "$@" > "$FAKE_CURL_ARGS.$count"
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || exit 2
      output=$2
      shift 2
      ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 2
case "$FAKE_CURL_MODE" in
  resume)
    case "$count" in
      1) head -c 8 -- "$FAKE_CURL_PAYLOAD" > "$output"; exit 92 ;;
      2)
        offset=$(wc -c < "$output")
        tail -c "+$((offset + 1))" -- "$FAKE_CURL_PAYLOAD" >> "$output"
        ;;
      *) exit 3 ;;
    esac
    ;;
  range-reset)
    case "$count" in
      1) head -c 8 -- "$FAKE_CURL_PAYLOAD" > "$output"; exit 92 ;;
      2) [ -s "$output" ] || exit 4; exit 33 ;;
      3) [ ! -e "$output" ] || exit 5; cp -- "$FAKE_CURL_PAYLOAD" "$output" ;;
      *) exit 6 ;;
    esac
    ;;
  complete-error)
    cp -- "$FAKE_CURL_PAYLOAD" "$output"
    exit 92
    ;;
  exhaust)
    head -c 8 -- "$FAKE_CURL_PAYLOAD" > "$output"
    exit 92
    ;;
  slow-exhaust)
    head -c 8 -- "$FAKE_CURL_PAYLOAD" > "$output"
    sleep "${FAKE_CURL_SLEEP:-3}"
    exit 92
    ;;
  corrupt) cp -- "$FAKE_CURL_WRONG_PAYLOAD" "$output" ;;
  *) exit 7 ;;
esac
SH
chmod 0700 "$download_fixture/curl"
export FAKE_CURL_PAYLOAD="$download_fixture/payload"
export FAKE_CURL_WRONG_PAYLOAD="$download_fixture/wrong-payload"

openpgp_fpr=0123456789ABCDEF0123456789ABCDEF01234567
printf 'parseable but truncated OpenPGP export prefix\n' > "$download_fixture/openpgp-prefix"
cat > "$download_fixture/gpg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_OPENPGP_FPR:?}"
printf 'pub:::::::::\nfpr:::::::::%s:\n' "$FAKE_OPENPGP_FPR"
SH
chmod 0700 "$download_fixture/gpg"
export FAKE_OPENPGP_FPR=$openpgp_fpr
PATH="$download_fixture:$PATH" ci_verify_download \
  "$download_fixture/openpgp-prefix" "openpgp-fpr:$openpgp_fpr"

if (
  export PATH="$download_fixture:$PATH"
  export FAKE_CURL_ARGS="$download_fixture/openpgp.args"
  export FAKE_CURL_COUNT="$download_fixture/openpgp.count"
  export FAKE_CURL_MODE=complete-error
  export FAKE_CURL_PAYLOAD="$download_fixture/openpgp-prefix"
  CI_CURL_BIN="$download_fixture/curl" ci_download \
    https://example.invalid/archive-key.gpg \
    "$download_fixture/openpgp" "openpgp-fpr:$openpgp_fpr"
) >/dev/null 2>&1; then
  echo 'nonzero curl exit accepted a parseable OpenPGP prefix' >&2
  exit 1
fi
[ "$(cat "$download_fixture/openpgp.count")" = 24 ]
[ ! -e "$download_fixture/openpgp" ]
if compgen -G "$download_fixture/openpgp.part.*" >/dev/null; then
  echo 'rejected OpenPGP prefix download left a partial file' >&2
  exit 1
fi

export FAKE_CURL_ARGS="$download_fixture/resume.args"
export FAKE_CURL_COUNT="$download_fixture/resume.count"
export FAKE_CURL_MODE=resume
CI_CURL_BIN="$download_fixture/curl" ci_download \
  https://example.invalid/kernel-sdk.tar.gz \
  "$download_fixture/resumed" "$download_sha256"
cmp -s "$download_fixture/payload" "$download_fixture/resumed"
[ "$(cat "$FAKE_CURL_COUNT")" = 2 ]
python3 - "$FAKE_CURL_ARGS" <<'PY'
from pathlib import Path
import sys

expected_prefix = [
    "--disable",
    "--proto", "=https",
    "--proto-redir", "=https",
    "--tlsv1.2",
    "--http1.1",
    "--fail",
    "--location",
    "--connect-timeout", "30",
    "--max-time", "3600.000",
    "--speed-limit", "1024",
    "--speed-time", "300",
    "--continue-at", "-",
    "--output",
]
logs = sorted(Path(sys.argv[1]).parent.glob(Path(sys.argv[1]).name + ".*"))
assert len(logs) == 2, logs
outputs = []
for log in logs:
    lines = log.read_text().splitlines()
    assert lines[:-2] == expected_prefix, log
    assert lines[-1] == "https://example.invalid/kernel-sdk.tar.gz", log
    outputs.append(lines[-2])
assert outputs[0] == outputs[1], outputs
assert ".resumed.part." in outputs[0], outputs
assert not Path(outputs[0]).exists(), outputs
PY

export FAKE_CURL_ARGS="$download_fixture/complete.args"
export FAKE_CURL_COUNT="$download_fixture/complete.count"
export FAKE_CURL_MODE=complete-error
CI_CURL_BIN="$download_fixture/curl" ci_download \
  https://example.invalid/kernel-sdk.tar.gz \
  "$download_fixture/complete" "sha256:$download_sha256"
cmp -s "$download_fixture/payload" "$download_fixture/complete"
[ "$(cat "$FAKE_CURL_COUNT")" = 1 ]

export FAKE_CURL_ARGS="$download_fixture/range.args"
export FAKE_CURL_COUNT="$download_fixture/range.count"
export FAKE_CURL_MODE=range-reset
CI_CURL_BIN="$download_fixture/curl" ci_download \
  https://example.invalid/kernel-sdk.tar.gz \
  "$download_fixture/range" "$download_sha256"
cmp -s "$download_fixture/payload" "$download_fixture/range"
[ "$(cat "$FAKE_CURL_COUNT")" = 3 ]

if (
  CI_CURL_BIN="$download_fixture/curl" \
    FAKE_CURL_ARGS="$download_fixture/corrupt.args" \
    FAKE_CURL_COUNT="$download_fixture/corrupt.count" \
    FAKE_CURL_MODE=corrupt \
    ci_download https://example.invalid/kernel-sdk.tar.gz \
      "$download_fixture/rejected" "$download_sha256"
) >/dev/null 2>&1; then
  echo 'wrong-digest HTTPS download was accepted' >&2
  exit 1
fi
[ ! -e "$download_fixture/rejected" ]
if compgen -G "$download_fixture/rejected.part.*" >/dev/null; then
  echo 'wrong-digest HTTPS download left a partial file' >&2
  exit 1
fi

if (
  CI_CURL_BIN="$download_fixture/curl" \
    FAKE_CURL_ARGS="$download_fixture/exhaust.args" \
    FAKE_CURL_COUNT="$download_fixture/exhaust.count" \
    FAKE_CURL_MODE=exhaust \
    ci_download https://example.invalid/kernel-sdk.tar.gz \
      "$download_fixture/exhausted" "$download_sha256"
) >/dev/null 2>&1; then
  echo 'exhausted HTTPS download was accepted' >&2
  exit 1
fi
[ "$(cat "$download_fixture/exhaust.count")" = 24 ]
[ ! -e "$download_fixture/exhausted" ]
if compgen -G "$download_fixture/exhausted.part.*" >/dev/null; then
  echo 'exhausted HTTPS download left a partial file' >&2
  exit 1
fi

for invalid_download_setting in \
  'CI_DOWNLOAD_MAX_ATTEMPTS=0' \
  'CI_DOWNLOAD_MAX_ATTEMPTS=33' \
  'CI_DOWNLOAD_DEADLINE_SECONDS=9' \
  'CI_DOWNLOAD_DEADLINE_SECONDS=86401'; do
  if (
    export FAKE_CURL_ARGS="$download_fixture/invalid.args"
    export FAKE_CURL_COUNT="$download_fixture/invalid.count"
    export FAKE_CURL_MODE=exhaust
    eval "export $invalid_download_setting"
    CI_CURL_BIN="$download_fixture/curl" ci_download \
      https://example.invalid/kernel-sdk.tar.gz \
      "$download_fixture/invalid" "$download_sha256"
  ) >/dev/null 2>&1; then
    echo "accepted invalid download budget: $invalid_download_setting" >&2
    exit 1
  fi
done

deadline_started=$(ci_monotonic_millis)
if (
  CI_DOWNLOAD_DEADLINE_SECONDS=10 \
    CI_DOWNLOAD_MAX_ATTEMPTS=24 \
    CI_CURL_BIN="$download_fixture/curl" \
    FAKE_CURL_ARGS="$download_fixture/deadline.args" \
    FAKE_CURL_COUNT="$download_fixture/deadline.count" \
    FAKE_CURL_MODE=slow-exhaust \
    FAKE_CURL_SLEEP=3 \
    ci_download https://example.invalid/kernel-sdk.tar.gz \
      "$download_fixture/deadline" "$download_sha256"
) >/dev/null 2>&1; then
  echo 'overall HTTPS download deadline was not enforced' >&2
  exit 1
fi
deadline_elapsed=$(( $(ci_monotonic_millis) - deadline_started ))
deadline_attempts=$(cat "$download_fixture/deadline.count")
# The old pair of AND lists silently accepted an elapsed time or an attempt
# count below its lower bound under Bash errexit. Keep both original bounds.
if ! (( deadline_elapsed >= 10000 && deadline_elapsed < 18000 && deadline_attempts >= 3 && deadline_attempts <= 4 )); then
  printf 'overall deadline fixture: elapsed_ms=%s attempts=%s (expected 10-18s, 3-4 attempts)\n' "$deadline_elapsed" "$deadline_attempts" >&2
  exit 1
fi
[ ! -e "$download_fixture/deadline" ]
if compgen -G "$download_fixture/deadline.part.*" >/dev/null; then
  echo 'deadline-expired HTTPS download left a partial file' >&2
  exit 1
fi
python3 - "$download_fixture/deadline.args" <<'PY'
from pathlib import Path
import sys

timeouts = []
for log in sorted(Path(sys.argv[1]).parent.glob(Path(sys.argv[1]).name + ".*")):
    lines = log.read_text().splitlines()
    index = lines.index("--max-time")
    timeouts.append(float(lines[index + 1]))
assert timeouts and timeouts[0] <= 10.0, timeouts
assert all(0 < timeout <= 10.0 for timeout in timeouts), timeouts
assert timeouts == sorted(timeouts, reverse=True), timeouts
PY

# A deterministic clock catches the former whole-second ceiling: when only
# 9.999 seconds (or 0.001 seconds) remain, curl must receive that exact budget,
# rather than a rounded-up value that can overrun the outer deadline.
exact_deadline_dir="$download_fixture/exact-deadline"
mkdir -p "$exact_deadline_dir"
set +e
(
  exact_clock_file="$exact_deadline_dir/clock.count"
  printf '0\n' > "$exact_clock_file"
  ci_monotonic_millis() {
    local call
    call=$(cat "$exact_clock_file")
    case "$call" in
      0) printf '100000\n' ;;
      1) printf '100001\n' ;;
      2) printf '109999\n' ;;
      *) printf '110000\n' ;;
    esac
    printf '%s\n' "$((call + 1))" > "$exact_clock_file"
  }
  CI_DOWNLOAD_DEADLINE_SECONDS=10 \
    CI_DOWNLOAD_MAX_ATTEMPTS=24 \
    CI_CURL_BIN="$download_fixture/curl" \
    FAKE_CURL_ARGS="$exact_deadline_dir/curl.args" \
    FAKE_CURL_COUNT="$exact_deadline_dir/curl.count" \
    FAKE_CURL_MODE=exhaust \
    ci_download https://example.invalid/kernel-sdk.tar.gz \
      "$exact_deadline_dir/output" "$download_sha256"
)
exact_deadline_status=$?
set -e
[ "$exact_deadline_status" -ne 0 ] || {
  echo 'deterministic deadline fixture unexpectedly succeeded' >&2
  exit 1
}
[ "$(cat "$exact_deadline_dir/curl.count")" = 2 ] || {
  echo 'deterministic deadline fixture made an unexpected curl count' >&2
  exit 1
}
python3 - "$exact_deadline_dir/curl.args" <<'PY'
from pathlib import Path
import sys

logs = sorted(Path(sys.argv[1]).parent.glob(Path(sys.argv[1]).name + ".*"))
timeouts = []
for log in logs:
    lines = log.read_text().splitlines()
    timeouts.append(lines[lines.index("--max-time") + 1])
assert timeouts == ["9.999", "0.001"], timeouts
PY
[ ! -e "$exact_deadline_dir/output" ]
if compgen -G "$exact_deadline_dir/output.part.*" >/dev/null; then
  echo 'deterministic deadline fixture left a partial file' >&2
  exit 1
fi

ci_download "$download_fixture/payload" "$download_fixture/local" "$download_sha256"
cmp -s "$download_fixture/payload" "$download_fixture/local"
grep -Fq 'cp --reflink=auto -- "$src" "$tmp"' "$SCRIPT_DIR/common.sh"
ln -s payload "$download_fixture/local-link"
if (ci_download "$download_fixture/local-link" "$download_fixture/local-link-output") \
  >/dev/null 2>&1; then
  echo 'symlink local download source was accepted' >&2
  exit 1
fi
[ ! -e "$download_fixture/local-link-output" ]

# A destination path must not escape through a symlinked directory or replace
# an existing symlink. The check runs before the private temporary file is
# created, so neither case may write through the link.
mkdir -p "$download_fixture/real-destination"
ln -s real-destination "$download_fixture/destination-link"
if (ci_download "$download_fixture/payload" \
    "$download_fixture/destination-link/escaped" "$download_sha256") \
    >/dev/null 2>&1; then
  echo 'accepted a symlinked download destination ancestor' >&2
  exit 1
fi
[ ! -e "$download_fixture/real-destination/escaped" ]
ln -s payload "$download_fixture/output-link"
if (ci_download "$download_fixture/payload" \
    "$download_fixture/output-link" "$download_sha256") \
    >/dev/null 2>&1; then
  echo 'accepted a symlinked download destination' >&2
  exit 1
fi

valid_hash='$6$tb321fu$zJjB0r4FpYTJ.Vtx4o/xHvn.VWOIHRPQPK.XmV3VXaAkhjWoFVZ8sV5lunaP32xQWicW7vMaOBLlnq0bbQ.1g.'
valid_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f tb321fu-test'
valid_sk_key='sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fAAAAC3NzaDp0YjMyMWZ1 tb321fu-sk-test'
# The target can have no Python crypt module (or no Python yet). An actual
# libcrypt probe must still accept the fixture quietly in that environment.
if ! (python3() { return 127; }; ci_validate_password_hash "$valid_hash") >"$scratch/crypt-output" 2>&1 ||
   [ -s "$scratch/crypt-output" ]; then
  echo 'bootstrapped crypt validation failed or emitted data' >&2
  exit 1
fi
# This has a permitted yescrypt envelope but an invalid algorithm setting.
# Insist on the backend failure, not just any nonzero status or syntax check.
printf -v bad_setting '$y$.$fixture$%043d' 0
if (ci_validate_password_hash "$bad_setting") >"$scratch/crypt-output" 2>&1 ||
   [[ $(<"$scratch/crypt-output") != 'error: DEFAULT_USER_PASSWORD_HASH is not accepted by the host crypt(3) implementation' ]]; then
  echo 'invalid crypt setting did not fail quietly at the libcrypt boundary' >&2
  exit 1
fi
if (PATH="$scratch/no-command-directory" ci_validate_password_hash "$valid_hash") >"$scratch/crypt-output" 2>&1 ||
   [[ $(<"$scratch/crypt-output") != 'error: could not run the crypt(3) validator; verify perl-base and libcrypt1 are installed' ]]; then
  echo 'missing crypt interpreter was misreported as an invalid password hash' >&2
  exit 1
fi
ci_require_sudo_password_hash password "$valid_hash"
ci_validate_authorized_keys "$valid_key"
ci_validate_authorized_keys "$valid_sk_key"
ci_require_sudo_password_hash nopasswd '!'
ci_require_sudo_password_hash none ''
if (ci_require_sudo_password_hash password '') >/dev/null 2>&1; then
  echo 'accepted an absent password hash for password sudo' >&2
  exit 1
fi
if (ci_require_sudo_password_hash password '!') >/dev/null 2>&1; then
  echo 'accepted a locked password hash for password sudo' >&2
  exit 1
fi
if (
  ci_require_user_access_path '!' '' 1
  ci_require_sudo_password_hash password '!'
) >/dev/null 2>&1; then
  echo 'autologin bypassed the password sudo hash requirement' >&2
  exit 1
fi
if (ci_require_sudo_password_hash password '*') >/dev/null 2>&1; then
  echo 'accepted an invalid password hash for password sudo' >&2
  exit 1
fi
if (ci_validate_password_hash 'not-a-real-crypt-hash') >/dev/null 2>&1; then
  echo 'accepted a non-crypt string with a password-hash-like length' >&2
  exit 1
fi
if (ci_validate_authorized_keys 'ssh-ed25519 AAAAAAAAAAAAAAAA') >/dev/null 2>&1; then
  echo 'accepted an authorized key with an invalid SSH wire blob' >&2
  exit 1
fi

ci_validate_https_apt_uri https://ports.ubuntu.com/ubuntu-ports
ci_validate_https_apt_sources_list \
  $'deb https://ports.ubuntu.com/ubuntu-ports resolute main\ndeb [arch=arm64 signed-by=/etc/apt/keyrings/mozilla.asc] https://packages.mozilla.org/apt mozilla main'
for unsafe_apt_uri in \
  http://ports.ubuntu.com/ubuntu-ports \
  https://ports.ubuntu.com/ubuntu-ports?mutable=1 \
  https://user@ports.ubuntu.com/ubuntu-ports \
  https://ports.ubuntu-.com/ubuntu-ports \
  https://ports..ubuntu.com/ubuntu-ports \
  https://ports.ubuntu.com:65536/ubuntu-ports \
  file:///mirror; do
  if (ci_validate_https_apt_uri "$unsafe_apt_uri") >/dev/null 2>&1; then
    echo "accepted unsafe APT URI: $unsafe_apt_uri" >&2
    exit 1
  fi
done
ci_validate_apt_proxy http://127.0.0.1:7897
ci_validate_apt_proxy https://proxy.example:443
ci_validate_apt_proxy 'http://[::1]:8080'
ci_validate_apt_proxy 'https://proxy.example:65535'
for unsafe_apt_proxy in \
  'http://127.0.0.1:9"; APT::Update::Pre-Invoke {"printf PWNED";}; //' \
  'http://user:password@proxy.invalid:8080' \
  'http://proxy.invalid:8080/path' \
  $'http://proxy.invalid:8080\nAPT::Update::Pre-Invoke {"id";};' \
  'http://proxy-.invalid:8080' \
  'http://proxy.invalid:65536'; do
  if (ci_validate_apt_proxy "$unsafe_apt_proxy") >/dev/null 2>&1; then
    echo "accepted unsafe APT proxy: $unsafe_apt_proxy" >&2
    exit 1
  fi
done
ci_validate_locales $'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8'
ci_validate_locales 'sr_RS@latin UTF-8'
ci_validate_lang_name_in_locales zh_CN.UTF-8 $'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8'
ci_validate_lang_name_in_locales C ''
ci_validate_timezone Asia/Shanghai
ci_validate_timezone Etc/GMT+8
ci_validate_timezone US/Eastern
ci_validate_timezone ''
for unsafe_timezone in \
  '/etc/passwd' \
  '../etc/passwd' \
  'Etc/../etc/passwd' \
  'Asia//Shanghai' \
  $'Asia/Shanghai\nROOT_PASSWORD_MODE=empty' \
  'Asia/Shanghai.'; do
  if (ci_validate_timezone "$unsafe_timezone") >/dev/null 2>&1; then
    echo "accepted unsafe TZ_REGION: $unsafe_timezone" >&2
    exit 1
  fi
done
for unsafe_locales in \
  '' \
  '   ' \
  $'\\)/\\1/;e printf PWNED;#' \
  'en_US.UTF-8 UTF-8 extra' \
  'en_US.UTF-8;id UTF-8' \
  $'en_US.UTF-8 UTF-8\n$(touch /tmp/locale-pwned)'; do
  if (ci_validate_locales "$unsafe_locales") >/dev/null 2>&1; then
    echo "accepted unsafe LOCALES value: $unsafe_locales" >&2
    exit 1
  fi
done
if (ci_validate_lang_name_in_locales zh_CN.UTF-8 'en_US.UTF-8 UTF-8') >/dev/null 2>&1; then
  echo 'accepted LANG_NAME absent from LOCALES' >&2
  exit 1
fi

ci_validate_rootfs_image_size 1G
ci_validate_rootfs_image_size 2768M
ci_validate_rootfs_image_size 20G
ci_validate_rootfs_image_size 64T
ci_validate_rootfs_image_size 08G
ci_validate_rootfs_image_size 000000000001G
ci_validate_rootfs_image_size 1024M
ci_validate_rootfs_image_size 65536G
ci_validate_rootfs_image_size 1073741824
ci_validate_rootfs_image_size 70368744177664
for unsafe_rootfs_size in '' 0 1073741823 1023M 65537G 65T 70368744177665 \
  999999999999999 -1G 1Gfoo $'20G\nROOTFS_LABEL=pwned'; do
  if (ci_validate_rootfs_image_size "$unsafe_rootfs_size") >/dev/null 2>&1; then
    echo "accepted unsafe ROOTFS_IMAGE_SIZE: $unsafe_rootfs_size" >&2
    exit 1
  fi
done

ci_validate_rootfs_label Ubuntu
ci_validate_rootfs_label Y700-ROOTFS
for unsafe_rootfs_label in '' 'has space' '01234567890123456' '-bad' $'Ubuntu\nROOT_PASSWORD_MODE=empty' $'Ubuntu\r'; do
  if (ci_validate_rootfs_label "$unsafe_rootfs_label") >/dev/null 2>&1; then
    echo "accepted unsafe ROOTFS_LABEL: $unsafe_rootfs_label" >&2
    exit 1
  fi
done

ci_validate_hostname y700
ci_validate_hostname tb321fu-2025
for unsafe_hostname in '' '-bad' 'bad-' 'has space' 'a.b' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  $'y700\nUSER_SUDO_MODE=nopasswd' $'y700\r'; do
  if (ci_validate_hostname "$unsafe_hostname") >/dev/null 2>&1; then
    echo "accepted unsafe HOSTNAME_NAME: $unsafe_hostname" >&2
    exit 1
  fi
done

ci_validate_account_name y700
ci_validate_account_name GUF296
ci_validate_account_name user_2
for unsafe_account in '' '-bad' 'bad.name' 'has space' 'a/b' \
  '123starts-with-digit' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  root systemd-network _apt $'y700\nUSER_SUDO_MODE=nopasswd' $'y700\r'; do
  if (ci_validate_account_name "$unsafe_account") >/dev/null 2>&1; then
    echo "accepted unsafe DEFAULT_USER_NAME: $unsafe_account" >&2
    exit 1
  fi
done

ci_validate_root_password_mode locked
ci_validate_root_password_mode set
ci_validate_root_password_mode empty
for unsafe_root_password_mode in '' SET 'locked\nset' 'set;id'; do
  if (ci_validate_root_password_mode "$unsafe_root_password_mode") >/dev/null 2>&1; then
    echo "accepted unsafe ROOT_PASSWORD_MODE: $unsafe_root_password_mode" >&2
    exit 1
  fi
done
ci_validate_user_sudo_mode password
ci_validate_user_sudo_mode nopasswd
ci_validate_user_sudo_mode none
for unsafe_sudo_mode in '' PASSWORD 'password\nnone' 'none;id'; do
  if (ci_validate_user_sudo_mode "$unsafe_sudo_mode") >/dev/null 2>&1; then
    echo "accepted unsafe USER_SUDO_MODE: $unsafe_sudo_mode" >&2
    exit 1
  fi
done
for bool_value in 0 1 yes no true false on off; do
  ci_validate_bool "$bool_value" fixture
done
if (ci_validate_bool maybe fixture) >/dev/null 2>&1; then
  echo 'accepted an unknown boolean value' >&2
  exit 1
fi
ci_validate_sddm_session plasma
ci_validate_sddm_session plasma.desktop
if (ci_validate_sddm_session $'plasma\nUser=root') >/dev/null 2>&1; then
  echo 'accepted a multiline SDDM session name' >&2
  exit 1
fi
ci_validate_distro_name noble
ci_validate_distro_name resolute
ci_validate_arch_name arm64
ci_validate_debootstrap_variant ''
ci_validate_debootstrap_variant minbase
ci_validate_uuid ''
ci_validate_uuid 01234567-89ab-cdef-0123-456789abcdef
ci_validate_uuid random
ci_validate_partlabel userdata ROOTFS_PARTLABEL
ci_validate_compression 7z
ci_validate_compression none
ci_validate_volume_size ''
ci_validate_volume_size 1M CHUNK_SIZE
ci_validate_volume_size 100M CHUNK_SIZE
ci_validate_volume_size 64G CHUNK_SIZE
for unsafe_distro in 'Noble' 'ubuntu/../../etc' 'ubuntu suite' $'noble\nPWNED'; do
  if (ci_validate_distro_name "$unsafe_distro") >/dev/null 2>&1; then
    echo "accepted unsafe DISTRO: $unsafe_distro" >&2
    exit 1
  fi
done
for unsafe_arch in 'arm64;id' 'arm 64' '../arm64' $'arm64\nPWNED'; do
  if (ci_validate_arch_name "$unsafe_arch") >/dev/null 2>&1; then
    echo "accepted unsafe ARCH: $unsafe_arch" >&2
    exit 1
  fi
done
for unsafe_variant in '../variant' 'min base' 'minbase;id' $'minbase\nPWNED'; do
  if (ci_validate_debootstrap_variant "$unsafe_variant") >/dev/null 2>&1; then
    echo "accepted unsafe DEBOOTSTRAP_VARIANT: $unsafe_variant" >&2
    exit 1
  fi
done
for unsafe_uuid in '01234567-89ab-cdef-0123-456789abcde' 'random;id' $'random\nPWNED'; do
  if (ci_validate_uuid "$unsafe_uuid" ROOTFS_UUID) >/dev/null 2>&1; then
    echo "accepted unsafe ROOTFS_UUID: $unsafe_uuid" >&2
    exit 1
  fi
done
for unsafe_partlabel in 'userdata label' '../userdata' $'userdata\nPWNED'; do
  if (ci_validate_partlabel "$unsafe_partlabel" ROOTFS_PARTLABEL) >/dev/null 2>&1; then
    echo "accepted unsafe ROOTFS_PARTLABEL: $unsafe_partlabel" >&2
    exit 1
  fi
done
for unsafe_compression in gzip '7z;id' $'none\nPWNED'; do
  if (ci_validate_compression "$unsafe_compression") >/dev/null 2>&1; then
    echo "accepted unsafe compression: $unsafe_compression" >&2
    exit 1
  fi
done
for unsafe_volume in 0M 512K 65G 999999999G '100M;id' $'100M\nPWNED'; do
  if (ci_validate_volume_size "$unsafe_volume" CHUNK_SIZE) >/dev/null 2>&1; then
    echo "accepted unsafe volume size: $unsafe_volume" >&2
    exit 1
  fi
done

package_flood=
for ((index = 0; index < 1025; ++index)); do
  package_flood+=" package$index"
done
if (ci_normalize_package_list "$package_flood") >/dev/null 2>&1; then
  echo 'accepted more than 1024 package tokens' >&2
  exit 1
fi

locale_flood=
for ((index = 0; index < 129; ++index)); do
  locale_flood+="locale$index.UTF-8 UTF-8"$'\n'
done
if (ci_validate_locales "$locale_flood") >/dev/null 2>&1; then
  echo 'accepted more than 128 locale records' >&2
  exit 1
fi

apt_source_flood=
for ((index = 0; index < 129; ++index)); do
  apt_source_flood+="deb https://ports.ubuntu.com/ubuntu-ports suite$index main"$'\n'
done
if (ci_validate_https_apt_sources_list "$apt_source_flood") >/dev/null 2>&1; then
  echo 'accepted more than 128 APT source records' >&2
  exit 1
fi

key_flood=
for ((index = 0; index < 257; ++index)); do
  key_flood+="$valid_key"$'\n'
done
if (ci_validate_authorized_keys "$key_flood") >/dev/null 2>&1; then
  echo 'accepted more than 256 authorized keys' >&2
  exit 1
fi

resolv_flood=
for ((index = 0; index < 257; ++index)); do
  resolv_flood+='nameserver 192.0.2.1'$'\n'
done
if (ci_validate_resolv_conf_content "$resolv_flood") >/dev/null 2>&1; then
  echo 'accepted more than 256 resolv.conf records' >&2
  exit 1
fi

for unsafe_scalar in $'safe\nROOT_PASSWORD_MODE=empty' $'safe\rROOT_PASSWORD_MODE=empty'; do
  if (ci_validate_single_line "$unsafe_scalar" workflow-input) >/dev/null 2>&1; then
    echo 'accepted a multiline workflow scalar' >&2
    exit 1
  fi
done
printf 'ROOTFS_LABEL=Ubuntu\000ROOT_PASSWORD_MODE=empty\n' > "$scratch/nul-rootfs.env"
if GITHUB_ENV="$scratch/nul-github.env" bash "$SCRIPT_DIR/apply-workflow-config.sh" \
  "$scratch/nul-rootfs.env" >/dev/null 2>&1; then
  echo 'accepted a NUL byte in workflow configuration' >&2
  exit 1
fi
[ ! -s "$scratch/nul-github.env" ]

# GITHUB_ENV heredoc delimiters must be unpredictable and must never occur in
# the value itself. Exercise one collision followed by retry, then bounded
# all-collision failure without a partial assignment.
delimiter_bin="$scratch/delimiter-bin"
mkdir -p "$delimiter_bin"
cat > "$delimiter_bin/od" <<'OD_FIXTURE'
#!/usr/bin/env bash
count=$(cat "${OD_COUNT_FILE:?}" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$OD_COUNT_FILE"
if [ "${OD_MODE:-retry}" = always ] || [ "$count" -eq 1 ]; then
  printf '%s\n' "$(printf '00%.0s' {1..32})"
else
  printf '%s\n' "$(printf '11%.0s' {1..32})"
fi
OD_FIXTURE
chmod 0755 "$delimiter_bin/od"
collision_value="TB321FU_ENV_RESOLV_CONF_CONTENT_$(printf '00%.0s' {1..32})"
printf 'RESOLV_CONF_CONTENT=%s\n' "$collision_value" > "$scratch/rootfs.env"
printf '0\n' > "$scratch/od-count"
OD_COUNT_FILE="$scratch/od-count" OD_MODE=retry PATH="$delimiter_bin:/usr/bin:/bin" \
  GITHUB_ENV="$scratch/delimiter-retry.env" bash "$SCRIPT_DIR/apply-workflow-config.sh" \
  "$scratch/rootfs.env"
retry_delimiter="TB321FU_ENV_RESOLV_CONF_CONTENT_$(printf '11%.0s' {1..32})"
grep -Fq -- "$retry_delimiter" "$scratch/delimiter-retry.env"
grep -Fq -- "$collision_value" "$scratch/delimiter-retry.env"
: > "$scratch/od-count"
if OD_COUNT_FILE="$scratch/od-count" OD_MODE=always PATH="$delimiter_bin:/usr/bin:/bin" \
  GITHUB_ENV="$scratch/delimiter-exhausted.env" bash "$SCRIPT_DIR/apply-workflow-config.sh" \
  "$scratch/rootfs.env" >/dev/null 2>&1; then
  echo 'workflow config accepted a value colliding with every delimiter' >&2
  exit 1
fi
[ ! -s "$scratch/delimiter-exhausted.env" ]
printf 'LOCALES=en_US.UTF-8 UTF-8\nLANG_NAME=zh_CN.UTF-8\n' > "$scratch/mismatched-locale.env"
if GITHUB_ENV="$scratch/mismatched-locale-github.env" bash "$SCRIPT_DIR/apply-workflow-config.sh" \
  "$scratch/mismatched-locale.env" >/dev/null 2>&1; then
  echo 'accepted LANG_NAME absent from workflow LOCALES' >&2
  exit 1
fi
[ ! -s "$scratch/mismatched-locale-github.env" ]

package_config="$scratch/rootfs.env"
{
  printf 'PACKAGE_LIST='
  for ((index = 0; index < 1025; ++index)); do
    printf 'package%s ' "$index"
  done
  printf '\n'
} > "$package_config"
if GITHUB_ENV="$scratch/package-flood-github.env" \
    bash "$SCRIPT_DIR/apply-workflow-config.sh" "$package_config" \
    >/dev/null 2>&1; then
  echo 'workflow config accepted more than 1024 package tokens' >&2
  exit 1
fi
[ ! -s "$scratch/package-flood-github.env" ]

: > "$scratch/rootfs.env"
for ((index = 0; index < 1025; ++index)); do
  printf '# comment %s\n' "$index" >> "$scratch/rootfs.env"
done
if GITHUB_ENV="$scratch/line-flood-github.env" \
    bash "$SCRIPT_DIR/apply-workflow-config.sh" "$scratch/rootfs.env" \
    >/dev/null 2>&1; then
  echo 'workflow config accepted more than 1024 physical lines' >&2
  exit 1
fi
[ ! -s "$scratch/line-flood-github.env" ]

truncate -s 262145 "$scratch/rootfs.env"
if GITHUB_ENV="$scratch/size-flood-github.env" \
    bash "$SCRIPT_DIR/apply-workflow-config.sh" "$scratch/rootfs.env" \
    >/dev/null 2>&1; then
  echo 'workflow config accepted more than 256 KiB' >&2
  exit 1
fi
[ ! -s "$scratch/size-flood-github.env" ]

notes_resolv=$'nameserver 192.0.2.1\nsearch example.invalid'
notes_resolv_b64=$(printf '%s' "$notes_resolv" | base64 --wrap=0)
cat > "$scratch/rootfs.env" <<EOF
# PRIVATE_COMMENT_MUST_NOT_LEAK
ROOTFS_LABEL=Old
ROOTFS_LABEL=Ubuntu
RESOLV_CONF_CONTENT_B64=$notes_resolv_b64
EOF
GITHUB_ENV="$scratch/sanitized-notes-github.env" \
  bash "$SCRIPT_DIR/apply-workflow-config.sh" "$scratch/rootfs.env" \
    "$scratch/sanitized-rootfs.env"
[ "$(grep -Fc 'ROOTFS_LABEL=' "$scratch/sanitized-rootfs.env")" -eq 1 ]
grep -Fq 'ROOTFS_LABEL=Ubuntu' "$scratch/sanitized-rootfs.env"
grep -Fq "RESOLV_CONF_CONTENT_B64=$notes_resolv_b64" \
  "$scratch/sanitized-rootfs.env"
if grep -Fq 'PRIVATE_COMMENT_MUST_NOT_LEAK' "$scratch/sanitized-rootfs.env" ||
   grep -Fq 'ROOTFS_LABEL=Old' "$scratch/sanitized-rootfs.env" ||
   grep -Fq 'nameserver 192.0.2.1' "$scratch/sanitized-rootfs.env"; then
  echo 'sanitized build notes leaked comments, overridden values, or multiline text' >&2
  exit 1
fi

printf 'ROOTARGS=```escaped fence```\n' > "$scratch/boot.env"
if GITHUB_ENV="$scratch/markdown-github.env" \
    bash "$SCRIPT_DIR/apply-workflow-config.sh" "$scratch/boot.env" \
      "$scratch/markdown-boot.env" >/dev/null 2>&1; then
  echo 'sanitized build notes accepted a Markdown fence escape' >&2
  exit 1
fi
[ ! -s "$scratch/markdown-github.env" ]
[ ! -e "$scratch/markdown-boot.env" ]

if (ci_validate_https_apt_sources_list \
  'deb http://ports.ubuntu.com/ubuntu-ports resolute main') >/dev/null 2>&1; then
  echo 'accepted an HTTP APT source entry' >&2
  exit 1
fi
for unsafe_apt_source in \
  'deb [trusted=yes] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [allow-insecure=yes] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [allow-downgrade-to-insecure=yes] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [check-valid-until=no] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [foo=bar] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [signed-by=relative.gpg] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [arch=amd64] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [arch=arm64 https://ports.ubuntu.com/ubuntu-ports resolute main'; do
  if (ci_validate_https_apt_sources_list "$unsafe_apt_source") >/dev/null 2>&1; then
    echo "accepted unsafe APT source entry: $unsafe_apt_source" >&2
    exit 1
  fi
done
if (ci_validate_https_apt_sources_list '# comments only') >/dev/null 2>&1; then
  echo 'accepted an APT source list with no repository entries' >&2
  exit 1
fi
ci_require_user_access_path "$valid_hash" '' 0
ci_require_user_access_path '!' "$valid_key" 0
ci_require_user_access_path '!' '' 1
if (ci_require_user_access_path '!' '' 0) >/dev/null 2>&1; then
  echo 'accepted a configuration with no user access path' >&2
  exit 1
fi
if (ci_require_user_access_path '!' 'command="id" ssh-ed25519 AAAA' 0) >/dev/null 2>&1; then
  echo 'accepted an option-prefixed or malformed authorized key' >&2
  exit 1
fi

# The workflow runs on both x86_64 and arm64 hosts.  Keep the actionlint
# downloader's architecture table and both immutable release digests present;
# a silent return to the amd64-only path would make every ARM build fail before
# any project validation runs.
actionlint_script=$SCRIPT_DIR/run-actionlint.sh
grep -Fq 'platform=linux_amd64' "$actionlint_script"
grep -Fq 'platform=linux_arm64' "$actionlint_script"
grep -Fq '401942f9c24ed71e4fe71b76c7d638f66d8633575c4016efd2977ce7c28317d0' "$actionlint_script"
grep -Fq '023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757' "$actionlint_script"
bash -n "$actionlint_script"

bash "$SCRIPT_DIR/test-desktop-apparmor.sh"
echo 'PASS input, access and filesystem path boundaries'
