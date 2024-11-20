const std = @import("std");
const builtin = @import("builtin");
const common = @import("../common_defs.zig");
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

pub const Instance = struct {
    vk_instance: c.VkInstance,
    debug_messenger: c.VkDebugUtilsMessengerEXT,
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    logical_device: c.VkDevice,
    graphics_compute_queue: c.VkQueue,
    present_queue: c.VkQueue,
    swap_chain_support: SwapChainSupportDetails,
    queue_family_indices: QueueFamilyIndices,

    const default_validation_layers: [1][*:0]const u8 = .{"VK_LAYER_KHRONOS_validation"};
    const default_device_extensions: [1][*:0]const u8 = .{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

    const QueueFamilyIndices = struct {
        graphics_compute_family: ?u32,
        present_family: ?u32,

        pub fn isComplete(self: QueueFamilyIndices) bool {
            return self.graphics_compute_family != null and self.present_family != null;
        }
    };

    const InitSettings = struct {
        enable_validation_layers: bool = builtin.mode == std.builtin.Mode.Debug,
        validation_layers: []const [*:0]const u8 = &default_validation_layers,
        device_extensions: []const [*:0]const u8 = &default_device_extensions,
        vk_app_info: c.VkApplicationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "BROT",
            .applicationVersion = c.VK_MAKE_API_VERSION(0, 1, 3, 0),
            .pEngineName = "No Engine",
            .engineVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0),
            .apiVersion = c.VK_API_VERSION_1_3,
        },
        debug_messenger_info: c.VkDebugUtilsMessengerCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
            .pfnUserCallback = debugCallback,
            .pUserData = null,
        },
    };

    pub fn init(alloc: Allocator, settings: InitSettings, window: *c.GLFWwindow) Error!Instance {
        var instance: Instance = .{
            .vk_instance = null,
            .debug_messenger = null,
            .surface = null,
            .physical_device = null,
            .logical_device = null,
            .graphics_compute_queue = null,
            .present_queue = null,
            .swap_chain_support = undefined,
            .queue_family_indices = undefined,
        };

        if (settings.enable_validation_layers and !try checkValidationLayerSupport(alloc, settings.validation_layers)) {
            return Error.validation_layer_unavailible;
        }

        try initVulkanInstance(&instance, alloc, settings);

        if (settings.enable_validation_layers) {
            if (createDebugUtilsMessengerEXT(instance.vk_instance, &settings.debug_messenger_info, null, &instance.debug_messenger) != c.VK_SUCCESS) {
                return Error.debug_messenger_setup_failed;
            }
        }

        if (c.glfwCreateWindowSurface(instance.vk_instance, window, null, &instance.surface) != c.VK_SUCCESS) {
            return Error.window_surface_creation_failed;
        }

        try choosePhysicalDevice(&instance, alloc, settings);
        try initLogicalDevice(&instance, alloc, settings);

        instance.swap_chain_support = try SwapChainSupportDetails.query(instance.surface, instance.physical_device, alloc);
        return instance;
    }

    fn initVulkanInstance(instance: *Instance, alloc: Allocator, settings: InitSettings) Error!void {
        var vk_instance_create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &settings.vk_app_info,
            .enabledLayerCount = 0,
        };

        const extensions = try getRequiredExtensions(alloc, settings.enable_validation_layers);
        defer alloc.free(extensions);
        vk_instance_create_info.enabledExtensionCount = @intCast(extensions.len);
        vk_instance_create_info.ppEnabledExtensionNames = extensions.ptr;

        if (settings.enable_validation_layers) {
            vk_instance_create_info.enabledLayerCount = @intCast(settings.validation_layers.len);
            vk_instance_create_info.ppEnabledLayerNames = settings.validation_layers.ptr;

            vk_instance_create_info.pNext = @ptrCast(&settings.debug_messenger_info);
        } else {
            vk_instance_create_info.enabledLayerCount = 0;

            vk_instance_create_info.pNext = null;
        }

        const result = c.vkCreateInstance(&vk_instance_create_info, null, &instance.vk_instance);
        if (result != c.VK_SUCCESS) {
            return Error.instance_creation_failed;
        }
    }

    fn choosePhysicalDevice(instance: *Instance, alloc: Allocator, settings: InitSettings) Error!void {
        var device_count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(instance.vk_instance, &device_count, null);

        if (device_count == 0) {
            return Error.gpu_with_vulkan_support_not_found;
        }

        const devices = try alloc.alloc(c.VkPhysicalDevice, device_count);
        defer alloc.free(devices);
        _ = c.vkEnumeratePhysicalDevices(instance.vk_instance, &device_count, devices.ptr);

        for (devices) |device| {
            if (try deviceIsSuitable(device, alloc, instance.surface, settings.device_extensions)) {
                instance.physical_device = device;
                break;
            }
        } else {
            return Error.suitable_gpu_not_found;
        }
    }

    fn initLogicalDevice(instance: *Instance, alloc: Allocator, settings: InitSettings) Error!void {
        instance.queue_family_indices = try findQueueFamilies(instance.physical_device, alloc, instance.surface);

        var unique_queue_families: [2]u32 = .{ instance.queue_family_indices.graphics_compute_family.?, instance.queue_family_indices.present_family.? };
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
            .ppEnabledExtensionNames = settings.device_extensions.ptr,
            .enabledExtensionCount = @intCast(settings.device_extensions.len),
        };

        if (settings.enable_validation_layers) {
            createInfo.enabledLayerCount = @intCast(settings.validation_layers.len);
            createInfo.ppEnabledLayerNames = settings.validation_layers.ptr;
        } else {
            createInfo.enabledLayerCount = 0;
        }

        if (c.vkCreateDevice(instance.physical_device, &createInfo, null, &instance.logical_device) != c.VK_SUCCESS) {
            return Error.logical_device_creation_failed;
        }

        c.vkGetDeviceQueue(instance.logical_device, instance.queue_family_indices.graphics_compute_family.?, 0, &instance.graphics_compute_queue);
        c.vkGetDeviceQueue(instance.logical_device, instance.queue_family_indices.present_family.?, 0, &instance.present_queue);
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

fn deviceIsSuitable(physical_device: c.VkPhysicalDevice, alloc: Allocator, surface: c.VkSurfaceKHR, device_extensions: []const [*:0]const u8) Allocator.Error!bool {
    const indices = try findQueueFamilies(physical_device, alloc, surface);

    const extensions_supported: bool = try checkDeviceExtensionSupport(physical_device, alloc, device_extensions);

    var swap_chain_adequate: bool = false;
    if (extensions_supported) {
        const swap_chain_support = try SwapChainSupportDetails.query(surface, physical_device, alloc);
        defer alloc.free(swap_chain_support.presentModes);
        defer alloc.free(swap_chain_support.formats);
        swap_chain_adequate = (swap_chain_support.formats.len != 0) and (swap_chain_support.presentModes.len != 0);
    }

    return indices.isComplete() and extensions_supported and swap_chain_adequate;
}

fn checkDeviceExtensionSupport(physical_device: c.VkPhysicalDevice, alloc: Allocator, device_extensions: []const [*:0]const u8) Allocator.Error!bool {
    var extension_count: u32 = undefined;
    _ = c.vkEnumerateDeviceExtensionProperties(physical_device, null, &extension_count, null);

    const availibleExtensions = try alloc.alloc(c.VkExtensionProperties, extension_count);
    defer alloc.free(availibleExtensions);
    _ = c.vkEnumerateDeviceExtensionProperties(physical_device, null, &extension_count, availibleExtensions.ptr);

    outer: for (device_extensions) |extension| {
        for (availibleExtensions) |availible| {
            if (common.str_eq(extension, @ptrCast(&availible.extensionName))) continue :outer;
        }
        return false;
    }

    return true;
}

fn debugCallback(
    message_severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: c.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.C) c.VkBool32 {
    if (message_severity >= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        std.debug.print("ERROR ", .{});
    } else if (message_severity >= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        std.debug.print("WARNING ", .{});
    }

    if (message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT != 0) {
        std.debug.print("[performance] ", .{});
    }
    if (message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT != 0) {
        std.debug.print("[validation] ", .{});
    }
    if (message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT != 0) {
        std.debug.print("[general] ", .{});
    }

    std.debug.print("{s}\n", .{p_callback_data.*.pMessage});
    _ = p_user_data;

    return c.VK_FALSE;
}

fn findQueueFamilies(device: c.VkPhysicalDevice, alloc: Allocator, surface: c.VkSurfaceKHR) Allocator.Error!Instance.QueueFamilyIndices {
    var indices = Instance.QueueFamilyIndices{
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

const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: []c.VkSurfaceFormatKHR,
    presentModes: []c.VkPresentModeKHR,
    alloc: Allocator,

    pub fn query(surface: c.VkSurfaceKHR, device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!SwapChainSupportDetails {
        var details: SwapChainSupportDetails = .{
            .formats = undefined,
            .capabilities = undefined,
            .presentModes = undefined,
            .alloc = alloc,
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

    pub fn deinit(this: *SwapChainSupportDetails) void {
        this.alloc.free(this.formats);
        this.alloc.free(this.presentModes);
    }
};
