const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createCommandPool(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const queue_family_indices = try v_common.findQueueFamilies(data.*, data.physical_device, alloc);

    const pool_info: glfw.VkCommandPoolCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = glfw.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.graphics_family.?,
    };

    if (glfw.vkCreateCommandPool(data.device, &pool_info, null, &data.command_pool) != glfw.VK_SUCCESS) {
        return InitVulkanError.command_pool_creation_failed;
    }
}
