const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createInstance(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    if (common.enable_validation_layers and !try checkValidationLayerSupport(alloc)) {
        return InitVulkanError.validation_layer_unavailible;
    }

    const app_info = glfw.VkApplicationInfo{
        .sType = glfw.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Hello Triangle",
        .applicationVersion = glfw.VK_MAKE_API_VERSION(0, 1, 3, 0),
        .pEngineName = "No Engine",
        .engineVersion = glfw.VK_MAKE_API_VERSION(0, 1, 0, 0),
        .apiVersion = glfw.VK_API_VERSION_1_3,
    };

    var create_info = glfw.VkInstanceCreateInfo{
        .sType = glfw.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
    };

    const extensions = try getRequiredExtensions(alloc);
    defer alloc.free(extensions);
    create_info.enabledExtensionCount = @intCast(extensions.len);
    create_info.ppEnabledExtensionNames = extensions.ptr;

    var debug_create_info: glfw.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    if (common.enable_validation_layers) {
        create_info.enabledLayerCount = common.validation_layers.len;
        create_info.ppEnabledLayerNames = &common.validation_layers;

        v_common.populateDebugMessengerCreateInfo(&debug_create_info);
        create_info.pNext = @ptrCast(&debug_create_info);
    } else {
        create_info.enabledLayerCount = 0;

        create_info.pNext = null;
    }

    const result = glfw.vkCreateInstance(&create_info, null, &data.instance);
    if (result != glfw.VK_SUCCESS) {
        return InitVulkanError.create_instance_failed;
    }
}

fn checkValidationLayerSupport(alloc: Allocator) Allocator.Error!bool {
    var layer_count: u32 = undefined;
    _ = glfw.vkEnumerateInstanceLayerProperties(&layer_count, null);

    const availible_layers = try alloc.alloc(glfw.VkLayerProperties, layer_count);
    defer alloc.free(availible_layers);
    _ = glfw.vkEnumerateInstanceLayerProperties(&layer_count, availible_layers.ptr);

    for (common.validation_layers) |v_layer| {
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

fn getRequiredExtensions(alloc: Allocator) Allocator.Error![][*c]const u8 {
    var glfw_extension_count: u32 = 0;
    const glfw_extensions: [*c]const [*c]const u8 = glfw.glfwGetRequiredInstanceExtensions(&glfw_extension_count);

    const out = try alloc.alloc([*c]const u8, glfw_extension_count + if (common.enable_validation_layers) 1 else 0);
    for (0..glfw_extension_count) |i| {
        out[i] = glfw_extensions[i];
    }
    if (common.enable_validation_layers) {
        out[glfw_extension_count] = glfw.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    }

    return out;
}
