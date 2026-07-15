#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

expected=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3
subkey=1111111111111111111111111111111111111111
attacker=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
fixture=$(mktemp)
trap 'rm -f -- "$fixture"' EXIT INT TERM
printf 'fixture\n' > "$fixture"

(
  gpg() {
    cat <<EOF
pub:::::::::
fpr:::::::::$expected:
sub:::::::::
fpr:::::::::$subkey:
EOF
  }
  ci_verify_download "$fixture" "openpgp-fpr:$expected"
)

if (
  gpg() {
    cat <<EOF
pub:::::::::
fpr:::::::::$expected:
pub:::::::::
fpr:::::::::$attacker:
EOF
  }
  ci_verify_download "$fixture" "openpgp-fpr:$expected"
) >/dev/null 2>&1; then
  printf 'OpenPGP bundle with a second primary key was accepted\n' >&2
  exit 1
fi

if (
  gpg() {
    cat <<EOF
pub:::::::::
fpr:::::::::$attacker:
EOF
  }
  ci_verify_download "$fixture" "openpgp-fpr:$expected"
) >/dev/null 2>&1; then
  printf 'wrong OpenPGP primary key was accepted\n' >&2
  exit 1
fi

printf 'OpenPGP primary-key pinning: PASS\n'
