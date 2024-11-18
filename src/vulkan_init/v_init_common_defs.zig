const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common_defs.zig");
const c = common.c;
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

pub fn createBuffer(
    data: *AppData,
    size: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    buffer: *c.VkBuffer,
    buffer_memory: *c.VkDeviceMemory,
) common.InitVulkanError!void {
    const buffer_info: c.VkBufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    if (c.vkCreateBuffer(data.device, &buffer_info, null, buffer) != c.VK_SUCCESS) {
        return common.InitVulkanError.buffer_creation_failed;
    }

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(data.device, buffer.*, &mem_requirements);

    const alloc_info: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(data, mem_requirements.memoryTypeBits, properties),
    };

    if (c.vkAllocateMemory(data.device, &alloc_info, null, buffer_memory) != c.VK_SUCCESS) {
        return common.InitVulkanError.buffer_memory_allocation_failed;
    }

    _ = c.vkBindBufferMemory(data.device, buffer.*, buffer_memory.*, 0);
}

pub fn findMemoryType(data: *common.AppData, type_filter: u32, properties: c.VkMemoryPropertyFlags) common.InitVulkanError!u32 {
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(data.physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
            return @intCast(i);
        }
    }

    return common.InitVulkanError.suitable_memory_type_not_found;
}
