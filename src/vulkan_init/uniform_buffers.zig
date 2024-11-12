const std = @import("std");
const common = @import("../common_defs.zig");
const v_init_common = @import("v_init_common_defs.zig");
const c = common.c;

const InitVulkanError = common.InitVulkanError;
const Allocator = std.mem.Allocator;

pub fn createUniformBuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const buffer_size: c.VkDeviceSize = @sizeOf(common.UniformBufferObject);

    data.uniform_buffers = try alloc.alloc(c.VkBuffer, common.max_frames_in_flight);
    data.uniform_buffers_memory = try alloc.alloc(c.VkDeviceMemory, common.max_frames_in_flight);
    data.uniform_buffers_mapped = try alloc.alloc(?*align(@alignOf(common.UniformBufferObject)) anyopaque, common.max_frames_in_flight);

    for (0..common.max_frames_in_flight) |i| {
        try v_init_common.createBuffer(
            data,
            buffer_size,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &data.uniform_buffers[i],
            &data.uniform_buffers_memory[i],
        );

        _ = c.vkMapMemory(
            data.device,
            data.uniform_buffers_memory[i],
            0,
            buffer_size,
            0,
            &data.uniform_buffers_mapped[i],
        );
    }
}
