const inst = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
const v_init_common = @import("v_init_common_defs.zig");
const c = common.c;

const Allocator = std.mem.Allocator;

pub const Error = error{descriptor_set_layout_creation_failed} || Allocator.Error || v_init_common.BufferCreationError;

pub fn UniformBuffer(UniformBufferObjectType: type) type {
    return struct {
        cpu_state: UniformBufferObjectType,
        gpu_buffers: []c.VkBuffer,
        gpu_memory: []c.VkDeviceMemory,
        gpu_memory_mapped: []?*align(@alignOf(UniformBufferObjectType)) anyopaque,
        descriptor_set_layout: c.VkDescriptorSetLayout,

        pub fn blueprint(instance: inst.Instance) Error!UniformBuffer(UniformBufferObjectType) {
            var out: UniformBuffer(UniformBufferObjectType) = undefined;

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

            if (c.vkCreateDescriptorSetLayout(instance.logical_device, &layout_info, null, &out.descriptor_set_layout) != c.VK_SUCCESS) {
                return Error.descriptor_set_layout_creation_failed;
            }

            return out;
        }

        pub fn create(self: *UniformBuffer(UniformBufferObjectType), instance: inst.Instance, alloc: Allocator) Error!void {
            const buffer_size: c.VkDeviceSize = @sizeOf(common.UniformBufferObject);

            self.gpu_buffers = try alloc.alloc(c.VkBuffer, common.max_frames_in_flight);
            self.gpu_memory = try alloc.alloc(c.VkDeviceMemory, common.max_frames_in_flight);
            self.gpu_memory_mapped = try alloc.alloc(?*align(@alignOf(UniformBufferObjectType)) anyopaque, common.max_frames_in_flight);

            for (0..common.max_frames_in_flight) |i| {
                try v_init_common.createBuffer(
                    instance,
                    buffer_size,
                    c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                    c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                    &self.gpu_buffers[i],
                    &self.gpu_memory[i],
                );

                _ = c.vkMapMemory(
                    instance.logical_device,
                    self.gpu_memory[i],
                    0,
                    buffer_size,
                    0,
                    &self.gpu_memory_mapped[i],
                );
            }
        }
    };
}
