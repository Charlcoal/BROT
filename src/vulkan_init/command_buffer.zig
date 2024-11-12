const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createCommandBuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.command_buffers = try alloc.alloc(c.VkCommandBuffer, common.max_frames_in_flight);

    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = data.command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = @intCast(data.command_buffers.len),
    };

    if (c.vkAllocateCommandBuffers(data.device, &alloc_info, data.command_buffers.ptr) != c.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}
