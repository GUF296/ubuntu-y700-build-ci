#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
WRITER=$ROOT/scripts/ci/write-release-manifest.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-release-manifest.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'RELEASE_MANIFEST=FAIL %s\n' "$*" >&2
  exit 1
}

[ -f "$WRITER" ] || fail "manifest writer is missing"
bash -n "$WRITER"

release_stage=$scratch/release-staging
release_dir=$release_stage/assets
mkdir -p "$release_dir"
printf 'beta\n' > "$release_dir/beta.bin"
printf 'alpha\n' > "$release_dir/alpha.bin"
printf '# Notes\n' > "$release_dir/BUILD-PARAMETERS.md"
printf 'stale self-referential checksum\n' > "$release_dir/SHA256SUMS.txt"

bash "$WRITER" "$release_stage"
manifest=$release_dir/SHA256SUMS.txt
[ -s "$manifest" ] || fail "manifest was not written"

actual_names=$(awk '
  length($1) != 64 || $1 !~ /^[0-9a-fA-F]+$/ { exit 2 }
  {
    name = substr($0, 67)
    sub(/^\*/, "", name)
    if (name == "" || name == "SHA256SUMS.txt") exit 3
    print name
  }
' "$manifest") || fail "manifest has an invalid or self-referential entry"
[ "$actual_names" = $'BUILD-PARAMETERS.md\nalpha.bin\nbeta.bin' ] ||
  fail "manifest entries are not deterministic lexical basenames: $actual_names"

(cd "$release_dir" && sha256sum --strict -c SHA256SUMS.txt) >/dev/null ||
  fail "manifest does not validate its payload files"

cp "$manifest" "$scratch/first-manifest"
bash "$WRITER" "$release_stage"
cmp -s "$scratch/first-manifest" "$manifest" ||
  fail "manifest output changed without a payload change"

ln -s "$release_stage" "$scratch/release-staging-link"
if bash "$WRITER" "$scratch/release-staging-link" >/dev/null 2>&1; then
  fail "manifest writer accepted a symlinked staging root"
fi

printf 'RELEASE_MANIFEST=PASS stale manifest is removed, excluded, deterministic, and staging links are rejected\n'
