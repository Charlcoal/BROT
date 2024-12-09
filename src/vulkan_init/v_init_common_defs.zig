const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common_defs.zig");
const c = common.c;
const inst = @import("instance.zig");
const AppData = common.AppData;
const Allocator = std.mem.Allocator;

pub const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: []c.VkSurfaceFormatKHR,
    presentModes: []c.VkPresentModeKHR,
};

pub const QueueFamilyIndices = struct {
    graphics_compute_family: ?u32,
    present_family: ?u32,

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_compute_family != null and self.present_family != null;
    }
};

pub fn findQueueFamilies(device: c.VkPhysicalDevice, alloc: Allocator, surface: c.VkSurfaceKHR) Allocator.Error!QueueFamilyIndices {
    var indices = QueueFamilyIndices{
        .graphics_compute_family = null,
        .present_family = null,
    };

    var queue_family_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try alloc.alloc(c.VkQueueFamilyProperties, queue_family_count);
    defer alloc.free(queue_families);
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queueFamily, i| {
        if (queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0 and queueFamily.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0) {
            indices.graphics_compute_family = @intCast(i);
        }

        var present_support: c.VkBool32 = c.VK_FALSE;
        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &present_support);

        if (present_support != c.VK_FALSE) {
            indices.present_family = @intCast(i);
        }

        if (indices.isComplete()) break;
    }
    return indices;
}

pub fn querySwapChainSupport(surface: c.VkSurfaceKHR, device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!SwapChainSupportDetails {
    var details: SwapChainSupportDetails = .{
        .formats = undefined,
        .capabilities = undefined,
        .presentModes = undefined,
    };

    _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities);

    var format_count: u32 = undefined;
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

    details.formats = try alloc.alloc(c.VkSurfaceFormatKHR, format_count);
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, details.formats.ptr);

    var present_mode_count: u32 = undefined;
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

    details.presentModes = try alloc.alloc(c.VkPresentModeKHR, present_mode_count);
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, details.presentModes.ptr);

    return details;
}

pub const BufferCreationError = error{
    suitable_memory_type_not_found,
    buffer_creation_failed,
    buffer_memory_allocation_failed,
};

pub fn createBuffer(
    instance: inst.Instance,
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

    if (c.vkCreateBuffer(instance.logical_device, &buffer_info, null, buffer) != c.VK_SUCCESS) {
        return BufferCreationError.buffer_creation_failed;
    }

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(instance.logical_device, buffer.*, &mem_requirements);

    const alloc_info: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(instance.physical_device, mem_requirements.memoryTypeBits, properties),
    };

    if (c.vkAllocateMemory(instance.logical_device, &alloc_info, null, buffer_memory) != c.VK_SUCCESS) {
        return BufferCreationError.buffer_memory_allocation_failed;
    }

    _ = c.vkBindBufferMemory(instance.logical_device, buffer.*, buffer_memory.*, 0);
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
