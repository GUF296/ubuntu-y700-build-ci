#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || {
  printf 'usage: write-release-manifest.sh RELEASE_STAGING_ROOT\n' >&2
  exit 1
}

release_stage=$1
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
STAGING_VALIDATOR=$SCRIPT_DIR/validate-release-staging.sh

[ -f "$STAGING_VALIDATOR" ] && [ ! -L "$STAGING_VALIDATOR" ] || {
  printf 'release staging validator is missing or unsafe\n' >&2
  exit 1
}
bash "$STAGING_VALIDATOR" "$release_stage"
release_stage=$(realpath -e -- "$release_stage")
release_dir="$release_stage/assets"

manifest="$release_dir/SHA256SUMS.txt"
rm -f -- "$manifest"

temporary=$(mktemp "${TMPDIR:-/tmp}/tb321fu-release-manifest.XXXXXX")
cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT INT TERM

(
  cd -- "$release_dir"
  LC_ALL=C find . -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS.txt -printf '%f\0' |
    LC_ALL=C sort -z |
    xargs -0 -r sha256sum --
) > "$temporary"

[ -s "$temporary" ] || {
  printf 'release directory has no non-manifest files: %s\n' "$release_dir" >&2
  exit 1
}

chmod 0644 "$temporary"
mv -f -- "$temporary" "$manifest"
trap - EXIT INT TERM
