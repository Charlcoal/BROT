const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn setupDebugMessenger(data: *common.AppData) InitVulkanError!void {
    if (!common.enable_validation_layers) return;

    var create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    v_common.populateDebugMessengerCreateInfo(&create_info);

    if (createDebugUtilsMessengerEXT(data.instance, &create_info, null, &data.debug_messenger) != c.VK_SUCCESS) {
        return InitVulkanError.debug_messenger_setup_failed;
    }
}

fn createDebugUtilsMessengerEXT(
    instance: c.VkInstance,
    p_create_info: [*c]const c.VkDebugUtilsMessengerCreateInfoEXT,
    p_vulkan_alloc: [*c]const c.VkAllocationCallbacks,
    p_debug_messenger: *c.VkDebugUtilsMessengerEXT,
) c.VkResult {
    const func: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    if (func) |ptr| {
        return ptr(instance, p_create_info, p_vulkan_alloc, p_debug_messenger);
    } else {
        return c.VK_ERROR_EXTENSION_NOT_PRESENT;
    }
}
