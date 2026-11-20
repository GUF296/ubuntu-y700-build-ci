#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
OVERLAY_SOURCE="$REPO_ROOT/source/tb321fu-camera-rootfs-overlay"
INSTALLER="$OVERLAY_SOURCE/install.sh"
MANIFEST="$OVERLAY_SOURCE/OVERLAY-MANIFEST.tsv"
VERIFIER="$SCRIPT_DIR/verify-camera-overlay.py"

fail() {
  printf 'CAMERA_OVERLAY_INSTALLER=FAIL %s\n' "$*" >&2
  exit 1
}

for required in "$INSTALLER" "$MANIFEST" "$VERIFIER"; do
  [ -f "$required" ] || fail "missing fixture input: $required"
done
python3 -I -B "$SCRIPT_DIR/test-camera-install-transaction.py" \
  "$SCRIPT_DIR/install-camera-overlay.py" "$VERIFIER" "$OVERLAY_SOURCE"
if grep -Eq '^[[:space:]]*(if[[:space:]]+)?strings[[:space:]]' "$INSTALLER"; then
  fail "installer depends on an undeclared host strings command"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tb321fu-camera-installer-test.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

target="$work_dir/target"
install -d -m 0755 "$target"
"$INSTALLER" "$target" >/dev/null
python3 -I -B "$VERIFIER" "$target" "$MANIFEST" >/dev/null

expected_owner="$(id -u):$(id -g)"
actual_owners=$(find "$target" -xdev -printf '%U:%G\n' | LC_ALL=C sort -u)
[ "$actual_owners" = "$expected_owner" ] ||
  fail "installer preserved foreign checkout ownership: $actual_owners"

# Existing files and legacy entries must be replaced through the transaction,
# while unrelated rootfs content survives unchanged.
legacy="$target/etc/udev/rules.d/70-y700-dma-heap.rules"
install -d -m 0755 "$(dirname "$legacy")"
printf 'legacy-camera-rule\n' >"$legacy"
chmod 0644 "$legacy"
chmod 0700 "$target/opt/libcamera-y700"
printf 'preserve-me\n' >"$target/keep-camera-file"
before_keep=$(sha256sum "$target/keep-camera-file" | awk '{print $1}')
"$INSTALLER" "$target" >/dev/null
[ ! -e "$legacy" ] || fail "legacy camera rule survived successful transaction"
[ "$(stat -c '%a' "$target/opt/libcamera-y700")" = 755 ] ||
  fail "existing camera directory mode was not normalized"
[ "$(sha256sum "$target/keep-camera-file" | awk '{print $1}')" = "$before_keep" ] ||
  fail "unrelated rootfs content changed"

# A failure after several committed mutations must restore both a replaced
# member and a legacy deletion, with no hidden transaction left behind.
rollback_target="$work_dir/rollback-target"
install -d -m 0755 "$rollback_target/etc/udev/rules.d"
printf 'legacy-camera-rule\n' >"$rollback_target/etc/udev/rules.d/70-y700-dma-heap.rules"
chmod 0644 "$rollback_target/etc/udev/rules.d/70-y700-dma-heap.rules"
if python3 -B "$REPO_ROOT/scripts/ci/install-camera-overlay.py" \
    --overlay "$OVERLAY_SOURCE/rootfs-overlay" \
    --manifest "$MANIFEST" \
    --target "$rollback_target" \
    --verifier "$VERIFIER" \
    --fail-after 52 >"$work_dir/rollback.stdout" 2>"$work_dir/rollback.stderr"; then
  fail "injected camera transaction failure was accepted"
fi
[ "$(cat "$rollback_target/etc/udev/rules.d/70-y700-dma-heap.rules")" = 'legacy-camera-rule' ] ||
  fail "legacy entry was not restored after rollback"
[ ! -e "$rollback_target/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so" ] ||
  fail "partial camera plugin survived rollback"
[ -z "$(find "$rollback_target" -maxdepth 1 -name '.tb321fu-camera-txn.*' -print -quit)" ] ||
  fail "rollback left a transaction directory"

# A symlink in a target parent must fail before any target mutation and must
# never redirect writes outside the rootfs.
symlink_target="$work_dir/symlink-target"
outside="$work_dir/outside"
install -d -m 0755 "$symlink_target" "$outside"
ln -s "$outside" "$symlink_target/opt"
if "$INSTALLER" "$symlink_target" >"$work_dir/symlink.stdout" 2>"$work_dir/symlink.stderr"; then
  fail "installer followed a target symlink parent"
fi
[ -z "$(find "$outside" -mindepth 1 -print -quit)" ] ||
  fail "target symlink parent redirected writes"

# A source executable-bit loss is a closed-manifest failure, not a reason to
# repair the source in place or partially update the target.
lost_exec_repo="$work_dir/lost-exec-repo"
install -d -m 0755 "$lost_exec_repo/source" "$lost_exec_repo/scripts/ci"
cp -a -- "$OVERLAY_SOURCE" "$lost_exec_repo/source/"
install -m 0644 "$VERIFIER" "$lost_exec_repo/scripts/ci/verify-camera-overlay.py"
install -m 0644 "$REPO_ROOT/scripts/ci/install-camera-overlay.py" \
  "$lost_exec_repo/scripts/ci/install-camera-overlay.py"
chmod 0644 "$lost_exec_repo/source/tb321fu-camera-rootfs-overlay/rootfs-overlay/opt/libcamera-y700/bin/cam"
lost_exec_target="$work_dir/lost-exec-target"
install -d -m 0755 "$lost_exec_target"
if "$lost_exec_repo/source/tb321fu-camera-rootfs-overlay/install.sh" \
    "$lost_exec_target" >"$work_dir/lost-exec.stdout" 2>"$work_dir/lost-exec.stderr"; then
  fail "installer accepted a source executable-bit loss"
fi
[ -z "$(find "$lost_exec_target" -mindepth 1 -print -quit)" ] ||
  fail "executable-bit rejection partially modified the target"

fixture_repo="$work_dir/repository"
install -d -m 0755 "$fixture_repo/source" "$fixture_repo/scripts/ci"
cp -a -- "$OVERLAY_SOURCE" "$fixture_repo/source/"
install -m 0644 "$VERIFIER" "$fixture_repo/scripts/ci/verify-camera-overlay.py"
install -m 0644 "$REPO_ROOT/scripts/ci/install-camera-overlay.py" \
  "$fixture_repo/scripts/ci/install-camera-overlay.py"
printf 'unreviewed camera payload\n' \
  > "$fixture_repo/source/tb321fu-camera-rootfs-overlay/rootfs-overlay/EXTRA"

hostile_target="$work_dir/hostile-target"
install -d -m 0755 "$hostile_target"
if "$fixture_repo/source/tb321fu-camera-rootfs-overlay/install.sh" \
    "$hostile_target" >"$work_dir/hostile.stdout" 2>"$work_dir/hostile.stderr"; then
  fail "installer accepted an overlay member outside the closed manifest"
fi
[ -z "$(find "$hostile_target" -mindepth 1 -print -quit)" ] ||
  fail "rejected overlay partially modified the target rootfs"

printf 'CAMERA_OVERLAY_INSTALLER=PASS\n'
