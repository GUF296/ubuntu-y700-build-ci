#!/usr/bin/env bash
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 WORKFLOW..." >&2; exit 2; }

version=1.7.7
archive="actionlint_${version}_linux_amd64.tar.gz"
archive_sha256=023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757
url="https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}"
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tb321fu-actionlint.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) echo "unsupported actionlint host architecture: $(uname -m)" >&2; exit 1 ;;
esac

curl --fail --show-error --silent --location \
  --proto '=https' --tlsv1.2 --output "$scratch/$archive" "$url"
printf '%s  %s\n' "$archive_sha256" "$scratch/$archive" | sha256sum --check --status
tar -xzf "$scratch/$archive" -C "$scratch" actionlint
chmod 0755 "$scratch/actionlint"
"$scratch/actionlint" "$@"
