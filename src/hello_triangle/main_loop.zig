const std = @import("std");
const common = @import("common_defs.zig");
const vulkan_init = @import("vulkan_init/all.zig");
const glfw = common.glfw;

const MainLoopError = common.MainLoopError;
const Allocator = std.mem.Allocator;

pub fn mainLoop(data: *common.AppData, alloc: Allocator) MainLoopError!void {
    while (glfw.glfwWindowShouldClose(data.window) == 0) {
        glfw.glfwPollEvents();
        try drawFrame(data, alloc);
    }

    _ = glfw.vkDeviceWaitIdle(data.device);
}

fn drawFrame(data: *common.AppData, alloc: Allocator) MainLoopError!void {
    _ = glfw.vkWaitForFences(data.device, 1, &data.in_flight_fences[data.current_frame], glfw.VK_TRUE, std.math.maxInt(u64));

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
    const result = glfw.vkAcquireNextImageKHR(
        data.device,
        data.swap_chain,
        std.math.maxInt(u64),
        data.image_availible_semaphores[data.current_frame],
        @ptrCast(glfw.VK_NULL_HANDLE),
        &image_index,
    );

    if (result == glfw.VK_ERROR_OUT_OF_DATE_KHR) {
        try vulkan_init.recreateSwapChain(data, alloc);
        return;
    } else if (result != glfw.VK_SUCCESS and result != glfw.VK_SUBOPTIMAL_KHR) {
        return MainLoopError.swap_chain_image_acquisition_failed;
    }

    _ = glfw.vkResetFences(data.device, 1, &data.in_flight_fences[data.current_frame]);

    _ = glfw.vkResetCommandBuffer(data.command_buffers[data.current_frame], 0);
    try recordCommandBuffer(data.*, data.command_buffers[data.current_frame], image_index);

    updateUniformBuffer(data, data.current_frame);

    const wait_semaphors = [_]glfw.VkSemaphore{data.image_availible_semaphores[data.current_frame]};
    const wait_stages = [_]glfw.VkPipelineStageFlags{glfw.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    const signal_semaphors = [_]glfw.VkSemaphore{data.render_finished_semaphores[data.current_frame]};
    const submit_info: glfw.VkSubmitInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = @intCast(wait_semaphors.len),
        .pWaitSemaphores = &wait_semaphors,
        .pWaitDstStageMask = &wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &data.command_buffers[data.current_frame],
        .signalSemaphoreCount = @intCast(signal_semaphors.len),
        .pSignalSemaphores = &signal_semaphors,
    };

    if (glfw.vkQueueSubmit(data.graphics_queue, 1, &submit_info, data.in_flight_fences[data.current_frame]) != glfw.VK_SUCCESS) {
        return MainLoopError.draw_command_buffer_submit_failed;
    }

    const swap_chains = [_]glfw.VkSwapchainKHR{data.swap_chain};
    const present_info: glfw.VkPresentInfoKHR = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = @intCast(signal_semaphors.len),
        .pWaitSemaphores = &signal_semaphors,
        .swapchainCount = @intCast(swap_chains.len),
        .pSwapchains = &swap_chains,
        .pImageIndices = &image_index,
        .pResults = null,
    };

    _ = glfw.vkQueuePresentKHR(data.present_queue, &present_info);
    data.current_frame = (data.current_frame + 1) % common.max_frames_in_flight;

    if (result == glfw.VK_ERROR_OUT_OF_DATE_KHR or result == glfw.VK_SUBOPTIMAL_KHR or data.frame_buffer_resized) {
        data.frame_buffer_resized = false;
        try vulkan_init.recreateSwapChain(data, alloc);
        return;
    } else if (result != glfw.VK_SUCCESS) {
        return MainLoopError.swap_chain_image_acquisition_failed;
    }
}

fn recordCommandBuffer(data: common.AppData, command_buffer: glfw.VkCommandBuffer, image_index: u32) MainLoopError!void {
    const begin_info: glfw.VkCommandBufferBeginInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    if (glfw.vkBeginCommandBuffer(command_buffer, &begin_info) != glfw.VK_SUCCESS) {
        return MainLoopError.command_buffer_recording_begin_failed;
    }

    const clear_color: glfw.VkClearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
    const render_pass_info: glfw.VkRenderPassBeginInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = data.render_pass,
        .framebuffer = data.swap_chain_framebuffers[image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = data.swap_chain_extent,
        },
        .clearValueCount = 1,
        .pClearValues = &clear_color,
    };

    glfw.vkCmdBeginRenderPass(command_buffer, &render_pass_info, glfw.VK_SUBPASS_CONTENTS_INLINE);
    glfw.vkCmdBindPipeline(command_buffer, glfw.VK_PIPELINE_BIND_POINT_GRAPHICS, data.graphics_pipeline);

    const viewport: glfw.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(data.swap_chain_extent.width),
        .height = @floatFromInt(data.swap_chain_extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    glfw.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor: glfw.VkRect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = data.swap_chain_extent,
    };
    glfw.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    glfw.vkCmdBindDescriptorSets(
        command_buffer,
        glfw.VK_PIPELINE_BIND_POINT_GRAPHICS,
        data.pipeline_layout,
        0,
        1,
        &data.descriptor_sets[data.current_frame],
        0,
        null,
    );

    glfw.vkCmdDraw(
        command_buffer,
        6,
        1,
        0,
        0,
    );
    glfw.vkCmdEndRenderPass(command_buffer);

    if (glfw.vkEndCommandBuffer(command_buffer) != glfw.VK_SUCCESS) {
        return MainLoopError.command_buffer_record_failed;
    }
}

fn updateUniformBuffer(data: *common.AppData, current_image: u32) void {
    @memcpy(
        @as(
            [*]common.UniformBufferObject,
            @ptrCast(data.uniform_buffers_mapped[@intCast(current_image)]),
        ),
        @as(
            *const [1]common.UniformBufferObject,
            @ptrCast(&data.current_uniform_state),
        ),
    );
}
