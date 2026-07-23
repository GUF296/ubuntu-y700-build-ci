#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || {
  printf 'usage: validate-release-staging.sh RELEASE_STAGING_ROOT\n' >&2
  exit 1
}

release_stage=$1

for command_name in find realpath wc; do
  command -v "$command_name" >/dev/null || {
    printf 'required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

# Artifact extraction is an input boundary. Reject links before resolving or
# enumerating the staging tree so a downloaded artifact cannot redirect a
# publish-only job outside its declared payload.
[ ! -L "$release_stage" ] || {
  printf 'release staging root must not be a symlink: %s\n' "$release_stage" >&2
  exit 1
}
[ -d "$release_stage" ] || {
  printf 'release staging root is not a directory: %s\n' "$release_stage" >&2
  exit 1
}
release_stage=$(realpath -e -- "$release_stage")

assets_dir="$release_stage/assets"
[ ! -L "$assets_dir" ] || {
  printf 'release staging assets directory must not be a symlink\n' >&2
  exit 1
}
[ -d "$assets_dir" ] || {
  printf 'release staging assets directory is missing\n' >&2
  exit 1
}

stage_entries=$(find -P "$release_stage" -mindepth 1 -maxdepth 1 -printf . | wc -c)
[ "$stage_entries" -eq 1 ] || {
  printf 'release staging root must contain only assets\n' >&2
  exit 1
}

asset_entries=$(find -P "$assets_dir" -mindepth 1 -maxdepth 1 -printf . | wc -c)
regular_assets=$(find -P "$assets_dir" -mindepth 1 -maxdepth 1 -type f -printf . | wc -c)
[ "$asset_entries" -gt 0 ] && [ "$asset_entries" -eq "$regular_assets" ] || {
  printf 'release staging assets must be nonempty regular files only\n' >&2
  exit 1
}

notes_file="$assets_dir/BUILD-PARAMETERS.md"
[ ! -L "$notes_file" ] && [ -f "$notes_file" ] || {
  printf 'release staging BUILD-PARAMETERS.md must be a regular file\n' >&2
  exit 1
}
