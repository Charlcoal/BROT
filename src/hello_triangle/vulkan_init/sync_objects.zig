const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createSyncObjects(data: *common.AppData) InitVulkanError!void {
    const semaphore_info: glfw.VkSemaphoreCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fence_info: glfw.VkFenceCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = glfw.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    if (glfw.vkCreateSemaphore(data.device, &semaphore_info, null, &data.image_availible_semaphore) != glfw.VK_SUCCESS or
        glfw.vkCreateSemaphore(data.device, &semaphore_info, null, &data.render_finished_semaphore) != glfw.VK_SUCCESS or
        glfw.vkCreateFence(data.device, &fence_info, null, &data.in_flight_fence) != glfw.VK_SUCCESS)
    {
        return InitVulkanError.semaphore_creation_failed;
    }
}
