#!/usr/bin/env bash
set -euo pipefail

release_tag=${1:?usage: publish-release.sh RELEASE_TAG RELEASE_DIR NOTES_FILE}
release_dir=${2:?usage: publish-release.sh RELEASE_TAG RELEASE_DIR NOTES_FILE}
notes_file=${3:?usage: publish-release.sh RELEASE_TAG RELEASE_DIR NOTES_FILE}

: "${GH_TOKEN:?RELEASE_TOKEN must be exposed as GH_TOKEN only for this step}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

[ "${PRERELEASE:-}" = 1 ] || {
  printf 'PRERELEASE must be exactly 1 for immutable remediation publication\n' >&2
  exit 1
}
publish_prerelease=true
publish_make_latest=false
release_kind=prerelease

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

for command_name in gh sha256sum stat find sort awk grep uniq wc seq sleep; do
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

local_asset_records=$(
  for asset in "${assets[@]}"; do
    asset_name=${asset##*/}
    local_size=$(stat -c '%s' "$asset")
    local_digest=sha256:$(sha256sum "$asset" | awk '{print $1}')
    printf '%s\t%s\t%s\n' "$asset_name" "$local_size" "$local_digest"
  done
)

fetch_release_snapshot() {
  gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --jq \
    '(["release", (.id | tostring), (.draft | tostring), .target_commitish, (.prerelease | tostring)], (.assets[] | ["asset", .name, (.size | tostring), (.digest // "")])) | @tsv'
}

verify_release_snapshot() {
  local snapshot=$1
  local expected_release_id=$2
  local expected_draft=$3
  local verify_assets=$4
  local expected_prerelease=${5:-}
  local metadata actual_kind actual_id actual_draft actual_target actual_prerelease
  local remote_assets remote_count expected_count expected_record
  local expected_name expected_size expected_digest remote_record

  metadata=$(printf '%s\n' "$snapshot" | awk -F '\t' \
    '$1 == "release" { print; found++ } END { if (found != 1) exit 1 }') || return 1
  IFS=$'\t' read -r actual_kind actual_id actual_draft actual_target actual_prerelease <<< "$metadata"
  [ "$actual_kind" = release ] || return 1
  [ "$actual_id" = "$expected_release_id" ] || return 1
  [ "$actual_draft" = "$expected_draft" ] || return 1
  [ "$actual_target" = "$GITHUB_SHA" ] || return 1
  if [ -n "$expected_prerelease" ]; then
    [ "$actual_prerelease" = "$expected_prerelease" ] || return 1
  fi
  [ "$verify_assets" = 1 ] || return 0

  remote_assets=$(printf '%s\n' "$snapshot" | awk -F '\t' \
    '$1 == "asset" { sub(/^asset\t/, ""); print }')
  remote_count=$(printf '%s\n' "$remote_assets" | awk 'NF { count++ } END { print count + 0 }')
  expected_count=$(printf '%s\n' "$local_asset_records" | awk 'NF { count++ } END { print count + 0 }')
  [ "$remote_count" -eq "$expected_count" ] || return 1

  while IFS=$'\t' read -r expected_name expected_size expected_digest; do
    [ -n "$expected_name" ] || continue
    expected_record=$(printf '%s\t%s\t%s' "$expected_name" "$expected_size" "$expected_digest")
    remote_record=$(printf '%s\n' "$remote_assets" | awk -F '\t' -v name="$expected_name" \
      '$1 == name { print; found++ } END { if (found != 1) exit 1 }') || return 1
    [ "$remote_record" = "$expected_record" ] || return 1
  done <<< "$local_asset_records"
}

resolve_tag_commit() {
  local object_type object_sha record
  local depth

  record=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$release_tag" --jq \
    '[.object.type, .object.sha] | @tsv') || return 1
  for depth in $(seq 1 8); do
    IFS=$'\t' read -r object_type object_sha <<< "$record"
    [[ $object_sha =~ ^[0-9a-f]{40}$ ]] || return 1
    case "$object_type" in
      commit)
        printf '%s\n' "$object_sha"
        return 0
        ;;
      tag)
        record=$(gh api "repos/$GITHUB_REPOSITORY/git/tags/$object_sha" --jq \
          '[.object.type, .object.sha] | @tsv') || return 1
        ;;
      *)
        return 1
        ;;
    esac
  done
  return 1
}

verify_tag_target() {
  local resolved

  resolved=$(resolve_tag_commit) || {
    printf 'release tag cannot be resolved to a commit: %s\n' "$release_tag" >&2
    return 1
  }
  [ "$resolved" = "$GITHUB_SHA" ] || {
    printf 'release tag target differs from this workflow commit: %s != %s\n' \
      "$resolved" "$GITHUB_SHA" >&2
    return 1
  }
}

existing_release_tags=$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
  --paginate --jq '.[].tag_name') || {
  printf 'cannot establish the existing release set\n' >&2
  exit 1
}
if printf '%s\n' "$existing_release_tags" | grep -Fxq -- "$release_tag"; then
  printf 'refusing to modify an existing release or draft: %s\n' "$release_tag" >&2
  exit 1
fi
matching_tag_refs=$(gh api \
  "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$release_tag" \
  --jq '.[].ref') || {
  printf 'cannot establish the existing tag set\n' >&2
  exit 1
}
if printf '%s\n' "$matching_tag_refs" | grep -Fxq -- "refs/tags/$release_tag"; then
  printf 'refusing to publish through an existing tag: %s\n' "$release_tag" >&2
  exit 1
fi

gh api -X POST "repos/$GITHUB_REPOSITORY/git/refs" \
  -f "ref=refs/tags/$release_tag" -f "sha=$GITHUB_SHA" >/dev/null
verify_tag_target || exit 1
gh release create "$release_tag" --draft --target "$GITHUB_SHA" \
  --verify-tag --title "$release_tag" --notes-file "$notes_file"
verify_tag_target || exit 1

release_id=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --jq .id)
[[ $release_id =~ ^[0-9]+$ ]] || {
  printf 'release API returned an invalid id: %s\n' "$release_id" >&2
  exit 1
}
initial_snapshot=$(fetch_release_snapshot)
verify_release_snapshot "$initial_snapshot" "$release_id" true 0 || {
  printf 'draft release identity/state changed before asset upload\n' >&2
  printf '%s\n' "$initial_snapshot" >&2
  exit 1
}

gh release upload "$release_tag" "${assets[@]}"

verified=false
remote_snapshot=
for attempt in $(seq 1 10); do
  if remote_snapshot=$(fetch_release_snapshot) && \
    verify_release_snapshot "$remote_snapshot" "$release_id" true 1; then
    verified=true
  fi
  $verified && break
  [ "$attempt" -eq 10 ] || sleep 2
done

$verified || {
  printf 'uploaded release assets failed remote name/size/SHA-256 verification; release remains draft\n' >&2
  printf '%s\n' "$remote_snapshot" >&2
  exit 1
}

final_snapshot=$(fetch_release_snapshot)
verify_release_snapshot "$final_snapshot" "$release_id" true 1 || {
  printf 'release changed concurrently after upload verification; release remains draft\n' >&2
  printf '%s\n' "$final_snapshot" >&2
  exit 1
}
verify_tag_target || {
  printf 'release tag changed before publication; release remains draft\n' >&2
  exit 1
}
gh api -X PATCH "repos/$GITHUB_REPOSITORY/releases/$release_id" \
  -F draft=false -F prerelease="$publish_prerelease" -F make_latest="$publish_make_latest" >/dev/null
published_snapshot=$(fetch_release_snapshot)
verify_release_snapshot "$published_snapshot" "$release_id" false 1 "$publish_prerelease" || {
  printf '%s did not reach the expected immutable public state after final PATCH\n' "$release_kind" >&2
  printf '%s\n' "$published_snapshot" >&2
  exit 1
}
verify_tag_target || {
  printf 'release tag changed after publication\n' >&2
  exit 1
}
printf 'Published immutable %s %s after verifying %d assets.\n' \
  "$release_kind" "$release_tag" "${#assets[@]}"
