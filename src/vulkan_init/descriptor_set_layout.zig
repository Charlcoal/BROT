const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;

const InitVulkanError = common.InitVulkanError;

pub fn createDescriptorSetLayout(data: *common.AppData) InitVulkanError!void {
    const ubo_layout_binding: c.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };

    var layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &ubo_layout_binding,
    };

    if (c.vkCreateDescriptorSetLayout(data.device, &layout_info, null, &data.descriptor_set_layout) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_set_layout_creation_failed;
    }
}
