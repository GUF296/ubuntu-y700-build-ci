#!/usr/bin/env bash
set -euo pipefail

release_tag=${1:?usage: publish-release.sh RELEASE_TAG RELEASE_DIR NOTES_FILE}
release_dir=${2:?usage: publish-release.sh RELEASE_TAG RELEASE_DIR NOTES_FILE}
notes_file=${3:?usage: publish-release.sh RELEASE_TAG RELEASE_DIR NOTES_FILE}

: "${GH_TOKEN:?RELEASE_TOKEN must be exposed as GH_TOKEN only for this step}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

[[ $release_tag =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
  printf 'unsafe release tag: %s\n' "$release_tag" >&2
  exit 1
}
[[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  printf 'unsafe repository name: %s\n' "$GITHUB_REPOSITORY" >&2
  exit 1
}
[[ $GITHUB_SHA =~ ^[0-9a-fA-F]{40}$ ]] || {
  printf 'GITHUB_SHA is not a full commit id: %s\n' "$GITHUB_SHA" >&2
  exit 1
}
[ -d "$release_dir" ] || { printf 'release directory not found: %s\n' "$release_dir" >&2; exit 1; }
[ -f "$notes_file" ] || { printf 'release notes not found: %s\n' "$notes_file" >&2; exit 1; }

for command_name in gh sha256sum stat find sort awk; do
  command -v "$command_name" >/dev/null || {
    printf 'required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

entry_count=$(find "$release_dir" -mindepth 1 -maxdepth 1 -printf . | wc -c)
regular_count=$(find "$release_dir" -mindepth 1 -maxdepth 1 -type f -printf . | wc -c)
[ "$entry_count" -eq "$regular_count" ] || {
  printf 'release directory contains a directory, symlink, or special file\n' >&2
  exit 1
}

mapfile -d '' -t assets < <(find "$release_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
[ "${#assets[@]}" -gt 1 ] || { printf 'release directory has too few assets\n' >&2; exit 1; }
[ -f "$release_dir/SHA256SUMS.txt" ] || { printf 'SHA256SUMS.txt is required\n' >&2; exit 1; }

for asset in "${assets[@]}"; do
  asset_name=${asset##*/}
  [[ $asset_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'unsafe release asset name: %s\n' "$asset_name" >&2
    exit 1
  }
done

manifest_names=$(awk '
  length($1) != 64 || $1 !~ /^[0-9a-fA-F]+$/ { exit 2 }
  {
    name = substr($0, 67)
    sub(/^\\*/, "", name)
    if (name == "" || name == "SHA256SUMS.txt") exit 3
    print name
  }
' "$release_dir/SHA256SUMS.txt") || {
  printf 'invalid SHA256SUMS.txt format\n' >&2
  exit 1
}
[ -n "$manifest_names" ] || { printf 'empty SHA256SUMS.txt\n' >&2; exit 1; }
[ "$(printf '%s\n' "$manifest_names" | wc -l)" -eq "$((${#assets[@]} - 1))" ] || {
  printf 'SHA256SUMS.txt does not cover every non-manifest asset exactly once\n' >&2
  exit 1
}
[ -z "$(printf '%s\n' "$manifest_names" | sort | uniq -d)" ] || {
  printf 'SHA256SUMS.txt contains duplicate asset names\n' >&2
  exit 1
}
for asset in "${assets[@]}"; do
  asset_name=${asset##*/}
  [ "$asset_name" = SHA256SUMS.txt ] && continue
  printf '%s\n' "$manifest_names" | grep -Fxq -- "$asset_name" || {
    printf 'asset is missing from SHA256SUMS.txt: %s\n' "$asset_name" >&2
    exit 1
  }
done
(cd "$release_dir" && sha256sum --strict -c SHA256SUMS.txt)

release_exists=false
if gh release view "$release_tag" >/dev/null 2>&1; then
  release_exists=true
fi

if $release_exists; then
  is_draft=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --jq .draft)
  [ "$is_draft" = true ] || {
    printf 'refusing to modify already-public release: %s\n' "$release_tag" >&2
    exit 1
  }
  target_commitish=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --jq .target_commitish)
  [ "$target_commitish" = "$GITHUB_SHA" ] || {
    printf 'draft release target differs from this workflow commit: %s != %s\n' "$target_commitish" "$GITHUB_SHA" >&2
    exit 1
  }
  gh release edit "$release_tag" --title "$release_tag" --notes-file "$notes_file"
  while IFS= read -r asset_name; do
    [ -n "$asset_name" ] || continue
    gh release delete-asset "$release_tag" "$asset_name" -y
  done < <(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --jq '.assets[].name')
else
  gh release create "$release_tag" --draft --target "$GITHUB_SHA" \
    --title "$release_tag" --notes-file "$notes_file"
fi

gh release upload "$release_tag" "${assets[@]}"

verified=false
remote_assets=
for attempt in $(seq 1 10); do
  remote_assets=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" \
    --jq '.assets[] | [.name, .size, (.digest // "")] | @tsv')
  remote_count=$(printf '%s\n' "$remote_assets" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$remote_count" -eq "${#assets[@]}" ]; then
    verified=true
    for asset in "${assets[@]}"; do
      asset_name=${asset##*/}
      local_size=$(stat -c '%s' "$asset")
      local_digest=sha256:$(sha256sum "$asset" | awk '{print $1}')
      remote_record=$(printf '%s\n' "$remote_assets" | awk -F '\t' -v name="$asset_name" '$1 == name { print; found++ } END { if (found != 1) exit 1 }') || {
        verified=false
        break
      }
      IFS=$'\t' read -r _ remote_size remote_digest <<< "$remote_record"
      if [ "$remote_size" != "$local_size" ] || [ "$remote_digest" != "$local_digest" ]; then
        verified=false
        break
      fi
    done
  fi
  $verified && break
  [ "$attempt" -eq 10 ] || sleep 2
done

$verified || {
  printf 'uploaded release assets failed remote name/size/SHA-256 verification; release remains draft\n' >&2
  printf '%s\n' "$remote_assets" >&2
  exit 1
}

release_id=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --jq .id)
gh api -X PATCH "repos/$GITHUB_REPOSITORY/releases/$release_id" \
  -F draft=false -F prerelease=false -F make_latest=true >/dev/null
[ "$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --jq .draft)" = false ] || {
  printf 'release did not become public after final PATCH\n' >&2
  exit 1
}
printf 'Published immutable release %s after verifying %d assets.\n' "$release_tag" "${#assets[@]}"
