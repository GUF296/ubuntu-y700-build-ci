#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
RECORDER="$SCRIPT_DIR/apt-transaction-provenance.sh"
WRITER="$SCRIPT_DIR/write-apt-provenance.sh"

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

root=$scratch/root
fake_bin=$scratch/bin
state=$scratch/state
mkdir -p \
  "$root/etc/apt/sources.list.d" \
  "$root/etc/apt/trusted.gpg.d" \
  "$root/etc/apt/keyrings" \
  "$root/etc/apt/apt.conf.d" \
  "$root/etc/apt/preferences.d" \
  "$root/usr/share/keyrings" \
  "$root/var/lib/apt" \
  "$root/var/lib/apt/lists" \
  "$fake_bin" \
  "$state"

cat > "$root/etc/apt/sources.list" <<'SOURCES'
# comment containing proxy://user:password@proxy.invalid must not be emitted
deb https://ports.ubuntu.com/ubuntu-ports resolute main restricted
SOURCES
cat > "$root/etc/apt/sources.list.d/mozilla.list" <<'SOURCES'
deb [arch=arm64 signed-by=/etc/apt/keyrings/mozilla.asc] https://packages.mozilla.org/apt mozilla main
SOURCES
cat > "$root/etc/apt/sources.list.d/shared-keyring.list" <<'SOURCES'
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://ports.ubuntu.com/ubuntu-ports resolute-backports main
SOURCES
printf 'ubuntu trusted keyring\n' > "$root/etc/apt/trusted.gpg.d/ubuntu.gpg"
printf 'mozilla signing keyring\n' > "$root/etc/apt/keyrings/mozilla.asc"
printf 'shared archive keyring\n' > "$root/usr/share/keyrings/ubuntu-archive-keyring.gpg"
printf 'Acquire::Languages "none";\n' > "$root/etc/apt/apt.conf"
printf 'Acquire::https::Proxy "http://user:password@proxy.invalid:8080";\n' \
  > "$root/etc/apt/apt.conf.d/10-network"
cat > "$root/etc/apt/preferences.d/mozilla-firefox" <<'PREFERENCES'
Package: firefox
Pin: origin packages.mozilla.org
Pin-Priority: 1001
PREFERENCES
printf 'Package: base-system\nAuto-Installed: 1\n\n' \
  > "$root/var/lib/apt/extended_states"
printf 'signed release metadata\n' \
  > "$root/var/lib/apt/lists/ports.ubuntu.com_ubuntu-ports_dists_resolute_InRelease"
printf 'package index\n' \
  > "$root/var/lib/apt/lists/ports.ubuntu.com_ubuntu-ports_dists_resolute_main_binary-arm64_Packages"
printf 'ii \tbase-system\t1.0\tarm64\n' > "$state/packages"
printf 'base-system\n' > "$state/auto-packages"

cat > "$fake_bin/apt-get" <<'APT_GET'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$APT_GET_LOG"
case " $* " in
  *' install '*) printf 'ii \tfixture-package\t2.0\tarm64\n' >> "$FAKE_DPKG_PACKAGES" ;;
esac
if [ "${FAKE_APT_MUTATE_AUTH:-0}" = 1 ]; then
  cat > "$CI_APT_ROOT/etc/apt/sources.list" <<'SOURCES'
deb https://ports.ubuntu.com/ubuntu-ports resolute-updates main restricted
SOURCES
  printf 'mutated Mozilla signing keyring\n' > "$CI_APT_ROOT/etc/apt/keyrings/mozilla.asc"
  printf 'Acquire::Languages "none";\n' > "$CI_APT_ROOT/etc/apt/apt.conf.d/50-after"
fi
APT_GET
chmod 0755 "$fake_bin/apt-get"

cat > "$fake_bin/dpkg-query" <<'DPKG_QUERY'
#!/usr/bin/env bash
set -euo pipefail
cat "$FAKE_DPKG_PACKAGES"
DPKG_QUERY
chmod 0755 "$fake_bin/dpkg-query"

cat > "$fake_bin/apt-mark" <<'APT_MARK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  showauto)
    cat "$FAKE_APT_AUTO"
    ;;
  auto)
    shift
    for package in "$@"; do
      grep -Fxq "$package" "$FAKE_APT_AUTO" || printf '%s\n' "$package" >> "$FAKE_APT_AUTO"
      if [ -n "${CI_APT_ROOT:-}" ]; then
        printf 'Package: %s\nAuto-Installed: 1\n\n' "$package" >> \
          "$CI_APT_ROOT/var/lib/apt/extended_states"
      fi
    done
    ;;
  *)
    printf 'unexpected apt-mark invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
APT_MARK
chmod 0755 "$fake_bin/apt-mark"
install -D -m 0755 "$fake_bin/apt-mark" "$root/usr/bin/apt-mark"

cat > "$fake_bin/chroot" <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
root=${1:?missing fake chroot root}
shift
case " $* " in
  *' dpkg-query '*) cat "$FAKE_DPKG_PACKAGES" ;;
  *'apt-mark showauto'*) cat "$FAKE_APT_AUTO" ;;
  *)
    printf 'unexpected fake chroot invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
CHROOT
chmod 0755 "$fake_bin/chroot"

printf '#!/bin/sh\nexit 0\n' > "$fake_bin/debootstrap"
chmod 0755 "$fake_bin/debootstrap"

run_recorder() {
  local phase=$1
  local provenance_dir=${TEST_PROVENANCE_DIR:-"$root/var/lib/tb321fu-build-provenance/apt-transactions"}
  local -a command=(
    env
    -u APT_CONFIG
    -u FAKE_APT_MUTATE_AUTH
    "PATH=$fake_bin:/usr/bin:/bin"
    "CI_APT_COMMON_SH=$SCRIPT_DIR/common.sh"
    "CI_APT_ROOT=$root"
    SOURCE_DATE_EPOCH=123456789
    "APT_GET_LOG=$state/apt-get.log"
    "FAKE_DPKG_PACKAGES=$state/packages"
    "FAKE_APT_AUTO=$state/auto-packages"
  )
  shift
  if [ "${TEST_APT_CONFIG+x}" = x ]; then
    command+=("APT_CONFIG=$TEST_APT_CONFIG")
  fi
  if [ "${TEST_FAKE_APT_MUTATE_AUTH+x}" = x ]; then
    command+=("FAKE_APT_MUTATE_AUTH=$TEST_FAKE_APT_MUTATE_AUTH")
  fi
  "${command[@]}" bash "$RECORDER" "$provenance_dir" "$phase" "$@"
}

bootstrap=$scratch/APT-BOOTSTRAP.tsv
debootstrap_sha256=$(sha256sum "$fake_bin/debootstrap" | awk '{print $1}')
PATH="$fake_bin:$PATH" \
  FAKE_DPKG_PACKAGES="$state/packages" \
  FAKE_APT_AUTO="$state/auto-packages" \
  SOURCE_DATE_EPOCH=123456789 \
  bash "$WRITER" capture-bootstrap \
    "$root" "$bootstrap" 1.0 "$debootstrap_sha256" resolute arm64 minbase \
    https://ports.ubuntu.com/ubuntu-ports

run_recorder rootfs-provision update
local_deb=$scratch/tb321fu-fixture_1.0_arm64.deb
printf 'fixture deb\n' > "$local_deb"
run_recorder rootfs-provision install -y "$local_deb"
run_recorder gpu-build update
run_recorder gpu-build install -y build-dependency
run_recorder gpu-build mark-auto build-dependency
run_recorder rootfs-provision purge -y snapd
run_recorder gpu-build autoremove -y --purge
TEST_FAKE_APT_MUTATE_AUTH=1
run_recorder rootfs-provision install -y mutation-package
unset TEST_FAKE_APT_MUTATE_AUTH

records_dir=$root/var/lib/tb321fu-build-provenance/apt-transactions/transactions
[ "$(find "$records_dir" -maxdepth 1 -type f -name '*.tsv' | wc -l)" -eq 8 ]
[ "$(wc -l < "$state/apt-get.log")" -eq 7 ]
grep -F 'Acquire::AllowInsecureRepositories=false' "$state/apt-get.log" >/dev/null
grep -F 'Acquire::AllowDowngradeToInsecureRepositories=false' "$state/apt-get.log" >/dev/null
for record in "$records_dir"/*.tsv; do
  grep -Fx $'timestamp\t123456789' "$record" >/dev/null
  grep -E $'^operation\t(update|install|purge|autoremove|mark-auto)$' "$record" >/dev/null
done
grep -F $'local-deb\ttb321fu-fixture_1.0_arm64.deb\t' \
  "$records_dir/0002-rootfs-provision-install.tsv" >/dev/null
grep -F $'keyring\tetc/apt/keyrings/mozilla.asc\t' \
  "$records_dir/0001-rootfs-provision-update.tsv" >/dev/null
grep -F $'keyring\tusr/share/keyrings/ubuntu-archive-keyring.gpg\t' \
  "$records_dir/0003-gpu-build-update.tsv" >/dev/null
grep -F $'pre-apt-config\tetc/apt/apt.conf.d/10-network\t' \
  "$records_dir/0004-gpu-build-install.tsv" >/dev/null
grep -F $'pre-preference\tetc/apt/preferences.d/mozilla-firefox\t' \
  "$records_dir/0001-rootfs-provision-update.tsv" >/dev/null
grep -F $'apt-mark-auto\tbuild-dependency' \
  "$records_dir/0005-gpu-build-mark-auto.tsv" >/dev/null
grep -F $'post-auto-package\tbuild-dependency' \
  "$records_dir/0005-gpu-build-mark-auto.tsv" >/dev/null
grep -F $'pre-source\tetc/apt/sources.list\tdeb\thttps://ports.ubuntu.com/ubuntu-ports\tresolute\tmain,restricted' \
  "$records_dir/0008-rootfs-provision-install.tsv" >/dev/null
grep -F $'post-source\tetc/apt/sources.list\tdeb\thttps://ports.ubuntu.com/ubuntu-ports\tresolute-updates\tmain,restricted' \
  "$records_dir/0008-rootfs-provision-install.tsv" >/dev/null
grep -F $'pre-keyring\tetc/apt/keyrings/mozilla.asc\t' \
  "$records_dir/0008-rootfs-provision-install.tsv" >/dev/null
grep -F $'post-keyring\tetc/apt/keyrings/mozilla.asc\t' \
  "$records_dir/0008-rootfs-provision-install.tsv" >/dev/null
grep -F $'post-apt-config\tetc/apt/apt.conf.d/50-after\t' \
  "$records_dir/0008-rootfs-provision-install.tsv" >/dev/null
grep -E $'^pre-sources-sha256\t[0-9a-f]{64}$' \
  "$records_dir/0008-rootfs-provision-install.tsv" >/dev/null
grep -E $'^post-sources-sha256\t[0-9a-f]{64}$' \
  "$records_dir/0008-rootfs-provision-install.tsv" >/dev/null

provenance=$scratch/APT-PROVENANCE.tsv
sources=$scratch/APT-SOURCES.txt
PATH="$fake_bin:$PATH" \
  FAKE_DPKG_PACKAGES="$state/packages" \
  FAKE_APT_AUTO="$state/auto-packages" \
  SOURCE_DATE_EPOCH=123456789 \
  bash "$WRITER" finalize "$root" "$bootstrap" "$provenance" "$sources"
grep -Fx $'schema\ttb321fu.apt-provenance/v3' "$provenance" >/dev/null
grep -Fx $'bootstrap-provenance-sha256\t'"$(sha256sum "$bootstrap" | awk '{print $1}')" "$provenance" >/dev/null
grep -Fx $'transaction-count\t8' "$provenance" >/dev/null
[ "$(grep -Fc $'transaction\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'timestamp\t123456789' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'operation\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'pre-keyrings-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'post-keyrings-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'pre-apt-configs-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'post-apt-configs-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'pre-preferences-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'post-preferences-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'pre-auto-packages-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'post-auto-packages-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'pre-extended-states-sha256\t' "$provenance")" -eq 8 ]
[ "$(grep -Fc $'post-extended-states-sha256\t' "$provenance")" -eq 8 ]
grep -E $'^final-sources-sha256\t[0-9a-f]{64}$' "$provenance" >/dev/null
grep -E $'^final-keyrings-sha256\t[0-9a-f]{64}$' "$provenance" >/dev/null
grep -E $'^final-apt-configs-sha256\t[0-9a-f]{64}$' "$provenance" >/dev/null
grep -E $'^final-preferences-sha256\t[0-9a-f]{64}$' "$provenance" >/dev/null
grep -E $'^final-auto-packages-sha256\t[0-9a-f]{64}$' "$provenance" >/dev/null
grep -E $'^final-extended-states-sha256\t[0-9a-f]{64}$' "$provenance" >/dev/null
grep -F $'final-preference\tetc/apt/preferences.d/mozilla-firefox\t' "$provenance" >/dev/null
grep -Fx $'final-auto-package\tbuild-dependency' "$provenance" >/dev/null
grep -E $'^final-extended-state\tvar/lib/apt/extended_states\t[0-9]+\t[0-9a-f]{64}$' \
  "$provenance" >/dev/null
grep -F $'source\tetc/apt/sources.list\tdeb\thttps://ports.ubuntu.com/ubuntu-ports\tresolute-updates\tmain,restricted' \
  "$sources" >/dev/null
grep -F $'source\tetc/apt/sources.list.d/mozilla.list\tdeb\thttps://packages.mozilla.org/apt\tmozilla\tmain' \
  "$sources" >/dev/null
if grep -Fq 'http://user:password@proxy.invalid:8080' "$provenance" "$sources" ||
  grep -Fq 'comment containing proxy://' "$provenance" "$sources"; then
  echo 'APT provenance emitted proxy or raw source configuration content' >&2
  exit 1
fi

assert_writer_rejected() {
  local label=$1

  if PATH="$fake_bin:$PATH" \
      FAKE_DPKG_PACKAGES="$state/packages" \
      FAKE_APT_AUTO="$state/auto-packages" \
      SOURCE_DATE_EPOCH=123456789 bash "$WRITER" finalize \
    "$root" "$bootstrap" "$scratch/$label-provenance.tsv" "$scratch/$label-sources.txt" \
    >/dev/null 2>&1; then
    echo "writer accepted hostile APT provenance fixture: $label" >&2
    exit 1
  fi
}

tampered_record="$records_dir/0008-rootfs-provision-install.tsv"
cp "$tampered_record" "$tampered_record.real"
{
  sed '/^post-sources-sha256/d' "$tampered_record.real"
  printf 'post-sources-sha256\t%s\n' \
    0000000000000000000000000000000000000000000000000000000000000000
} > "$tampered_record"
assert_writer_rejected post-source-digest-mismatch
mv "$tampered_record.real" "$tampered_record"

tampered_bootstrap="$bootstrap.tampered"
sed '/^bootstrap-indexes-sha256\t/d' "$bootstrap" > "$tampered_bootstrap"
if PATH="$fake_bin:$PATH" \
    FAKE_DPKG_PACKAGES="$state/packages" \
    FAKE_APT_AUTO="$state/auto-packages" \
    SOURCE_DATE_EPOCH=123456789 bash "$WRITER" finalize \
      "$root" "$tampered_bootstrap" "$scratch/tampered-bootstrap.tsv" "$scratch/tampered-bootstrap-sources.tsv" \
      >/dev/null 2>&1; then
  echo 'writer accepted a tampered bootstrap provenance lock' >&2
  exit 1
fi
rm -f "$tampered_bootstrap"

mv "$root/etc/apt/sources.list" "$root/etc/apt/sources.list.real"
ln -s sources.list.real "$root/etc/apt/sources.list"
assert_writer_rejected final-sources-list-symlink
rm "$root/etc/apt/sources.list"
mv "$root/etc/apt/sources.list.real" "$root/etc/apt/sources.list"

mv "$root/etc/apt/sources.list.d/mozilla.list" \
  "$root/etc/apt/sources.list.d/mozilla.list.real"
ln -s mozilla.list.real "$root/etc/apt/sources.list.d/mozilla.list"
assert_writer_rejected final-sources-list-d-symlink
rm "$root/etc/apt/sources.list.d/mozilla.list"
mv "$root/etc/apt/sources.list.d/mozilla.list.real" \
  "$root/etc/apt/sources.list.d/mozilla.list"

mv "$root/etc/apt/keyrings/mozilla.asc" "$root/etc/apt/keyrings/mozilla.asc.real"
ln -s mozilla.asc.real "$root/etc/apt/keyrings/mozilla.asc"
assert_writer_rejected final-keyring-symlink
rm "$root/etc/apt/keyrings/mozilla.asc"
mv "$root/etc/apt/keyrings/mozilla.asc.real" "$root/etc/apt/keyrings/mozilla.asc"

mv "$root/etc/apt/apt.conf.d/10-network" \
  "$root/etc/apt/apt.conf.d/10-network.real"
ln -s 10-network.real "$root/etc/apt/apt.conf.d/10-network"
assert_writer_rejected final-apt-config-symlink
rm "$root/etc/apt/apt.conf.d/10-network"
mv "$root/etc/apt/apt.conf.d/10-network.real" \
  "$root/etc/apt/apt.conf.d/10-network"

mv "$root/etc/apt/preferences.d/mozilla-firefox" \
  "$root/etc/apt/preferences.d/mozilla-firefox.real"
ln -s mozilla-firefox.real "$root/etc/apt/preferences.d/mozilla-firefox"
assert_writer_rejected final-preference-symlink
rm "$root/etc/apt/preferences.d/mozilla-firefox"
mv "$root/etc/apt/preferences.d/mozilla-firefox.real" \
  "$root/etc/apt/preferences.d/mozilla-firefox"

mv "$root/var/lib/apt/extended_states" "$root/var/lib/apt/extended_states.real"
ln -s extended_states.real "$root/var/lib/apt/extended_states"
assert_writer_rejected final-extended-states-symlink
rm "$root/var/lib/apt/extended_states"
mv "$root/var/lib/apt/extended_states.real" "$root/var/lib/apt/extended_states"

printf 'Acquire::AllowInsecureRepositories "true";\n' \
  > "$root/etc/apt/apt.conf.d/90-hostile"
assert_writer_rejected final-apt-config-auth-override
rm "$root/etc/apt/apt.conf.d/90-hostile"

assert_rejected_before_apt() {
  local label=$1
  shift
  : > "$state/apt-get.log"
  if "$@" >/dev/null 2>&1; then
    echo "accepted hostile APT source fixture: $label" >&2
    exit 1
  fi
  [ ! -s "$state/apt-get.log" ] || {
    echo "hostile APT source fixture reached apt-get: $label" >&2
    exit 1
  }
}

rm -rf "$root/var/lib/tb321fu-build-provenance"
mv "$root/etc/apt/sources.list" "$root/etc/apt/sources.list.real"
ln -s sources.list.real "$root/etc/apt/sources.list"
assert_rejected_before_apt sources-list-symlink run_recorder hostile update
rm "$root/etc/apt/sources.list"
mv "$root/etc/apt/sources.list.real" "$root/etc/apt/sources.list"

mv "$root/etc/apt/sources.list.d/mozilla.list" \
  "$root/etc/apt/sources.list.d/mozilla.list.real"
ln -s mozilla.list.real "$root/etc/apt/sources.list.d/mozilla.list"
assert_rejected_before_apt sources-list-d-symlink run_recorder hostile update
rm "$root/etc/apt/sources.list.d/mozilla.list"
mv "$root/etc/apt/sources.list.d/mozilla.list.real" \
  "$root/etc/apt/sources.list.d/mozilla.list"

mv "$root/etc/apt/keyrings/mozilla.asc" "$root/etc/apt/keyrings/mozilla.asc.real"
ln -s mozilla.asc.real "$root/etc/apt/keyrings/mozilla.asc"
assert_rejected_before_apt keyring-symlink run_recorder hostile update
rm "$root/etc/apt/keyrings/mozilla.asc"
mv "$root/etc/apt/keyrings/mozilla.asc.real" "$root/etc/apt/keyrings/mozilla.asc"

mv "$root/etc/apt/apt.conf.d/10-network" \
  "$root/etc/apt/apt.conf.d/10-network.real"
ln -s 10-network.real "$root/etc/apt/apt.conf.d/10-network"
assert_rejected_before_apt apt-config-symlink run_recorder hostile update
rm "$root/etc/apt/apt.conf.d/10-network"
mv "$root/etc/apt/apt.conf.d/10-network.real" \
  "$root/etc/apt/apt.conf.d/10-network"

mv "$root/etc/apt/preferences.d/mozilla-firefox" \
  "$root/etc/apt/preferences.d/mozilla-firefox.real"
ln -s mozilla-firefox.real "$root/etc/apt/preferences.d/mozilla-firefox"
assert_rejected_before_apt preference-symlink run_recorder hostile update
rm "$root/etc/apt/preferences.d/mozilla-firefox"
mv "$root/etc/apt/preferences.d/mozilla-firefox.real" \
  "$root/etc/apt/preferences.d/mozilla-firefox"

printf 'deb http://ports.ubuntu.com/ubuntu-ports resolute main\n' \
  > "$root/etc/apt/sources.list"
assert_rejected_before_apt http-source run_recorder hostile update

printf 'deb https://ports.ubuntu.com/ubuntu-ports resolute-updates main restricted\n' \
  > "$root/etc/apt/sources.list"
printf 'Dir::Etc::sourcelist "other.list";\n' \
  > "$root/etc/apt/apt.conf.d/90-hostile"
assert_rejected_before_apt apt-config-path-redirect run_recorder hostile update
rm "$root/etc/apt/apt.conf.d/90-hostile"

printf 'Acquire::https::Verify-Peer "false";\n' \
  > "$root/etc/apt/apt.conf.d/90-hostile"
assert_rejected_before_apt apt-config-auth-override run_recorder hostile update
rm "$root/etc/apt/apt.conf.d/90-hostile"

printf 'Acquire::Languages "none";\n' > "$scratch/alternate-apt.conf"
TEST_APT_CONFIG="$scratch/alternate-apt.conf"
assert_rejected_before_apt apt-config-environment run_recorder hostile update
unset TEST_APT_CONFIG
assert_rejected_before_apt apt-option-override \
  run_recorder hostile update -o Dir::Etc::sourcelist=other.list
assert_rejected_before_apt mark-auto-without-package \
  run_recorder hostile mark-auto
assert_rejected_before_apt mark-auto-unsafe-package \
  run_recorder hostile mark-auto ../unsafe
TEST_PROVENANCE_DIR="$scratch/unexpected-provenance"
assert_rejected_before_apt unexpected-provenance-directory run_recorder hostile update
unset TEST_PROVENANCE_DIR
rm -rf "$root/var/lib/tb321fu-build-provenance"
ln -s "$scratch/escaped-provenance" \
  "$root/var/lib/tb321fu-build-provenance"
[ -L "$root/var/lib/tb321fu-build-provenance" ] || {
  echo 'failed to construct provenance symlink fixture' >&2
  exit 1
}
assert_rejected_before_apt provenance-parent-symlink run_recorder hostile update
rm "$root/var/lib/tb321fu-build-provenance"

python3 - \
  "$SCRIPT_DIR/build-rootfs-image.sh" \
  "$RECORDER" \
  "$WRITER" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert text.count("apt_secure update") == 2
assert text.count("apt_secure install") == 3
assert text.count("apt_secure purge") == 1
assert text.count("apt_secure autoremove") == 1
assert text.count("mark-auto ") == 1
for direct_call in ("apt-get update", "apt-get install", "apt-get purge", "apt-get autoremove"):
    assert direct_call not in text, direct_call
assert 'purge_candidates=()' in text
assert 'apt_secure purge -y "${purge_candidates[@]}"' in text
assert 'apt_secure purge -y snapd plasma-discover-backend-snap || true' not in text
assert 'apt_secure autoremove -y --purge || true' not in text
assert text.count('assert_apt_recorder_integrity') == 4
assert text.count('CI_APT_RECORDER_SHA256=') == 5
assert text.count('CI_APT_COMMON_SHA256=') == 5
assert text.count('trusted APT recorder integrity check failed') == 2
assert 'APT_PROVENANCE_PHASE=rootfs-provision' in text
assert 'APT_PROVENANCE_PHASE=gpu-build' in text
assert 'chroot "$root" dpkg --install "$package_deb"' not in text
assert '/root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build install -y -- "$package_deb"' in text
assert '/root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build mark-auto "${new_build_deps[@]}"' in text
assert '/root/ci-apt-transaction.sh "$apt_transaction_dir" gpu-build autoremove -y --purge' in text
assert 'capture-bootstrap' in text
assert 'write-apt-provenance.sh" finalize' in text
assert 'rootfs.apt-bootstrap.tsv' in text

recorder = Path(sys.argv[2]).read_text(encoding="utf-8")
writer = Path(sys.argv[3]).read_text(encoding="utf-8")
for token in (
    'collect_keyrings',
    'collect_apt_configs',
    'pre-keyrings-sha256',
    'post-keyrings-sha256',
    'pre-apt-configs-sha256',
    'post-apt-configs-sha256',
    'pre-preferences-sha256',
    'post-preferences-sha256',
    'pre-auto-packages-sha256',
    'post-auto-packages-sha256',
    'pre-extended-states-sha256',
    'post-extended-states-sha256',
    'mark-auto-inputs-sha256',
    'APT_CONFIG environment override is forbidden',
    'Dir::Etc::sourcelist=sources.list',
    'caller-supplied apt-get option is forbidden',
    'unexpected provenance directory',
    'provenance path must not contain a symlink',
    'APT keyring directory contains a symlink',
    'apt.conf.d contains a symlink',
):
    assert token in recorder, token
for token in (
    'validate_keyring_relative',
    'validate_apt_config_relative',
    'validate_preference_relative',
    'capture-bootstrap',
    'validate_bootstrap_file',
    'pre-keyrings-sha256',
    'post-keyrings-sha256',
    'final-keyrings-sha256',
    'final-apt-configs-sha256',
    'final-preferences-sha256',
    'final-auto-packages-sha256',
    'final-extended-states-sha256',
    'bootstrap-provenance-sha256',
    'collect_final_keyrings',
    'collect_final_apt_configs',
    'collect_final_preferences',
    'collect_final_auto_packages',
    'collect_final_extended_states',
    'validate_final_keyring_and_config_layout',
):
    assert token in writer, token
PY

echo 'APT_PROVENANCE=PASS'
