const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createCommandBuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.command_buffers = try alloc.alloc(glfw.VkCommandBuffer, common.max_frames_in_flight);

    const alloc_info: glfw.VkCommandBufferAllocateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = data.command_pool,
        .level = glfw.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = @intCast(data.command_buffers.len),
    };

    if (glfw.vkAllocateCommandBuffers(data.device, &alloc_info, data.command_buffers.ptr) != glfw.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}
