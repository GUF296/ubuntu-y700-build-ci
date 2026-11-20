#!/usr/bin/env python3
"""Exercise real IPA policy selection without starting cameras or IPC workers."""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import tempfile

PROGRAM = r"""
#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <libcamera/camera_manager.h>
#include <libcamera/base/file.h>
#include "libcamera/internal/ipa_manager.h"
#include "libcamera/internal/ipa_module.h"
#include "libcamera/internal/pipeline_handler.h"

struct Choice {
    struct Threaded;
    struct Isolated;
    Choice(libcamera::IPAModule *module, bool isolation)
        : isolated(isolation), modulePath(module->path()) {}
    virtual ~Choice() = default;
    bool isValid() const { return true; }
    bool isolated;
    std::string modulePath;
};
struct Choice::Threaded : Choice {
    Threaded(libcamera::IPAModule *module, const libcamera::CameraManager &)
        : Choice(module, false) {}
};
struct Choice::Isolated : Choice {
    Isolated(libcamera::IPAModule *module, const libcamera::CameraManager &)
        : Choice(module, true) {}
};

int main(int argc, char **argv)
{
    if (argc != 3)
        return 2;
    libcamera::IPAModule module(argv[2]);
    libcamera::File file(argv[2]);
    if (!module.isValid() || !file.open(libcamera::File::OpenModeFlag::ReadOnly))
        return 6;
    auto data = file.map();
    if (data.empty() || !libcamera::IPAManager::pubKey().verify(data, module.signature()))
        return 6;
    libcamera::CameraManager manager; // Never call start() or device match().
    const auto *factory = libcamera::PipelineHandlerFactoryBase::getFactoryByName("simple");
    if (!factory)
        return 3;
    auto pipeline = factory->create(&manager);
    libcamera::IPAManager ipas(manager);
    // The production template finds and authenticates the real IPA module.
    // Only final proxy construction is replaced with a choice recorder, so
    // this test cannot launch a worker, create namespaces or access a camera.
    auto choice = ipas.createIPA<Choice>(pipeline.get(), 0, UINT32_MAX);
    if (!choice || choice->modulePath != argv[2])
        return 4;
    const std::string mode = choice->isolated ? "isolated" : "threaded";
    if (mode != argv[1]) {
        std::cerr << "IPA policy chose " << mode << " instead of " << argv[1] << std::endl;
        return 5;
    }
    std::cout << "IPA_POLICY=" << mode << std::endl;
}
"""

def run(source: pathlib.Path, build: pathlib.Path, runtime: pathlib.Path, forced_build=False) -> None:
    libraries = runtime / "opt/libcamera-y700/lib/aarch64-linux-gnu"
    module = libraries / "libcamera/ipa/ipa_soft_simple.so"
    if not module.is_file() or not module.with_name(module.name + ".sign").is_file():
        raise RuntimeError("a coherent installed runtime and its signature are required")
    with tempfile.TemporaryDirectory(prefix="tb321fu-ipa-policy-test-") as temporary:
        root = pathlib.Path(temporary)
        binary = root / "policy-test"
        base_env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
        subprocess.run(
            ["/usr/bin/aarch64-linux-gnu-g++-13", "-x", "c++", "-std=c++20",
             "-Wall", "-Wextra", "-Werror", "-pthread", "-DLIBCAMERA_BASE_PRIVATE",
             "-include", str(build / "config.h"), "-I" + str(source / "include"),
             "-I" + str(build / "include"), "-", "-L" + str(libraries),
             "-Wl,-rpath-link," + str(libraries), "-Wl,-rpath-link,/usr/lib/aarch64-linux-gnu",
             "-l:libcamera.so.0.7.1", "-l:libcamera-base.so.0.7.1", "-o", str(binary)],
            input=PROGRAM, text=True, capture_output=True, env=base_env, timeout=30, check=True,
        )
        configuration = root / "config/libcamera"
        configuration.mkdir(parents=True)
        cases = (
            (False, None, "threaded"),
            (False, "1", "isolated"),
            (True, None, "isolated"),
            (False, "0", "isolated"),  # upstream treats any nonempty override as true
            (False, "", "threaded"),
            (True, "", "isolated"),
        )
        for configured, override, expected in cases:
            if forced_build:
                expected = "isolated"
            (configuration / "configuration.yaml").write_text(
                "version: 1\nconfiguration:\n  ipa:\n    force_isolation: "
                + ("true" if configured else "false") + "\n", encoding="utf-8",
            )
            env = dict(base_env, HOME=str(root), XDG_CONFIG_HOME=str(configuration.parent),
                       LIBCAMERA_IPA_MODULE_PATH=str(module.parent))
            if override is not None:
                env["LIBCAMERA_IPA_FORCE_ISOLATION"] = override
            result = subprocess.run(
                ["/usr/bin/qemu-aarch64-static", "-L", "/usr/aarch64-linux-gnu",
                 "-E", "LD_LIBRARY_PATH=" + str(libraries), str(binary), expected, str(module)],
                env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15,
            )
            if result.returncode != 0 or result.stdout.strip() != "IPA_POLICY=" + expected:
                raise RuntimeError(f"policy case {(configured, override)} failed: "
                                   f"status={result.returncode} {result.stdout} {result.stderr}")
    print(f"LIBCAMERA_REAL_IPA_POLICY=PASS cases=6 compiled_force={int(forced_build)} no_hardware_or_worker_start=1")

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=pathlib.Path)
    parser.add_argument("--build-root", required=True, type=pathlib.Path)
    parser.add_argument("--runtime-root", required=True, type=pathlib.Path)
    parser.add_argument("--forced-build", action="store_true")
    arguments = parser.parse_args()
    run(arguments.source_root.resolve(strict=True), arguments.build_root.resolve(strict=True),
        arguments.runtime_root.resolve(strict=True), arguments.forced_build)

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit("LIBCAMERA_REAL_IPA_POLICY=FAIL: " + str(getattr(error, "stderr", None) or error))
