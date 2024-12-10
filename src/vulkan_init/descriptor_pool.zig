const instance = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;

const InitVulkanError = common.InitVulkanError;

const Error = error{descriptor_pool_creation_failed};

pub const DescriptorPool = struct {
    vk_descriptor_pool: c.VkDescriptorPool,

    pub fn init(inst: instance.Instance, pool_sizes: []const c.VkDescriptorPoolSize, max_sets: u32) Error!DescriptorPool {
        var out: DescriptorPool = undefined;

        const pool_info: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .poolSizeCount = @intCast(pool_sizes.len),
            .pPoolSizes = pool_sizes.ptr,
            .maxSets = max_sets,
        };

        if (c.vkCreateDescriptorPool(inst.logical_device, &pool_info, null, &out.vk_descriptor_pool) != c.VK_SUCCESS) {
            return Error.descriptor_pool_creation_failed;
        }

        return out;
    }
};
