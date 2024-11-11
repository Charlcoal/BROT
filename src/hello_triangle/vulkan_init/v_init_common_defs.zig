const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const AppData = common.AppData;
const Allocator = std.mem.Allocator;

pub const SwapChainSupportDetails = struct {
    capabilities: glfw.VkSurfaceCapabilitiesKHR,
    formats: []glfw.VkSurfaceFormatKHR,
    presentModes: []glfw.VkPresentModeKHR,
};

pub fn populateDebugMessengerCreateInfo(create_info: *glfw.VkDebugUtilsMessengerCreateInfoEXT) void {
    create_info.* = glfw.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = glfw.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
        .messageType = glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
}

pub const QueueFamilyIndices = struct {
    graphics_compute_family: ?u32,
    present_family: ?u32,

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_compute_family != null and self.present_family != null;
    }
};

pub fn findQueueFamilies(data: AppData, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!QueueFamilyIndices {
    var indices = QueueFamilyIndices{
        .graphics_compute_family = null,
        .present_family = null,
    };

    var queue_family_count: u32 = 0;
    _ = glfw.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try alloc.alloc(glfw.VkQueueFamilyProperties, queue_family_count);
    defer alloc.free(queue_families);
    _ = glfw.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queueFamily, i| {
        if (queueFamily.queueFlags & glfw.VK_QUEUE_GRAPHICS_BIT != 0 and queueFamily.queueFlags & glfw.VK_QUEUE_COMPUTE_BIT != 0) {
            indices.graphics_compute_family = @intCast(i);
        }

        var present_support: glfw.VkBool32 = glfw.VK_FALSE;
        _ = glfw.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), data.surface, &present_support);

        if (present_support != glfw.VK_FALSE) {
            indices.present_family = @intCast(i);
        }

        if (indices.isComplete()) break;
    }
    return indices;
}

pub fn querySwapChainSupport(surface: glfw.VkSurfaceKHR, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!SwapChainSupportDetails {
    var details: SwapChainSupportDetails = .{
        .formats = undefined,
        .capabilities = undefined,
        .presentModes = undefined,
    };

    _ = glfw.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities);

    var format_count: u32 = undefined;
    _ = glfw.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

    details.formats = try alloc.alloc(glfw.VkSurfaceFormatKHR, format_count);
    _ = glfw.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, details.formats.ptr);

    var present_mode_count: u32 = undefined;
    _ = glfw.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

    details.presentModes = try alloc.alloc(glfw.VkPresentModeKHR, present_mode_count);
    _ = glfw.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, details.presentModes.ptr);

    return details;
}

pub fn createBuffer(
    data: *AppData,
    size: glfw.VkDeviceSize,
    usage: glfw.VkBufferUsageFlags,
    properties: glfw.VkMemoryPropertyFlags,
    buffer: *glfw.VkBuffer,
    buffer_memory: *glfw.VkDeviceMemory,
) common.InitVulkanError!void {
    const buffer_info: glfw.VkBufferCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = glfw.VK_SHARING_MODE_EXCLUSIVE,
    };

    if (glfw.vkCreateBuffer(data.device, &buffer_info, null, buffer) != glfw.VK_SUCCESS) {
        return common.InitVulkanError.buffer_creation_failed;
    }

    var mem_requirements: glfw.VkMemoryRequirements = undefined;
    glfw.vkGetBufferMemoryRequirements(data.device, buffer.*, &mem_requirements);

    const alloc_info: glfw.VkMemoryAllocateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(data, mem_requirements.memoryTypeBits, properties),
    };

    if (glfw.vkAllocateMemory(data.device, &alloc_info, null, buffer_memory) != glfw.VK_SUCCESS) {
        return common.InitVulkanError.buffer_memory_allocation_failed;
    }

    _ = glfw.vkBindBufferMemory(data.device, buffer.*, buffer_memory.*, 0);
}

pub fn findMemoryType(data: *common.AppData, type_filter: u32, properties: glfw.VkMemoryPropertyFlags) common.InitVulkanError!u32 {
    var mem_properties: glfw.VkPhysicalDeviceMemoryProperties = undefined;
    glfw.vkGetPhysicalDeviceMemoryProperties(data.physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
            return @intCast(i);
        }
    }

    return common.InitVulkanError.suitable_memory_type_not_found;
}

fn debugCallback(
    message_severity: glfw.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: glfw.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_data: [*c]const glfw.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.C) glfw.VkBool32 {
    if (message_severity >= glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        std.debug.print("ERROR ", .{});
    } else if (message_severity >= glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        std.debug.print("WARNING ", .{});
    }

    if (message_type & glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT != 0) {
        std.debug.print("[performance] ", .{});
    }
    if (message_type & glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT != 0) {
        std.debug.print("[validation] ", .{});
    }
    if (message_type & glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT != 0) {
        std.debug.print("[general] ", .{});
    }

    std.debug.print("{s}\n", .{p_callback_data.*.pMessage});
    _ = p_user_data;

    return glfw.VK_FALSE;
}
