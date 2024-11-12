const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn setupDebugMessenger(data: *common.AppData) InitVulkanError!void {
    if (!common.enable_validation_layers) return;

    var create_info: glfw.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    v_common.populateDebugMessengerCreateInfo(&create_info);

    if (createDebugUtilsMessengerEXT(data.instance, &create_info, null, &data.debug_messenger) != glfw.VK_SUCCESS) {
        return InitVulkanError.debug_messenger_setup_failed;
    }
}

fn createDebugUtilsMessengerEXT(
    instance: glfw.VkInstance,
    p_create_info: [*c]const glfw.VkDebugUtilsMessengerCreateInfoEXT,
    p_vulkan_alloc: [*c]const glfw.VkAllocationCallbacks,
    p_debug_messenger: *glfw.VkDebugUtilsMessengerEXT,
) glfw.VkResult {
    const func: glfw.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(glfw.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    if (func) |ptr| {
        return ptr(instance, p_create_info, p_vulkan_alloc, p_debug_messenger);
    } else {
        return glfw.VK_ERROR_EXTENSION_NOT_PRESENT;
    }
}
