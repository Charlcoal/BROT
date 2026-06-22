// BROT - A fast mandelbrot set explorer
// Copyright (C) 2025 - 2026 Charles Reischer
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pub fn mainLoop(alloc: Allocator, io: std.Io) !void {
    while (c.glfwWindowShouldClose(window.glfw) == 0) {
        c.glfwPollEvents();
        try gui.show(io, alloc);

        const delta = get_update_delta_time(io);
        try renderedBufferResolve(io);
        updateFractalPosition(delta);
        try renderedBufferDispatch(io);

        try drawFrame(alloc, io);
    }

    common.gpu_interface_lock.lockUncancelable(io);
    try vulkan.device.deviceWaitIdle();
    common.gpu_interface_lock.unlock(io);
}

fn drawFrame(alloc: Allocator, io: std.Io) !void {
    if (common.frame_buffer_just_resized) {
        _ = try vulkan.device.waitForFences(
            (&common.in_flight_fences[common.current_frame])[0..1],
            .true,
            60_000_000,
        );
        common.frame_buffer_just_resized = false;
    } else {
        _ = try vulkan.device.waitForFences(
            (&common.in_flight_fences[common.current_frame])[0..1],
            .true,
            std.math.maxInt(u64),
        );
    }
    try vulkan.device.resetFences((&common.in_flight_fences[common.current_frame])[0..1]);

    var delta_dur = common.prev_frame_time.untilNow(io, common.clock);
    const target_delta: i96 = @intFromFloat(1e9 / vulkan.target_frame_rate);
    if (delta_dur.nanoseconds < target_delta) {
        const sleep_nanosecs = target_delta - delta_dur.nanoseconds;
        try io.sleep(.fromNanoseconds(sleep_nanosecs), .boot);
        delta_dur = common.prev_frame_time.untilNow(io, common.clock);
    }
    common.prev_frame_time = common.clock.now(io);

    const image_khr_result = try vulkan.device.acquireNextImageKHR(
        common.swap_chain,
        std.math.maxInt(u64),
        common.image_availible_semaphores[common.current_frame],
        .null_handle,
    );
    const result = image_khr_result.result;
    const image_index = image_khr_result.image_index;

    common.gpu_interface_lock.lockUncancelable(io);
    defer common.gpu_interface_lock.unlock(io);

    if (result == .error_out_of_date_khr) {
        try vulkan.recreateSwapChain(alloc);
        return;
    } else if (result != .success and result != .suboptimal_khr) {
        return error.imageAcquisitionFailed;
    } else if (result == .suboptimal_khr) {}

    try vulkan.device.resetCommandBuffer(common.graphics_command_buffers[common.current_frame], .{});
    try recordColoringCommandBuffer(common.graphics_command_buffers[common.current_frame], image_index);

    const signal_semaphores = [_]vk.Semaphore{common.render_finished_semaphores[image_index]};
    try vulkan.device.queueSubmit(vulkan.graphics_queue, &.{.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &.{common.image_availible_semaphores[common.current_frame]},
        .p_wait_dst_stage_mask = &.{.{ .color_attachment_output_bit = true }},
        .command_buffer_count = 1,
        .p_command_buffers = &.{common.graphics_command_buffers[common.current_frame]},
        .signal_semaphore_count = signal_semaphores.len,
        .p_signal_semaphores = &signal_semaphores,
    }}, common.in_flight_fences[common.current_frame]);

    _ = try vulkan.device.queuePresentKHR(vulkan.present_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = 1,
        .p_swapchains = &.{common.swap_chain},
        .p_image_indices = &.{image_index},
        .p_results = null,
    });

    if (result == .error_out_of_date_khr or result == .suboptimal_khr or common.frame_buffer_needs_resize) {
        common.frame_buffer_needs_resize = false;
        try vulkan.recreateSwapChain(alloc);
        return;
    } else if (result != .success) {
        return error.imageAcquisitionFailed;
    }
}

pub fn computeManage(alloc: Allocator, io: std.Io) common.ComputeManageError!void {
    for (0.., &common.resolutions_complete, &common.res_complete_tmp) |i, *res, *res_tmp| {
        const width = common.escape_potential_buffer_block_num_x * @as(u32, 1) << @as(u5, @intCast(common.max_res_scale_exponent - i));
        const height = common.escape_potential_buffer_block_num_y * @as(u32, 1) << @as(u5, @intCast(common.max_res_scale_exponent - i));
        res.* = try alloc.alloc([]bool, width);
        res_tmp.* = try alloc.alloc([]bool, width);
        for (res.*, res_tmp.*) |*col, *col_tmp| {
            col.* = try alloc.alloc(bool, height);
            col_tmp.* = try alloc.alloc(bool, height);
        }
    }

    defer for (common.resolutions_complete, common.res_complete_tmp) |res, res_tmp| {
        for (res, res_tmp) |col, col_tmp| {
            alloc.free(col);
            alloc.free(col_tmp);
        }
        alloc.free(res);
        alloc.free(res_tmp);
    };

    const FenceStatusTag = enum { unassigned, assigned_normal, assigned_background };
    const FenceStatus = union(FenceStatusTag) {
        unassigned: void,
        assigned_normal: usize,
        assigned_background: usize,
    };
    var round_robin_index: usize = 0;
    var fences_status = [1]FenceStatus{.{ .unassigned = void{} }} ** common.num_active_render_patches;

    while (!common.compute_manager_should_close) {
        // wait for a rendering task to complete
        _ = try vulkan.device.waitForFences(common.rendering_fences[0..], .false, std.math.maxInt(u64));

        const comp_index: usize = label: {
            for (common.rendering_fences) |_| {
                round_robin_index += 1;
                round_robin_index %= common.rendering_fences.len;
                if (try vulkan.device.getFenceStatus(common.rendering_fences[round_robin_index]) == .success) {
                    break :label round_robin_index;
                }
            }
            unreachable;
        };

        switch (fences_status[comp_index]) {
            .unassigned => {},
            .assigned_normal => |index| {
                if (common.render_patches_status[index] == .cancelled) {
                    common.render_patches_status[index] = .empty;
                } else {
                    common.render_patches_status[index] = .complete;
                }
                fences_status[comp_index] = .unassigned;
            },
            .assigned_background => |index| {
                common.back_r2c_is_rendering[index] = false;
                common.current_back_r2c_descriptor_index = index;
                fences_status[comp_index] = .unassigned;
            },
        }

        if (common.buffer_invalidated) {
            common.buffer_invalidated = false;
            try common.render_patch_mutex.lock(io);
            common.background_needs_render = true;
            resetRenderPatchsResComps(common.resolutions_complete);
            common.render_patch_mutex.unlock(io);
        }

        // waiting on reference to be ready
        if (common.reference_center_stale) {
            try io.sleep(.fromMicroseconds(500), .boot);
            continue;
        }

        const bg_next_render_index: usize = (common.current_back_r2c_descriptor_index + 1) % common.back_r2c_descriptor_sets.len;

        const render_params: RenderingParams = if (common.background_needs_render and
            !common.back_r2c_is_rendering[bg_next_render_index])
        blk: {
            const res_exp: u5 = 3 + std.math.log2_int(u32, @divTrunc(
                @as(u32, @intCast(@max(window.height, window.width))),
                common.renderPatchSize(0),
            ));

            try common.render_patch_mutex.lock(io);
            defer common.render_patch_mutex.unlock(io);
            common.background_needs_render = false;
            common.back_r2c_is_rendering[bg_next_render_index] = true;
            common.back_r2c_offset[bg_next_render_index] = .{ .x = 0, .y = 0, .zoom = -@as(i32, res_exp) };
            fences_status[comp_index] = .{ .assigned_background = bg_next_render_index };

            break :blk .{
                .offset = @Vector(2, i32){
                    -@as(i32, @intCast((common.renderPatchSize(res_exp) / 2))),
                    -@as(i32, @intCast((common.renderPatchSize(res_exp) / 2))),
                },
                .res_exp = res_exp,
                .zoom_exp = common.fractal_pos.zoom_exp,
                .patch_descriptor_set = common.back_r2c_descriptor_sets[bg_next_render_index],
                .active_ref = common.current_cpu_to_render_descriptor_index,
            };
        } else blk: { // normal render patch
            const buffer_to_render_to: ?usize = for (0.., common.render_patches_status) |i, status| {
                if (status == .empty) break i;
            } else null;

            // waiting on render queue to empty patch buffers
            if (buffer_to_render_to == null) {
                try io.sleep(.fromMicroseconds(500), .boot);
                continue;
            }

            try common.render_patch_mutex.lock(io);
            const patch_to_render_maybe = chooseRenderPatch(common.resolutions_complete);
            var patch_to_render: RenderPatch = undefined;
            if (patch_to_render_maybe) |patch| {
                patch_to_render = patch;
            } else {
                common.render_patch_mutex.unlock(io);
                common.render_patches_saturated = true;
                try io.sleep(.fromMicroseconds(500), .boot);
                continue;
            }

            fences_status[comp_index] = .{ .assigned_normal = buffer_to_render_to.? };
            common.render_patches_status[buffer_to_render_to.?] = .rendering;
            common.render_patches[buffer_to_render_to.?] = patch_to_render;

            const resolution_scale_exponent: u32 = patch_to_render.resolution_scale_exponent;

            var render_patch_size: u32 = @as(u32, 1) << @as(u5, @intCast(resolution_scale_exponent));
            render_patch_size *= common.sqrt_invocation_num;
            render_patch_size *= common.sqrt_workgroup_num;

            const center_screen_pos = @Vector(2, i32){
                @intCast((common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_x) / 2),
                @intCast((common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_y) / 2),
            };

            common.render_patch_mutex.unlock(io);
            break :blk .{
                .offset = @Vector(2, i32){
                    @as(i32, @intCast(render_patch_size * patch_to_render.x_pos)) - center_screen_pos[0],
                    @as(i32, @intCast(render_patch_size * patch_to_render.y_pos)) - center_screen_pos[1],
                },
                .res_exp = @intCast(patch_to_render.resolution_scale_exponent),
                .zoom_exp = common.fractal_pos.zoom_exp,
                .patch_descriptor_set = common.render_patch_descriptor_sets[buffer_to_render_to.?],
                .active_ref = common.current_cpu_to_render_descriptor_index,
            };
        };

        try common.gpu_interface_lock.lock(io);
        defer common.gpu_interface_lock.unlock(io);

        _ = try vulkan.device.resetFences(common.rendering_fences[comp_index .. comp_index + 1]);

        try vulkan.device.resetCommandBuffer(common.rendering_command_buffers[comp_index], .{});
        try recordRenderingCommandBuffer(common.rendering_command_buffers[comp_index], render_params);

        const submit_info: vk.SubmitInfo = .{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = null,
            .p_wait_dst_stage_mask = &.{},
            .command_buffer_count = 1,
            .p_command_buffers = (&common.rendering_command_buffers[comp_index])[0..1],
            .signal_semaphore_count = 0,
            .p_signal_semaphores = null,
        };

        try vulkan.device.queueSubmit(vulkan.compute_queue, (&submit_info)[0..1], common.rendering_fences[comp_index]);
    }

    _ = try vulkan.device.waitForFences(common.rendering_fences[0..], .true, std.math.maxInt(u64));
}

fn fractalToBlockScale() f64 {
    const block_size = common.renderPatchSize(common.max_res_scale_exponent);
    return @as(f64, @floatFromInt(window.height)) / @as(f64, @floatFromInt(block_size));
}

fn updateFractalPosition(delta_time: f64) void {
    common.fractal_pos.interp_prog += @floatCast(delta_time);

    var block_x_diff = common.fractal_pos.x_diff() * fractalToBlockScale();
    var block_y_diff = common.fractal_pos.y_diff() * fractalToBlockScale();

    var updated_state: bool = false;

    var remap_x: i32 = 0;
    var remap_y: i32 = 0;
    var remap_exp: i32 = 0;

    if (common.fractal_pos.zoom_diff() >= 2.0) {
        remap_exp = 1;
        updated_state = true;
        block_x_diff *= 0.5;
        block_y_diff *= 0.5;
    }
    if (common.fractal_pos.zoom_diff() < 1.0) {
        remap_exp = -1;
        updated_state = true;
        block_x_diff *= 2.0;
        block_y_diff *= 2.0;
    }

    if (@abs(block_x_diff) > 0.5 or @abs(block_y_diff) > 0.5) {
        updated_state = true;
        remap_x = @intFromFloat(@round(block_x_diff));
        remap_y = @intFromFloat(@round(block_y_diff));
    }
    if (updated_state) {
        common.remap_x = remap_x;
        common.remap_y = remap_y;
        common.remap_exp = remap_exp;

        //common.buffer_invalidated = true;
        common.remap_needed = true;
    }
}

fn renderedBufferResolve(io: std.Io) !void {
    _ = try vulkan.device.waitForFences((&common.render_buffer_write_fence)[0..1], .true, std.math.maxInt(u64));

    if (common.placing_patches) {
        common.placing_patches = false;
        for (&common.render_patches_status) |*status| {
            if (status.* == .placing) status.* = .empty;
        }
    }

    if (common.remapping_buffer) {
        common.remapping_buffer = false;

        common.render_patch_mutex.lockUncancelable(io);
        defer common.render_patch_mutex.unlock(io);

        for (common.back_r2c_offset[0..]) |*offset| {
            if (common.remap_exp != 0) common.background_needs_render = true;

            offset.x /= std.math.exp2(@as(f64, @floatFromInt(common.remap_exp)));
            offset.y /= std.math.exp2(@as(f64, @floatFromInt(common.remap_exp)));
            offset.zoom += common.remap_exp;
            offset.x += @as(f64, @floatFromInt(common.remap_x)); // * scale;
            offset.y += @as(f64, @floatFromInt(common.remap_y)); // * scale;
        }

        moveUnplacedPatches();
        moveRenderPatches(
            common.resolutions_complete,
            common.res_complete_tmp,
        );
        std.mem.swap(
            [common.num_distinct_res_scales][][]bool,
            &common.resolutions_complete,
            &common.res_complete_tmp,
        );

        common.fractal_pos.remap(
            common.remap_exp,
            common.remap_x,
            common.remap_y,
            fractalToBlockScale(),
            &common.mpf_intermediates[0],
            &common.mpf_intermediates[1],
        );

        const needed_prec = c.mpf_get_prec(&common.fractal_pos.x);
        if (needed_prec > c.mpf_get_prec(&common.ref_calc_x)) {
            for (common.mpf_intermediates[2 .. common.mpf_intermediates.len - 1]) |*intermediate| {
                c.mpf_set_prec(intermediate, needed_prec);
            }
            c.mpf_set_prec(&common.ref_calc_x, needed_prec);
            c.mpf_set_prec(&common.ref_calc_y, needed_prec);
            std.log.debug("set precision to: {}", .{needed_prec});
        }
        common.reference_center_stale = true;
        try reference_calc.update(io, common.max_iterations);
        common.reference_center_stale = false;

        var next_index = (common.current_render_to_coloring_descriptor_index + 1);
        next_index %= common.render_to_coloring_descriptor_sets.len;
        common.current_render_to_coloring_descriptor_index = next_index;
    }
}

fn renderedBufferDispatch(io: std.Io) common.ComputeManageError!void {
    if (common.remap_needed) {
        common.remap_needed = false;
        try remap_buffer(io);
        common.remapping_buffer = true;
    } else if (common.render_patches_saturated and numCompletePatches() != 0 or
        numCompletePatches() >= common.rendering_command_buffers.len)
    {
        try place_patches(io);
        common.placing_patches = true;
    }
}

fn remap_buffer(io: std.Io) common.ComputeManageError!void {
    try vulkan.device.resetFences((&common.render_buffer_write_fence)[0..1]);

    common.gpu_interface_lock.lockUncancelable(io);
    defer common.gpu_interface_lock.unlock(io);

    try vulkan.device.resetCommandBuffer(common.rnd_buffer_write_command_buffer, .{});
    try recordBufferRemapCommandBuffer();

    const compute_submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = null,
        .p_wait_dst_stage_mask = null,
        .command_buffer_count = 1,
        .p_command_buffers = (&common.rnd_buffer_write_command_buffer)[0..1],
        .signal_semaphore_count = 0,
        .p_signal_semaphores = null,
    };

    try vulkan.device.queueSubmit(
        vulkan.compute_queue,
        (&compute_submit_info)[0..1],
        common.render_buffer_write_fence,
    );
}

fn place_patches(io: std.Io) common.ComputeManageError!void {
    try vulkan.device.resetFences((&common.render_buffer_write_fence)[0..1]);

    common.gpu_interface_lock.lockUncancelable(io);
    defer common.gpu_interface_lock.unlock(io);

    try vulkan.device.resetCommandBuffer(common.rnd_buffer_write_command_buffer, .{});
    common.render_patches_saturated = false;
    try recordPatchPlaceCommandBuffer();

    try vulkan.device.queueSubmit(vulkan.compute_queue, (&vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = null,
        .p_wait_dst_stage_mask = &.{.{}},
        .p_command_buffers = (&common.rnd_buffer_write_command_buffer)[0..1],
    })[0..1], common.render_buffer_write_fence);
}

fn numCompletePatches() u32 {
    var count: u32 = 0;
    for (common.render_patches_status) |status| {
        if (status == .complete) count += 1;
    }
    return count;
}

fn resetRenderPatchsResComps(resolutions_complete: [common.num_distinct_res_scales][][]bool) void {
    for (resolutions_complete) |res| {
        for (res) |col| {
            for (col) |*patch| {
                patch.* = false;
            }
        }
    }
}

fn moveUnplacedPatches() void {
    const remap = calculateRemapDimensions();

    for (&common.render_patches_status, &common.render_patches, 0..) |*status, *patch, i| {
        if (status.* == .rendering or status.* == .complete) {
            const new_exp = @as(i64, patch.resolution_scale_exponent) - common.remap_exp;
            if (new_exp > common.max_res_scale_exponent or new_exp < 0) {
                if (status.* == .rendering) status.* = .cancelled;
                if (status.* == .complete) status.* = .empty;
                patch_log.debug("cancelled render patch #{} (exp: {})", .{ i, new_exp });
                continue;
            }

            const src_start: common.Pos = remap.src_start.shft(@intCast(common.max_res_scale_exponent - @as(i32, @intCast(patch.resolution_scale_exponent)) - 1));
            const dst_start: common.Pos = remap.dst_start.shft(@intCast(common.max_res_scale_exponent - @as(i32, @intCast(new_exp)) - 1));

            const diff_x: i64 = @as(i64, patch.x_pos) - src_start.x;
            const diff_y: i64 = @as(i64, patch.y_pos) - src_start.y;

            const new_x: i64 = dst_start.x + diff_x;
            const new_y: i64 = dst_start.y + diff_y;
            const new_shft: u5 = @intCast(common.max_res_scale_exponent - new_exp);

            if (new_x < 0 or
                new_x >= common.escape_potential_buffer_block_num_x << new_shft or
                new_y < 0 or
                new_y >= common.escape_potential_buffer_block_num_y << new_shft)
            {
                if (status.* == .rendering) status.* = .cancelled;
                if (status.* == .complete) status.* = .empty;
                patch_log.debug("cancelled render patch #{} (exp: {})", .{ i, new_exp });
                continue;
            }

            patch.resolution_scale_exponent = @intCast(new_exp);
            patch.x_pos = @intCast(new_x);
            patch.y_pos = @intCast(new_y);
        }
    }
}

fn moveRenderPatches(
    resolutions_complete_src: [common.num_distinct_res_scales][]const []const bool,
    resolutions_complete_dst: [common.num_distinct_res_scales][][]bool,
) void {
    const remap_dims = calculateRemapDimensions();

    const dst_exp_start: usize = if (common.remap_exp < 0) @intCast(-common.remap_exp) else 0;
    const src_exp_start: usize = if (common.remap_exp > 0) @intCast(common.remap_exp) else 0;

    for (resolutions_complete_dst) |res| {
        for (res) |col| {
            for (col) |*elem| {
                elem.* = false;
            }
        }
    }
    for (
        dst_exp_start..,
        src_exp_start..,
        resolutions_complete_dst[dst_exp_start .. common.num_distinct_res_scales - src_exp_start],
    ) |dst_exp, src_exp, res| {
        const src_start: common.Pos = remap_dims.src_start.shft(@intCast(common.max_res_scale_exponent - @as(i32, @intCast(src_exp)) - 1));
        const dst_start: common.Pos = remap_dims.dst_start.shft(@intCast(common.max_res_scale_exponent - @as(i32, @intCast(dst_exp)) - 1));
        const range: common.Pos = .{
            .x = @intCast(@min(res.len - dst_start.x, resolutions_complete_src[src_exp].len - src_start.x)),
            .y = @intCast(@min(res[0].len - dst_start.y, resolutions_complete_src[src_exp][0].len - src_start.y)),
        };
        for (src_start.x.., res[dst_start.x..(range.x + dst_start.x)]) |i, col| {
            for (src_start.y.., col[dst_start.y..(range.y + dst_start.y)]) |j, *elem| {
                elem.* = resolutions_complete_src[src_exp][i][j];
            }
        }
    }
    if (common.remap_exp == 1) {
        for (resolutions_complete_dst[common.max_res_scale_exponent], 0..) |col, i| {
            for (col, 0..) |*elem, j| {
                elem.* =
                    resolutions_complete_dst[common.max_res_scale_exponent - 1][2 * i][2 * j] and
                    resolutions_complete_dst[common.max_res_scale_exponent - 1][2 * i][2 * j + 1] and
                    resolutions_complete_dst[common.max_res_scale_exponent - 1][2 * i + 1][2 * j] and
                    resolutions_complete_dst[common.max_res_scale_exponent - 1][2 * i + 1][2 * j + 1];
            }
        }
    }
}

fn patchVisible(patch: RenderPatch) bool {
    const patch_size: u32 = common.renderPatchSize(@intCast(patch.resolution_scale_exponent));

    const screen_center = common.getScreenCenter();

    const screen_left_edge: u32 = @intFromFloat(@max(screen_center.x - @as(f64, @floatFromInt(window.width)) * common.fractal_pos.zoom_diff() / 2, 0.0));
    const screen_right_edge: u32 = @intFromFloat(@max(screen_center.x + @as(f64, @floatFromInt(window.width)) * common.fractal_pos.zoom_diff() / 2, 0.0));
    const screen_top_edge: u32 = @intFromFloat(@max(screen_center.y - @as(f64, @floatFromInt(window.height)) * common.fractal_pos.zoom_diff() / 2, 0.0));
    const screen_bottom_edge: u32 = @intFromFloat(@max(screen_center.y + @as(f64, @floatFromInt(window.height)) * common.fractal_pos.zoom_diff() / 2, 0.0));

    if (patch_size * patch.x_pos > screen_right_edge) return false;
    if (patch_size * (patch.x_pos + 1) < screen_left_edge) return false;
    if (patch_size * patch.y_pos > screen_bottom_edge) return false;
    if (patch_size * (patch.y_pos + 1) < screen_top_edge) return false;

    return true;
}

fn patch_overlap(patch: RenderPatch, resolutions_complete: [common.num_distinct_res_scales][][]bool) bool {
    // ensures patches are "in order," i.e. lower resolutions never render after higher resolutions
    for (1..(common.num_distinct_res_scales - patch.resolution_scale_exponent)) |exp_diff| {
        const res_scale = patch.resolution_scale_exponent + exp_diff;
        const x = patch.x_pos >> @intCast(exp_diff);
        const y = patch.y_pos >> @intCast(exp_diff);
        if (!resolutions_complete[res_scale][x][y]) return true;
    }

    // ensure overlapping patches are never simultaniusly rendered
    for (common.render_patches_status, common.render_patches) |status, active_patch| {
        if (status == .empty or status == .placing or status == .cancelled) continue;
        const active_higher_exp = active_patch.resolution_scale_exponent > patch.resolution_scale_exponent;
        const exp_diff = if (active_higher_exp)
            active_patch.resolution_scale_exponent - patch.resolution_scale_exponent
        else
            patch.resolution_scale_exponent - active_patch.resolution_scale_exponent;

        const a_x = if (active_higher_exp) active_patch.x_pos else active_patch.x_pos >> @intCast(exp_diff);
        const a_y = if (active_higher_exp) active_patch.y_pos else active_patch.y_pos >> @intCast(exp_diff);
        const p_x = if (active_higher_exp) patch.x_pos >> @intCast(exp_diff) else patch.x_pos;
        const p_y = if (active_higher_exp) patch.y_pos >> @intCast(exp_diff) else patch.y_pos;

        if (a_x == p_x and a_y == p_y) return true;
    }

    return false;
}

fn chooseRenderPatch(resolutions_complete: [common.num_distinct_res_scales][][]bool) ?RenderPatch {
    const screen_center = common.getScreenCenter();

    var mouse_x_flt: f64 = undefined;
    var mouse_y_flt: f64 = undefined;
    c.glfwGetCursorPos(window.glfw, &mouse_x_flt, &mouse_y_flt);

    mouse_x_flt = std.math.clamp(mouse_x_flt, 0.0, @as(f64, @floatFromInt(window.width)));
    mouse_y_flt = std.math.clamp(mouse_y_flt, 0.0, @as(f64, @floatFromInt(window.height)));

    var mouse_x_from_screen_center: f64 = (mouse_x_flt - @as(f64, @floatFromInt(window.width)) / 2.0);
    var mouse_y_from_screen_center: f64 = (mouse_y_flt - @as(f64, @floatFromInt(window.height)) / 2.0);

    // to buffer coordinates
    mouse_x_from_screen_center = mouse_x_from_screen_center * common.fractal_pos.zoom_diff();
    mouse_y_from_screen_center = mouse_y_from_screen_center * common.fractal_pos.zoom_diff();

    const buffer_target_pos_x: u32 = @intFromFloat(@max(0, mouse_x_from_screen_center + screen_center.x));
    const buffer_target_pos_y: u32 = @intFromFloat(@max(0, mouse_y_from_screen_center + screen_center.y));

    var running_dists: [common.num_distinct_res_scales]f64 = [1]f64{std.math.floatMax(f64)} ** common.num_distinct_res_scales;
    var min_dist_poss: [common.num_distinct_res_scales]common.Pos = [1]common.Pos{.{}} ** common.num_distinct_res_scales;
    var res_incompletes: [common.num_distinct_res_scales]bool = [1]bool{false} ** common.num_distinct_res_scales;
    for (0..common.num_distinct_res_scales) |res_scale_exp| {
        const patch_size: u32 = common.renderPatchSize(@intCast(res_scale_exp));
        for (0.., resolutions_complete[res_scale_exp]) |i, max_res_col| {
            for (0.., max_res_col) |j, max_res_patch| {
                if (!max_res_patch) {
                    const patch: RenderPatch = .{
                        .resolution_scale_exponent = @intCast(res_scale_exp),
                        .x_pos = @intCast(i),
                        .y_pos = @intCast(j),
                    };

                    if (!patchVisible(patch)) continue;
                    if (patch_overlap(patch, resolutions_complete)) continue;

                    res_incompletes[res_scale_exp] = true;

                    const dist_x: f64 = @as(f64, @floatFromInt(buffer_target_pos_x)) -
                        @as(f64, @floatFromInt(i * patch_size + patch_size / 2));
                    const dist_y: f64 = @as(f64, @floatFromInt(buffer_target_pos_y)) -
                        @as(f64, @floatFromInt(j * patch_size + patch_size / 2));
                    const patch_dist = std.math.sqrt(dist_x * dist_x + dist_y * dist_y);

                    if (patch_dist < running_dists[res_scale_exp]) {
                        running_dists[res_scale_exp] = patch_dist;
                        min_dist_poss[res_scale_exp] = .{ .x = @intCast(i), .y = @intCast(j) };
                    }
                }
            }
        }
    }

    if (res_incompletes[common.max_res_scale_exponent]) {
        const pos: common.Pos = min_dist_poss[common.max_res_scale_exponent];
        resolutions_complete[common.max_res_scale_exponent][pos.x][pos.y] = true;
        resolutions_complete[common.max_res_scale_exponent - 1][2 * pos.x][2 * pos.y] = false;
        resolutions_complete[common.max_res_scale_exponent - 1][2 * pos.x][2 * pos.y + 1] = false;
        resolutions_complete[common.max_res_scale_exponent - 1][2 * pos.x + 1][2 * pos.y] = false;
        resolutions_complete[common.max_res_scale_exponent - 1][2 * pos.x + 1][2 * pos.y + 1] = false;
        return RenderPatch{
            .resolution_scale_exponent = common.max_res_scale_exponent,
            .x_pos = pos.x,
            .y_pos = pos.y,
        };
    }

    var min_dist: f64 = std.math.floatMax(f64);
    var min_dist_exp: u32 = 0;
    for (0..common.max_res_scale_exponent) |exp| {
        if (!res_incompletes[exp]) continue;
        if (running_dists[exp] / @as(f64, @floatFromInt(1 + exp)) < min_dist) {
            min_dist = running_dists[exp] / @as(f64, @floatFromInt(1 + exp));
            min_dist_exp = @intCast(exp);
        }
    }

    // all complete
    if (min_dist == std.math.floatMax(f64)) return null;

    const pos: common.Pos = min_dist_poss[min_dist_exp];
    resolutions_complete[min_dist_exp][pos.x][pos.y] = true;
    if (min_dist_exp > 0) {
        resolutions_complete[min_dist_exp - 1][2 * pos.x][2 * pos.y] = false;
        resolutions_complete[min_dist_exp - 1][2 * pos.x][2 * pos.y + 1] = false;
        resolutions_complete[min_dist_exp - 1][2 * pos.x + 1][2 * pos.y] = false;
        resolutions_complete[min_dist_exp - 1][2 * pos.x + 1][2 * pos.y + 1] = false;
    }
    return RenderPatch{
        .resolution_scale_exponent = min_dist_exp,
        .x_pos = pos.x,
        .y_pos = pos.y,
    };
}

fn recordBufferRemapCommandBuffer() !void {
    try vulkan.device.beginCommandBuffer(common.rnd_buffer_write_command_buffer, &.{
        .flags = .{},
        .p_inheritance_info = null,
    });

    vulkan.device.cmdBindPipeline(common.rnd_buffer_write_command_buffer, .compute, common.buffer_remap_pipeline);

    const next_index = (common.current_render_to_coloring_descriptor_index + 1) %
        common.render_to_coloring_descriptor_sets.len;

    vulkan.device.cmdBindDescriptorSets(
        common.rnd_buffer_write_command_buffer,
        .compute,
        common.buffer_remap_pipeline_layout,
        0,
        &.{
            common.render_to_coloring_descriptor_sets[common.current_render_to_coloring_descriptor_index],
            common.render_to_coloring_descriptor_sets[next_index],
        },
        null,
    );

    const remap_dims = calculateRemapDimensions();
    const half_patch_size: u32 = common.renderPatchSize(common.max_res_scale_exponent - 1);

    const buffer_src_offset_x: u32 = remap_dims.src_start.x * half_patch_size;
    const buffer_src_offset_y: u32 = remap_dims.src_start.y * half_patch_size;
    const buffer_dst_offset_x: u32 = remap_dims.dst_start.x * half_patch_size;
    const buffer_dst_offset_y: u32 = remap_dims.dst_start.y * half_patch_size;

    vulkan.device.cmdPushConstants(
        common.rnd_buffer_write_command_buffer,
        common.buffer_remap_pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(common.BufferRemapConstants),
        &common.BufferRemapConstants{
            .dst_offset = @Vector(2, u32){ buffer_dst_offset_x, buffer_dst_offset_y },
            .src_offset = @Vector(2, u32){ buffer_src_offset_x, buffer_src_offset_y },
            .buf_size = @Vector(2, u32){
                common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_x,
                common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_y,
            },
            .scale_diff = common.remap_exp,
            .scale_parity = @intCast(@abs(common.fractal_pos.zoom_exp) % 2),
        },
    );

    const sqrt_workgroups_per_patch: u32 = common.sqrt_workgroup_num << common.max_res_scale_exponent;

    vulkan.device.cmdDispatch(
        common.rnd_buffer_write_command_buffer,
        sqrt_workgroups_per_patch * common.escape_potential_buffer_block_num_x,
        sqrt_workgroups_per_patch * common.escape_potential_buffer_block_num_y,
        1,
    );

    try vulkan.device.endCommandBuffer(common.rnd_buffer_write_command_buffer);
}

/// in units of half blocks (half of largest render patch size)
fn calculateRemapDimensions() struct { src_start: common.Pos, dst_start: common.Pos } {
    // in half "blocks;" half largest render patchs as units
    // to be potentially scaled by exp_diff
    var buffer_src_start: common.Pos = .{};
    var buffer_dst_start: common.Pos = .{};

    patch_log.debug("remapping by ({}, {}) x {}", .{ common.remap_x, common.remap_y, common.remap_exp });

    if (common.remap_x < 0) {
        buffer_dst_start.x = @intCast(2 * -common.remap_x);
    } else {
        buffer_src_start.x = @intCast(2 * common.remap_x);
    }
    if (common.remap_y < 0) {
        buffer_dst_start.y = @intCast(2 * -common.remap_y);
    } else {
        buffer_src_start.y = @intCast(2 * common.remap_y);
    }

    if (common.remap_exp == 1) {
        buffer_src_start.x <<= 1;
        buffer_src_start.y <<= 1;
        buffer_dst_start.x += common.escape_potential_buffer_block_num_x / 2;
        buffer_dst_start.y += common.escape_potential_buffer_block_num_y / 2;
    } else if (common.remap_exp == -1) {
        buffer_src_start.x >>= 1;
        buffer_src_start.y >>= 1;
        buffer_src_start.x += common.escape_potential_buffer_block_num_x / 2;
        buffer_src_start.y += common.escape_potential_buffer_block_num_y / 2;
    }

    buffer_src_start.x = @min(2 * common.escape_potential_buffer_block_num_x, buffer_src_start.x);
    buffer_src_start.y = @min(2 * common.escape_potential_buffer_block_num_y, buffer_src_start.y);
    buffer_dst_start.x = @min(2 * common.escape_potential_buffer_block_num_x, buffer_dst_start.x);
    buffer_dst_start.y = @min(2 * common.escape_potential_buffer_block_num_y, buffer_dst_start.y);

    return .{
        .src_start = buffer_src_start,
        .dst_start = buffer_dst_start,
    };
}

fn recordPatchPlaceCommandBuffer() !void {
    try vulkan.device.beginCommandBuffer(common.rnd_buffer_write_command_buffer, &.{
        .flags = .{},
        .p_inheritance_info = null,
    });

    vulkan.device.cmdBindPipeline(common.rnd_buffer_write_command_buffer, .compute, common.patch_place_pipeline);

    for (0.., &common.render_patches_status, common.render_patches) |i, *status, patch| {
        if (status.* != .complete) continue;
        status.* = .placing;

        vulkan.device.cmdBindDescriptorSets(
            common.rnd_buffer_write_command_buffer,
            .compute,
            common.patch_place_pipeline_layout,
            0,
            &.{
                common.render_patch_descriptor_sets[i],
                common.render_to_coloring_descriptor_sets[common.current_render_to_coloring_descriptor_index],
            },
            null,
        );

        const patch_size: u32 = common.renderPatchSize(@intCast(patch.resolution_scale_exponent));
        const buffer_offset: u32 = patch_size * (patch.x_pos +
            patch.y_pos * common.escape_potential_buffer_block_num_x *
                common.renderPatchSize(common.max_res_scale_exponent));

        vulkan.device.cmdPushConstants(
            common.rnd_buffer_write_command_buffer,
            common.patch_place_pipeline_layout,
            .{ .compute_bit = true },
            0,
            @sizeOf(common.PatchPlaceConstants),
            &.{
                .buffer_offset = buffer_offset,
                .max_width = common.renderPatchSize(common.max_res_scale_exponent) *
                    common.escape_potential_buffer_block_num_x,
                .resolution_scale_exponent = @as(u32, @intCast(patch.resolution_scale_exponent)),
            },
        );

        vulkan.device.cmdDispatch(
            common.rnd_buffer_write_command_buffer,
            common.sqrt_workgroup_num,
            common.sqrt_workgroup_num,
            1,
        );
    }

    try vulkan.device.endCommandBuffer(common.rnd_buffer_write_command_buffer);
}

const RenderingParams = struct {
    offset: @Vector(2, i32),
    res_exp: i32,
    zoom_exp: i32,
    patch_descriptor_set: vk.DescriptorSet,
    active_ref: usize,
};

fn recordRenderingCommandBuffer(rendering_command_buffer: vk.CommandBuffer, params: RenderingParams) !void {
    try vulkan.device.beginCommandBuffer(rendering_command_buffer, &.{
        .flags = .{},
        .p_inheritance_info = null,
    });

    vulkan.device.cmdBindPipeline(rendering_command_buffer, .compute, common.rendering_pipeline);

    vulkan.device.cmdBindDescriptorSets(
        rendering_command_buffer,
        .compute,
        common.rendering_pipeline_layout,
        0,
        &.{
            params.patch_descriptor_set,
            common.cpu_to_render_descriptor_sets[params.active_ref],
        },
        null,
    );

    vulkan.device.cmdPushConstants(
        rendering_command_buffer,
        common.rendering_pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(common.RenderingConstants),
        &common.RenderingConstants{
            .screen_offset = params.offset,
            .max_iterations = common.max_iterations,
            .height_scale_exp = params.zoom_exp,
            .resolution_scale_exponent = params.res_exp,
            .cur_height = @intCast(window.height),
        },
    );

    vulkan.device.cmdDispatch(rendering_command_buffer, common.sqrt_workgroup_num, common.sqrt_workgroup_num, 1);
    try vulkan.device.endCommandBuffer(rendering_command_buffer);
}

fn recordColoringCommandBuffer(command_buffer: vk.CommandBuffer, image_index: u32) !void {
    try vulkan.device.beginCommandBuffer(command_buffer, &.{
        .flags = .{},
        .p_inheritance_info = null,
    });

    const clear_color: vk.ClearValue = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } };
    vulkan.device.cmdBeginRenderPass(command_buffer, &.{
        .render_pass = vulkan.render_pass,
        .framebuffer = common.swap_chain_framebuffers[image_index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = common.swap_chain_extent,
        },
        .p_clear_values = &.{clear_color},
        .clear_value_count = 1,
    }, .@"inline");

    vulkan.device.cmdBindPipeline(command_buffer, .graphics, common.coloring_pipeline);
    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @as(f32, @floatFromInt(common.swap_chain_extent.width)),
        .height = @as(f32, @floatFromInt(common.swap_chain_extent.height)),
        .min_depth = 0,
        .max_depth = 1,
    };
    vulkan.device.cmdSetViewport(command_buffer, 0, (&viewport)[0..1]);

    vulkan.device.cmdSetScissor(command_buffer, 0, &.{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = common.swap_chain_extent,
    }});

    // --------------- draw main rendered area ---------------
    vulkan.device.cmdBindDescriptorSets(command_buffer, .graphics, common.coloring_pipeline_layout, 0, &.{
        common.render_to_coloring_descriptor_sets[common.current_render_to_coloring_descriptor_index],
        common.back_r2c_descriptor_sets[common.current_back_r2c_descriptor_index],
    }, null);

    const screen_center = common.getScreenCenter();
    const zoom_mult = @exp2(@as(f64, @floatFromInt(
        common.back_r2c_offset[common.current_back_r2c_descriptor_index].zoom,
    )));
    const offset_factor = zoom_mult * @as(f64, @floatFromInt(common.renderPatchSize(common.max_res_scale_exponent)));
    const background_zoom = (common.fractal_pos.zoom_diff() * zoom_mult);

    const background_offset = @Vector(2, f64){
        common.back_r2c_offset[common.current_back_r2c_descriptor_index].x * offset_factor +
            common.fractal_pos.x_diff() * zoom_mult * @as(f64, @floatFromInt(window.height)) +
            @as(f64, @floatFromInt(common.renderPatchSize(0))) / 2.0,
        common.back_r2c_offset[common.current_back_r2c_descriptor_index].y * offset_factor +
            common.fractal_pos.y_diff() * zoom_mult * @as(f64, @floatFromInt(window.height)) +
            @as(f64, @floatFromInt(common.renderPatchSize(0))) / 2.0,
    };

    vulkan.device.cmdPushConstants(
        command_buffer,
        common.coloring_pipeline_layout,
        .{ .fragment_bit = true },
        0,
        @sizeOf(common.ColoringConstants),
        &common.ColoringConstants{
            .cur_resolution = @Vector(2, u32){ @intCast(window.width), @intCast(window.height) },
            .center_position = @Vector(2, u32){
                @intFromFloat(screen_center.x),
                @intFromFloat(screen_center.y),
            },
            .buffer_size = @Vector(2, u32){
                common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_x,
                common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_y,
            },
            .background_offset = .{
                @floatCast(background_offset[0]),
                @floatCast(background_offset[1]),
            },
            .background_size = .{
                common.renderPatchSize(0),
                common.renderPatchSize(0),
            },
            .zoom_diff = @floatCast(common.fractal_pos.zoom_diff()),
            .background_zoom = @floatCast(background_zoom),
        },
    );

    vulkan.device.cmdDraw(command_buffer, 6, 1, 0, 0);
    gui.draw(command_buffer);

    vulkan.device.cmdEndRenderPass(command_buffer);
    try vulkan.device.endCommandBuffer(command_buffer);
}

fn get_update_delta_time(io: std.Io) f64 {
    const current_time = common.clock.now(io);
    const delta_dur = common.prev_update_time.durationTo(current_time);
    const delta_time: f64 = @as(f64, @floatFromInt(delta_dur.toMicroseconds())) / 1_000_000;
    common.prev_update_time = current_time;
    return delta_time;
}

const patch_log = std.log.scoped(.render_patch);

const Allocator = std.mem.Allocator;
const RenderPatch = common.RenderPatch;

const vk = @import("vulkan");
const std = @import("std");
const common = @import("common_defs.zig");
const vulkan = @import("vulkan.zig");
const window = @import("window.zig");
const c = @import("c");
const big_float = @import("big_float.zig");
const reference_calc = @import("reference_calc.zig");
const gui = @import("gui.zig");
