#!/usr/bin/env bash
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 WORKFLOW..." >&2; exit 2; }

# actionlint silently omits shell diagnostics if this executable is absent.
command -v shellcheck >/dev/null || { echo 'workflow validation requires shellcheck on PATH' >&2; exit 1; }

version=1.7.7

# GitHub-hosted ARM runners execute this gate natively.  Keep the download
# architecture explicit and pinned instead of relying on an emulation layer or
# a mutable "latest" asset.
case "$(uname -m)" in
  x86_64|amd64)
    platform=linux_amd64
    archive_sha256=023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757
    ;;
  aarch64|arm64)
    platform=linux_arm64
    archive_sha256=401942f9c24ed71e4fe71b76c7d638f66d8633575c4016efd2977ce7c28317d0
    ;;
  *)
    echo "unsupported actionlint host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
archive="actionlint_${version}_${platform}.tar.gz"
url="https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}"
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tb321fu-actionlint.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

curl --fail --show-error --silent --location \
  --proto '=https' --tlsv1.2 --output "$scratch/$archive" "$url"
printf '%s  %s\n' "$archive_sha256" "$scratch/$archive" | sha256sum --check --status
tar -xzf "$scratch/$archive" -C "$scratch" actionlint
chmod 0755 "$scratch/actionlint"
"$scratch/actionlint" "$@"
