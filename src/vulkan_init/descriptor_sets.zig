const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createDescriptorSets(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const layouts: []glfw.VkDescriptorSetLayout = try alloc.alloc(glfw.VkDescriptorSetLayout, common.max_frames_in_flight);
    defer alloc.free(layouts);
    for (0..common.max_frames_in_flight) |i| {
        layouts[i] = data.descriptor_set_layout;
    }

    const alloc_info: glfw.VkDescriptorSetAllocateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = data.descriptor_pool,
        .descriptorSetCount = @intCast(common.max_frames_in_flight),
        .pSetLayouts = layouts.ptr,
    };

    data.descriptor_sets = try alloc.alloc(glfw.VkDescriptorSet, common.max_frames_in_flight);
    if (glfw.vkAllocateDescriptorSets(data.device, &alloc_info, data.descriptor_sets.ptr) != glfw.VK_SUCCESS) {
        return InitVulkanError.descriptor_sets_allocation_failed;
    }

    for (0..common.max_frames_in_flight) |i| {
        const buffer_info: glfw.VkDescriptorBufferInfo = .{
            .buffer = data.uniform_buffers[i],
            .offset = 0,
            .range = @sizeOf(common.UniformBufferObject),
        };

        //const image_info: glfw.VkDescriptorImageInfo = .{
        //    .imageLayout = glfw.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        //    .imageView = data.texture_image_view,
        //    .sampler = data.texture_sampler,
        //};

        const descriptor_writes: [1]glfw.VkWriteDescriptorSet = .{
            .{
                .sType = glfw.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = data.descriptor_sets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = glfw.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &buffer_info,
                .pImageInfo = null,
                .pTexelBufferView = null,
            },
            //.{
            //    .sType = glfw.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            //    .dstSet = data.descriptor_sets[i],
            //    .dstBinding = 1,
            //    .dstArrayElement = 0,
            //    .descriptorType = glfw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            //    .descriptorCount = 1,
            //    .pImageInfo = &image_info,
            //}
        };

        glfw.vkUpdateDescriptorSets(data.device, @intCast(descriptor_writes.len), &descriptor_writes, 0, null);
    }
}
