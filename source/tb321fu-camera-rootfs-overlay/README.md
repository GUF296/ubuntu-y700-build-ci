# Y700 Camera Rootfs Overlay

This overlay captures the Lenovo Y700 TB321FU camera payload recovered from the
2026-06-22 live rootfs backup. The `/opt/libcamera-y700` libraries, IPA/tuning
files, service drop-ins, and udev rule retain that historical device evidence.
The remediation package now rebuilds the complete libcamera/IPA/proxy/cam/
GStreamer runtime and the PipeWire SPA plugin from locked source. Baseline
tuning, services, wrappers and symlinks remain unchanged. This source-built
prerelease candidate has no new hardware acceptance solely from CI success.

## Install Into A Mounted Rootfs

The manual installer below deploys the bundled **historical baseline**, not the
source-built remediation binaries. Use the generated camera Debian package for
the new runtime; merely copying this baseline directory does not deliver the fixes.

```sh
sudo ./install.sh /path/to/rootfs
```

Use `/` as the target only when intentionally applying it to a live system.
Run the installer from this repository checkout: it uses the shared closed-world
overlay verifier and `scripts/ci/install-camera-overlay.py`. The helper takes a
descriptor/no-follow snapshot, then applies a same-filesystem hidden transaction
with a durable journal. Existing files, directory modes, and legacy entries are
restored in reverse order if any replacement or final verification fails; target
symlink parents, hard links, extra members, type/mode/link drift, and checksum
drift are rejected before an unsafe write.

## Contents

- `rootfs-overlay/opt/libcamera-y700`: verified libcamera app-chain, IPA proxy, SoftISP IPA, and Y700 tuning files.
- `rootfs-overlay/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so`: historical device-tested `spa-libcamera` baseline, SHA256 `25e951d022816b999f51d85e285f548b79d865db0c3959019bcc08981261665c`; the Debian producer rebuilds it against the exact new runtime headers and libraries.
- `rootfs-overlay/etc/systemd/user/pipewire.service.d`: PipeWire namespace and libcamera path drop-ins.
- `rootfs-overlay/etc/systemd/user/wireplumber.service.d`: WirePlumber libcamera path drop-in.
- `rootfs-overlay/etc/udev/rules.d/70-y700-camera-dma-heap.rules`: DMA heap access for camera users.
- `source/libcamera-source.cpp.clean-minimal-daily`: full patched source used to build the plugin.
- `source/spa-libcamera-producer`: closed companion-source, public-header, Meson, manifest, toolchain, and provenance inputs used by the Debian producer.
- `../../scripts/ci/install-camera-overlay.py`: descriptor-safe, journaled installer used by `install.sh`.
- `source/y700-camera-daily-minimal-upstream-1.6.2.patch`: historical June 2026 rotation-only patch retained for provenance; it is not the current build input.
- `OVERLAY-MANIFEST.tsv`: canonical 56-entry path/type/mode/size/hash/link contract for the complete runtime overlay.

## Runtime Model

- Applies only to Y700 built-in cameras detected by libcamera IDs containing `/base/soc@0/cci@ac15000` or `/base/soc@0/cci@ac16000`.
- Preserves libcamera's original camera orientation transform.
- Keeps rotation cache, inotify descriptors, and helper process state per camera node.
- Resolves the active session configuration from `XDG_CONFIG_HOME`, `HOME`, or the current UID's passwd entry; no account name or numeric session bus is embedded.
- Runs the fixed `/usr/bin/kscreen-doctor` executable with bounded output and a one-second deadline, then watches the resolved config directory with nonblocking inotify and only re-queries after `kwinoutputconfig.json` events.
- Does not use `/run/user/1000/y700-display-rotation`, `/etc/y700-camera-display-transform-mode`, or an external systemd updater.

## Regression Checks

The complete libcamera worktree snapshot is now carried in
`source/libcamera-producer/libcamera-source.tar.xz`, with a source lock and
per-member manifest. It includes the SoftISP repair and explicit device source
additions, not the old build tree or a signing private key. The Debian producer
uses `build-tb321fu-libcamera-runtime.py` to build two independent clean replicas
and compare every installed member before replacing seven compiled runtime/
signature files and the separately rebuilt SPA plugin. Build-only headers are
not shipped. `LIBCAMERA-BUILD-ENVIRONMENT.json` pins the cross-build closure;
the CI-only installer fails on unavailable versions instead of substituting
packages or permitting downgrades.

Both replicas authenticate their IPA signatures and exercise the real source
policy under QEMU. Compile-time forced isolation preserves the baseline
execution model even with valid signatures. A per-run signing key is private
to temporary build state; only its public key and provenance enter the report.
Same-input reproducibility includes the same key, not independently random keys.

`python3 -B scripts/ci/materialize-libcamera-source.py --output /unused/source/path`
authenticates the closed input set, checks every archive member before extraction,
uses the shared safe extractor, and re-verifies the resulting source tree. Its
content-derived `.tarball-version` works without Git tags or wall-clock time.
The output's parent directory must already exist; existing output is never replaced.

Source gates: `python3 -B scripts/ci/test-libcamera-source-export.py` and
`python3 -B scripts/ci/test-libcamera-source-materialization.py`. Source export
is an operator action from the intended Git checkout; it does not approve code.

From the repository root, run `python3 -B scripts/ci/test-camera-source-contract.py`
and `python3 -B scripts/ci/test-camera-data-loop.py`. The latter requires a native
C++17 compiler (`c++`); CI installs it explicitly for validation. It compiles the
actual activity guard and output-buffer reuse entry point with a minimal buffer
ownership fixture. Stop-before-entry, entry-before-stop, invalid IDs, and a
concurrently held lifecycle mutex must converge; deliberate lifecycle-lock,
stopping-bypass, missing-accounting and missing-buffer-lock changes must fail.
These are process/concurrency checks, not libcamera hardware validation.

## Verified Tags

- `normal`: rear main/macro `rotate-90`, front `rotate-270`.
- `left`: all three `rotate-180`.
- `inverted`: rear main/macro `rotate-270`, front `rotate-90`.
- `right`: all three `rotate-0`.

Physical testing of the restored 2026-06-22 baseline confirmed its color output
and camera rotation. That evidence applies to the baseline plugin named above,
not automatically to any source-built remediation binary. The package build
allows only the authenticated eight-file compiled/runtime-signature delta,
retains all other overlay bytes and rejects the older
`opt/libcamera-y700-test` app-chain. Full camera hardware acceptance remains
required for the new TB321FU prerelease.
