#!/usr/bin/env python3
"""Static and model contracts for the TB321FU PipeWire camera source."""

from __future__ import annotations

import pathlib
import sys


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
DEFAULT_SOURCE = (
    SCRIPT_DIR.parent.parent
    / "source/tb321fu-camera-rootfs-overlay/source/"
    "libcamera-source.cpp.clean-minimal-daily"
)


class ContractError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def extract_function(source: str, marker: str) -> str:
    search_from = 0
    while True:
        start = source.find(marker, search_from)
        require(start >= 0, f"missing function: {marker}")
        brace = source.find("{", start)
        require(brace >= 0, f"missing function body: {marker}")
        semicolon = source.find(";", start, brace)
        if semicolon < 0:
            break
        search_from = start + len(marker)
    depth = 0
    index = brace
    state = "code"
    while index < len(source):
        char = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "line-comment":
            if char == "\n":
                state = "code"
        elif state == "block-comment":
            if char == "*" and following == "/":
                state = "code"
                index += 1
        elif state in {"single-quote", "double-quote"}:
            if char == "\\":
                index += 1
            elif (state == "single-quote" and char == "'") or (
                state == "double-quote" and char == '"'
            ):
                state = "code"
        elif char == "/" and following == "/":
            state = "line-comment"
            index += 1
        elif char == "/" and following == "*":
            state = "block-comment"
            index += 1
        elif char == "'":
            state = "single-quote"
        elif char == '"':
            state = "double-quote"
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
        index += 1
    raise ContractError(f"unterminated function: {marker}")


def cpp_code(source: str) -> str:
    """Mask comments and literals so lexical contracts only match executable code."""
    result = list(source)
    index = 0
    state = "code"
    while index < len(source):
        char = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if char == "/" and following == "/":
                result[index] = result[index + 1] = " "
                state = "line-comment"
                index += 1
            elif char == "/" and following == "*":
                result[index] = result[index + 1] = " "
                state = "block-comment"
                index += 1
            elif char in {'"', "'"}:
                result[index] = " "
                state = "double-quote" if char == '"' else "single-quote"
        elif state == "line-comment":
            if char == "\n":
                state = "code"
            else:
                result[index] = " "
        elif state == "block-comment":
            result[index] = " "
            if char == "*" and following == "/":
                result[index + 1] = " "
                state = "code"
                index += 1
        else:
            result[index] = " "
            if char == "\\":
                if index + 1 < len(source):
                    result[index + 1] = " "
                    index += 1
            elif (state == "double-quote" and char == '"') or (
                state == "single-quote" and char == "'"
            ):
                state = "code"
        index += 1
    return "".join(result)


def require_order(body: str, *tokens: str) -> None:
    body = cpp_code(body)
    position = -1
    for token in tokens:
        current = body.find(token, position + 1)
        require(current >= 0, f"missing ordered contract token: {token}")
        require(current > position, f"out-of-order contract token: {token}")
        position = current


def validate_source(source: str) -> None:
    for unavailable in (
        "SPA_IO_CLOCK_FLAG_NO_RATE",
        "SPA_KEY_PORT_GROUP",
        "spa_pod_body_get_",
        "spa_pod_parser_push_sequence",
        "spa_pod_parser_push_object",
        "spa_pod_parser_push_struct",
    ):
        require(unavailable not in source, f"unavailable SPA 1.0.5 API: {unavailable}")

    require("struct spa_fraction rate = { 1, 30 };" in source, "clock rate is not reciprocal")
    require(
        "return SPA_FRACTION(normalized.denom, normalized.num);" in source,
        "negotiated framerate is not converted to a clock basis",
    )
    require(
        "spa_dll_set_bw(&impl->dll, SPA_DLL_BW_MAX, rate.num, rate.denom);" in source,
        "DLL period/rate contract regressed",
    )

    stop = extract_function(source, "\tint stop(")
    require_order(
        stop,
        "stopping = true;",
        "camera_remove_source_invoke",
        "processes_inflight == 0",
        "camera->stop()",
        "requestCompleted.disconnect",
        "callbacks_inflight == 0 && processes_inflight == 0",
        "spa_system_close",
        "completed_requests.fill(nullptr)",
    )
    require("keep_stopping || first_error < 0" in cpp_code(stop), "stop drops outer teardown latch")

    stream_on = extract_function(source, "int spa_libcamera_stream_on")
    require_order(
        stream_on,
        "spa_dll_init(&impl->dll);",
        "camera->start",
        "requestCompleted.connect",
        "active.store(true",
        "camera->queueRequest",
    )

    set_format = extract_function(source, "int spa_libcamera_set_format")
    require_order(
        set_format,
        "if (try_only)",
        "const int stop_res = impl->stop(true);",
        "stopping_transaction_guard stopping_guard(impl);",
        "freeBuffers(impl, port)",
        "camera->configure(candidate.get())",
        "clear_buffers_locked(port)",
        "port->rate = framerate_to_clock_rate",
    )
    before_restore = set_format[: set_format.find("auto restore")]
    require(
        "if (was_active)" not in before_restore,
        "terminal format replacement still gates stop on active state",
    )
    require(
        "if (restore_res == 0 && was_active)" in set_format,
        "rollback no longer preserves prior active-state restart policy",
    )
    require(
        "rollback_config" in set_format
        and "format_transaction_failed" in set_format
        and "stopping_guard.abandon()" in set_format,
        "failed format rollback does not retain ownership and stopping state",
    )
    require(
        "impl->rollback_config = std::move(old_config);" in set_format,
        "failed format rollback drops the previous configuration owner",
    )
    quarantine = extract_function(source, "auto quarantine = [&](int error)")
    require_order(
        quarantine,
        "if (old_config)",
        "impl->format_transaction_failed = true;",
        "impl->stopping = true;",
        "stopping_guard.abandon();",
        "mark_completion_failure(impl, error);",
    )

    reuse = extract_function(source, "int impl_node_port_reuse_buffer")
    require(
        "lifecycle_mutex" not in cpp_code(reuse),
        "data-loop buffer reuse waits for lifecycle mutex",
    )
    require_order(
        reuse,
        "process_activity_guard activity{impl};",
        "if (activity.stopping)",
        "return -EBUSY;",
        "buffer_guard(impl->buffer_mutex)",
        "buffer_id < port->n_buffers",
        "return recycle_buffer_locked(impl, port, buffer_id);",
    )
    require(
        "spa_libcamera_buffer_recycle" not in cpp_code(source),
        "obsolete lifecycle-locked buffer recycling wrapper remains",
    )
    activity = extract_function(source, "struct process_activity_guard {")
    require_order(
        activity,
        "lock(self->completion_mutex)",
        "++self->processes_inflight",
        "stopping = self->stopping",
        "~process_activity_guard()",
        "lock(self->completion_mutex)",
        "--self->processes_inflight",
        "self->completion_cv.notify_all()",
    )
    require(
        "++self->processes_inflight;\n\t\tstopping = self->stopping;" in activity,
        "stopping data-loop invocation escapes activity accounting",
    )

    process = extract_function(source, "int impl_node_process")
    require("lifecycle_mutex" not in process, "data-loop process waits for lifecycle mutex")
    require_order(
        process,
        "process_activity_guard",
        "if (activity.stopping)",
        "buffer_guard(impl->buffer_mutex)",
        "process_control",
        "recycle_buffer_locked",
    )

    fd_events = extract_function(source, "void libcamera_on_fd_events")
    fd_events_code = cpp_code(fd_events)
    require_order(
        fd_events,
        "bool retire_completion_source = false;",
        "bool stopping = false;",
        "stopping = impl->stopping;",
        "if (stopping)",
        "retire_completion_source = impl->data_loop != nullptr",
        "if (stopping)",
        "if (retire_completion_source)",
        "camera_remove_source_on_data_loop(impl)",
        "return;",
        "for (std::size_t i = 0; i < ready_count; ++i)",
        "lock(impl->completion_mutex)",
        "retire_completion_source = !impl->stopping",
        "if (retire_completion_source)",
        "camera_remove_source_on_data_loop(impl)",
    )
    stopping_assignment = fd_events_code.find("stopping = impl->stopping;")
    stopping_retire = fd_events_code.find(
        "retire_completion_source = impl->data_loop != nullptr", stopping_assignment
    )
    stopping_return = fd_events_code.find("return;", stopping_assignment)
    require(
        0 <= stopping_assignment < stopping_retire < stopping_return,
        "stopping callback returns before deciding registered-source retirement",
    )
    ready_loop = fd_events.find("for (std::size_t i = 0; i < ready_count; ++i)")
    stopping_removal_start = fd_events.rfind("\n\tif (stopping) {", 0, ready_loop)
    require(stopping_removal_start >= 0, "missing stopping source-retirement branch")
    stopping_removal = cpp_code(fd_events[stopping_removal_start:ready_loop])
    require(
        "lock_guard" not in stopping_removal
        and "camera_remove_source_on_data_loop(impl)" in stopping_removal,
        "stopping source is not retired from unlocked data-loop context",
    )
    require("spa_system_close" not in fd_events_code, "callback closes stop-owned eventfd")
    require(
        "if (event->len > 0 &&" not in fd_events_code,
        "camera source retains an unbraced event-name condition",
    )
    retirement_start = fd_events.find("retire_completion_source = !impl->stopping")
    require(retirement_start >= 0, "missing terminal source-retirement decision")
    retirement = fd_events[retirement_start:]
    lock_scope_end = retirement.find("\n\t\t}")
    removal = retirement.find("camera_remove_source_on_data_loop")
    require(
        0 <= lock_scope_end < removal,
        "completion source is removed while completion_mutex remains held",
    )
    require(
        fd_events_code.count("camera_remove_source_on_data_loop(impl)") == 2
        and "spa_loop_remove_source" not in fd_events_code,
        "callback source retirement bypasses atomic registration publication",
    )

    apply_controls = extract_function(source, "int spa_libcamera_apply_controls")
    require(
        "lifecycle_mutex" not in apply_controls,
        "process control path indirectly reacquires lifecycle mutex",
    )

    control_update = extract_function(
        source, "int control_list_update_from_prop"
    )
    require_order(
        control_update,
        "control_value_from_pod",
        "if (val.isNone())",
        "control_value_is_valid",
        "return -ERANGE",
        "list.set",
    )

    control_validation = extract_function(
        source, "static bool control_value_is_valid"
    )
    for token in (
        "value.isNone() || value.isArray()",
        "std::isfinite(value.get<float>())",
        "info.values().empty()",
        "allowed == value",
        "info.min().type() != value.type()",
        "ControlTypeInteger32",
        "value.get<int32_t>() >= min",
        "std::isfinite(min) && std::isfinite(max)",
    ):
        require(token in cpp_code(control_validation),
                f"control value validation omits {token}")
    props_validation = cpp_code(
        extract_function(source, "static int control_list_update_from_props_pod")
    )
    require_order(
        props_validation,
        "ControlList candidate = list",
        "control_list_update_from_prop(candidate",
        "list = std::move(candidate)",
    )

    clear_locked = extract_function(source, "static int clear_buffers_locked")
    require_order(
        clear_locked,
        "bound_spa_buffer_graph_matches_locked",
        "data->type = SPA_ID_INVALID",
        "port->n_buffers = 0",
    )
    require(
        "buffers_blocks" not in cpp_code(clear_locked),
        "SPA graph detach destroys allocator block layout",
    )
    free_buffers = extract_function(source, "int freeBuffers")
    require(
        "port->buffers_blocks = 1;" in cpp_code(free_buffers),
        "allocator release no longer resets block layout",
    )
    bound_match = extract_function(source, "static bool bound_spa_buffer_matches_locked")
    for token in ("validated_chunks", "validated_types", "validated_fds"):
        require(token in bound_match, f"clear authentication omits {token}")

    validation = extract_function(source, "static int validate_spa_buffer_graph_locked")
    for token in (
        "plane_per_data",
        "group_per_data",
        "build_plane_groups",
        "group_count != port->buffers_blocks",
        "add_buffer_graph_range",
        "candidate_manifest",
        "derive_plane_stride",
        "derive_group_stride",
        "binding.plane_count > 1",
    ):
        require(token in cpp_code(validation), f"buffer validation omits {token}")
    require(
        "buffers[i]->n_datas > planes.size()" not in validation,
        "arbitrary partial plane collapse is still accepted",
    )
    validation_code = cpp_code(validation)
    require(
        validation_code.count("buffer_graph_manifests_overlap(*candidate_manifest, io_manifest)")
        >= 2,
        "candidate graph is not checked against registered IO before dereference",
    )
    buffer_nonnull = validation_code.find("if (buffers[i] == nullptr)")
    buffer_range = validation_code.find(
        "add_graph_range(buffers[i],"
    )
    first_buffer_dereference = validation_code.find("buffers[i]->")
    require(
        0 <= buffer_nonnull < buffer_range < first_buffer_dereference,
        "spa_buffer fields are read before pointer/range validation",
    )

    binding = extract_function(source, "static void bind_spa_buffer_graph_validated_locked")
    binding_code = cpp_code(binding)
    require("validate_spa_buffer_graph" not in binding_code, "binding revalidates after detach")
    for token in (
        "data[j].fd = binding.fd;",
        "data[j].mapoffset = binding.offset;",
        "data[j].maxsize = binding.size;",
        "data[j].chunk->offset = 0;",
        "data[j].chunk->stride = static_cast<int32_t>(binding.stride);",
        "b->first_planes[j] = binding.first_plane;",
        "b->plane_counts[j] = binding.plane_count;",
    ):
        require(token in binding_code, f"binding contract omits {token}")
    require(
        "data[j].fd = planes[j].fd.get();" not in binding_code,
        "binding bypasses the validated plane/group plan",
    )

    memtype = cpp_code(extract_function(source, "static uint32_t choose_spa_memtype"))
    require_order(
        memtype,
        "if (type == SPA_ID_INVALID)",
        "return SPA_DATA_DmaBuf;",
        "if (type == SPA_DATA_DmaBuf)",
        "return SPA_DATA_Invalid;",
    )
    require("SPA_DATA_MemFd" not in memtype, "memfd is not an accepted camera export")
    require("type & SPA_DATA_DmaBuf" not in memtype, "memtype is treated as a bitmask")

    chunk_sizes = cpp_code(extract_function(source, "static int update_chunk_sizes_from_metadata"))
    for token in (
        "metadata.planes()",
        "bytesused",
        "bytes_used > plane.length",
        "used_end - map_start",
        "validated_chunks[i]->size",
    ):
        require(token in chunk_sizes, f"bytesused publication omits {token}")

    manifest = cpp_code(extract_function(source, "static int add_buffer_graph_range"))
    require("begin < range.end && range.begin < end" in manifest, "range overlap is not closed")
    overlap = cpp_code(extract_function(source, "static bool buffer_graph_manifests_overlap"))
    require("right.ranges[j].begin < left.ranges[i].end" in overlap, "old/new overlap is not closed")

    use_buffers = extract_function(source, "int impl_node_port_use_buffers")
    use_buffers_code = cpp_code(use_buffers)
    pointer_array_alignment = use_buffers_code.find(
        "naturally_aligned<struct spa_buffer *>(buffers)"
    )
    first_pointer_array_index = use_buffers_code.find("buffers[i]")
    require(
        0 <= pointer_array_alignment < first_pointer_array_index,
        "spa_buffer pointer array is indexed before alignment validation",
    )
    final_epoch = use_buffers.rfind("buffer_guard(impl->buffer_mutex)")
    require(final_epoch >= 0, "missing final buffer transaction")
    require_order(
        use_buffers[final_epoch:],
        "validate_spa_buffer_graph_locked",
        "build_bound_buffer_graph_manifest_locked",
        "buffer_graph_manifests_overlap",
        "clear_buffers_locked",
        "bind_spa_buffer_graph_validated_locked",
    )

    color_parse = cpp_code(extract_function(source, "static int colorimetry_to_color_space"))
    for token in (
        "SPA_VIDEO_COLOR_RANGE_UNKNOWN",
        "ColorSpace::YcbcrEncoding::Rec2020",
        "ColorSpace::TransferFunction::Rec709",
        "ColorSpace::Primaries::Rec2020",
    ):
        require(token in color_parse, f"colorimetry conversion omits {token}")
    set_format_code = cpp_code(set_format)
    for token in (
        "modifier_requested != modifier_required",
        "validate_stream_configuration(candidate.get()",
        "publish_color_space(port->streamConfig.colorSpace, &raw)",
    ):
        require(token in set_format_code, f"adjusted format contract omits {token}")
    configured_validation = extract_function(source, "static int validate_stream_configuration")
    configured_validation_code = cpp_code(configured_validation)
    for token in (
        "configuration->size() != 1",
        "stream.pixelFormat != info.pix",
        "stream.size.width != requested_size.width",
        "*stream.colorSpace != *requested_color_space",
        "info.media_subtype == SPA_MEDIA_SUBTYPE_raw && stream.stride == 0",
        "stream.frameSize == 0",
        "stream.stride != 0 && stream.frameSize < stream.stride",
        "stream.stream() == nullptr",
        "stream.bufferCount == 0",
        "stream.bufferCount > MAX_BUFFERS",
    ):
        require(token in configured_validation_code, f"configured stream check omits {token}")
    require_order(
        set_format,
        "candidate->validate()",
        "validate_stream_configuration(candidate.get()",
        "camera->configure(candidate.get())",
        "validate_stream_configuration(candidate.get()",
        "impl->config = std::move(candidate)",
        "allocBuffers(impl, port, port->streamConfig.bufferCount)",
    )

    port_set = cpp_code(extract_function(source, "int port_set_format"))
    require_order(
        port_set,
        "stopping_transaction_guard stopping_guard(impl);",
        "auto terminal_failure = [&](int error)",
        "clear_buffers_locked(port)",
        "return terminal_failure(clear_res);",
        "return terminal_failure(free_res);",
        "return terminal_failure(close_res);",
    )
    require(
        "stopping_guard.abandon();" in port_set
        and "impl->format_transaction_failed = true;" in port_set,
        "terminal format teardown failure releases the stopping latch",
    )
    require(
        "port->streamConfig = {};" in port_set
        and "port->rate = defaultClockRate;" in port_set
        and "port->buffers_blocks = 1;" in port_set,
        "null format teardown leaves stale stream configuration state",
    )

    node_param = cpp_code(extract_function(source, "int impl_node_set_param"))
    require_order(
        node_param,
        "if (param == nullptr)",
        "control_list_update_from_props_pod(controls, param",
        "spa_libcamera_apply_controls",
    )
    require("SPA_POD_OBJECT_FOREACH" not in node_param, "node Props uses unchecked macro walk")
    props_walk = extract_function(source, "static int control_list_update_from_props_pod")
    props_walk_code = cpp_code(props_walk)
    for token in (
        "available < sizeof(struct spa_pod)",
        "pod_size > available",
        "pod_size > max_props_pod_size",
        "pod->size < sizeof(struct spa_pod_object_body)",
        "SPA_POD_OBJECT_TYPE(obj) != SPA_TYPE_OBJECT_Props",
        "object_address > std::numeric_limits<std::uintptr_t>::max() - sizeof(*obj)",
        "properties_address > std::numeric_limits<std::uintptr_t>::max()",
        "remaining < sizeof(struct spa_pod_prop)",
        "prop_address % alignof(struct spa_pod_prop) != 0",
        "checked_pod_advance(prop_size, remaining, &padded_prop_size)",
        "cursor += padded_prop_size",
        "cursor != properties_size",
    ):
        require(token in props_walk_code, f"bounded Props walker omits {token}")
    checked_advance = cpp_code(extract_function(source, "static bool checked_pod_advance"))
    for token in (
        "unpadded_size > std::numeric_limits<uint64_t>::max() - 7",
        "rounded < unpadded_size",
        "rounded > remaining",
    ):
        require(token in checked_advance, f"POD padded advance omits {token}")
    process_controls = cpp_code(extract_function(source, "int process_control"))
    require(
        "control_list_update_from_props_pod(controls, &c->value" in process_controls,
        "sequence Properties bypasses the shared bounded Props walker",
    )

    rotation_parser = extract_function(source, "static bool y700_parse_kscreen_rotation")
    for token in (
        "errno = 0;",
        "errno == 0",
        "*end == '\\0'",
        "std::numeric_limits<int>::min()",
        "std::numeric_limits<int>::max()",
    ):
        require(token in rotation_parser, f"rotation parser accepts malformed value: {token}")

    node_io = extract_function(source, "int impl_node_set_io")
    port_io = extract_function(source, "int impl_node_port_set_io")
    for type_name in ("spa_io_clock", "spa_io_position"):
        require(f"naturally_aligned<struct {type_name}>" in node_io, f"unaligned {type_name}")
    for type_name in ("spa_io_buffers", "spa_io_sequence"):
        require(f"naturally_aligned<struct {type_name}>" in port_io, f"unaligned {type_name}")
    require(
        "size > std::numeric_limits<uint32_t>::max()" in port_io,
        "control IO size can truncate",
    )
    require(
        cpp_code(node_io).count("size > std::numeric_limits<uint32_t>::max()") >= 2,
        "clock/position IO size bounds are incomplete",
    )
    require(
        cpp_code(port_io).count("size > std::numeric_limits<uint32_t>::max()") >= 2,
        "buffer/control IO size bounds are incomplete",
    )
    io_manifest = extract_function(
        source, "static int build_registered_io_manifest_locked"
    )
    for token in (
        "registered_io_slot::clock",
        "registered_io_slot::position",
        "registered_io_slot::buffers",
        "registered_io_slot::control",
        "clock_size",
        "position_size",
        "io_size",
    ):
        require(token in io_manifest, f"registered IO manifest omits {token}")
    io_overlap = extract_function(
        source, "static int reject_buffer_graph_io_overlap"
    )
    require(
        "build_registered_io_manifest_locked" in io_overlap
        and "buffer_graph_manifests_overlap" in io_overlap,
        "buffer graph does not authenticate registered IO aliases",
    )
    io_registration = extract_function(
        source, "static int validate_io_registration_locked"
    )
    require_order(
        io_registration,
        "build_registered_io_manifest_locked",
        "add_registered_io_range",
        "build_bound_buffer_graph_manifest_locked",
        "buffer_graph_manifests_overlap",
    )
    require_order(
        node_io,
        "validate_io_registration_locked",
        "impl->clock = (struct spa_io_clock*)data;",
    )
    require_order(
        port_io,
        "validate_io_registration_locked",
        "port->io = (struct spa_io_buffers*)data;",
    )
    require(
        "impl->clock_size = data != nullptr ? size : 0;" in node_io
        and "impl->position_size = data != nullptr ? size : 0;" in node_io
        and "port->io_size = data != nullptr ? size : 0;" in port_io,
        "registered IO extent is not retained for alias checks",
    )

    rotation = extract_function(source, "static bool y700_query_kscreen_rotation")
    for forbidden in ("popen(", "system(", "/bin/sh"):
        require(forbidden not in rotation, f"rotation query uses forbidden path: {forbidden}")
    for token in (
        "/usr/bin/kscreen-doctor",
        "max_output",
        "deadline",
        "POSIX_SPAWN_SETPGROUP",
        "y700_terminate_rotation_child",
    ):
        require(token in rotation, f"rotation query omits {token}")
    require("waitpid(child, &status, 0)" not in source, "rotation cleanup has an unbounded wait")
    require("kill(-child, SIGKILL)" in source, "rotation timeout does not kill the child group")
    require(
        "display_rotation_child_pid" in source,
        "unreaped rotation child is not retained to prevent respawn",
    )
    require(
        "kill(-child, SIGKILL)" not in cpp_code(rotation),
        "rotation query retains a raw process-group kill after its wait loop",
    )
    rotation_cleanup = rotation[rotation.rfind("close(pipefd[0]);") :]
    require(
        "if (failed && reaped)" not in rotation_cleanup,
        "rotation query signals a process group after waitpid reaped the child",
    )
    require_order(
        rotation_cleanup,
        "close(pipefd[0]);",
        "if (!reaped)",
        "y700_terminate_rotation_child(impl)",
    )
    terminate = extract_function(source, "static bool y700_terminate_rotation_child")
    require(
        "display_rotation_child_pid <= 0" in cpp_code(terminate)
        and "kill(-child, SIGKILL)" in cpp_code(terminate),
        "rotation termination does not require a still-owned child PID",
    )

    rotation_reset = extract_function(
        source, "static void y700_display_rotation_watch_reset"
    )
    require_order(
        rotation_reset,
        "close(impl->display_rotation_inotify_fd)",
        "impl->display_rotation_inotify_fd = -1;",
        "impl->display_rotation_inotify_wd = -1;",
        "impl->display_rotation_config_dir.clear();",
    )
    rotation_init = extract_function(
        source, "static void y700_display_rotation_watch_init"
    )
    for token in (
        "IN_DELETE_SELF",
        "IN_MOVE_SELF",
        "IN_UNMOUNT",
        "inotify_add_watch",
    ):
        require(token in rotation_init, f"rotation watch init omits {token}")
    rotation_watch = extract_function(
        source, "static bool y700_display_rotation_watch_changed"
    )
    for token in (
        "bool invalidated = false;",
        "errno == EINTR",
        "IN_Q_OVERFLOW",
        "IN_IGNORED",
        "IN_UNMOUNT",
        "IN_DELETE_SELF",
        "IN_MOVE_SELF",
        "y700_display_rotation_watch_reset(impl);",
        "y700_display_rotation_watch_init(impl);",
    ):
        require(token in rotation_watch, f"rotation watch invalidation omits {token}")
    require_order(
        rotation_watch,
        "bool invalidated = false;",
        "if (invalidated)",
        "y700_display_rotation_watch_reset(impl);",
        "y700_display_rotation_watch_init(impl);",
        "return changed;",
    )
    rotation_read = extract_function(
        source, "static int y700_read_display_rotation"
    )
    rotation_read_code = cpp_code(rotation_read)
    require_order(
        rotation_read,
        "y700_display_rotation_watch_init(impl);",
        "y700_display_rotation_watch_changed(impl)",
        "display_rotation_refresh_pending = true;",
        "const auto now = std::chrono::steady_clock::now();",
        "if (now < impl->display_rotation_retry_after)",
        "if (y700_query_kscreen_rotation(impl, &rotation))",
        "display_rotation_initialized = true;",
        "display_rotation_refresh_pending = false;",
        "display_rotation_retry_after = {};",
        "display_rotation_retry_after = now + std::chrono::seconds(1);",
    )
    query_pos = rotation_read_code.find("y700_query_kscreen_rotation(impl, &rotation)")
    initialized_pos = rotation_read_code.find(
        "impl->display_rotation_initialized = true;"
    )
    require(
        query_pos >= 0 and initialized_pos > query_pos,
        "rotation query failure can latch initialized state",
    )
    require(
        "impl->display_rotation_refresh_pending = false;" in rotation_read_code,
        "successful rotation query does not clear refresh latch",
    )
    require(
        "impl->display_rotation_retry_after = now + std::chrono::seconds(1);"
        in rotation_read_code,
        "failed rotation query has no bounded retry deadline",
    )

    clear = extract_function(source, "int impl_clear")
    clear_code = cpp_code(clear)
    require_order(
        clear,
        "std::move(owner->state)",
        "std::shared_ptr<struct impl> shared_state",
        "impl->stop(true)",
        "if (!impl_provider_ownership_retired(impl))",
        "lifecycle_guard.unlock()",
        "impl_quarantine_reaper::instance().enqueue",
        "std::destroy_at(owner)",
        "finalize_impl_resources(impl)",
    )
    require(".wait(" not in clear_code, "terminal clear contains an unbounded wait")
    require(
        "completion_cv.wait(" not in cpp_code(stop),
        "stop uses an unbounded completion wait",
    )
    require(
        "if (stop_res < 0)\n\t\treturn stop_res;" not in clear_code,
        "clear exposes an impossible stop retry contract",
    )
    retirement = cpp_code(
        extract_function(source, "static bool impl_provider_ownership_retired")
    )
    require(
        "!impl->source_registered.load(std::memory_order_acquire)" in retirement
        and "!impl->camera_started.load(std::memory_order_acquire)" in retirement
        and "!impl->signal_connected.load(std::memory_order_acquire)" in retirement
        and "impl->source_fd.load(std::memory_order_acquire) < 0" in retirement,
        "terminal clear does not prove atomic provider ownership retirement",
    )
    require(
        "std::atomic<bool> source_registered{false};" in source
        and "std::atomic<int> source_fd{-1};" in source
        and "std::atomic<bool> camera_started{false};" in source
        and "std::atomic<bool> signal_connected{false};" in source,
        "provider ownership state is not represented by atomic mirrors",
    )
    require(
        "self->source_registered.store(self->source.loop != nullptr" in source,
        "data-loop source add/remove does not publish registration identity",
    )
    require(
        "impl->source_fd.store(res, std::memory_order_release);" in source
        and "source_fd.store(-1, std::memory_order_release);" in cpp_code(stop),
        "eventfd ownership is not mirrored atomically across start/stop",
    )
    require_order(
        stop,
        "camera->stop()",
        "camera_started.store(false, std::memory_order_release);",
        "requestCompleted.disconnect",
        "signal_connected.store(false, std::memory_order_release);",
        "spa_system_close",
        "source_fd.store(-1, std::memory_order_release);",
    )
    require_order(
        extract_function(source, "static int camera_remove_source_on_data_loop"),
        "spa_loop_remove_source",
        "source_registered.store(self->source.loop != nullptr",
    )
    require(
        "return camera_remove_source_on_data_loop(" in cpp_code(
            extract_function(source, "static int camera_remove_source_invoke")
        ),
        "loop-invoke removal bypasses the registration-publishing helper",
    )
    require_order(
        extract_function(source, "static int camera_add_source_invoke"),
        "spa_loop_add_source",
        "source_registered.store(self->source.loop != nullptr",
    )
    require(
        "impl_quarantine_reaper::instance().enqueue(std::move(shared_state));"
        in clear_code,
        "provider-owned state is not retained by the process-lifetime reaper",
    )
    require(
        "if (final_res < 0)" in clear_code,
        "terminal resource failure is silently discarded",
    )
    require(
        "return sizeof(struct handle_owner);" in source
        and "std::make_unique<struct impl>" in source
        and "new (handle) impl" not in source,
        "loader-owned handle storage still contains callback state",
    )


def model_plane_groups(planes: list[tuple[int, int, int]]) -> list[tuple[int, int, int]]:
    groups: list[list[int]] = []
    for fd, offset, length in planes:
        if fd < 0 or offset < 0 or length <= 0 or offset + length > 0xFFFFFFFF:
            raise ValueError("invalid plane")
        end = offset + length
        if not groups or groups[-1][0] != fd:
            groups.append([fd, offset, end])
        else:
            groups[-1][1] = min(groups[-1][1], offset)
            groups[-1][2] = max(groups[-1][2], end)
    return [(fd, start, end - start) for fd, start, end in groups]


def model_mapping(offset: int, size: int) -> tuple[int, int, int, int]:
    if offset < 0 or size <= 0 or offset + size > 0xFFFFFFFF:
        raise ValueError("invalid mapping")
    return offset, size, 0, size


def model_reject_io_alias(
    graph_ranges: list[tuple[int, int]], io_ranges: list[tuple[int, int]]
) -> None:
    """Registered IO must not overlap graph memory or another IO object."""
    for begin, end in io_ranges:
        if begin < 0 or end <= begin:
            raise ValueError("invalid IO range")
    for begin, end in io_ranges:
        if any(begin < old_end and old_begin < end for old_begin, old_end in graph_ranges):
            raise ValueError("IO aliases graph")
    for index, (begin, end) in enumerate(io_ranges):
        if any(
            index != other
            and begin < old_end
            and old_begin < end
            for other, (old_begin, old_end) in enumerate(io_ranges)
        ):
            raise ValueError("IO objects overlap")


def model_format_rollback(
    allocator_retired: bool, old_config_present: bool, candidate_present: bool
) -> tuple[str, bool, bool]:
    """Model ownership after candidate teardown succeeds or fails."""
    if allocator_retired:
        return "restore", old_config_present, False
    # A failed allocator retirement is terminal: retain both owners and latch stop.
    return "quarantine", old_config_present or candidate_present, True


def model_bytesused(
    planes: list[tuple[int, int]],
    bytesused: list[int],
    first: int,
    count: int,
    mapoffset: int,
    maxsize: int,
) -> int:
    if len(planes) != len(bytesused) or count <= 0 or first < 0 or first + count > len(planes):
        raise ValueError("invalid plane span")
    used_end = mapoffset
    for (offset, length), used in zip(
        planes[first : first + count], bytesused[first : first + count]
    ):
        if used < 0 or used > length:
            raise ValueError("bytesused exceeds plane")
        if used == 0:
            continue
        end = offset + used
        if offset < mapoffset or end > mapoffset + maxsize:
            raise ValueError("bytesused escapes mapping")
        used_end = max(used_end, end)
    return used_end - mapoffset


def add_model_range(ranges: list[tuple[int, int]], begin: int, size: int) -> None:
    if begin < 0 or size <= 0:
        raise ValueError("invalid range")
    end = begin + size
    if any(begin < old_end and old_begin < end for old_begin, old_end in ranges):
        raise ValueError("overlapping graph")
    ranges.append((begin, end))


def model_plane_stride(
    pixel_format: str, height: int, plane: int, length: int, configured_stride: int
) -> int:
    if plane == 0:
        return configured_stride
    half_height = {"NV12", "NV21", "I420", "YV12"}
    full_height = {"NV16", "NV61", "NV24", "Y42B"}
    plane_height = (height + 1) // 2 if pixel_format in half_height else height
    if pixel_format not in half_height | full_height or plane_height <= 0 or length % plane_height:
        raise ValueError("stride cannot be represented")
    stride = length // plane_height
    if stride <= 0 or stride > 0x7FFFFFFF:
        raise ValueError("invalid stride")
    return stride


def model_group_stride(
    pixel_format: str,
    height: int,
    lengths: list[int],
    configured_stride: int,
) -> int:
    """A grouped SPA data can represent only one row stride."""
    if not lengths:
        raise ValueError("empty plane group")
    strides = [
        model_plane_stride(pixel_format, height, plane, length, configured_stride)
        for plane, length in enumerate(lengths)
    ]
    if len(set(strides)) != 1:
        raise ValueError("grouped planes need different strides")
    return strides[0]


def model_memtype(offered: str) -> str:
    if offered in {"unspecified", "dmabuf"}:
        return "dmabuf"
    raise ValueError("libcamera cannot export requested memory type")


def model_terminal_clear(
    activity_quiescent: bool,
    source_registered: bool,
    camera_started: bool,
    signal_connected: bool,
    event_fd_open: bool,
) -> str:
    retired = (
        activity_quiescent
        and not source_registered
        and not camera_started
        and not signal_connected
        and not event_fd_open
    )
    return "destroy" if retired else "quarantine"


def model_completion_wakeup(
    stopping: bool, source_registered: bool, readable: bool
) -> str:
    if stopping:
        return "retire" if source_registered else "ignore"
    return "process" if readable else "ignore"


def model_rotation_refresh(
    initialized: bool, pending: bool, retry_ready: bool, query_ok: bool
) -> tuple[str, bool, bool, bool]:
    """Model the cached transform and retry latch without invoking a desktop."""
    if not initialized:
        pending = True
    if not pending or not retry_ready:
        return "cached", initialized, pending, False
    if query_ok:
        return "updated", True, False, False
    return "cached", initialized, True, True


def validate_models() -> None:
    groups = model_plane_groups([(10, 0, 100), (10, 128, 40), (11, 4, 32)])
    require(groups == [(10, 0, 168), (11, 4, 32)], "fd-group span model failed")
    require(
        groups[0][0] == 10 and groups[0][1] == 0 and groups[0][2] == 168,
        "first fd group membership changed",
    )
    require(
        groups[1][0] == 11 and groups[1][1] == 4 and groups[1][2] == 32,
        "second fd group membership changed",
    )
    require(
        model_plane_groups([(10, 0, 100), (11, 0, 100), (10, 128, 40)])
        == [(10, 0, 100), (11, 0, 100), (10, 128, 40)],
        "non-consecutive fd groups were collapsed",
    )

    require(model_mapping(4096, 8192) == (4096, 8192, 0, 8192), "mapping basis regressed")
    try:
        model_mapping(0xFFFFFFF0, 32)
    except ValueError:
        pass
    else:
        raise ContractError("overflowing mapping accepted")

    graph = [(0x1000, 0x1100), (0x1200, 0x1280)]
    model_reject_io_alias(graph, [(0x2000, 0x2040), (0x2100, 0x2180)])
    for hostile in (
        [(0x1080, 0x10C0)],
        [(0x2000, 0x2040), (0x2030, 0x2080)],
    ):
        try:
            model_reject_io_alias(graph, hostile)
        except ValueError:
            continue
        raise ContractError("hostile IO alias accepted")

    require(
        model_format_rollback(True, True, True) == ("restore", True, False),
        "successful rollback model failed",
    )
    require(
        model_format_rollback(False, True, True) == ("quarantine", True, True),
        "failed rollback did not retain stopping ownership",
    )

    planes = [(4096, 100), (4224, 40), (8192, 64)]
    used = [80, 20, 16]
    require(model_bytesused(planes, used, 0, 2, 4096, 168) == 148, "group bytesused failed")
    require(model_bytesused(planes, used, 2, 1, 8192, 64) == 16, "plane bytesused failed")
    for hostile in ([101, 20, 16], [80, 200, 16]):
        try:
            model_bytesused(planes, hostile, 0, 2, 4096, 168)
        except ValueError:
            continue
        raise ContractError("out-of-range bytesused accepted")

    ranges: list[tuple[int, int]] = []
    add_model_range(ranges, 0x1000, 0x100)
    add_model_range(ranges, 0x1200, 0x80)
    for begin, size in ((0x1000, 8), (0x1080, 0x100), (0x11F0, 0x20)):
        try:
            add_model_range(ranges, begin, size)
        except ValueError:
            continue
        raise ContractError("hostile graph alias accepted")

    require(model_plane_stride("I420", 480, 1, 76800, 640) == 320, "chroma stride failed")
    require(model_plane_stride("NV24", 480, 1, 614400, 640) == 1280, "NV24 stride failed")
    require(
        model_group_stride("NV12", 480, [307200, 153600], 640) == 640,
        "equal-stride grouped layout rejected",
    )
    try:
        model_group_stride("I420", 480, [307200, 76800, 76800], 640)
    except ValueError:
        pass
    else:
        raise ContractError("grouped planes with different strides accepted")
    try:
        model_plane_stride("unknown", 480, 1, 1, 640)
    except ValueError:
        pass
    else:
        raise ContractError("unknown per-plane stride accepted")

    require(model_memtype("unspecified") == "dmabuf", "unspecified memtype failed")
    require(model_memtype("dmabuf") == "dmabuf", "DMA-BUF type failed")
    for unsupported in ("dmabuf-mask", "memfd", "memfd-mask", "memptr"):
        try:
            model_memtype(unsupported)
        except ValueError:
            continue
        raise ContractError("non-DMA libcamera memory accepted")

    require(
        model_terminal_clear(True, False, False, False, False) == "destroy",
        "retired terminal state was not destroyed",
    )
    for hostile in (
        (False, False, False, False, False),
        (True, True, False, False, False),
        (True, False, True, False, False),
        (True, False, False, True, False),
        (True, False, False, False, True),
    ):
        require(
            model_terminal_clear(*hostile) == "quarantine",
            "provider-owned terminal state was destroyed",
        )

    require(
        model_completion_wakeup(True, True, True) == "retire",
        "readable stopping source was not retired",
    )
    require(
        model_completion_wakeup(True, True, False) == "retire",
        "stopping source retirement depends on wakeup mask",
    )
    require(
        model_completion_wakeup(True, False, True) == "ignore",
        "unregistered stopping source was removed twice",
    )
    require(
        model_completion_wakeup(False, True, True) == "process",
        "active readable source was not processed",
    )

    require(
        model_rotation_refresh(False, True, True, False)
        == ("cached", False, True, True),
        "failed initial rotation query was latched as initialized",
    )
    require(
        model_rotation_refresh(False, True, True, True)
        == ("updated", True, False, False),
        "successful initial rotation query did not clear the refresh latch",
    )
    require(
        model_rotation_refresh(True, True, False, True)
        == ("cached", True, True, False),
        "rotation retry ignored its monotonic deadline",
    )
    require(
        model_rotation_refresh(True, True, True, False)
        == ("cached", True, True, True),
        "failed rotation refresh discarded the pending retry",
    )

def validate_mutations(source: str) -> None:
    mutations = {
        "non-reciprocal clock": source.replace(
            "struct spa_fraction rate = { 1, 30 };",
            "struct spa_fraction rate = { 30, 1 };",
            1,
        ),
        "process lifecycle lock": source.replace(
            "int impl_node_process(void *object)\n{",
            "int impl_node_process(void *object)\n{\n\tlifecycle_mutex.lock();",
            1,
        ),
        "reuse lifecycle lock": source.replace(
            "return recycle_buffer_locked(impl, port, buffer_id);",
            "std::lock_guard<std::recursive_mutex> old_lock(impl->lifecycle_mutex);\n"
            "\treturn recycle_buffer_locked(impl, port, buffer_id);",
            1,
        ),
        "reuse activity accounting removed": source.replace(
            "process_activity_guard activity{impl};",
            "struct { bool stopping = false; } activity;",
            1,
        ),
        "unplanned fd binding": source.replace(
            "data[j].fd = binding.fd;", "data[j].fd = planes[j].fd.get();", 1
        ),
        "zero mapoffset": source.replace(
            "data[j].mapoffset = binding.offset;", "data[j].mapoffset = 0;", 1
        ),
        "absolute chunk offset": source.replace(
            "data[j].chunk->offset = 0;", "data[j].chunk->offset = binding.offset;", 1
        ),
        "capacity instead of bytesused": source.replace(
            "const auto metadata_planes = metadata.planes();",
            "const auto metadata_planes = frame_planes;",
            1,
        ),
        "graph clear resets allocator blocks": source.replace(
            "\tport->n_buffers = 0;\n\n\treturn 0;",
            "\tport->n_buffers = 0;\n\tport->buffers_blocks = 1;\n\n\treturn 0;",
            1,
        ),
        "old-new alias bypass": source.replace(
            "if (buffer_graph_manifests_overlap(candidate_manifest, bound_manifest))",
            "if (false)",
        ),
        "adjusted pixel format accepted": source.replace(
            "stream.pixelFormat != info.pix", "false", 1
        ),
        "modifier ignored": source.replace(
            "modifier_requested != modifier_required", "false", 1
        ),
        "adjusted colorimetry hidden": source.replace(
            "publish_color_space(port->streamConfig.colorSpace, &raw);",
            "publish_color_space(std::nullopt, &raw);",
            1,
        ),
        "single stride for every plane": source.replace(
            "data[j].chunk->stride = static_cast<int32_t>(binding.stride);",
            "data[j].chunk->stride = port->streamConfig.stride;",
            1,
        ),
        "grouped stride mismatch ignored": source.replace(
            "const int stride_res = binding.plane_count > 1\n"
            "\t\t\t\t? derive_group_stride(port->streamConfig, planes,",
            "const int stride_res = false\n"
            "\t\t\t\t? derive_group_stride(port->streamConfig, planes,",
            1,
        ),
        "rollback owner dropped": source.replace(
            "impl->rollback_config = std::move(old_config);",
            "old_config.reset();",
            1,
        ),
        "rollback latch released": source.replace(
            "stopping_guard.abandon();",
            "stopping_guard.finish();",
            1,
        ),
        "terminal teardown latch released": source.replace(
            "return terminal_failure(free_res);",
            "return free_res;",
            1,
        ),
        "stale terminal stream retained": source.replace(
            "port->streamConfig = {};",
            "port->streamConfig = port->streamConfig;",
            1,
        ),
        "node props type unchecked": source.replace(
            "SPA_POD_OBJECT_TYPE(obj) != SPA_TYPE_OBJECT_Props",
            "false",
            1,
        ),
        "props object size unbounded": source.replace(
            "pod_size > available || pod_size > max_props_pod_size",
            "false",
            1,
        ),
        "props object body underflow": source.replace(
            "pod->size < sizeof(struct spa_pod_object_body)",
            "false",
            1,
        ),
        "props base pointer overflow": source.replace(
            "object_address > std::numeric_limits<std::uintptr_t>::max() - sizeof(*obj)",
            "false",
            1,
        ),
        "props truncated header accepted": source.replace(
            "remaining < sizeof(struct spa_pod_prop)",
            "false",
            1,
        ),
        "props padded bound bypass": source.replace(
            "!checked_pod_advance(prop_size, remaining, &padded_prop_size)",
            "false",
            1,
        ),
        "props terminal cursor ignored": source.replace(
            "if (cursor != properties_size)\n\t\treturn -EINVAL;",
            "if (false)\n\t\treturn -EINVAL;",
            1,
        ),
        "control range bypass": source.replace(
            "if (!control_value_is_valid(list.infoMap()->at(it->second), val))\n\t\treturn -ERANGE;",
            "if (false)\n\t\treturn -ERANGE;",
            1,
        ),
        "control partial commit": source.replace(
            "control_list_update_from_prop(candidate, prop)",
            "control_list_update_from_prop(list, prop)",
            1,
        ),
        "configured stride accepted": source.replace(
            "info.media_subtype == SPA_MEDIA_SUBTYPE_raw && stream.stride == 0",
            "false",
            1,
        ),
        "configured frame size accepted": source.replace(
            "stream.frameSize == 0", "false", 1
        ),
        "configured stream pointer accepted": source.replace(
            "stream.stream() == nullptr", "false", 1
        ),
        "configured zero buffers accepted": source.replace(
            "stream.bufferCount == 0", "false", 1
        ),
        "configured excess buffers accepted": source.replace(
            "stream.bufferCount > MAX_BUFFERS", "false", 1
        ),
        "IO alias bypass": source.replace(
            "return buffer_graph_manifests_overlap(io_manifest, bound_manifest)\n"
            "\t\t? -EINVAL : 0;",
            "return 0;",
            1,
        ),
        "candidate IO alias bypass": source.replace(
            "return buffer_graph_manifests_overlap(*candidate_manifest, io_manifest)\n"
            "\t\t\t? -EINVAL : 0;",
            "return 0;",
            1,
        ),
        "clock IO extent dropped": source.replace(
            "impl->clock_size = data != nullptr ? size : 0;",
            "impl->clock_size = 0;",
            1,
        ),
        "unspecified memory rejected": source.replace(
            "if (type == SPA_ID_INVALID)\n\t\treturn SPA_DATA_DmaBuf;",
            "if (type == SPA_ID_INVALID)\n\t\treturn SPA_DATA_Invalid;",
            1,
        ),
        "retryable production clear": source.replace(
            "int stop_res = impl->stop(true);\n\tlog_clear_error(\"stop\", stop_res);",
            "int stop_res = impl->stop(true);\n\tif (stop_res < 0)\n\t\treturn stop_res;\n"
            "\tlog_clear_error(\"stop\", stop_res);",
            1,
        ),
        "unbounded terminal wait": source.replace(
            "completion_cv.wait_for(lock, std::chrono::seconds(5),",
            "completion_cv.wait(lock,",
            1,
        ),
        "destructive provider-owned clear": source.replace(
            "if (!impl_provider_ownership_retired(impl))", "if (false)", 1
        ),
        "placement-owned callback state": source.replace(
            "return sizeof(struct handle_owner);", "return sizeof(struct impl);", 1
        ),
        "stopping process unaccounted": source.replace(
            "++self->processes_inflight;\n\t\tstopping = self->stopping;",
            "stopping = self->stopping;\n\t\tif (!stopping)\n"
            "\t\t\t++self->processes_inflight;",
            1,
        ),
        "truncating control size": source.replace(
            "(data != nullptr && size > std::numeric_limits<uint32_t>::max())",
            "false",
            1,
        ),
        "unaligned pointer array accepted": source.replace(
            "if (!naturally_aligned<struct spa_buffer *>(buffers))",
            "if (false)",
            1,
        ),
        "per-buffer alignment removed": source.replace(
            "add_graph_range(buffers[i],",
            "add_graph_range(nullptr,",
            1,
        ),
        "source removal under completion lock": source.replace(
            "\t\t}\n\t\t/* This callback already runs on data_loop.",
            "\t\t/* This callback already runs on data_loop.",
            1,
        ),
        "stopping source early return": source.replace(
            "\t\tif (stopping) {\n\t\t\tretire_completion_source =",
            "\t\tif (stopping)\n\t\t\treturn;\n\t\tif (stopping) {\n"
            "\t\t\tretire_completion_source =",
            1,
        ),
        "stopping source retirement disabled": source.replace(
            "retire_completion_source = impl->data_loop != nullptr &&\n"
            "\t\t\t\timpl->source_registered.load(std::memory_order_acquire);",
            "retire_completion_source = false;",
            1,
        ),
        "callback retirement bypasses registration mirror": source.replace(
            "(void)camera_remove_source_on_data_loop(impl);",
            "(void)spa_loop_remove_source(impl->data_loop, &impl->source);",
            1,
        ),
        "source removal mirror publication removed": source.replace(
            "self->source_registered.store(self->source.loop != nullptr,\n"
            "\t\tstd::memory_order_release);",
            "(void)self->source.loop;",
            1,
        ),
        "provider retirement plain fields": source.replace(
            "!impl->source_registered.load(std::memory_order_acquire) &&\n"
            "\t\t!impl->camera_started.load(std::memory_order_acquire) &&\n"
            "\t\t!impl->signal_connected.load(std::memory_order_acquire) &&\n"
            "\t\timpl->source_fd.load(std::memory_order_acquire) < 0;",
            "!impl->source.loop && !impl->camera_started &&\n"
            "\t\t!impl->signal_connected && impl->source.fd < 0;",
            1,
        ),
        "rotation failure latched initialized": source.replace(
            "if (y700_query_kscreen_rotation(impl, &rotation)) {",
            "impl->display_rotation_initialized = true;\n"
            "\tif (y700_query_kscreen_rotation(impl, &rotation)) {",
            1,
        ),
        "rotation retry deadline removed": source.replace(
            "impl->display_rotation_retry_after = now + std::chrono::seconds(1);",
            "impl->display_rotation_retry_after = {};",
            1,
        ),
        "reaped rotation process-group kill": source.replace(
            "\tif (!reaped)\n\t\treaped = y700_terminate_rotation_child(impl);",
            "\tif (failed && reaped)\n\t\t(void)kill(-child, SIGKILL);\n"
            "\tif (!reaped)\n\t\treaped = y700_terminate_rotation_child(impl);",
            1,
        ),
        "rotation refresh latch cleared on failure": source.replace(
            "impl->display_rotation_refresh_pending = false;",
            "impl->display_rotation_refresh_pending = true;",
            1,
        ),
        "rotation trailing junk accepted": source.replace(
            "*end == '\\0' && errno == 0",
            "errno == 0",
            1,
        ),
        "inotify overflow ignored": source.replace(
            "IN_Q_OVERFLOW | IN_IGNORED | IN_UNMOUNT |",
            "IN_IGNORED | IN_UNMOUNT |",
            1,
        ),
        "inotify watch invalidation masks omitted": source.replace(
            "IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT",
            "IN_DELETE_SELF",
            1,
        ),
        "inotify watch not recreated": source.replace(
            "y700_display_rotation_watch_reset(impl);\n\t\ty700_display_rotation_watch_init(impl);",
            "y700_display_rotation_watch_reset(impl);",
            1,
        ),
    }
    for label, mutation in mutations.items():
        require(mutation != source, f"mutation anchor disappeared: {label}")
        try:
            validate_source(mutation)
        except ContractError:
            continue
        raise ContractError(f"contract fixture accepted mutation: {label}")


def main() -> int:
    source_path = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_SOURCE
    if len(sys.argv) > 2:
        raise ContractError("usage: test-camera-source-contract.py [camera-source]")
    source = source_path.read_text(encoding="utf-8")
    validate_source(source)
    validate_models()
    validate_mutations(source)
    print("CAMERA_SOURCE_CONTRACT=PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, UnicodeError) as error:
        print(f"CAMERA_SOURCE_CONTRACT=FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
