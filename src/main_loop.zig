const std = @import("std");
const common = @import("common_defs.zig");
const vulkan_init = @import("vulkan_init/all.zig");
const c = common.c;

const MainLoopError = common.MainLoopError;
const Allocator = std.mem.Allocator;

pub fn mainLoop(data: *common.AppData, alloc: Allocator) MainLoopError!void {
    while (c.glfwWindowShouldClose(data.window) == 0) {
        c.glfwPollEvents();
        try drawFrame(data, alloc);
    }

    _ = c.vkDeviceWaitIdle(data.inst.logical_device);
}

fn drawFrame(data: *common.AppData, alloc: Allocator) MainLoopError!void {
    _ = c.vkWaitForFences(data.inst.logical_device, 1, &data.in_flight_fences[data.current_frame], c.VK_TRUE, std.math.maxInt(u64));

    var delta_time: f64 = @as(f64, @floatFromInt(data.time.read() - data.prev_time)) / 1_000_000_000;
    if (delta_time < 1.0 / common.target_frame_rate) {
        std.time.sleep(@intFromFloat((1.0 / common.target_frame_rate - delta_time) * 1_000_000_000));
        delta_time = @as(f64, @floatFromInt(data.time.read() - data.prev_time)) / 1_000_000_000;
    } else {
        std.debug.print("MISSED FRAME: {d:.4} seconds\n", .{delta_time});
    }
    //std.debug.print("time: {d:.3}\n", .{delta_time});
    data.prev_time = data.time.read();

    var image_index: u32 = undefined;
    const result = c.vkAcquireNextImageKHR(
        data.inst.logical_device,
        data.screen_rend.swapchain.vk_swapchain,
        std.math.maxInt(u64),
        data.image_availible_semaphores[data.current_frame],
        @ptrCast(c.VK_NULL_HANDLE),
        &image_index,
    );

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
        try data.screen_rend.recreateSwapchain(data.inst, alloc, data.window);
        return;
    } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
        return MainLoopError.swap_chain_image_acquisition_failed;
    }

    _ = c.vkResetFences(data.inst.logical_device, 1, &data.in_flight_fences[data.current_frame]);

    _ = c.vkResetCommandBuffer(data.screen_rend.command_buffers[data.current_frame], 0);
    try recordCommandBuffer(data.*, data.screen_rend.command_buffers[data.current_frame], image_index);

    updateUniformBuffer(data, data.current_frame);

    const wait_semaphors = [_]c.VkSemaphore{data.image_availible_semaphores[data.current_frame]};
    const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    const signal_semaphors = [_]c.VkSemaphore{data.render_finished_semaphores[data.current_frame]};
    const submit_info: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = @intCast(wait_semaphors.len),
        .pWaitSemaphores = &wait_semaphors,
        .pWaitDstStageMask = &wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &data.screen_rend.command_buffers[data.current_frame],
        .signalSemaphoreCount = @intCast(signal_semaphors.len),
        .pSignalSemaphores = &signal_semaphors,
    };

    if (c.vkQueueSubmit(data.inst.graphics_compute_queue, 1, &submit_info, data.in_flight_fences[data.current_frame]) != c.VK_SUCCESS) {
        return MainLoopError.draw_command_buffer_submit_failed;
    }

    const swap_chains = [_]c.VkSwapchainKHR{data.screen_rend.swapchain.vk_swapchain};
    const present_info: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = @intCast(signal_semaphors.len),
        .pWaitSemaphores = &signal_semaphors,
        .swapchainCount = @intCast(swap_chains.len),
        .pSwapchains = &swap_chains,
        .pImageIndices = &image_index,
        .pResults = null,
    };

    _ = c.vkQueuePresentKHR(data.inst.present_queue, &present_info);
    data.current_frame = (data.current_frame + 1) % common.max_frames_in_flight;

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or data.frame_buffer_resized) {
        data.frame_buffer_resized = false;
        try data.screen_rend.recreateSwapchain(data.inst, alloc, data.window);
        return;
    } else if (result != c.VK_SUCCESS) {
        return MainLoopError.swap_chain_image_acquisition_failed;
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
        .renderPass = data.screen_rend.render_pass,
        .framebuffer = data.screen_rend.swapchain.framebuffers[image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = data.screen_rend.swapchain.extent,
        },
        .clearValueCount = 1,
        .pClearValues = &clear_color,
    };

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, data.screen_rend.graphics_pipeline);

    const viewport: c.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(data.screen_rend.swapchain.extent.width),
        .height = @floatFromInt(data.screen_rend.swapchain.extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor: c.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = data.screen_rend.swapchain.extent,
    };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    c.vkCmdBindDescriptorSets(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        data.screen_rend.pipeline_layout,
        0,
        1,
        &data.descriptor_set.vk_descriptor_sets[data.current_frame],
        0,
        null,
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

fn updateUniformBuffer(data: *common.AppData, current_image: u32) void {
    @memcpy(
        @as(
            [*]common.UniformBufferObject,
            @ptrCast(data.ubo.gpu_memory_mapped[@intCast(current_image)]),
        ),
        @as(
            *const [1]common.UniformBufferObject,
            @ptrCast(&data.ubo.cpu_state),
        ),
    );
}
