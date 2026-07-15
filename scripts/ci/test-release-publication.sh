#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
PUBLISH=$ROOT/scripts/ci/publish-release.sh
WORKFLOW=$ROOT/.github/workflows/build-rootfs-and-grub.yml
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
cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${GH_STATE:?}"
mkdir -p "$GH_STATE"
printf '%q ' "$@" >> "$GH_STATE/calls.log"
printf '\n' >> "$GH_STATE/calls.log"

if [ "${1:-}" = release ]; then
  operation=${2:-}
  shift 2
  case $operation in
    view)
      [ -f "$GH_STATE/exists" ]
      ;;
    create)
      tag=$1
      shift
      draft=false
      verify_tag=false
      target=
      while [ "$#" -gt 0 ]; do
        case $1 in
          --draft) draft=true; shift ;;
          --verify-tag) verify_tag=true; shift ;;
          --target) target=$2; shift 2 ;;
          --title|--notes-file) shift 2 ;;
          *) printf 'unexpected create argument: %s\n' "$1" >&2; exit 2 ;;
        esac
      done
      [ "$draft" = true ]
      [ "$verify_tag" = true ]
      [ -f "$GH_STATE/tag-exists" ]
      : "${target:?}"
      : > "$GH_STATE/exists"
      printf '%s\n' "$tag" > "$GH_STATE/tag"
      printf '%s\n' "$target" > "$GH_STATE/target"
      printf 'true\n' > "$GH_STATE/draft"
      printf 'false\n' > "$GH_STATE/prerelease"
      printf '101\n' > "$GH_STATE/id"
      : > "$GH_STATE/assets.tsv"
      printf 'create-draft\n' >> "$GH_STATE/events.log"
      ;;
    edit)
      printf 'edit-draft\n' >> "$GH_STATE/events.log"
      ;;
    delete-asset)
      name=$2
      awk -F '\t' -v name="$name" '$1 != name' "$GH_STATE/assets.tsv" > "$GH_STATE/assets.next"
      mv "$GH_STATE/assets.next" "$GH_STATE/assets.tsv"
      printf 'delete %s\n' "$name" >> "$GH_STATE/events.log"
      ;;
    upload)
      shift
      printf 'upload-start\n' >> "$GH_STATE/events.log"
      [ "${GH_FAIL_UPLOAD:-0}" != 1 ] || exit 73
      : > "$GH_STATE/assets.tsv"
      for file in "$@"; do
        name=${file##*/}
        size=$(stat -c '%s' "$file")
        digest=sha256:$(sha256sum "$file" | awk '{print $1}')
        if [ "${GH_CORRUPT_DIGEST:-0}" = 1 ]; then
          digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        fi
        printf '%s\t%s\t%s\n' "$name" "$size" "$digest" >> "$GH_STATE/assets.tsv"
      done
      printf 'upload-complete\n' >> "$GH_STATE/events.log"
      ;;
    *) printf 'unexpected release operation: %s\n' "$operation" >&2; exit 2 ;;
  esac
  exit
fi

if [ "${1:-}" = api ]; then
  shift
  method=GET
  if [ "${1:-}" = -X ]; then
    method=$2
    shift 2
  fi
  endpoint=$1
  shift
  query=
  fields=()
  while [ "$#" -gt 0 ]; do
    case $1 in
      --paginate) shift ;;
      --jq) query=$2; shift 2 ;;
      -f|-F) fields+=("$2"); shift 2 ;;
      *) printf 'unexpected api argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  if [ "$method" = POST ]; then
    [ "$endpoint" = "repos/owner/repository/git/refs" ]
    [ ! -f "$GH_STATE/tag-exists" ] || exit 65
    ref=
    sha=
    for field in "${fields[@]}"; do
      key=${field%%=*}
      value=${field#*=}
      case $key in
        ref) ref=$value ;;
        sha) sha=$value ;;
        *) printf 'unexpected POST field: %s\n' "$key" >&2; exit 2 ;;
      esac
    done
    [ "$ref" = refs/tags/test-20260715 ]
    [[ $sha =~ ^[0-9a-f]{40}$ ]]
    tag_target=${GH_CREATE_TAG_TARGET:-$sha}
    : > "$GH_STATE/tag-exists"
    if [ "${GH_ANNOTATED_TAG:-0}" = 1 ]; then
      printf 'tag\n' > "$GH_STATE/tag-type"
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$GH_STATE/tag-object"
      printf 'commit\n' > "$GH_STATE/peeled-type"
      printf '%s\n' "$tag_target" > "$GH_STATE/peeled-object"
    else
      printf 'commit\n' > "$GH_STATE/tag-type"
      printf '%s\n' "$tag_target" > "$GH_STATE/tag-object"
    fi
    exit
  fi
  if [ "$method" = PATCH ]; then
    [ "$endpoint" = "repos/owner/repository/releases/101" ]
    for field in "${fields[@]}"; do
      key=${field%%=*}
      value=${field#*=}
      printf '%s=%s\n' "$key" "$value" >> "$GH_STATE/patch-fields.log"
      case $key in
        draft) printf '%s\n' "$value" > "$GH_STATE/draft" ;;
        prerelease) printf '%s\n' "$value" > "$GH_STATE/prerelease" ;;
        make_latest) : ;;
        *) printf 'unexpected PATCH field: %s\n' "$key" >&2; exit 2 ;;
      esac
    done
    printf 'publish\n' >> "$GH_STATE/events.log"
    exit
  fi

  case "$endpoint" in
    'repos/owner/repository/releases?per_page=100')
      [ "${GH_FAIL_RELEASE_LIST:-0}" != 1 ] || exit 70
      [ ! -f "$GH_STATE/exists" ] || cat "$GH_STATE/tag"
      exit
      ;;
    repos/owner/repository/git/matching-refs/tags/*)
      [ "${GH_FAIL_REF_LIST:-0}" != 1 ] || exit 71
      [ ! -f "$GH_STATE/tag-exists" ] || printf 'refs/tags/%s\n' test-20260715
      exit
      ;;
    repos/owner/repository/git/ref/tags/*)
      [ -f "$GH_STATE/tag-exists" ] || exit 1
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
  esac

  if [[ $query == *'["release"'* ]]; then
    count=0
    [ ! -f "$GH_STATE/snapshot-count" ] || count=$(cat "$GH_STATE/snapshot-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$GH_STATE/snapshot-count"
    id=$(cat "$GH_STATE/id")
    draft=$(cat "$GH_STATE/draft")
    target=$(cat "$GH_STATE/target")
    prerelease=$(cat "$GH_STATE/prerelease")
    mutate=false
    if [ "${GH_MUTATE_SNAPSHOT:-0}" -eq "$count" ]; then mutate=true; fi
    if $mutate; then
      case ${GH_MUTATE_KIND:-target} in
        id) id=202 ;;
        draft) draft=false ;;
        target) target=ffffffffffffffffffffffffffffffffffffffff ;;
        extra) : ;;
        digest) : ;;
        *) printf 'unknown mutation kind\n' >&2; exit 2 ;;
      esac
      printf 'external-mutation-%s\n' "${GH_MUTATE_KIND:-target}" >> "$GH_STATE/events.log"
    fi
    printf 'release\t%s\t%s\t%s\t%s\n' "$id" "$draft" "$target" "$prerelease"
    if $mutate && [ "${GH_MUTATE_KIND:-}" = digest ]; then
      awk -F '\t' 'BEGIN { OFS="\t" } NR == 1 { $3="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } { print }' \
        "$GH_STATE/assets.tsv" | sed 's/^/asset\t/'
    else
      sed 's/^/asset\t/' "$GH_STATE/assets.tsv"
    fi
    if $mutate && [ "${GH_MUTATE_KIND:-}" = extra ]; then
      printf 'asset\tintruder.bin\t1\tsha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'
    fi
    exit
  fi

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
chmod +x "$fakebin/gh" "$fakebin/sleep"

mkdir -p "$scratch/release"
printf 'alpha\n' > "$scratch/release/alpha.bin"
printf 'beta\n' > "$scratch/release/beta.bin"
(cd "$scratch/release" && sha256sum alpha.bin beta.bin > SHA256SUMS.txt)
printf '# Notes\n' > "$scratch/notes.md"

run_publish() {
  local state=$1
  shift
  PATH="$fakebin:$PATH" GH_STATE="$state" GH_TOKEN=test-release-token \
    GITHUB_REPOSITORY=owner/repository \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
    "$@" "$PUBLISH" test-20260715 "$scratch/release" "$scratch/notes.md"
}

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
grep -Fxq 'draft=false' "$state_prerelease/patch-fields.log"
grep -Fxq 'prerelease=true' "$state_prerelease/patch-fields.log"
grep -Fxq 'make_latest=false' "$state_prerelease/patch-fields.log"
[ "$(cat "$state_prerelease/prerelease")" = true ]
before=$(wc -l < "$state_prerelease/events.log")
if run_publish "$state_prerelease" env PRERELEASE=1 >/dev/null 2>&1; then
  printf 'existing public release was accepted on rerun\n' >&2
  exit 1
fi
[ "$before" -eq "$(wc -l < "$state_prerelease/events.log")" ]
printf 'PASS prerelease is public, never latest, and immutable on rerun\n'

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
    GH_CREATE_TAG_TARGET=ffffffffffffffffffffffffffffffffffffffff >/dev/null 2>&1; then
  printf 'racing mismatched tag target was accepted\n' >&2
  exit 1
fi
[ ! -f "$state_tag_race/exists" ]
[ ! -f "$state_tag_race/assets.tsv" ]
[ ! -f "$state_tag_race/patch-fields.log" ]

state_annotated=$scratch/state-annotated
run_publish "$state_annotated" env PRERELEASE=1 GH_ANNOTATED_TAG=1 >/dev/null
[ "$(cat "$state_annotated/prerelease")" = true ]
printf 'PASS existing tags fail closed and annotated tags are peeled to the exact commit\n'

for mutation in id draft target extra digest; do
  state=$scratch/state-mutation-$mutation
  if run_publish "$state" env PRERELEASE=1 \
      GH_MUTATE_SNAPSHOT=3 GH_MUTATE_KIND="$mutation" >/dev/null 2>&1; then
    printf 'concurrent %s mutation was accepted\n' "$mutation" >&2
    exit 1
  fi
  [ ! -f "$state/patch-fields.log" ]
done
printf 'PASS final single-snapshot gate rejects concurrent identity/state/asset changes\n'

state_upload_fail=$scratch/state-upload-fail
if run_publish "$state_upload_fail" env PRERELEASE=1 GH_FAIL_UPLOAD=1 >/dev/null 2>&1; then
  printf 'simulated upload failure was accepted\n' >&2
  exit 1
fi
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
