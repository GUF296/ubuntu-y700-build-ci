#!/usr/bin/env bash
set -euo pipefail
set +x

[ "$#" -eq 2 ] || {
  printf 'usage: publish-release.sh RELEASE_TAG RELEASE_STAGING_ROOT\n' >&2
  exit 1
}

release_tag=$1
release_stage=$2
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
notes_file="$release_dir/BUILD-PARAMETERS.md"

: "${GH_TOKEN:?RELEASE_TOKEN must be exposed as GH_TOKEN only for this step}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
[ "${#GH_TOKEN}" -le 4096 ] || {
  printf 'GH_TOKEN exceeds the supported length\n' >&2
  exit 1
}
case $GH_TOKEN in
  *$'\r'*|*$'\n'*)
    printf 'GH_TOKEN contains a forbidden line break\n' >&2
    exit 1
    ;;
esac

[ "${PRERELEASE:-}" = 1 ] || {
  printf 'PRERELEASE must be exactly 1 for immutable remediation publication\n' >&2
  exit 1
}
publish_prerelease=true
release_kind='prerelease draft'

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
for command_name in gh curl sha256sum stat find sort awk grep uniq wc seq sleep base64 realpath env python3; do
  command -v "$command_name" >/dev/null || {
    printf 'required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

camera_deb_asset=$(python3 -I -B "$SCRIPT_DIR/camera-package-policy.py" deb-name)
camera_checksum_asset=$(python3 -I -B "$SCRIPT_DIR/camera-package-policy.py" checksum-name)

[ ! -L "$notes_file" ] && [ -f "$notes_file" ] || {
  printf 'release asset BUILD-PARAMETERS.md must be a regular file\n' >&2
  exit 1
}
release_title=$release_tag
notes_body_b64=$(base64 -w 0 "$notes_file")

entry_count=$(find "$release_dir" -mindepth 1 -maxdepth 1 -printf . | wc -c)
regular_count=$(find "$release_dir" -mindepth 1 -maxdepth 1 -type f -printf . | wc -c)
[ "$entry_count" -eq "$regular_count" ] || {
  printf 'release directory contains a directory, symlink, or special file\n' >&2
  exit 1
}

mapfile -d '' -t assets < <(find "$release_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
[ "${#assets[@]}" -gt 1 ] || { printf 'release directory has too few assets\n' >&2; exit 1; }
[ -f "$release_dir/SHA256SUMS.txt" ] || { printf 'SHA256SUMS.txt is required\n' >&2; exit 1; }

# The build job emits a closed release inventory. Keep the publisher equally
# strict so a modified staging artifact cannot add an unrelated payload merely
# by adding it to SHA256SUMS.txt.
declare -A stream_stem=() stream_files=() stream_chunks=() stream_chunk_seen=()
declare -A fixed_seen=()
total_asset_bytes=0
fixed_asset_names=(
  BUILD-PARAMETERS.md SHA256SUMS.txt boot.img.7z
  KERNEL-BUNDLE.tsv VERIFIED-BUNDLE.tsv VERIFIED-INPUTS.tsv
  KERNEL-SOURCE-LOCK.tsv SENSOR-SOURCE-LOCK.tsv HAPTICS-SOURCE-LOCK.tsv
  HAPTICS-BUILD-TOOLS.tsv MODULES.sha256 KERNEL-SDK-MANIFEST.tsv
  KERNEL-TOOLCHAIN.tsv KBUILD-FLAGS.tsv ROOTFS-PACKAGES.tsv
  APT-PROVENANCE.tsv APT-BOOTSTRAP.tsv APT-SOURCES.txt
  CAMERA-HANDOFF.tsv CAMERA-BUILD-REPORT.txt
  "$camera_deb_asset" "$camera_checksum_asset"
)
is_fixed_asset() {
  local candidate=$1 fixed
  for fixed in "${fixed_asset_names[@]}"; do
    [ "$candidate" = "$fixed" ] && return 0
  done
  return 1
}

for asset in "${assets[@]}"; do
  asset_name=${asset##*/}
  [[ $asset_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'unsafe release asset name: %s\n' "$asset_name" >&2
    exit 1
  }
  size=$(stat -c '%s' -- "$asset")
  [[ $size =~ ^[0-9]+$ ]] || {
    printf 'invalid release asset size: %s\n' "$asset_name" >&2
    exit 1
  }
  total_asset_bytes=$((total_asset_bytes + size))
  [ "$total_asset_bytes" -le $((16 * 1024 * 1024 * 1024)) ] || {
    printf 'release asset payload exceeds the 16 GiB aggregate limit\n' >&2
    exit 1
  }
  if is_fixed_asset "$asset_name"; then
    fixed_seen[$asset_name]=1
    continue
  fi
  [[ $asset_name =~ ^(rootfs|grub)\.img(\.(zst|xz|7z))?(\.([0-9]{3}))?$ ]] || {
    printf 'unexpected release asset name: %s\n' "$asset_name" >&2
    exit 1
  }
  stream=${BASH_REMATCH[1]}
  chunk=${BASH_REMATCH[5]:-}
  if [ -n "$chunk" ]; then
    stem=${asset_name%."$chunk"}
  else
    stem=$asset_name
  fi
  if [ -n "${stream_stem[$stream]+x}" ] &&
     [ "${stream_stem[$stream]}" != "$stem" ]; then
    printf 'release %s image mixes compression names\n' "$stream" >&2
    exit 1
  fi
  stream_stem[$stream]=$stem
  stream_files[$stream]=$(( ${stream_files[$stream]:-0} + 1 ))
  if [ -n "$chunk" ]; then
    [ -z "${stream_chunk_seen[$stream:$chunk]+x}" ] || {
      printf 'duplicate release image chunk: %s\n' "$asset_name" >&2
      exit 1
    }
    stream_chunk_seen[$stream:$chunk]=1
    stream_chunks[$stream]=$(( ${stream_chunks[$stream]:-0} + 1 ))
  fi
done
for fixed in "${fixed_asset_names[@]}"; do
  [ -n "${fixed_seen[$fixed]+x}" ] || {
    printf 'release is missing required asset: %s\n' "$fixed" >&2
    exit 1
  }
done

for stream in rootfs grub; do
  [ -n "${stream_files[$stream]:-}" ] || {
    printf 'release is missing the %s image\n' "$stream" >&2
    exit 1
  }
  if [ "${stream_chunks[$stream]:-0}" -gt 0 ]; then
    [ "${stream_files[$stream]}" -eq "${stream_chunks[$stream]}" ] || {
      printf 'release %s image mixes a complete file with chunks\n' "$stream" >&2
      exit 1
    }
    for ((chunk_index=0; chunk_index<stream_chunks[$stream]; chunk_index++)); do
      printf -v chunk_name '%03d' "$chunk_index"
      [ -n "${stream_chunk_seen[$stream:$chunk_name]+x}" ] || {
        printf 'release %s image chunks are not contiguous\n' "$stream" >&2
        exit 1
      }
    done
  else
    [ "${stream_files[$stream]}" -eq 1 ] || {
      printf 'release %s image has duplicate unchunked files\n' "$stream" >&2
      exit 1
    }
  fi
done

manifest_names=$(awk '
  length($1) != 64 || $1 !~ /^[0-9a-fA-F]+$/ { exit 2 }
  {
    name = substr($0, 67)
    sub(/^\*/, "", name)
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
  grep -Fxq -- "$asset_name" <<< "$manifest_names" || {
    printf 'asset is missing from SHA256SUMS.txt: %s\n' "$asset_name" >&2
    exit 1
  }
done
(cd "$release_dir" && sha256sum --strict -c SHA256SUMS.txt)
python3 -I -B "$SCRIPT_DIR/verify-camera-release-assets.py" "$release_dir" \
  --repository "$GITHUB_REPOSITORY" --commit "$GITHUB_SHA" \
  --run-id "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}" \
  --run-attempt "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

local_asset_records=$(
  for asset in "${assets[@]}"; do
    asset_name=${asset##*/}
    local_size=$(stat -c '%s' "$asset")
    local_digest=sha256:$(sha256sum "$asset" | awk '{print $1}')
    printf '%s\t%s\t%s\n' "$asset_name" "$local_size" "$local_digest"
  done
)

fetch_release_snapshot() {
  local release_id=$1

  gh api "repos/$GITHUB_REPOSITORY/releases/$release_id" --jq \
    '["release", (.id | tostring), (.draft | tostring), .tag_name, .target_commitish, (.prerelease | tostring), .name, ((.body // "") | @base64)] | @tsv'
  gh api "repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
    --paginate --jq '.[] | ["asset", .name, (.size | tostring), (.digest // "")] | @tsv'
}

verify_release_snapshot() {
  local snapshot=$1
  local expected_release_id=$2
  local expected_draft=$3
  local expected_target=$4
  local expected_prerelease=$5
  local expected_title=$6
  local expected_body_b64=$7
  local verify_assets=$8
  local metadata actual_kind actual_id actual_draft actual_tag actual_target actual_prerelease actual_title actual_body_b64
  local remote_assets remote_count expected_count expected_record
  local expected_name expected_size expected_digest remote_record

  metadata=$(printf '%s\n' "$snapshot" | awk -F '\t' \
    '$1 == "release" { print; found++ } END { if (found != 1) exit 1 }') || return 1
  IFS=$'\t' read -r actual_kind actual_id actual_draft actual_tag actual_target actual_prerelease actual_title actual_body_b64 <<< "$metadata"
  [ "$actual_kind" = release ] || return 1
  [ "$actual_id" = "$expected_release_id" ] || return 1
  [ "$actual_draft" = "$expected_draft" ] || return 1
  [ "$actual_tag" = "$release_tag" ] || return 1
  [ "$actual_target" = "$expected_target" ] || return 1
  [ "$actual_prerelease" = "$expected_prerelease" ] || return 1
  [ "$actual_title" = "$expected_title" ] || return 1
  [ "$actual_body_b64" = "$expected_body_b64" ] || return 1
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

list_matching_tags() {
  gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$release_tag" \
    --paginate --jq '.[].ref'
}

verify_draft_ref() {
  local matching
  # A new private draft can legitimately have no public Git tag until PATCH
  # draft=false. A failed list is *not* absence. An already visible exact
  # tag cannot be attributed to our draft, even if it points to our commit.
  matching=$(list_matching_tags) || return 1
  if grep -Fxq -- "refs/tags/$release_tag" <<< "$matching"; then
    printf 'unexpected public tag appeared while our release is private: %s\n' "$release_tag" >&2
    return 1
  fi
  return 0
}

existing_release_tags=$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
  --paginate --jq '.[].tag_name') || {
  printf 'cannot establish the existing release set\n' >&2
  exit 1
}
if grep -Fxq -- "$release_tag" <<< "$existing_release_tags"; then
  printf 'refusing to modify an existing release or draft: %s\n' "$release_tag" >&2
  exit 1
fi
matching_tag_refs=$(list_matching_tags) || {
  printf 'cannot establish the existing tag set\n' >&2
  exit 1
}
if grep -Fxq -- "refs/tags/$release_tag" <<< "$matching_tag_refs"; then
  printf 'refusing to publish through an existing tag: %s\n' "$release_tag" >&2
  exit 1
fi

# Let the release API own eventual tag creation. Do not create an orphan ref.
# Until publication, the numeric draft ID and exact target SHA own its identity.
release_record=$(gh api -X POST "repos/$GITHUB_REPOSITORY/releases" \
  -f "tag_name=$release_tag" \
  -f "target_commitish=$GITHUB_SHA" \
  -f "name=$release_title" \
  -F "body=@$notes_file" \
  -F draft=true -F prerelease="$publish_prerelease" --jq \
  '[.id, .tag_name, (.draft | tostring), .target_commitish, (.prerelease | tostring), .name, ((.body // "") | @base64)] | @tsv') || {
  printf 'cannot create the draft release\n' >&2
  exit 1
}
IFS=$'\t' read -r release_id created_tag created_draft \
  release_target_commitish created_prerelease created_title created_body_b64 <<< "$release_record"
[[ $release_id =~ ^[0-9]+$ ]] || {
  printf 'release API returned an invalid id: %s\n' "$release_id" >&2
  exit 1
}
[ "$created_tag" = "$release_tag" ] || {
  printf 'release API returned an unexpected tag: %s\n' "$created_tag" >&2
  exit 1
}
[ "$created_draft" = true ] || {
  printf 'release API did not create a draft\n' >&2
  exit 1
}
[ "$created_prerelease" = "$publish_prerelease" ] || {
  printf 'release API created an unexpected prerelease state\n' >&2
  exit 1
}
[ "$created_title" = "$release_title" ] || {
  printf 'release API returned an unexpected title: %s\n' "$created_title" >&2
  exit 1
}
[ "$created_body_b64" = "$notes_body_b64" ] || {
  printf 'release API returned an unexpected release body\n' >&2
  exit 1
}
[ "$release_target_commitish" = "$GITHUB_SHA" ] || {
  printf 'draft release target is not the requested exact commit\n' >&2
  exit 1
}
verify_draft_ref || exit 1
initial_snapshot=$(fetch_release_snapshot "$release_id")
verify_release_snapshot "$initial_snapshot" "$release_id" true \
  "$release_target_commitish" "$publish_prerelease" "$release_title" "$notes_body_b64" 0 || {
  printf 'draft release identity/state changed before asset upload\n' >&2
  printf '%s\n' "$initial_snapshot" >&2
  exit 1
}

for asset in "${assets[@]}"; do
  asset_name=${asset##*/}
  printf 'Authorization: Bearer %s\n' "$GH_TOKEN" |
    env -u GH_TOKEN -u GITHUB_TOKEN -u CURL_HOME -u HOME \
    curl --disable --fail-with-body --silent --show-error --request POST \
    --header 'Accept: application/vnd.github+json' \
    --header '@-' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header 'Content-Type: application/octet-stream' \
    --upload-file "$asset" \
    "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$release_id/assets?name=$asset_name" \
    >/dev/null
done

verified=false
remote_snapshot=
for attempt in $(seq 1 10); do
  if remote_snapshot=$(fetch_release_snapshot "$release_id") && \
    verify_release_snapshot "$remote_snapshot" "$release_id" true \
      "$release_target_commitish" "$publish_prerelease" "$release_title" "$notes_body_b64" 1; then
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

final_snapshot=$(fetch_release_snapshot "$release_id") || {
  printf 'cannot fetch the final verified draft release snapshot\n' >&2
  exit 1
}
verify_release_snapshot "$final_snapshot" "$release_id" true \
  "$release_target_commitish" "$publish_prerelease" "$release_title" "$notes_body_b64" 1 || {
  printf 'release changed concurrently after upload verification; release remains draft\n' >&2
  printf '%s\n' "$final_snapshot" >&2
  exit 1
}
verify_draft_ref || {
  printf 'cannot confirm draft ref state after upload; release remains private\n' >&2
  exit 1
}
printf 'Created verified %s %s with %d assets; draft remains private for manual publication.\n' \
  "$release_kind" "$release_tag" "${#assets[@]}"
