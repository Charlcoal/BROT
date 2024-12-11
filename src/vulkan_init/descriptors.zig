const instance = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
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

            updateDescriptorSets(
                .{
                    .DescriptorTypes = DescriptorTypes,
                    .DescriptorInternalTypes = DescriptorInternalTypes,
                    .SetCreationType = SetCreationType,
                    .type_num = type_num,
                },
                inst,
                descriptors,
                this.vk_descriptor_sets,
                sets,
            );
        }

        pub fn deinit(self: @This(), inst: instance.Instance, alloc: Allocator) void {
            c.vkDestroyDescriptorPool(inst.logical_device, self.descriptor_pool, null);
            alloc.free(self.vk_descriptor_sets);
        }
    };
}

const DescriptorComptimeInfo = struct {
    DescriptorTypes: []const type,
    DescriptorInternalTypes: []const ?type,
    SetCreationType: type,
    type_num: comptime_int,
};

fn updateDescriptorSets(
    comptime_info: DescriptorComptimeInfo,
    inst: instance.Instance,
    descriptors: comptime_info.SetCreationType,
    vk_descriptor_sets: []c.VkDescriptorSet,
    sets: u32,
) void {
    for (0..sets) |i| {
        var descriptor_buffs: [comptime_info.type_num]c.VkDescriptorBufferInfo = undefined;
        var descriptor_writes: [comptime_info.type_num]c.VkWriteDescriptorSet = undefined;

        inline for (
            comptime_info.DescriptorTypes,
            comptime_info.DescriptorInternalTypes,
            'a'..,
            &descriptor_buffs,
            &descriptor_writes,
        ) |DType, DInternType, field_name, *d_buff, *d_write| {
            const uniform_buffer: DType = @field(descriptors, &.{field_name});
            descriptorWrite(
                DType,
                DInternType,
                uniform_buffer.gpu_buffers[i],
                vk_descriptor_sets[i],
                d_buff,
                d_write,
            );
        }

        c.vkUpdateDescriptorSets(
            inst.logical_device,
            @intCast(descriptor_writes.len),
            &descriptor_writes,
            0,
            null,
        );
    }
}

fn descriptorWrite(
    DType: type,
    DInternType: ?type,
    gpu_buffer: c.VkBuffer,
    vk_descriptor_set: c.VkDescriptorSet,
    descriptorBuff: *c.VkDescriptorBufferInfo,
    writeDescriptor: *c.VkWriteDescriptorSet,
) void {
    switch (DType) {
        UniformBuffer(DInternType.?) => {
            descriptorBuff.* = .{
                .buffer = gpu_buffer,
                .offset = 0,
                .range = @sizeOf(DInternType.?),
            };

            writeDescriptor.* = .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = vk_descriptor_set,
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = descriptorBuff,
                .pImageInfo = null,
                .pTexelBufferView = null,
            };
        },
        else => unreachable,
    }
}

pub const UniformBufferError = error{descriptor_set_layout_creation_failed} || Allocator.Error || BufferCreationError;

pub fn UniformBuffer(UniformBufferObjectType: type) type {
    return struct {
        cpu_state: UniformBufferObjectType,
        gpu_buffers: []c.VkBuffer,
        gpu_memory: []c.VkDeviceMemory,
        gpu_memory_mapped: []?*align(@alignOf(UniformBufferObjectType)) anyopaque,
        descriptor_set_layout: c.VkDescriptorSetLayout,

        pub fn blueprint(self: *@This(), inst: instance.Instance) UniformBufferError!void {
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

            if (c.vkCreateDescriptorSetLayout(inst.logical_device, &layout_info, null, &self.descriptor_set_layout) != c.VK_SUCCESS) {
                return UniformBufferError.descriptor_set_layout_creation_failed;
            }
        }

        pub fn create(self: *UniformBuffer(UniformBufferObjectType), inst: instance.Instance, alloc: Allocator) UniformBufferError!void {
            const buffer_size: c.VkDeviceSize = @sizeOf(common.UniformBufferObject);

            self.gpu_buffers = try alloc.alloc(c.VkBuffer, common.max_frames_in_flight);
            self.gpu_memory = try alloc.alloc(c.VkDeviceMemory, common.max_frames_in_flight);
            self.gpu_memory_mapped = try alloc.alloc(?*align(@alignOf(UniformBufferObjectType)) anyopaque, common.max_frames_in_flight);

            for (0..common.max_frames_in_flight) |i| {
                try createBuffer(
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

        pub fn deinit(self: *UniformBuffer(UniformBufferObjectType), inst: instance.Instance, alloc: Allocator) void {
            for (self.gpu_memory, self.gpu_buffers) |mem, buf| {
                c.vkDestroyBuffer(inst.logical_device, buf, null);
                c.vkFreeMemory(inst.logical_device, mem, null);
            }
            alloc.free(self.gpu_memory);
            alloc.free(self.gpu_buffers);
            alloc.free(self.gpu_memory_mapped);

            c.vkDestroyDescriptorSetLayout(inst.logical_device, self.descriptor_set_layout, null);
        }
    };
}

pub const BufferCreationError = error{
    suitable_memory_type_not_found,
    buffer_creation_failed,
    buffer_memory_allocation_failed,
};

pub fn createBuffer(
    inst: instance.Instance,
    size: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    buffer: *c.VkBuffer,
    buffer_memory: *c.VkDeviceMemory,
) BufferCreationError!void {
    const buffer_info: c.VkBufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    if (c.vkCreateBuffer(inst.logical_device, &buffer_info, null, buffer) != c.VK_SUCCESS) {
        return BufferCreationError.buffer_creation_failed;
    }

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(inst.logical_device, buffer.*, &mem_requirements);

    const alloc_info: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(inst.physical_device, mem_requirements.memoryTypeBits, properties),
    };

    if (c.vkAllocateMemory(inst.logical_device, &alloc_info, null, buffer_memory) != c.VK_SUCCESS) {
        return BufferCreationError.buffer_memory_allocation_failed;
    }

    _ = c.vkBindBufferMemory(inst.logical_device, buffer.*, buffer_memory.*, 0);
}

pub fn findMemoryType(physical_device: c.VkPhysicalDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) BufferCreationError!u32 {
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
            return @intCast(i);
        }
    }

    return BufferCreationError.suitable_memory_type_not_found;
}
