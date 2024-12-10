const instance = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
const v_init_common = @import("v_init_common_defs.zig");
const c = common.c;

const Allocator = std.mem.Allocator;

pub const DescriptorSetError = error{
    descriptor_pool_creation_failed,
    descriptor_sets_allocation_failed,
} || Allocator.Error;

/// input types must be one of:
/// UniformBuffer
pub fn DescriptorSet(DescriptorTypes: []const type, DescriptorInternalTypes: []const ?type) type {
    if (DescriptorTypes.len != DescriptorInternalTypes.len) @compileError("DescriptorSet must recieve equal length Types and InternalTypes");
    const type_num = DescriptorTypes.len;

    var set_creation_fields: [type_num]std.builtin.Type.StructField = undefined;
    for (DescriptorTypes, &set_creation_fields, 'a'..) |t, *field, n| {
        field.* = .{
            .name = &.{@intCast(n)},
            .is_comptime = false,
            .default_value = null,
            .type = t,
            .alignment = @alignOf(t),
        };
    }
    const set_creation_type_info: std.builtin.Type = .{ .Struct = .{
        .fields = &set_creation_fields,
        .layout = .auto,
        .is_tuple = false,
        .decls = &.{},
    } };
    const SetCreationType = @Type(set_creation_type_info);

    return struct {
        vk_descriptor_sets: []c.VkDescriptorSet,
        descriptor_pool: c.VkDescriptorPool,

        pub fn allocatePool(inst: instance.Instance, max_sets: u32) DescriptorSetError!@This() {
            var out: @This() = undefined;

            var pool_sizes: [type_num]c.VkDescriptorPoolSize = undefined;
            inline for (&pool_sizes, DescriptorTypes, DescriptorInternalTypes) |*size, DType, DInternType| {
                size.* = switch (DType) {
                    UniformBuffer(DInternType.?) => .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = max_sets },
                    else => @compileError("Invalid Descriptor"),
                };
            }

            const pool_info: c.VkDescriptorPoolCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .poolSizeCount = @intCast(type_num),
                .pPoolSizes = &pool_sizes,
                .maxSets = max_sets,
            };

            if (c.vkCreateDescriptorPool(inst.logical_device, &pool_info, null, &out.descriptor_pool) != c.VK_SUCCESS) {
                return DescriptorSetError.descriptor_pool_creation_failed;
            }

            return out;
        }

        pub fn createSets(this: *@This(), inst: instance.Instance, descriptors: SetCreationType, alloc: Allocator, sets: u32) DescriptorSetError!void {
            const layouts: []c.VkDescriptorSetLayout = try alloc.alloc(c.VkDescriptorSetLayout, sets * type_num);
            defer alloc.free(layouts);
            inline for (DescriptorTypes, DescriptorInternalTypes, 'a'.., 0..) |DType, DInternType, field_name, i| {
                const layout: c.VkDescriptorSetLayout = switch (DType) {
                    UniformBuffer(DInternType.?) => @as(DType, @field(descriptors, &.{field_name})).descriptor_set_layout,
                    else => unreachable,
                };
                for (layouts[(i * sets)..((i + 1) * sets)]) |*l| {
                    l.* = layout;
                }
            }

            const alloc_info: c.VkDescriptorSetAllocateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .descriptorPool = this.descriptor_pool,
                .descriptorSetCount = sets,
                .pSetLayouts = layouts.ptr,
            };

            this.vk_descriptor_sets = try alloc.alloc(c.VkDescriptorSet, sets);
            if (c.vkAllocateDescriptorSets(inst.logical_device, &alloc_info, this.vk_descriptor_sets.ptr) != c.VK_SUCCESS) {
                return DescriptorSetError.descriptor_sets_allocation_failed;
            }

            for (0..sets) |i| {
                var descriptor_writes: [type_num]c.VkWriteDescriptorSet = undefined;

                inline for (DescriptorTypes, DescriptorInternalTypes, 'a'.., &descriptor_writes) |DType, DInternType, field_name, *d_write| {
                    switch (DType) {
                        UniformBuffer(DInternType.?) => {
                            const uniform_buffer: DType = @field(descriptors, &.{field_name});

                            const buffer_info: c.VkDescriptorBufferInfo = .{
                                .buffer = uniform_buffer.gpu_buffers[i],
                                .offset = 0,
                                .range = @sizeOf(DInternType.?),
                            };

                            d_write.* = .{
                                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                                .dstSet = this.vk_descriptor_sets[i],
                                .dstBinding = 0,
                                .dstArrayElement = 0,
                                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                                .descriptorCount = 1,
                                .pBufferInfo = &buffer_info,
                                .pImageInfo = null,
                                .pTexelBufferView = null,
                            };
                        },
                        else => unreachable,
                    }
                }

                c.vkUpdateDescriptorSets(inst.logical_device, @intCast(descriptor_writes.len), &descriptor_writes, 0, null);
            }
        }
    };
}

pub const UniformBufferError = error{descriptor_set_layout_creation_failed} || Allocator.Error || v_init_common.BufferCreationError;

pub fn UniformBuffer(UniformBufferObjectType: type) type {
    return struct {
        cpu_state: UniformBufferObjectType,
        gpu_buffers: []c.VkBuffer,
        gpu_memory: []c.VkDeviceMemory,
        gpu_memory_mapped: []?*align(@alignOf(UniformBufferObjectType)) anyopaque,
        descriptor_set_layout: c.VkDescriptorSetLayout,

        pub fn blueprint(inst: instance.Instance) UniformBufferError!UniformBuffer(UniformBufferObjectType) {
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

            if (c.vkCreateDescriptorSetLayout(inst.logical_device, &layout_info, null, &out.descriptor_set_layout) != c.VK_SUCCESS) {
                return UniformBufferError.descriptor_set_layout_creation_failed;
            }

            return out;
        }

        pub fn create(self: *UniformBuffer(UniformBufferObjectType), inst: instance.Instance, alloc: Allocator) UniformBufferError!void {
            const buffer_size: c.VkDeviceSize = @sizeOf(common.UniformBufferObject);

            self.gpu_buffers = try alloc.alloc(c.VkBuffer, common.max_frames_in_flight);
            self.gpu_memory = try alloc.alloc(c.VkDeviceMemory, common.max_frames_in_flight);
            self.gpu_memory_mapped = try alloc.alloc(?*align(@alignOf(UniformBufferObjectType)) anyopaque, common.max_frames_in_flight);

            for (0..common.max_frames_in_flight) |i| {
                try v_init_common.createBuffer(
                    inst,
                    buffer_size,
                    c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                    c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                    &self.gpu_buffers[i],
                    &self.gpu_memory[i],
                );

                _ = c.vkMapMemory(
                    inst.logical_device,
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
