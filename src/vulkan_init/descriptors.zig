const screen_renderer = @import("screen_renderer.zig");
const instance = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;

const Allocator = std.mem.Allocator;

pub const Error = DescriptorSetError || UniformBufferError || BufferCreationError || StorageImageError;

pub const DescriptorSetError = error{
    descriptor_pool_creation_failed,
    descriptor_sets_allocation_failed,
    descriptor_set_layout_creation_failed,
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
        layout: c.VkDescriptorSetLayout,

        pub fn blueprint(inst: instance.Instance, bindings: *const [type_num]c.VkDescriptorSetLayoutBinding) DescriptorSetError!@This() {
            var out: @This() = undefined;

            const create_info: c.VkDescriptorSetLayoutCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .bindingCount = type_num,
                .pBindings = bindings,
            };

            if (c.vkCreateDescriptorSetLayout(inst.logical_device, &create_info, null, &out.layout) != c.VK_SUCCESS) {
                return DescriptorSetError.descriptor_set_layout_creation_failed;
            }

            return out;
        }

        pub fn allocatePool(self: *@This(), inst: instance.Instance, descriptors: SetCreationType) DescriptorSetError!void {
            var pool_sizes: [type_num]c.VkDescriptorPoolSize = undefined;
            var max_sets: u32 = 0;
            inline for (&pool_sizes, DescriptorTypes, DescriptorInternalTypes, 'a'..) |*size, DType, DInternType, name| {
                size.descriptorCount = @field(descriptors, &.{name}).num;
                if (max_sets < size.descriptorCount) max_sets = size.descriptorCount;

                size.type = switch (DType) {
                    UniformBuffer(DInternType.?) => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    StorageImage => c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                    else => @compileError("Invalid Descriptor"),
                };
            }

            const pool_info: c.VkDescriptorPoolCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .poolSizeCount = @intCast(type_num),
                .pPoolSizes = &pool_sizes,
                .maxSets = max_sets,
            };

            if (c.vkCreateDescriptorPool(inst.logical_device, &pool_info, null, &self.descriptor_pool) != c.VK_SUCCESS) {
                return DescriptorSetError.descriptor_pool_creation_failed;
            }
        }

        pub fn createSets(self: *@This(), inst: instance.Instance, descriptors: SetCreationType, alloc: Allocator, num_sets: u32) DescriptorSetError!void {
            const layouts: []c.VkDescriptorSetLayout = try alloc.alloc(c.VkDescriptorSetLayout, num_sets * type_num);
            defer alloc.free(layouts);
            for (layouts[0..num_sets]) |*l| {
                l.* = self.layout;
            }

            const alloc_info: c.VkDescriptorSetAllocateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .descriptorPool = self.descriptor_pool,
                .descriptorSetCount = num_sets,
                .pSetLayouts = layouts.ptr,
            };

            self.vk_descriptor_sets = try alloc.alloc(c.VkDescriptorSet, num_sets);
            if (c.vkAllocateDescriptorSets(inst.logical_device, &alloc_info, self.vk_descriptor_sets.ptr) != c.VK_SUCCESS) {
                return DescriptorSetError.descriptor_sets_allocation_failed;
            }

            try updateDescriptorSets(
                .{
                    .DescriptorTypes = DescriptorTypes,
                    .DescriptorInternalTypes = DescriptorInternalTypes,
                    .SetCreationType = SetCreationType,
                    .type_num = type_num,
                },
                alloc,
                inst,
                descriptors,
                self.vk_descriptor_sets,
                num_sets,
            );
        }

        pub fn deinit(self: @This(), inst: instance.Instance, alloc: Allocator) void {
            c.vkDestroyDescriptorPool(inst.logical_device, self.descriptor_pool, null);
            alloc.free(self.vk_descriptor_sets);

            c.vkDestroyDescriptorSetLayout(inst.logical_device, self.layout, null);
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
    alloc: Allocator,
    inst: instance.Instance,
    descriptors: comptime_info.SetCreationType,
    vk_descriptor_sets: []c.VkDescriptorSet,
    num_sets: u32,
) Allocator.Error!void {
    var alloc_arena = std.heap.ArenaAllocator.init(alloc);
    defer alloc_arena.deinit();
    for (0..num_sets) |i| {
        var descriptor_writes: [comptime_info.type_num]c.VkWriteDescriptorSet = undefined;

        inline for (
            comptime_info.DescriptorTypes,
            comptime_info.DescriptorInternalTypes,
            'a'..,
            &descriptor_writes,
        ) |DType, DInternType, field_name, *d_write| {
            const descriptor: DType = @field(descriptors, &.{field_name});
            d_write.* = try descriptorWrite(
                DType,
                DInternType,
                alloc_arena.allocator(),
                descriptor,
                vk_descriptor_sets[i],
                i,
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
    arena_alloc: Allocator,
    descriptor: DType,
    vk_descriptor_set: c.VkDescriptorSet,
    index: usize,
) Allocator.Error!c.VkWriteDescriptorSet {
    switch (DType) {
        UniformBuffer(DInternType.?) => {
            const descriptor_buff_info = try arena_alloc.create(c.VkDescriptorBufferInfo);
            descriptor_buff_info.* = .{
                .buffer = descriptor.gpu_buffers[index],
                .offset = 0,
                .range = @sizeOf(DInternType.?),
            };

            return .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = vk_descriptor_set,
                .dstBinding = descriptor.descriptor_set_binding.binding,
                .dstArrayElement = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = descriptor_buff_info,
                .pImageInfo = null,
                .pTexelBufferView = null,
            };
        },
        StorageImage => {
            const image_info = try arena_alloc.create(c.VkDescriptorImageInfo);
            image_info.* = .{
                .imageLayout = c.VK_IMAGE_LAYOUT_SHARED_PRESENT_KHR,
                .imageView = descriptor.view,
                .sampler = descriptor.sampler,
            };

            return .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = vk_descriptor_set,
                .dstBinding = descriptor.descriptor_set_binding.binding,
                .dstArrayElement = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = null,
                .pImageInfo = &image_info,
                .pTexelBufferView = null,
            };
        },
        else => unreachable,
    }
}

pub const UniformBufferError = error{descriptor_set_layout_creation_failed} || Allocator.Error || BufferCreationError;

pub fn UniformBuffer(UniformBufferObjectType: type) type {
    return struct {
        num: u32,
        cpu_state: UniformBufferObjectType,
        gpu_buffers: []c.VkBuffer,
        gpu_memory: []c.VkDeviceMemory,
        gpu_memory_mapped: []?*align(@alignOf(UniformBufferObjectType)) anyopaque,
        descriptor_set_binding: c.VkDescriptorSetLayoutBinding,

        pub fn blueprint(self: *@This(), binding: u32, num: u32) UniformBufferError!void {
            self.descriptor_set_binding = .{
                .binding = binding,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            };
            self.num = num;
        }

        pub fn create(self: *UniformBuffer(UniformBufferObjectType), inst: instance.Instance, alloc: Allocator) UniformBufferError!void {
            const buffer_size: c.VkDeviceSize = @sizeOf(common.UniformBufferObject);

            self.gpu_buffers = try alloc.alloc(c.VkBuffer, self.num);
            self.gpu_memory = try alloc.alloc(c.VkDeviceMemory, self.num);
            self.gpu_memory_mapped = try alloc.alloc(?*align(@alignOf(UniformBufferObjectType)) anyopaque, self.num);

            for (0..self.num) |i| {
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
        }
    };
}

pub const BufferCreationError = error{
    suitable_memory_type_not_found,
    buffer_creation_failed,
    buffer_memory_allocation_failed,
};

fn createBuffer(
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

fn findMemoryType(physical_device: c.VkPhysicalDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) BufferCreationError!u32 {
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
            return @intCast(i);
        }
    }

    return BufferCreationError.suitable_memory_type_not_found;
}

pub const StorageImageError = error{
    storage_image_creation_failed,
    storage_image_allocation_failed,
};

pub const StorageImage = struct {
    num: u32,
    vk_image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    descriptor_set_binding: c.VkDescriptorSetLayout,

    pub fn blueprint(binding: u32, num: u32) StorageImage {
        var out: StorageImage = undefined;
        out.num = num;
        out.descriptor_set_binding = .{
            .binding = binding,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImmutableSamplers = null,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_COMPUTE_BIT,
        };
        return out;
    }

    pub fn create(self: *StorageImage, inst: instance.Instance, screen_rend: screen_renderer.ScreenRenderer, width: u32, height: u32, format: c.VkFormat) StorageImageError!void {
        const vk_image_info: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .extent = .{
                .width = width,
                .height = height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .format = format,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_STORAGE_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .samples = c.VK_SAMPLE_COUNT_1,
            .flags = 0,
        };

        if (c.vkCreateImage(inst.logical_device, &vk_image_info, null, &self.vk_image) != c.VK_SUCCESS) {
            return StorageImageError.storage_image_creation_failed;
        }

        var mem_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(inst.logical_device, self.vk_image, &mem_requirements);

        const alloc_info: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = findMemoryType(
                inst.physical_device,
                mem_requirements.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            ),
        };

        if (c.vkAllocateMemory(inst.logical_device, &alloc_info, null, &self.memory) != c.VK_SUCCESS) {
            return StorageImageError.storage_image_allocation_failed;
        }
        c.vkBindImageMemory(inst.logical_device, self.vk_image, self.memory, 0);

        transitionImageLayout(inst, screen_rend, self.vk_image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
    }
};

fn transitionImageLayout(
    inst: instance.Instance,
    screen_rend: screen_renderer.ScreenRenderer,
    image: c.VkImage,
    old_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
) void {
    const command_buffer = beginSingleTimeCommands(inst, screen_rend);

    var barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .srcAccessMask = undefined,
        .dstAccessMask = undefined,
    };

    var source_stage: c.VkPipelineStageFlags = undefined;
    var destination_stage: c.VkPipelineStageFlags = undefined;

    if (old_layout == c.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

        source_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        destination_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
    } else if (old_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        source_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        destination_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    } else {
        std.debug.panic("unsupported layout transition:\n\told: {}\n\tnew: {}\n", .{ old_layout, new_layout });
    }

    c.vkCmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    endSingleTimeCommands(inst, screen_rend, command_buffer);
}

fn beginSingleTimeCommands(inst: instance.Instance, screen_rend: screen_renderer.ScreenRenderer) c.VkCommandBuffer {
    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = screen_rend.command_pool,
        .commandBufferCount = 1,
    };

    var command_buffer: c.VkCommandBuffer = undefined;
    _ = c.vkAllocateCommandBuffers(inst.logical_device, &alloc_info, &command_buffer);

    const begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    _ = c.vkBeginCommandBuffer(command_buffer, &begin_info);

    return command_buffer;
}

fn endSingleTimeCommands(inst: instance.Instance, screen_rend: screen_renderer.ScreenRenderer, command_buffer: c.VkCommandBuffer) void {
    _ = c.vkEndCommandBuffer(command_buffer);

    const submit_info: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };

    _ = c.vkQueueSubmit(inst.graphics_compute_queue, 1, &submit_info, null);
    _ = c.vkQueueWaitIdle(inst.graphics_compute_queue);

    c.vkFreeCommandBuffers(inst.logicaL_device, screen_rend.command_pool, 1, &command_buffer);
}
