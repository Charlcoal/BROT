const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;

const InitVulkanError = common.InitVulkanError;

pub fn createDescriptorSetLayout(data: *common.AppData) InitVulkanError!void {
    const ubo_layout_binding: glfw.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = glfw.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = glfw.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };

    var layout_info: glfw.VkDescriptorSetLayoutCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &ubo_layout_binding,
    };

    if (glfw.vkCreateDescriptorSetLayout(data.device, &layout_info, null, &data.descriptor_set_layout) != glfw.VK_SUCCESS) {
        return InitVulkanError.descriptor_set_layout_creation_failed;
    }
}
