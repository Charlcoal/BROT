const std = @import("std");
const common = @import("common_defs.zig");
const vulkan_init = @import("vulkan_init.zig");
const c = common.c;

const MainLoopError = common.MainLoopError;
const Allocator = std.mem.Allocator;

pub fn mainLoop(data: *common.AppData, alloc: Allocator) MainLoopError!void {
    while (c.glfwWindowShouldClose(data.window) == 0) {
        c.glfwPollEvents();

        try drawFrame(data, alloc);
    }

    data.gpu_interface_semaphore.wait();
    _ = c.vkDeviceWaitIdle(data.device);
    data.gpu_interface_semaphore.post();
}

pub fn startComputeManager(data: *common.AppData, alloc: Allocator) std.Thread.SpawnError!void {
    data.compute_manager_thread = try std.Thread.spawn(.{ .allocator = alloc }, computeManage, .{data});
}

const Direction = enum { left, down, right, up };
const Spiral = struct {
    dir: Direction = .left,
    delta_x: i32 = 1,
    delta_y: i32 = 0,
};

fn computeManage(data: *common.AppData) void {
    var spiral: Spiral = .{};

    while (!data.compute_manager_should_close) {
        _ = c.vkWaitForFences(data.device, data.compute_fences.len, &data.compute_fences, c.VK_FALSE, std.math.maxInt(u64));

        const comp_index: usize = label: {
            for (0..data.compute_fences.len) |i| {
                if (c.vkGetFenceStatus(data.device, data.compute_fences[i]) == c.VK_SUCCESS) {
                    break :label i;
                }
            }
            unreachable;
        };

        if (data.frame_updated) {
            data.compute_idle = false;
            data.frame_updated = false;
            spiral = .{};
        }

        if (data.compute_idle) {
            std.Thread.sleep(1_000_000); // 1ms
            continue;
        }

        const sqrt_workgroup_num: u32 = 8;
        var render_patch_size: u32 = @as(u32, 1) << @as(u5, @intCast(3));
        render_patch_size *= sqrt_workgroup_num;
        const spiral_result = calculateNextSpiral(data, &spiral, render_patch_size);
        if (spiral_result.spiral_exhausted) continue;

        data.gpu_interface_semaphore.wait();
        defer data.gpu_interface_semaphore.post();

        //updateUniformBuffer(data);

        //std.debug.print("starting compute\n", .{});
        _ = c.vkResetFences(data.device, 1, &data.compute_fences[comp_index]);

        _ = c.vkResetCommandBuffer(data.compute_command_buffers[comp_index], 0);
        recordComputeCommandBuffer(data.*, data.compute_command_buffers[comp_index], sqrt_workgroup_num, spiral_result.pos) catch {
            @panic("compute manager failed to record buffer!");
        };

        const wait_stages: u32 = 0;
        const submit_info: c.VkSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &data.compute_command_buffers[comp_index],
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        if (c.vkQueueSubmit(data.compute_queue, 1, &submit_info, data.compute_fences[comp_index]) != c.VK_SUCCESS) {
            @panic("compute manager failed to submit queue!");
        }
    }

    _ = c.vkWaitForFences(data.device, data.compute_fences.len, &data.compute_fences, c.VK_FALSE, std.math.maxInt(u64));
}

fn drawFrame(data: *common.AppData, alloc: Allocator) MainLoopError!void {
    if (data.frame_buffer_just_resized) {
        _ = c.vkWaitForFences(data.device, 1, &data.in_flight_fences[data.current_frame], c.VK_TRUE, 60_000_000);
        data.frame_buffer_just_resized = false;
    } else {
        _ = c.vkWaitForFences(data.device, 1, &data.in_flight_fences[data.current_frame], c.VK_TRUE, std.math.maxInt(u64));
    }

    _ = c.vkResetFences(data.device, 1, &data.in_flight_fences[data.current_frame]);

    var delta_time: f64 = @as(f64, @floatFromInt(data.time.read() - data.prev_time)) / 1_000_000_000;
    if (delta_time < 1.0 / common.target_frame_rate) {
        std.time.sleep(@intFromFloat((1.0 / common.target_frame_rate - delta_time) * 1_000_000_000));
        delta_time = @as(f64, @floatFromInt(data.time.read() - data.prev_time)) / 1_000_000_000;
    } else {
        //std.debug.print("MISSED FRAME: {d:.4} seconds\n", .{delta_time});
    }
    //std.debug.print("time: {d:.3}\n", .{delta_time});
    data.prev_time = data.time.read();

    var image_index: u32 = undefined;
    const result = c.vkAcquireNextImageKHR(
        data.device,
        data.swap_chain,
        std.math.maxInt(u64),
        data.image_availible_semaphores[data.current_frame],
        @ptrCast(c.VK_NULL_HANDLE),
        &image_index,
    );

    data.gpu_interface_semaphore.wait();
    defer data.gpu_interface_semaphore.post();

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
        try vulkan_init.recreateSwapChain(data, alloc);
        return;
    } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
        return MainLoopError.swap_chain_image_acquisition_failed;
    } else if (result == c.VK_SUBOPTIMAL_KHR) {}

    _ = c.vkResetCommandBuffer(data.graphics_command_buffers[data.current_frame], 0);
    try recordCommandBuffer(data.*, data.graphics_command_buffers[data.current_frame], image_index);

    const wait_semaphors = [_]c.VkSemaphore{data.image_availible_semaphores[data.current_frame]};
    const wait_stages: u32 = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    const signal_semaphors = [_]c.VkSemaphore{data.render_finished_semaphores[image_index]};
    const submit_info: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = @intCast(wait_semaphors.len),
        .pWaitSemaphores = &wait_semaphors,
        .pWaitDstStageMask = &wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &data.graphics_command_buffers[data.current_frame],
        .signalSemaphoreCount = @intCast(signal_semaphors.len),
        .pSignalSemaphores = &signal_semaphors,
    };

    if (c.vkQueueSubmit(data.graphics_queue, 1, &submit_info, data.in_flight_fences[data.current_frame]) != c.VK_SUCCESS) {
        return MainLoopError.draw_command_buffer_submit_failed;
    }

    const swap_chains = [_]c.VkSwapchainKHR{data.swap_chain};
    const present_info: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = @intCast(signal_semaphors.len),
        .pWaitSemaphores = &signal_semaphors,
        .swapchainCount = @intCast(swap_chains.len),
        .pSwapchains = &swap_chains,
        .pImageIndices = &image_index,
        .pResults = null,
    };

    _ = c.vkQueuePresentKHR(data.present_queue, &present_info);

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or data.frame_buffer_needs_resize) {
        data.frame_buffer_needs_resize = false;
        try vulkan_init.recreateSwapChain(data, alloc);
        return;
    } else if (result != c.VK_SUCCESS) {
        return MainLoopError.swap_chain_image_acquisition_failed;
    }
}

fn calculateNextSpiral(data: *common.AppData, spiral: *Spiral, render_patch_size: u32) struct { spiral_exhausted: bool, pos: @Vector(2, u32) } {
    // determine next location
    const num_render_patch_x: u32 = @divTrunc(@as(u32, @intCast(data.width)) - 1, render_patch_size) + 1;
    const num_render_patch_y: u32 = @divTrunc(@as(u32, @intCast(data.height)) - 1, render_patch_size) + 1;
    const spiral_center_x: i32 = @intCast(@divTrunc(data.render_start_screen_x, render_patch_size));
    const spiral_center_y: i32 = @intCast(@divTrunc(data.render_start_screen_y, render_patch_size));

    var reached_max_x: bool = false;
    var reached_max_y: bool = false;
    var reached_min_x: bool = false;
    var reached_min_y: bool = false;

    while (true) {
        switch (spiral.dir) {
            .left => {
                spiral.delta_x -= 1;
                if (spiral.delta_x < spiral.delta_y) {
                    spiral.dir = .down;
                }
            },
            .down => {
                spiral.delta_y += 1;
                if (spiral.delta_y >= -spiral.delta_x) {
                    spiral.dir = .right;
                }
            },
            .right => {
                spiral.delta_x += 1;
                if (spiral.delta_x >= spiral.delta_y) {
                    spiral.dir = .up;
                }
            },
            .up => {
                spiral.delta_y -= 1;
                if (spiral.delta_y <= -spiral.delta_x) {
                    spiral.dir = .left;
                }
            },
        }
        var cont: bool = false;
        // repeat spiral traversal if location is out of bounds
        if (spiral.delta_x + spiral_center_x < 0) {
            cont = true;
            reached_min_x = true;
        }
        if (spiral.delta_x + spiral_center_x >= num_render_patch_x) {
            cont = true;
            reached_max_x = true;
        }
        if (spiral.delta_y + spiral_center_y < 0) {
            cont = true;
            reached_min_y = true;
        }
        if (spiral.delta_y + spiral_center_y >= num_render_patch_y) {
            cont = true;
            reached_max_y = true;
        }
        if (reached_max_x and reached_min_x and reached_max_y and reached_min_y) {
            data.compute_idle = true;
            return .{ .spiral_exhausted = true, .pos = undefined };
        }

        if (!cont) break;
    }

    const scr_x: i32 = spiral_center_x + spiral.delta_x;
    const scr_y: i32 = spiral_center_y + spiral.delta_y;
    const pos_x: u32 = @as(u32, @intCast(scr_x)) * render_patch_size;
    const pos_y: u32 = @as(u32, @intCast(scr_y)) * render_patch_size;
    return .{ .spiral_exhausted = false, .pos = .{ pos_x, pos_y } };
}

fn recordComputeCommandBuffer(data: common.AppData, compute_command_buffer: c.VkCommandBuffer, render_patch_size: u32, pos: @Vector(2, u32)) MainLoopError!void {
    const begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    if (c.vkBeginCommandBuffer(compute_command_buffer, &begin_info) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_recording_begin_failed;
    }

    c.vkCmdBindPipeline(
        compute_command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        data.compute_pipeline,
    );
    c.vkCmdBindDescriptorSets(
        compute_command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        data.compute_pipeline_layout,
        0,
        1,
        &data.descriptor_sets[0],
        0,
        0,
    );

    c.vkCmdPushConstants(
        compute_command_buffer,
        data.compute_pipeline_layout,
        c.VK_SHADER_STAGE_COMPUTE_BIT,
        0,
        @sizeOf(common.ComputeConstants),
        &common.ComputeConstants{
            .fractal_pos = data.fractal_pos,
            .max_resolution = data.max_resolution,
            .screen_offset = pos,
            .height_scale = data.zoom / @as(f32, @floatFromInt(data.height)),
            .resolution_scale_exponent = 0,
        },
    );

    c.vkCmdDispatch(compute_command_buffer, render_patch_size, render_patch_size, 1);

    if (c.vkEndCommandBuffer(compute_command_buffer) != c.VK_SUCCESS) {
        return MainLoopError.command_buffer_record_failed;
    }
}

fn recordCommandBuffer(data: common.AppData, command_buffer: c.VkCommandBuffer, image_index: u32) MainLoopError!void {
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
        .renderPass = data.render_pass,
        .framebuffer = data.swap_chain_framebuffers[image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = data.swap_chain_extent,
        },
        .clearValueCount = 1,
        .pClearValues = &clear_color,
    };

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, data.graphics_pipeline);

    const viewport: c.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(data.swap_chain_extent.width),
        .height = @floatFromInt(data.swap_chain_extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor: c.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = data.swap_chain_extent,
    };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    c.vkCmdBindDescriptorSets(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        data.render_pipeline_layout,
        0,
        1,
        &data.descriptor_sets[data.current_frame],
        0,
        null,
    );

    c.vkCmdPushConstants(
        command_buffer,
        data.render_pipeline_layout,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(common.RenderConstants),
        &common.RenderConstants{ .max_width = data.max_resolution[0] },
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

//fn updateUniformBuffer(data: *common.AppData, current_image: u32) void {
//    @memcpy(
//        @as(
//            [*]common.ComputeConstants,
//            @ptrCast(data.REPLACE[@intCast(current_image)]),
//        ),
//        @as(
//            *const [1]common.ComputeConstants,
//            @ptrCast(&data.current_uniform_state),
//        ),
//    );
//}
