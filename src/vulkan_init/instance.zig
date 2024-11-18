const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub const Error = error{
    validation_layer_unavailible,
    instance_creation_failed,
    debug_messenger_setup_failed,
    window_surface_creation_failed,
    gpu_with_vulkan_support_not_found,
    suitable_gpu_not_found,
    logical_device_creation_failed,
} || Allocator.Error;

pub const InstanceSettings = struct {
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

pub const Instance = struct {
    vk_instance: c.VkInstance,
    debug_messenger: c.VkDebugUtilsMessengerEXT,
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    logical_device: c.VkDevice,
    graphics_compute_queue: c.VkQueue,
    present_queue: c.VkQueue,

    pub fn init(alloc: Allocator, settings: InstanceSettings, window: *c.GLFWwindow, validation_layers: []const [*:0]const u8) Error!Instance {
        var instance: Instance = .{
            .vk_instance = null,
            .debug_messenger = null,
            .surface = null,
            .physical_device = null,
            .logical_device = null,
            .graphics_compute_queue = null,
            .present_queue = null,
        };

        // ----------------------------------- Vulkan Instance ------------------------------
        if (settings.enable_validation_layers and !try checkValidationLayerSupport(alloc, validation_layers)) {
            return Error.validation_layer_unavailible;
        }

        var vk_instance_create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &settings.app_info,
            .enabledLayerCount = 0,
        };

        const extensions = try getRequiredExtensions(alloc, settings.enable_validation_layers);
        defer alloc.free(extensions);
        vk_instance_create_info.enabledExtensionCount = @intCast(extensions.len);
        vk_instance_create_info.ppEnabledExtensionNames = extensions.ptr;

        var debug_create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
        if (settings.enable_validation_layers) {
            vk_instance_create_info.enabledLayerCount = @intCast(validation_layers.len);
            vk_instance_create_info.ppEnabledLayerNames = validation_layers.ptr;

            v_common.populateDebugMessengerCreateInfo(&debug_create_info);
            vk_instance_create_info.pNext = @ptrCast(&debug_create_info);
        } else {
            vk_instance_create_info.enabledLayerCount = 0;

            vk_instance_create_info.pNext = null;
        }

        const result = c.vkCreateInstance(&vk_instance_create_info, null, &instance.vk_instance);
        if (result != c.VK_SUCCESS) {
            return Error.instance_creation_failed;
        }

        // ------------------------ Debug Messenger -------------------------
        if (common.enable_validation_layers) {
            var debug_messenger_create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
            v_common.populateDebugMessengerCreateInfo(&debug_messenger_create_info);

            if (createDebugUtilsMessengerEXT(instance.vk_instance, &debug_messenger_create_info, null, &instance.debug_messenger) != c.VK_SUCCESS) {
                return Error.debug_messenger_setup_failed;
            }
        }

        // ------------------------ Surface ---------------------------------
        if (c.glfwCreateWindowSurface(instance.vk_instance, window, null, &instance.surface) != c.VK_SUCCESS) {
            return Error.window_surface_creation_failed;
        }

        // ----------------------- Physical Device ---------------------------
        var device_count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(instance.vk_instance, &device_count, null);

        if (device_count == 0) {
            return Error.gpu_with_vulkan_support_not_found;
        }

        const devices = try alloc.alloc(c.VkPhysicalDevice, device_count);
        defer alloc.free(devices);
        _ = c.vkEnumeratePhysicalDevices(instance.vk_instance, &device_count, devices.ptr);

        for (devices) |device| {
            if (try deviceIsSuitable(device, alloc, instance.surface)) {
                instance.physical_device = device;
                break;
            }
        } else {
            return Error.suitable_gpu_not_found;
        }

        // ----------------- Logical Device ------------------------------------

        const indicies = try v_common.findQueueFamilies(instance.physical_device, alloc, instance.surface);

        var unique_queue_families: [2]u32 = .{ indicies.graphics_compute_family.?, indicies.present_family.? };
        var unique_queue_num: u32 = 0;

        outer: for (unique_queue_families) |queue_family| {
            for (unique_queue_families[0..unique_queue_num]) |existing_unique_queue_family| {
                if (existing_unique_queue_family == queue_family) continue :outer;
            }
            unique_queue_families[unique_queue_num] = queue_family;
            unique_queue_num += 1;
        }

        const queue_create_infos = try alloc.alloc(c.VkDeviceQueueCreateInfo, unique_queue_num);
        defer alloc.free(queue_create_infos);

        const queue_priority: f32 = 1;
        for (unique_queue_families[0..unique_queue_num], queue_create_infos) |queue_family, *queue_create_info| {
            queue_create_info.* = .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = queue_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
        }

        const device_features: c.VkPhysicalDeviceFeatures = .{};

        var createInfo: c.VkDeviceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pQueueCreateInfos = queue_create_infos.ptr,
            .queueCreateInfoCount = unique_queue_num,
            .pEnabledFeatures = &device_features,
            .ppEnabledExtensionNames = &common.device_extensions,
            .enabledExtensionCount = @intCast(common.device_extensions.len),
        };

        if (common.enable_validation_layers) {
            createInfo.enabledLayerCount = @intCast(common.validation_layers.len);
            createInfo.ppEnabledLayerNames = &common.validation_layers;
        } else {
            createInfo.enabledLayerCount = 0;
        }

        if (c.vkCreateDevice(instance.physical_device, &createInfo, null, &instance.logical_device) != c.VK_SUCCESS) {
            return Error.logical_device_creation_failed;
        }

        c.vkGetDeviceQueue(instance.logical_device, indicies.graphics_compute_family.?, 0, &instance.graphics_compute_queue);
        c.vkGetDeviceQueue(instance.logical_device, indicies.present_family.?, 0, &instance.present_queue);
        return instance;
    }
};

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

fn deviceIsSuitable(device: c.VkPhysicalDevice, alloc: Allocator, surface: c.VkSurfaceKHR) Allocator.Error!bool {
    const indices = try v_common.findQueueFamilies(device, alloc, surface);

    const extensions_supported: bool = try checkDeviceExtensionSupport(device, alloc);

    var swap_chain_adequate: bool = false;
    if (extensions_supported) {
        const swap_chain_support = try v_common.querySwapChainSupport(surface, device, alloc);
        defer alloc.free(swap_chain_support.presentModes);
        defer alloc.free(swap_chain_support.formats);
        swap_chain_adequate = (swap_chain_support.formats.len != 0) and (swap_chain_support.presentModes.len != 0);
    }

    return indices.isComplete() and extensions_supported and swap_chain_adequate;
}

fn checkDeviceExtensionSupport(device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    var extension_count: u32 = undefined;
    _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);

    const availibleExtensions = try alloc.alloc(c.VkExtensionProperties, extension_count);
    defer alloc.free(availibleExtensions);
    _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, availibleExtensions.ptr);

    outer: for (common.device_extensions) |extension| {
        for (availibleExtensions) |availible| {
            if (common.str_eq(extension, @ptrCast(&availible.extensionName))) continue :outer;
        }
        return false;
    }

    return true;
}
