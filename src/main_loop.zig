// BROT - A fast mandelbrot set explorer
// Copyright (C) 2025  Charles Reischer
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

const std = @import("std");
const common = @import("common_defs.zig");
const vulkan_init = @import("vulkan_init.zig");
const c = common.c;
const big_float = @import("big_float.zig");
const reference_calc = @import("reference_calc.zig");

const MainLoopError = common.MainLoopError;
const Allocator = std.mem.Allocator;
const RenderPatch = common.RenderPatch;

pub fn mainLoop(alloc: Allocator) MainLoopError!void {
    while (c.glfwWindowShouldClose(common.window) == 0) {
        c.glfwPollEvents();

        try drawFrame(alloc);
    }

    common.gpu_interface_lock.lock();
    _ = c.vkDeviceWaitIdle(common.device);
    common.gpu_interface_lock.unlock();
}

pub fn startComputeManager(alloc: Allocator) std.Thread.SpawnError!void {
    common.compute_manager_thread = try std.Thread.spawn(.{ .allocator = alloc }, computeManage, .{alloc});
    common.patch_placer_thread = try std.Thread.spawn(.{ .allocator = alloc }, placePatches, .{});
}

fn drawFrame(alloc: Allocator) MainLoopError!void {
    if (common.frame_buffer_just_resized) {
        _ = c.vkWaitForFences(
            common.device,
            1,
            &common.in_flight_fences[common.current_frame],
            c.VK_TRUE,
            60_000_000,
        );
        common.frame_buffer_just_resized = false;
    } else {
        _ = c.vkWaitForFences(
            common.device,
            1,
            &common.in_flight_fences[common.current_frame],
            c.VK_TRUE,
            std.math.maxInt(u64),
        );
    }

    _ = c.vkResetFences(common.device, 1, &common.in_flight_fences[common.current_frame]);

    var delta_time: f64 = @as(f64, @floatFromInt(common.time.read() - common.prev_time)) / 1_000_000_000;
    if (delta_time < 1.0 / common.target_frame_rate) {
        std.Thread.sleep(@intFromFloat((1.0 / common.target_frame_rate - delta_time) * 1_000_000_000));
        delta_time = @as(f64, @floatFromInt(common.time.read() - common.prev_time)) / 1_000_000_000;
    } else {
        //std.debug.print("MISSED FRAME: {d:.4} seconds\n", .{delta_time});
    }
    //std.debug.print("time: {d:.3}\n", .{delta_time});
    common.prev_time = common.time.read();

    var image_index: u32 = undefined;
    const result = c.vkAcquireNextImageKHR(
        common.device,
        common.swap_chain,
        std.math.maxInt(u64),
        common.image_availible_semaphores[common.current_frame],
        @ptrCast(c.VK_NULL_HANDLE),
        &image_index,
    );

    common.gpu_interface_lock.lock();
    defer common.gpu_interface_lock.unlock();

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
        try vulkan_init.recreateSwapChain(alloc);
        return;
    } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
        return MainLoopError.swap_chain_image_acquisition_failed;
    } else if (result == c.VK_SUBOPTIMAL_KHR) {}

    _ = c.vkResetCommandBuffer(common.graphics_command_buffers[common.current_frame], 0);
    try recordColoringCommandBuffer(common.graphics_command_buffers[common.current_frame], image_index);

    const wait_semaphors = [_]c.VkSemaphore{common.image_availible_semaphores[common.current_frame]};
    const wait_stages: u32 = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    const signal_semaphors = [_]c.VkSemaphore{common.render_finished_semaphores[image_index]};
    const submit_info: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = @intCast(wait_semaphors.len),
        .pWaitSemaphores = &wait_semaphors,
        .pWaitDstStageMask = &wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &common.graphics_command_buffers[common.current_frame],
        .signalSemaphoreCount = @intCast(signal_semaphors.len),
        .pSignalSemaphores = &signal_semaphors,
    };

    if (c.vkQueueSubmit(
        common.graphics_queue,
        1,
        &submit_info,
        common.in_flight_fences[common.current_frame],
    ) != c.VK_SUCCESS) {
        return MainLoopError.draw_command_buffer_submit_failed;
    }

    const swap_chains = [_]c.VkSwapchainKHR{common.swap_chain};
    const present_info: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = @intCast(signal_semaphors.len),
        .pWaitSemaphores = &signal_semaphors,
        .swapchainCount = @intCast(swap_chains.len),
        .pSwapchains = &swap_chains,
        .pImageIndices = &image_index,
        .pResults = null,
    };

    _ = c.vkQueuePresentKHR(common.present_queue, &present_info);

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or common.frame_buffer_needs_resize) {
        common.frame_buffer_needs_resize = false;
        try vulkan_init.recreateSwapChain(alloc);
        return;
    } else if (result != c.VK_SUCCESS) {
        return MainLoopError.swap_chain_image_acquisition_failed;
    }
}

fn computeManage(alloc: Allocator) Allocator.Error!void {
    var resolutions_complete: [common.num_distinct_res_scales][][]bool = undefined;

    for (0.., &resolutions_complete) |i, *res| {
        const width = common.escape_potential_buffer_block_num_x * @as(u32, 1) << @as(u5, @intCast(common.max_res_scale_exponent - i));
        const height = common.escape_potential_buffer_block_num_y * @as(u32, 1) << @as(u5, @intCast(common.max_res_scale_exponent - i));
        res.* = try alloc.alloc([]bool, width);
        for (res.*) |*col| {
            col.* = try alloc.alloc(bool, height);
        }
    }

    defer {
        for (resolutions_complete) |res| {
            for (res) |col| {
                alloc.free(col);
            }
            alloc.free(res);
        }
    }

    while (!common.compute_manager_should_close) {
        // wait for a rendering task to complete
        _ = c.vkWaitForFences(
            common.device,
            common.rendering_fences.len,
            &common.rendering_fences,
            c.VK_FALSE,
            std.math.maxInt(u64),
        );

        const comp_index: usize = label: {
            for (0..common.rendering_fences.len) |i| {
                if (c.vkGetFenceStatus(common.device, common.rendering_fences[i]) == c.VK_SUCCESS) {
                    break :label i;
                }
            }
            unreachable;
        };

        if (common.fence_to_patch_index[comp_index]) |index| {
            common.render_patches_status[index] = .complete;
            common.fence_to_patch_index[comp_index] = null;
        }

        if (common.buffer_invalidated) {
            common.buffer_invalidated = false;
            resetRenderPatchsResComps(resolutions_complete);
        }

        if (common.frame_updated) {
            common.frame_updated = false;
        }

        // waiting on reference to be calculated
        if (common.reference_center_updated) {
            std.Thread.sleep(1_000_000); // 1ms
            continue;
        }

        const buffer_to_render_to: ?usize = for (0.., common.render_patches_status) |i, status| {
            if (status == .empty) break i;
        } else null;

        // waiting on render queue to empty patch buffers
        if (buffer_to_render_to == null) {
            std.Thread.sleep(1_000_000); // 1ms
            continue;
        }

        const patch_to_render_maybe = chooseRenderPatch(resolutions_complete);
        var patch_to_render: RenderPatch = undefined;
        if (patch_to_render_maybe) |patch| {
            patch_to_render = patch;
        } else {
            common.render_patches_saturated = true;
            std.Thread.sleep(4_000_000); // 4ms
            continue;
        }

        common.fence_to_patch_index[comp_index] = buffer_to_render_to;
        common.render_patches_status[buffer_to_render_to.?] = .rendering;
        common.render_patches[buffer_to_render_to.?] = patch_to_render;

        const resolution_scale_exponent: u32 = patch_to_render.resolution_scale_exponent;

        var render_patch_size: u32 = @as(u32, 1) << @as(u5, @intCast(resolution_scale_exponent));
        render_patch_size *= common.sqrt_invocation_num;
        render_patch_size *= common.sqrt_workgroup_num;

        common.gpu_interface_lock.lock();
        defer common.gpu_interface_lock.unlock();

        //updateUniformBuffer();

        //std.debug.print("starting compute\n", .{});
        _ = c.vkResetFences(common.device, 1, &common.rendering_fences[comp_index]);

        _ = c.vkResetCommandBuffer(common.rendering_command_buffers[comp_index], 0);
        recordRenderingCommandBuffer(
            common.rendering_command_buffers[comp_index],
            buffer_to_render_to.?,
            common.sqrt_workgroup_num,
            @Vector(2, u32){
                render_patch_size * patch_to_render.x_pos,
                render_patch_size * patch_to_render.y_pos,
            }, //spiral_result.pos,
            @intCast(resolution_scale_exponent),
        ) catch {
            @panic("compute manager failed to record buffer!");
        };

        const wait_stages: u32 = 0;
        const submit_info: c.VkSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &common.rendering_command_buffers[comp_index],
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        if (c.vkQueueSubmit(common.compute_queue, 1, &submit_info, common.rendering_fences[comp_index]) != c.VK_SUCCESS) {
            @panic("compute manager failed to submit queue!");
        }
    }

    _ = c.vkWaitForFences(
        common.device,
        common.rendering_fences.len,
        &common.rendering_fences,
        c.VK_TRUE,
        std.math.maxInt(u64),
    );
}

fn placePatches() MainLoopError!void {
    while (!common.compute_manager_should_close) {
        _ = c.vkWaitForFences(
            common.device,
            1,
            &common.patch_place_fence,
            c.VK_TRUE,
            std.math.maxInt(u64),
        );

        for (&common.render_patches_status) |*status| {
            if (status.* == .placing) status.* = .empty;
        }

        while (!common.render_patches_saturated and numCompletePatches() < common.rendering_command_buffers.len or
            numCompletePatches() == 0)
        {
            std.Thread.sleep(500_000);
            if (common.compute_manager_should_close) break;
        }

        _ = c.vkResetFences(common.device, 1, &common.patch_place_fence);

        common.gpu_interface_lock.lock();
        defer common.gpu_interface_lock.unlock();

        _ = c.vkResetCommandBuffer(common.patch_place_command_buffer, 0);
        common.render_patches_saturated = false;
        try recordPatchPlaceCommandBuffer();

        const compute_wait_stages: u32 = 0;
        const compute_submit_info: c.VkSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = &compute_wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &common.patch_place_command_buffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        if (c.vkQueueSubmit(common.compute_queue, 1, &compute_submit_info, common.patch_place_fence) != c.VK_SUCCESS) {
            @panic("patch placement failed to submit queue!");
        }
    }

    _ = c.vkWaitForFences(
        common.device,
        1,
        &common.patch_place_fence,
        c.VK_TRUE,
        std.math.maxInt(u64),
    );
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

fn patchVisible(patch: RenderPatch) bool {
    const patch_size: u32 = common.renderPatchSize(@intCast(patch.resolution_scale_exponent));

    const screen_center = common.get_screen_center();

    const screen_left_edge: u32 = @intFromFloat(@max(screen_center.x - @as(f32, @floatFromInt(common.width)) * common.zoom_diff / 2, 0.0));
    const screen_right_edge: u32 = @intFromFloat(@max(screen_center.x + @as(f32, @floatFromInt(common.width)) * common.zoom_diff / 2, 0.0));
    const screen_top_edge: u32 = @intFromFloat(@max(screen_center.y - @as(f32, @floatFromInt(common.height)) * common.zoom_diff / 2, 0.0));
    const screen_bottom_edge: u32 = @intFromFloat(@max(screen_center.y + @as(f32, @floatFromInt(common.height)) * common.zoom_diff / 2, 0.0));

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
        if (status == .empty or status == .placing) continue;
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
    const screen_center = common.get_screen_center();

    var mouse_x_flt: f64 = undefined;
    var mouse_y_flt: f64 = undefined;
    c.glfwGetCursorPos(common.window, &mouse_x_flt, &mouse_y_flt);

    //std.debug.print("mouse position: {}, {}\n", .{ mouse_x_flt, mouse_y_flt });

    mouse_x_flt = std.math.clamp(mouse_x_flt, 0.0, @as(f64, @floatFromInt(common.width)));
    mouse_y_flt = std.math.clamp(mouse_y_flt, 0.0, @as(f64, @floatFromInt(common.height)));

    var mouse_x_from_screen_center: f64 = (mouse_x_flt - @as(f64, @floatFromInt(common.width)) / 2.0);
    var mouse_y_from_screen_center: f64 = (mouse_y_flt - @as(f64, @floatFromInt(common.height)) / 2.0);

    // to buffer coordinates
    mouse_x_from_screen_center = mouse_x_from_screen_center * common.zoom_diff;
    mouse_y_from_screen_center = mouse_y_from_screen_center * common.zoom_diff;

    const buffer_target_pos_x: u32 = @intFromFloat(mouse_x_from_screen_center + screen_center.x);
    const buffer_target_pos_y: u32 = @intFromFloat(mouse_y_from_screen_center + screen_center.y);

    //std.debug.print("target render pos: {}, {}\n", .{ buffer_target_pos_x, buffer_target_pos_y });

    const Pos = struct { x: u32 = 0, y: u32 = 0 };

    var running_dists: [common.num_distinct_res_scales]f32 = [1]f32{std.math.floatMax(f32)} ** common.num_distinct_res_scales;
    var min_dist_poss: [common.num_distinct_res_scales]Pos = [1]Pos{.{}} ** common.num_distinct_res_scales;
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

                    const dist_x: f32 = @as(f32, @floatFromInt(buffer_target_pos_x)) -
                        @as(f32, @floatFromInt(i * patch_size + patch_size / 2));
                    const dist_y: f32 = @as(f32, @floatFromInt(buffer_target_pos_y)) -
                        @as(f32, @floatFromInt(j * patch_size + patch_size / 2));
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
        const pos: Pos = min_dist_poss[common.max_res_scale_exponent];
        resolutions_complete[common.max_res_scale_exponent][pos.x][pos.y] = true;
        return RenderPatch{
            .resolution_scale_exponent = common.max_res_scale_exponent,
            .x_pos = pos.x,
            .y_pos = pos.y,
        };
    }

    var min_dist: f32 = std.math.floatMax(f32);
    var min_dist_exp: u32 = 0;
    for (0..common.max_res_scale_exponent) |exp| {
        if (!res_incompletes[exp]) continue;
        if (running_dists[exp] / @as(f32, @floatFromInt(1 + exp)) < min_dist) {
            min_dist = running_dists[exp] / @as(f32, @floatFromInt(1 + exp));
            min_dist_exp = @intCast(exp);
        }
    }

    // all complete
    if (min_dist == std.math.floatMax(f32)) return null;

    const pos: Pos = min_dist_poss[min_dist_exp];
    resolutions_complete[min_dist_exp][pos.x][pos.y] = true;
    return RenderPatch{
        .resolution_scale_exponent = min_dist_exp,
        .x_pos = pos.x,
        .y_pos = pos.y,
    };
}

// TODO: properly syncronize - should probably be blocking in some mannor as it should run very fast
fn recordPatchPlaceCommandBuffer() MainLoopError!void {
    const begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    if (c.vkBeginCommandBuffer(common.patch_place_command_buffer, &begin_info) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_recording_begin_failed;
    }

    c.vkCmdBindPipeline(
        common.patch_place_command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        common.patch_place_pipeline,
    );

    for (0.., &common.render_patches_status, common.render_patches) |i, *status, patch| {
        if (status.* != .complete) continue;
        status.* = .placing;

        const descriptor_sets = [_]c.VkDescriptorSet{
            common.render_patch_descriptor_sets[i],
            common.render_to_coloring_descriptor_sets[common.current_render_to_coloring_descriptor_index],
        };

        c.vkCmdBindDescriptorSets(
            common.patch_place_command_buffer,
            c.VK_PIPELINE_BIND_POINT_COMPUTE,
            common.patch_place_pipeline_layout,
            0,
            descriptor_sets.len,
            &descriptor_sets,
            0,
            0,
        );

        const patch_size: u32 = common.renderPatchSize(@intCast(patch.resolution_scale_exponent));
        const buffer_offset: u32 = patch_size * (patch.x_pos +
            patch.y_pos * common.escape_potential_buffer_block_num_x *
                common.renderPatchSize(common.max_res_scale_exponent));

        c.vkCmdPushConstants(
            common.patch_place_command_buffer,
            common.patch_place_pipeline_layout,
            c.VK_SHADER_STAGE_COMPUTE_BIT,
            0,
            @sizeOf(common.PatchPlaceConstants),
            &common.PatchPlaceConstants{
                .buffer_offset = buffer_offset,
                .max_width = common.renderPatchSize(common.max_res_scale_exponent) *
                    common.escape_potential_buffer_block_num_x,
                .resolution_scale_exponent = @intCast(patch.resolution_scale_exponent),
            },
        );

        c.vkCmdDispatch(
            common.patch_place_command_buffer,
            common.sqrt_workgroup_num,
            common.sqrt_workgroup_num,
            1,
        );
    }

    if (c.vkEndCommandBuffer(common.patch_place_command_buffer) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_record_failed;
    }
}

fn recordRenderingCommandBuffer(
    rendering_command_buffer: c.VkCommandBuffer,
    patch_buffer_index: usize,
    render_patch_size: u32,
    pos: @Vector(2, u32),
    resolution_scale_exponent: i32,
) MainLoopError!void {
    const begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    if (c.vkBeginCommandBuffer(rendering_command_buffer, &begin_info) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_recording_begin_failed;
    }

    const descriptor_sets = [_]c.VkDescriptorSet{
        common.render_patch_descriptor_sets[patch_buffer_index],
        common.cpu_to_render_descriptor_sets[common.current_cpu_to_render_descriptor_index],
    };

    c.vkCmdBindPipeline(
        rendering_command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        common.rendering_pipeline,
    );
    c.vkCmdBindDescriptorSets(
        rendering_command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        common.rendering_pipeline_layout,
        0,
        descriptor_sets.len,
        &descriptor_sets,
        0,
        0,
    );

    c.vkCmdPushConstants(
        rendering_command_buffer,
        common.rendering_pipeline_layout,
        c.VK_SHADER_STAGE_COMPUTE_BIT,
        0,
        @sizeOf(common.RenderingConstants),
        &common.RenderingConstants{
            .center_screen_pos = @Vector(2, u32){
                @intCast((common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_x) / 2),
                @intCast((common.renderPatchSize(common.max_res_scale_exponent) * common.escape_potential_buffer_block_num_y) / 2),
            },
            .screen_offset = pos,
            .height_scale_exp = common.zoom_exp,
            .resolution_scale_exponent = resolution_scale_exponent,
            .cur_height = @intCast(common.height),
        },
    );

    c.vkCmdDispatch(rendering_command_buffer, render_patch_size, render_patch_size, 1);

    if (c.vkEndCommandBuffer(rendering_command_buffer) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_record_failed;
    }
}

fn recordColoringCommandBuffer(command_buffer: c.VkCommandBuffer, image_index: u32) MainLoopError!void {
    const begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    if (c.vkBeginCommandBuffer(command_buffer, &begin_info) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_recording_begin_failed;
    }

    const clear_color: c.VkClearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
    const render_pass_info: c.VkRenderPassBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = common.render_pass,
        .framebuffer = common.swap_chain_framebuffers[image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = common.swap_chain_extent,
        },
        .clearValueCount = 1,
        .pClearValues = &clear_color,
    };

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, common.coloring_pipeline);

    const viewport: c.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(common.swap_chain_extent.width),
        .height = @floatFromInt(common.swap_chain_extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor: c.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = common.swap_chain_extent,
    };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    c.vkCmdBindDescriptorSets(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        common.coloring_pipeline_layout,
        0,
        1,
        &common.render_to_coloring_descriptor_sets[common.current_render_to_coloring_descriptor_index],
        0,
        null,
    );

    const screen_center = common.get_screen_center();

    c.vkCmdPushConstants(
        command_buffer,
        common.coloring_pipeline_layout,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(common.ColoringConstants),
        &common.ColoringConstants{
            .cur_resolution = @Vector(2, u32){ @intCast(common.width), @intCast(common.height) },
            .center_position = @Vector(2, u32){
                @intFromFloat(screen_center.x),
                @intFromFloat(screen_center.y),
            },
            .max_width = common.renderPatchSize(@intCast(common.max_res_scale_exponent)) * common.escape_potential_buffer_block_num_x,
            .zoom_diff = common.zoom_diff,
        },
    );

    c.vkCmdDraw(
        command_buffer,
        6,
        1,
        0,
        0,
    );
    c.vkCmdEndRenderPass(command_buffer);

    if (c.vkEndCommandBuffer(command_buffer) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_record_failed;
    }
}

//fn updateUniformBuffer(current_image: u32) void {
//    @memcpy(
//        @as(
//            [*]common.ComputeConstants,
//            @ptrCast(common.REPLACE[@intCast(current_image)]),
//        ),
//        @as(
//            *const [1]common.ComputeConstants,
//            @ptrCast(&common.current_uniform_state),
//        ),
//    );
//}
