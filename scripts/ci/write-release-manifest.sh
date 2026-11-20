#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || {
  printf 'usage: write-release-manifest.sh RELEASE_STAGING_ROOT\n' >&2
  exit 1
}

release_stage=$1
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
STAGING_VALIDATOR=$SCRIPT_DIR/validate-release-staging.sh
. "$SCRIPT_DIR/common.sh"

[ -f "$STAGING_VALIDATOR" ] && [ ! -L "$STAGING_VALIDATOR" ] || {
  printf 'release staging validator is missing or unsafe\n' >&2
  exit 1
}
bash "$STAGING_VALIDATOR" "$release_stage"
ci_validate_no_symlink_ancestors "$release_stage" RELEASE_STAGING_ROOT
release_stage=$(realpath -e -- "$release_stage")
release_dir="$release_stage/assets"
ci_validate_no_symlink_ancestors "$release_dir" RELEASE_ASSETS_DIR

manifest="$release_dir/SHA256SUMS.txt"
rm -f -- "$manifest"

# Keep the temporary inode beside the destination.  A cross-filesystem `mv`
# may degrade into copy-and-unlink, leaving a partially published manifest.
temporary=$(mktemp "$release_dir/.SHA256SUMS.txt.tmp.XXXXXX")
temporary_name=${temporary##*/}
cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT INT TERM

(
  cd -- "$release_dir"
  LC_ALL=C find . -mindepth 1 -maxdepth 1 -type f \
    ! -name SHA256SUMS.txt ! -name "$temporary_name" -printf '%f\0' |
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
