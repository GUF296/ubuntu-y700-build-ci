#!/usr/bin/env bash
set -euo pipefail

# Keep distro provisioning off the runner. Only the artifact directory is writable
# from the container. Host checkout credentials and Actions tokens stay on the host.
workspace=$(pwd -P)
[ "${GITHUB_WORKSPACE:?}" = "$workspace" ]
cidfile="${RUNNER_TEMP:?}/tb321fu-camera.cid"
image='ubuntu@sha256:3afff29dffbc200d202546dc6c4f614edc3b109691e7ab4aa23d02b42ba86790'

case "${1:-}" in
  prepare)
    [ "$#" = 1 ]
    inputs=$(mktemp -d "$RUNNER_TEMP/tb321fu-camera-inputs.XXXXXXXX")
    chmod 0755 "$inputs"
    python3 -I -B scripts/ci/prepare-libcamera-build-environment.py >"$inputs/packages"
    snapshot=https://snapshot.ubuntu.com/ubuntu
    curl_opts=(--proto '=https' --proto-redir '=https' --location --fail --silent --show-error
               --max-time 90 --retry 2 --retry-max-time 180)
    curl "${curl_opts[@]}" "$snapshot/20250301T000000Z/pool/main/b/base-files/base-files_13ubuntu10.2_amd64.deb" -o "$inputs/base-files.deb"
    curl "${curl_opts[@]}" "$snapshot/20260201T000000Z/pool/main/o/openldap/libldap2_2.6.7+dfsg-1~exp1ubuntu8.2_amd64.deb" -o "$inputs/libldap2.deb"
    out="$workspace/out/tb321fu-camera-stack-debs"
    install -d -m 0755 "$out"
    docker run --detach --rm --cidfile "$cidfile" --platform linux/amd64 \
      --mount "type=bind,source=$workspace,target=$workspace,readonly" \
      --mount "type=bind,source=$out,target=$out" \
      --mount "type=bind,source=$inputs,target=/run/tb321fu-camera-inputs,readonly" \
      --mount type=bind,source=/etc/ssl/certs/ca-certificates.crt,target=/run/tb321fu-camera-ca.crt,readonly \
      --workdir "$workspace" "$image" sleep infinity
    docker exec --env GITHUB_ACTIONS --env RUNNER_ARCH --env RUNNER_OS --env GITHUB_WORKSPACE \
      "$(cat "$cidfile")" bash scripts/ci/install-libcamera-build-environment.sh --install
    ;;
  build)
    [ "$#" = 1 ]
    docker exec --user "$(id -u):$(id -g)" --env HOME=/tmp \
      --env OUTPUT_DIR --env ARCH --env CAMERA_STACK_DEB_VERSION --env CAMERA_STACK_ARCHIVE \
      --env CAMERA_STACK_ARCHIVE_SHA256 --env CAMERA_STACK_DIR \
      "$(cat "$cidfile")" bash scripts/ci/build-tb321fu-camera-stack-deb.sh
    ;;
  stop)
    [ "$#" = 1 ]
    if [ -s "$cidfile" ]; then
      docker stop --timeout 3 "$(cat "$cidfile")" >/dev/null
    fi
    ;;
  *) echo 'usage: camera-producer-container.sh prepare|build|stop' >&2; exit 2 ;;
esac
