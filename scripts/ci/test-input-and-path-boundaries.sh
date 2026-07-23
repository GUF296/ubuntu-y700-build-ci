#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

expected=$'base\nlibfoo:arm64\npkg=1.2-3'
actual=$(ci_normalize_package_list $'base libfoo:arm64\npkg=1.2-3')
[ "$actual" = "$expected" ]
for hostile in '--config' 'lib*' '$(touch /tmp/not-run)' 'bad/token'; do
  if (ci_normalize_package_list "$hostile") >/dev/null 2>&1; then
    printf 'accepted hostile package token: %s\n' "$hostile" >&2
    exit 1
  fi
done

touch "$scratch/boot.img" "$scratch/rootfs.img"
ci_require_distinct_paths BOOT "$scratch/boot.img" ROOTFS "$scratch/rootfs.img" OUTPUT "$scratch/disk.img"
if (ci_require_distinct_paths BOOT "$scratch/boot.img" OUTPUT "$scratch/./boot.img") >/dev/null 2>&1; then
  echo 'accepted canonically identical paths' >&2
  exit 1
fi
ln "$scratch/boot.img" "$scratch/boot-hardlink.img"
if (ci_require_distinct_paths BOOT "$scratch/boot.img" OUTPUT "$scratch/boot-hardlink.img") >/dev/null 2>&1; then
  echo 'accepted hard-linked paths' >&2
  exit 1
fi

mkdir -p "$scratch/cleanup/.rootfs-build.target/child"
cleanup_target=$(realpath -e "$scratch/cleanup/.rootfs-build.target")
FAKE_MOUNTS=$cleanup_target
findmnt() { printf '%s\n' "$FAKE_MOUNTS"; }
if ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .rootfs-build. >/dev/null 2>&1; then
  echo 'deleted a target that is itself a mount root' >&2
  exit 1
fi
test -d "$cleanup_target"
FAKE_MOUNTS=$cleanup_target/child
if ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .rootfs-build. >/dev/null 2>&1; then
  echo 'deleted a target containing a descendant mount' >&2
  exit 1
fi
FAKE_MOUNTS=
ci_safe_rmtree "$cleanup_target" "$scratch/cleanup" .rootfs-build.
test ! -e "$cleanup_target"

valid_hash='$6$tb321fu$zJjB0r4FpYTJ.Vtx4o/xHvn.VWOIHRPQPK.XmV3VXaAkhjWoFVZ8sV5lunaP32xQWicW7vMaOBLlnq0bbQ.1g.'
valid_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZha2VidXRzeW50YWN0aWNhbGx5dmFsaWQ tb321fu-test'
ci_require_sudo_password_hash password "$valid_hash"
ci_require_sudo_password_hash nopasswd '!'
ci_require_sudo_password_hash none ''
if (ci_require_sudo_password_hash password '') >/dev/null 2>&1; then
  echo 'accepted an absent password hash for password sudo' >&2
  exit 1
fi
if (ci_require_sudo_password_hash password '!') >/dev/null 2>&1; then
  echo 'accepted a locked password hash for password sudo' >&2
  exit 1
fi
if (
  ci_require_user_access_path '!' '' 1
  ci_require_sudo_password_hash password '!'
) >/dev/null 2>&1; then
  echo 'autologin bypassed the password sudo hash requirement' >&2
  exit 1
fi
if (ci_require_sudo_password_hash password '*') >/dev/null 2>&1; then
  echo 'accepted an invalid password hash for password sudo' >&2
  exit 1
fi

ci_validate_https_apt_uri https://ports.ubuntu.com/ubuntu-ports
ci_validate_https_apt_sources_list \
  $'deb https://ports.ubuntu.com/ubuntu-ports resolute main\ndeb [arch=arm64 signed-by=/etc/apt/keyrings/mozilla.asc] https://packages.mozilla.org/apt mozilla main'
for unsafe_apt_uri in \
  http://ports.ubuntu.com/ubuntu-ports \
  https://ports.ubuntu.com/ubuntu-ports?mutable=1 \
  https://user@ports.ubuntu.com/ubuntu-ports \
  file:///mirror; do
  if (ci_validate_https_apt_uri "$unsafe_apt_uri") >/dev/null 2>&1; then
    echo "accepted unsafe APT URI: $unsafe_apt_uri" >&2
    exit 1
  fi
done
if (ci_validate_https_apt_sources_list \
  'deb http://ports.ubuntu.com/ubuntu-ports resolute main') >/dev/null 2>&1; then
  echo 'accepted an HTTP APT source entry' >&2
  exit 1
fi
for unsafe_apt_source in \
  'deb [trusted=yes] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [allow-insecure=yes] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [allow-downgrade-to-insecure=yes] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [check-valid-until=no] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [foo=bar] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [signed-by=relative.gpg] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [arch=amd64] https://ports.ubuntu.com/ubuntu-ports resolute main' \
  'deb [arch=arm64 https://ports.ubuntu.com/ubuntu-ports resolute main'; do
  if (ci_validate_https_apt_sources_list "$unsafe_apt_source") >/dev/null 2>&1; then
    echo "accepted unsafe APT source entry: $unsafe_apt_source" >&2
    exit 1
  fi
done
if (ci_validate_https_apt_sources_list '# comments only') >/dev/null 2>&1; then
  echo 'accepted an APT source list with no repository entries' >&2
  exit 1
fi
ci_require_user_access_path "$valid_hash" '' 0
ci_require_user_access_path '!' "$valid_key" 0
ci_require_user_access_path '!' '' 1
if (ci_require_user_access_path '!' '' 0) >/dev/null 2>&1; then
  echo 'accepted a configuration with no user access path' >&2
  exit 1
fi
if (ci_require_user_access_path '!' 'command="id" ssh-ed25519 AAAA' 0) >/dev/null 2>&1; then
  echo 'accepted an option-prefixed or malformed authorized key' >&2
  exit 1
fi

echo 'PASS input, access and filesystem path boundaries'
