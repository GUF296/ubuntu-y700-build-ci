# TB321FU SPA libcamera producer provenance

This directory is the minimal source and public-header closure needed to build
`libspa-libcamera.so`. The authoritative patched implementation remains the
sibling file `../libcamera-source.cpp.clean-minimal-daily`; the package builder
copies that exact file into a private verified snapshot before compilation.

The PipeWire companion files originate from the historical six-file camera
source archive:

- archive SHA-256: `bf6b70a7de607f2603063ba1252158836cd7e88ac3329eee4e5523f69c03cfc3`
- baseline: Ubuntu PipeWire `1.6.2-1ubuntu1`
- upstream source SHA-256: `13eaaf67558ddccf3d61ab7826f202d53538de422b015dd841ec92e1b7f5c0d8`
- manager/plugin shims and standalone Meson files: exact files from the
  content-addressed successful producer snapshot identified by the archive hash
  above, imported with their original SPDX headers intact

The public libcamera headers come from the 2026-07-14 reconstruction of the
tested camera source:

- libcamera base commit: `2985ca6ac024ff89a077f088de49f7a69ab40d37`
- tracked patch SHA-256: `25cd4f1f69f1b4ab084c3be283186aa5e51b99ddd52824a35d8b21deda9e74e1`
- changed-files archive SHA-256: `f13e891d31b033ecebaa65b81bab45378f86c8761f2fac34b578579f8902cd12`
- installed public API version: `0.7.1`

Only the SPA plugin is rebuilt. The package builder links against and retains
the tested overlay runtime libraries byte-for-byte:

- `libcamera.so.0.7.1`: `67caad74463f5885d0e03c1d9746216a3d6f78c125ca71805c5ebf584602c1ef`
- `libcamera-base.so.0.7.1`: `c50d02b3a0337915837736cdc3606d034f99e558802659f310d3f64c4a4f62ba`

`SOURCE-MANIFEST.tsv` is the closed-world path/type/mode/size/content contract
for this directory. `TOOLCHAIN.tsv` locks every build tool and package used by
the Ubuntu 24.04 ARM64 cross producer.
