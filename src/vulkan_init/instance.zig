const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub const Error = error{
    validation_layer_unavailible,
    instance_creation_failed,
} || Allocator.Error;

pub const VulkanInstanceSettings = struct {
    enable_validation_layers: bool = true,
    app_info: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "BROT",
        .applicationVersion = c.VK_MAKE_API_VERSION(0, 1, 3, 0),
        .pEngineName = "No Engine",
        .engineVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0),
        .apiVersion = c.VK_API_VERSION_1_3,
    },
};

pub const VulkanInstance = struct {
    vk_instance: c.VkInstance,

    pub fn init(alloc: Allocator, settings: VulkanInstanceSettings, validation_layers: []const [*:0]const u8) Error!VulkanInstance {
        var vulkan_instance: VulkanInstance = .{ .vk_instance = null };

        if (settings.enable_validation_layers and !try checkValidationLayerSupport(alloc, validation_layers)) {
            return Error.validation_layer_unavailible;
        }

        var create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &settings.app_info,
            .enabledLayerCount = 0,
        };

        const extensions = try getRequiredExtensions(alloc, settings.enable_validation_layers);
        defer alloc.free(extensions);
        create_info.enabledExtensionCount = @intCast(extensions.len);
        create_info.ppEnabledExtensionNames = extensions.ptr;

        var debug_create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
        if (settings.enable_validation_layers) {
            create_info.enabledLayerCount = @intCast(validation_layers.len);
            create_info.ppEnabledLayerNames = validation_layers.ptr;

            v_common.populateDebugMessengerCreateInfo(&debug_create_info);
            create_info.pNext = @ptrCast(&debug_create_info);
        } else {
            create_info.enabledLayerCount = 0;

            create_info.pNext = null;
        }

        const result = c.vkCreateInstance(&create_info, null, &vulkan_instance.vk_instance);
        if (result != c.VK_SUCCESS) {
            return Error.instance_creation_failed;
        }

        return vulkan_instance;
    }
};

//pub fn createInstance(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
//    if (common.enable_validation_layers and !try checkValidationLayerSupport(alloc, &common.validation_layers)) {
//        return InitVulkanError.validation_layer_unavailible;
//    }
//
//    const app_info = c.VkApplicationInfo{
//        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
//        .pApplicationName = "Hello Triangle",
//        .applicationVersion = c.VK_MAKE_API_VERSION(0, 1, 3, 0),
//        .pEngineName = "No Engine",
//        .engineVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0),
//        .apiVersion = c.VK_API_VERSION_1_3,
//    };
//
//    var create_info = c.VkInstanceCreateInfo{
//        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
//        .pApplicationInfo = &app_info,
//        .enabledLayerCount = 0,
//    };
//
//    const extensions = try getRequiredExtensions(alloc, common.enable_validation_layers);
//    defer alloc.free(extensions);
//    create_info.enabledExtensionCount = @intCast(extensions.len);
//    create_info.ppEnabledExtensionNames = extensions.ptr;
//
//    var debug_create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
//    if (common.enable_validation_layers) {
//        create_info.enabledLayerCount = common.validation_layers.len;
//        create_info.ppEnabledLayerNames = &common.validation_layers;
//
//        v_common.populateDebugMessengerCreateInfo(&debug_create_info);
//        create_info.pNext = @ptrCast(&debug_create_info);
//    } else {
//        create_info.enabledLayerCount = 0;
//
//        create_info.pNext = null;
//    }
//
//    const result = c.vkCreateInstance(&create_info, null, &data.instance);
//    if (result != c.VK_SUCCESS) {
//        return InitVulkanError.instance_creation_failed;
//    }
//}

fn checkValidationLayerSupport(alloc: Allocator, validation_layers: []const [*:0]const u8) Allocator.Error!bool {
    var layer_count: u32 = undefined;
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, null);

    const availible_layers = try alloc.alloc(c.VkLayerProperties, layer_count);
    defer alloc.free(availible_layers);
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, availible_layers.ptr);

    for (validation_layers) |v_layer| {
        var layer_found: bool = false;

        for (availible_layers) |a_layer| {
            if (common.str_eq(v_layer, @as([*:0]const u8, @ptrCast(&a_layer.layerName)))) {
                layer_found = true;
                break;
            }
        }

        if (!layer_found) return false;
    }

    return true;
}

fn getRequiredExtensions(alloc: Allocator, enable_validation_layers: bool) Allocator.Error![][*c]const u8 {
    var glfw_extension_count: u32 = 0;
    const glfw_extensions: [*c]const [*c]const u8 = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count);

    const out = try alloc.alloc([*c]const u8, glfw_extension_count + if (enable_validation_layers) @as(usize, 1) else @as(usize, 0));
    for (0..glfw_extension_count) |i| {
        out[i] = glfw_extensions[i];
    }
    if (enable_validation_layers) {
        out[glfw_extension_count] = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    }

    return out;
}
