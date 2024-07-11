const std = @import("std");
pub const glfw = @import("imports.zig").glfw;
const builtin = @import("builtin");

pub const dbg = builtin.mode == std.builtin.Mode.Debug;
pub const enable_validation_layers = dbg;

pub const InitWindowError = error{create_window_failed};
pub const InitVulkanError = error{
    create_instance_failed,
    validation_layer_unavailible,
    debug_messenger_setup_failed,
    failed_to_create_window_surface,
    failed_to_find_gpu_with_vulkan_support,
    failed_to_find_suitable_gpu,
    failed_to_create_logical_device,
    failed_to_create_swap_chain,
    failde_to_create_image_views,
} || Allocator.Error;

const Allocator = std.mem.Allocator;

pub const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

pub const device_extensions = [_][*:0]const u8{
    glfw.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};

//result of following OOP-based tutorial, change in future
pub const AppData = struct {
    window: *glfw.GLFWwindow,
    height: i32,
    width: i32,
    instance: glfw.VkInstance,
    debug_messenger: glfw.VkDebugUtilsMessengerEXT,
    surface: glfw.VkSurfaceKHR,
    physical_device: glfw.VkPhysicalDevice,
    device: glfw.VkDevice,
    graphics_queue: glfw.VkQueue,
    present_queue: glfw.VkQueue,
    swap_chain: glfw.VkSwapchainKHR,
    swap_chain_images: []glfw.VkImage,
    swap_chain_image_format: glfw.VkFormat,
    swap_chain_extent: glfw.VkExtent2D,
    swap_chain_image_views: []glfw.VkImageView,
};

pub fn str_eq(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return true;
    }
    return false;
}
