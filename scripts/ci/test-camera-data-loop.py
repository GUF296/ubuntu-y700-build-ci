#!/usr/bin/env python3
"""Compile actual camera data-loop entry code with a minimal ownership fixture."""

from __future__ import annotations

import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "camera_source_contract", SCRIPT_DIR / "test-camera-source-contract.py"
)
assert spec is not None and spec.loader is not None
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)

PRELUDE = r"""
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <future>
#include <iostream>
#include <mutex>
#include <thread>
using namespace std::chrono_literals;
struct port { uint32_t n_buffers = 2; };
struct impl {
    std::recursive_mutex lifecycle_mutex;
    std::mutex completion_mutex, buffer_mutex;
    std::condition_variable completion_cv;
    unsigned int processes_inflight = 0;
    bool stopping = false;
    port out_ports[1];
    std::atomic<unsigned int> recycled{0};
};
#define spa_return_val_if_fail(condition, value) do { if (!(condition)) return value; } while (0)
#define GET_OUT_PORT(self, id) (&(self)->out_ports[id])
static int recycle_buffer_locked(struct impl *self, struct port *, uint32_t)
{
    {
        std::lock_guard<std::mutex> lock(self->completion_mutex);
        if (self->processes_inflight != 1)
            return -EPROTO;
    }
    // Observe buffer ownership from another thread: try_lock on a mutex already
    // owned by this thread would not be a valid ownership test.
    const bool held = std::async(std::launch::async, [self] {
        if (self->buffer_mutex.try_lock()) {
            self->buffer_mutex.unlock();
            return false;
        }
        return true;
    }).get();
    if (!held)
        return -ENOLCK;
    ++self->recycled;
    return 0;
}
"""

TESTS = r"""
static bool invoke_while_lifecycle_owned(bool stopping, int expected)
{
    impl state;
    state.stopping = stopping;
    std::unique_lock<std::recursive_mutex> lifecycle(state.lifecycle_mutex);
    auto result = std::async(std::launch::async, [&state] {
        return impl_node_port_reuse_buffer(&state, 0, 0);
    });
    const bool finished = result.wait_for(2s) == std::future_status::ready;
    // Always release the synthetic stop-side lock, including on hostile code,
    // so a rejected lock cycle cannot hang fixture teardown.
    lifecycle.unlock();
    const int status = result.get();
    return finished && status == expected && state.processes_inflight == 0 &&
        state.recycled == (stopping ? 0U : 1U);
}

static bool entered_before_stop()
{
    impl state;
    std::unique_lock<std::mutex> buffer(state.buffer_mutex);
    auto result = std::async(std::launch::async, [&state] {
        return impl_node_port_reuse_buffer(&state, 0, 0);
    });
    bool entered = false;
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (std::chrono::steady_clock::now() < deadline) {
        {
            std::lock_guard<std::mutex> completion(state.completion_mutex);
            entered = state.processes_inflight == 1;
            if (entered) {
                state.stopping = true;
                break;
            }
        }
        std::this_thread::yield();
    }
    buffer.unlock();
    const int status = result.get();
    return entered && status == 0 && state.processes_inflight == 0 &&
        state.recycled == 1;
}

int main()
{
    if (!invoke_while_lifecycle_owned(false, 0)) {
        std::cerr << "reuse blocked on lifecycle or lost buffer/activity ownership\n";
        return 1;
    }
    if (!invoke_while_lifecycle_owned(true, -EBUSY)) {
        std::cerr << "stopping reuse did not reject and retire immediately\n";
        return 2;
    }
    if (!entered_before_stop()) {
        std::cerr << "pre-stop reuse escaped the provider retirement barrier\n";
        return 3;
    }
    impl state;
    if (impl_node_port_reuse_buffer(nullptr, 0, 0) != -EINVAL ||
        impl_node_port_reuse_buffer(&state, 1, 0) != -EINVAL ||
        impl_node_port_reuse_buffer(&state, 0, 2) != -EINVAL ||
        state.processes_inflight != 0 || state.recycled != 0)
        return 4;
    std::cout << "CAMERA_DATA_LOOP_CPP=PASS\n";
}
"""


def run_case(compiler: str, root: pathlib.Path, name: str, code: str) -> int:
    binary = root / name
    subprocess.run(
        [compiler, "-std=c++17", "-pthread", "-Wall", "-Wextra", "-Werror",
         "-x", "c++", "-", "-o", str(binary)],
        input=code, text=True, capture_output=True, timeout=30, check=True,
    )
    result = subprocess.run(
        [str(binary)], text=True, capture_output=True, timeout=10, check=False
    )
    if name == "current" and result.returncode != 0:
        raise RuntimeError(f"current production entry failed: {result.stderr.strip()}")
    if result.returncode < 0 or result.returncode not in {0, 1, 2, 3, 4}:
        raise RuntimeError(f"fixture did not exit through an assertion: {name}")
    return result.returncode


def main() -> int:
    if len(sys.argv) > 2:
        raise RuntimeError("usage: test-camera-data-loop.py [camera-source]")
    source_path = pathlib.Path(sys.argv[1]) if len(sys.argv) == 2 else contract.DEFAULT_SOURCE
    source = source_path.read_text(encoding="utf-8")
    compiler = shutil.which("c++")
    if compiler is None:
        raise RuntimeError("native C++17 compiler required for camera data-loop regression")
    guard = contract.extract_function(source, "struct process_activity_guard {")
    reuse = contract.extract_function(source, "int impl_node_port_reuse_buffer")
    code = PRELUDE + guard + ";\n" + reuse + TESTS
    mutations = {
        "lifecycle-lock": code.replace(
            "process_activity_guard activity{impl};",
            "std::lock_guard<std::recursive_mutex> old_lock(impl->lifecycle_mutex);\n"
            "process_activity_guard activity{impl};", 1,
        ),
        "missing-activity": code.replace(
            "process_activity_guard activity{impl};",
            "struct { bool stopping = false; } activity;", 1,
        ),
        "stopping-bypass": code.replace(
            "if (activity.stopping)", "if (false)", 1,
        ),
        "buffer-lock-bypass": code.replace(
            "std::lock_guard<std::mutex> buffer_guard(impl->buffer_mutex);", ";", 1,
        ),
    }
    with tempfile.TemporaryDirectory(prefix="tb321fu-camera-data-loop-") as temporary:
        root = pathlib.Path(temporary)
        run_case(compiler, root, "current", code)
        for name, mutation in mutations.items():
            if mutation == code:
                raise RuntimeError(f"missing mutation anchor: {name}")
            if run_case(compiler, root, name, mutation) == 0:
                raise RuntimeError(f"runtime fixture accepted mutation: {name}")
    print("CAMERA_DATA_LOOP_REGRESSION=PASS hostile_variants=4")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        detail = getattr(error, "stderr", None)
        print(f"CAMERA_DATA_LOOP_REGRESSION=FAIL: {detail or error}", file=sys.stderr)
        raise SystemExit(1)
