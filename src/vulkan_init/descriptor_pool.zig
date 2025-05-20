const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;

const InitVulkanError = common.InitVulkanError;

pub fn createDescriptorPool(data: *common.AppData) InitVulkanError!void {
    const pool_sizes: [1]glfw.VkDescriptorPoolSize = .{
        .{
            .type = glfw.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = @intCast(common.max_frames_in_flight),
        },
        //.{
        //    .type = glfw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        //    .descriptorCount = @intCast(common.max_frames_in_flight),
        //}
    };

    const pool_info: glfw.VkDescriptorPoolCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = @intCast(pool_sizes.len),
        .pPoolSizes = &pool_sizes,
        .maxSets = common.max_frames_in_flight,
    };

    if (glfw.vkCreateDescriptorPool(data.device, &pool_info, null, &data.descriptor_pool) != glfw.VK_SUCCESS) {
        return InitVulkanError.descriptor_pool_creation_failed;
    }
}
