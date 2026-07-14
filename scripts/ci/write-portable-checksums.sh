#!/usr/bin/env bash
set -euo pipefail

output=${1:?usage: write-portable-checksums.sh OUTPUT PATH...}
shift
[ "$#" -gt 0 ] || { printf 'at least one input path is required\n' >&2; exit 1; }

mkdir -p "$(dirname -- "$output")"
temporary=$(mktemp "${output}.tmp.XXXXXX")
cleanup() { rm -f -- "$temporary"; }
trap cleanup EXIT INT TERM

write_entry() {
  local file=$1 label=$2 name digest
  name=${file##*/}
  [[ $label =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'unsafe checksum label: %s\n' "$label" >&2; exit 1; }
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'unsafe checksum filename: %s\n' "$name" >&2; exit 1; }
  digest=$(sha256sum "$file" | awk '{print $1}')
  printf '%s  %s/%s\n' "$digest" "$label" "$name" >> "$temporary"
}

for input in "$@"; do
  if [ -d "$input" ]; then
    label=${input%/}
    label=${label##*/}
    while IFS= read -r -d '' file; do
      write_entry "$file" "$label"
    done < <(find "$input" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
  elif [ -f "$input" ]; then
    parent=${input%/*}
    [ "$parent" != "$input" ] || parent=.
    label=${parent%/}
    label=${label##*/}
    [ "$label" != . ] || label=files
    write_entry "$input" "$label"
  else
    printf 'checksum input not found: %s\n' "$input" >&2
    exit 1
  fi
done

[ -s "$temporary" ] || { printf 'no files found for checksum manifest\n' >&2; exit 1; }
[ -z "$(awk '{ print substr($0, 67) }' "$temporary" | sort | uniq -d)" ] || {
  printf 'duplicate portable checksum path\n' >&2
  exit 1
}
chmod 0644 "$temporary"
mv -f -- "$temporary" "$output"
trap - EXIT INT TERM
