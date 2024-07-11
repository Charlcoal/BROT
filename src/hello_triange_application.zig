const glfw = @import("imports.zig").glfw;
const std = @import("std");
const builtin = @import("builtin");
const dbg = builtin.mode == std.builtin.Mode.Debug;
const enable_validation_layers = dbg;

const InitWindowError = error{create_window_failed};
const InitVulkanError = error{
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
pub const Error = InitWindowError || InitVulkanError;

const Allocator = std.mem.Allocator;

const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

const device_extensions = [_][*:0]const u8{
    glfw.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};

const SwapChainSupportDetails = struct {
    capabilities: glfw.VkSurfaceCapabilitiesKHR,
    formats: []glfw.VkSurfaceFormatKHR,
    presentModes: []glfw.VkPresentModeKHR,
};

//result of following OOP-based tutorial, change in future
const AppData = struct {
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

pub fn run(alloc: Allocator) Error!void {
    var app_data = AppData{
        .width = 800,
        .height = 600,
        .window = undefined,
        .instance = null,
        .debug_messenger = null,
        .surface = null,
        .physical_device = null,
        .device = null,
        .graphics_queue = null,
        .present_queue = null,
        .swap_chain = null,
        .swap_chain_images = undefined,
        .swap_chain_image_format = undefined,
        .swap_chain_extent = undefined,
        .swap_chain_image_views = undefined,
    };

    try initWindow(&app_data);
    try initVulkan(&app_data, alloc);
    mainLoop(app_data);
    cleanup(app_data, alloc);
}

fn initWindow(data: *AppData) InitWindowError!void {
    _ = glfw.glfwInit();

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE);

    data.window = glfw.glfwCreateWindow(data.width, data.height, "Vulkan", null, null) orelse return InitWindowError.create_window_failed;
}

fn initVulkan(data: *AppData, alloc: Allocator) InitVulkanError!void {
    try createInstance(data, alloc);
    try setupDebugMessenger(data);
    try createSurface(data);
    try pickPhysicalDevice(data, alloc);
    try createLogicalDevice(data, alloc);
    try createSwapChain(data, alloc);
    try createImageViews(data, alloc);
}

fn mainLoop(data: AppData) void {
    while (glfw.glfwWindowShouldClose(data.window) == 0) {
        glfw.glfwPollEvents();
    }
}

fn cleanup(data: AppData, alloc: Allocator) void {
    for (data.swap_chain_image_views) |view| {
        glfw.vkDestroyImageView(data.device, view, null);
    }
    alloc.free(data.swap_chain_image_views);

    glfw.vkDestroySwapchainKHR(data.device, data.swap_chain, null);
    alloc.free(data.swap_chain_images);

    glfw.vkDestroyDevice(data.device, null);

    if (enable_validation_layers) {
        destroyDebugUtilsMessengerEXT(data.instance, data.debug_messenger, null);
    }

    glfw.vkDestroySurfaceKHR(data.instance, data.surface, null);
    glfw.vkDestroyInstance(data.instance, null);
    glfw.glfwDestroyWindow(data.window);
    glfw.glfwTerminate();
}

fn str_eq(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return true;
    }
    return false;
}

fn checkValidationLayerSupport(alloc: Allocator) Allocator.Error!bool {
    var layer_count: u32 = undefined;
    _ = glfw.vkEnumerateInstanceLayerProperties(&layer_count, null);

    const availible_layers = try alloc.alloc(glfw.VkLayerProperties, layer_count);
    defer alloc.free(availible_layers);
    _ = glfw.vkEnumerateInstanceLayerProperties(&layer_count, availible_layers.ptr);

    for (validation_layers) |v_layer| {
        var layer_found: bool = false;

        for (availible_layers) |a_layer| {
            if (str_eq(v_layer, @as([*:0]const u8, @ptrCast(&a_layer.layerName)))) {
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

    const out = try alloc.alloc([*c]const u8, glfw_extension_count + if (enable_validation_layers) 1 else 0);
    for (0..glfw_extension_count) |i| {
        out[i] = glfw_extensions[i];
    }
    if (enable_validation_layers) {
        out[glfw_extension_count] = glfw.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    }

    return out;
}

fn CreateDebugUtilsMessengerEXT(
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

fn destroyDebugUtilsMessengerEXT(
    instance: glfw.VkInstance,
    debug_messenger: glfw.VkDebugUtilsMessengerEXT,
    p_vulkan_alloc: [*c]const glfw.VkAllocationCallbacks,
) void {
    const func: glfw.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(glfw.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT"));
    if (func) |fptr| {
        fptr(
            instance,
            debug_messenger,
            p_vulkan_alloc,
        );
    }
}

fn querySwapChainSupport(surface: glfw.VkSurfaceKHR, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!SwapChainSupportDetails {
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

fn createSwapChain(data: *AppData, alloc: Allocator) InitVulkanError!void {
    const swap_chain_support = try querySwapChainSupport(data.surface, data.physical_device, alloc);
    defer alloc.free(swap_chain_support.formats);
    defer alloc.free(swap_chain_support.presentModes);

    const surface_format = chooseSwapSurfaceFormat(swap_chain_support.formats);
    const present_mode = chooseSwapPresentMode(swap_chain_support.presentModes);
    const extent = chooseSwapExtent(data.*, &swap_chain_support.capabilities);

    var image_count: u32 = swap_chain_support.capabilities.minImageCount + 1;
    if (swap_chain_support.capabilities.maxImageCount > 0 and image_count > swap_chain_support.capabilities.maxImageCount) {
        image_count = swap_chain_support.capabilities.maxImageCount;
    }

    var create_info: glfw.VkSwapchainCreateInfoKHR = .{
        .sType = glfw.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = data.surface,
        .minImageCount = image_count,
        .imageFormat = surface_format.format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = glfw.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = swap_chain_support.capabilities.currentTransform,
        .compositeAlpha = glfw.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = glfw.VK_TRUE,
    };

    const indices = try findQueueFamilies(data.*, data.physical_device, alloc);
    const queue_family_indices = [_]u32{ indices.graphics_family.?, indices.present_family.? };

    if (indices.graphics_family != indices.present_family) {
        create_info.imageSharingMode = glfw.VK_SHARING_MODE_CONCURRENT;
        create_info.queueFamilyIndexCount = 2;
        create_info.pQueueFamilyIndices = &queue_family_indices;
    } else {
        create_info.imageSharingMode = glfw.VK_SHARING_MODE_EXCLUSIVE;
        create_info.queueFamilyIndexCount = 0;
        create_info.pQueueFamilyIndices = null;
        create_info.oldSwapchain = @ptrCast(glfw.VK_NULL_HANDLE);
    }

    if (glfw.vkCreateSwapchainKHR(data.device, &create_info, null, &data.swap_chain) != glfw.VK_SUCCESS) {
        return InitVulkanError.failed_to_create_swap_chain;
    }

    _ = glfw.vkGetSwapchainImagesKHR(data.device, data.swap_chain, &image_count, null);
    data.swap_chain_images = try alloc.alloc(glfw.VkImage, image_count);
    _ = glfw.vkGetSwapchainImagesKHR(data.device, data.swap_chain, &image_count, data.swap_chain_images.ptr);

    data.swap_chain_image_format = surface_format.format;
    data.swap_chain_extent = extent;
}

fn createImageViews(data: *AppData, alloc: Allocator) InitVulkanError!void {
    data.swap_chain_image_views = try alloc.alloc(glfw.VkImageView, data.swap_chain_images.len);

    for (data.swap_chain_images, 0..) |image, i| {
        const create_info: glfw.VkImageViewCreateInfo = .{
            .sType = glfw.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = glfw.VK_IMAGE_VIEW_TYPE_2D,
            .format = data.swap_chain_image_format,
            .components = .{
                .r = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = glfw.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        if (glfw.vkCreateImageView(data.device, &create_info, null, &data.swap_chain_image_views[i]) != glfw.VK_SUCCESS) {
            return InitVulkanError.failde_to_create_image_views;
        }
    }
}

const QueueFamilyIndices = struct {
    graphics_family: ?u32,
    present_family: ?u32,

    fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_family != null and self.present_family != null;
    }
};

fn findQueueFamilies(data: AppData, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!QueueFamilyIndices {
    var indices = QueueFamilyIndices{
        .graphics_family = null,
        .present_family = null,
    };

    var queue_family_count: u32 = 0;
    _ = glfw.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try alloc.alloc(glfw.VkQueueFamilyProperties, queue_family_count);
    defer alloc.free(queue_families);
    _ = glfw.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queueFamily, i| {
        if (queueFamily.queueFlags & glfw.VK_QUEUE_GRAPHICS_BIT != 0) {
            indices.graphics_family = @intCast(i);
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

fn chooseSwapSurfaceFormat(availible_formats: []const glfw.VkSurfaceFormatKHR) glfw.VkSurfaceFormatKHR {
    for (availible_formats) |format| {
        if (format.format == glfw.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == glfw.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return format;
        }
    }

    return availible_formats[0];
}

fn chooseSwapPresentMode(availible_present_modes: []const glfw.VkPresentModeKHR) glfw.VkPresentModeKHR {
    for (availible_present_modes) |mode| {
        if (mode == glfw.VK_PRESENT_MODE_MAILBOX_KHR) {
            return mode;
        }
    }

    //always availible
    return glfw.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(data: AppData, capabilities: *const glfw.VkSurfaceCapabilitiesKHR) glfw.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    } else {
        var height: c_int = undefined;
        var width: c_int = undefined;
        glfw.glfwGetFramebufferSize(data.window, &width, &height);

        var actualExtent: glfw.VkExtent2D = .{
            .height = @intCast(height),
            .width = @intCast(width),
        };

        actualExtent.width = std.math.clamp(
            actualExtent.width,
            capabilities.minImageExtent.width,
            capabilities.maxImageExtent.width,
        );
        actualExtent.height = std.math.clamp(
            actualExtent.height,
            capabilities.minImageExtent.height,
            capabilities.maxImageExtent.height,
        );

        return actualExtent;
    }
}

fn deviceIsSuitable(data: AppData, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    const indices = try findQueueFamilies(data, device, alloc);

    const extensions_supported: bool = try checkDeviceExtensionSupport(device, alloc);

    var swap_chain_adequate: bool = false;
    if (extensions_supported) {
        const swap_chain_support = try querySwapChainSupport(data.surface, device, alloc);
        defer alloc.free(swap_chain_support.presentModes);
        defer alloc.free(swap_chain_support.formats);
        swap_chain_adequate = (swap_chain_support.formats.len != 0) and (swap_chain_support.presentModes.len != 0);
    }

    return indices.isComplete() and extensions_supported and swap_chain_adequate;
}

fn checkDeviceExtensionSupport(device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    var extension_count: u32 = undefined;
    _ = glfw.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);

    const availibleExtensions = try alloc.alloc(glfw.VkExtensionProperties, extension_count);
    defer alloc.free(availibleExtensions);
    _ = glfw.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, availibleExtensions.ptr);

    outer: for (device_extensions) |extension| {
        for (availibleExtensions) |availible| {
            if (str_eq(extension, @ptrCast(&availible.extensionName))) continue :outer;
        }
        return false;
    }

    return true;
}

fn pickPhysicalDevice(data: *AppData, alloc: Allocator) InitVulkanError!void {
    var device_count: u32 = 0;
    _ = glfw.vkEnumeratePhysicalDevices(data.instance, &device_count, null);

    if (device_count == 0) {
        return InitVulkanError.failed_to_find_gpu_with_vulkan_support;
    }

    const devices = try alloc.alloc(glfw.VkPhysicalDevice, device_count);
    defer alloc.free(devices);
    _ = glfw.vkEnumeratePhysicalDevices(data.instance, &device_count, devices.ptr);

    for (devices) |device| {
        if (try deviceIsSuitable(data.*, device, alloc)) {
            data.physical_device = device;
            break;
        }
    } else {
        return InitVulkanError.failed_to_find_suitable_gpu;
    }
}

fn createLogicalDevice(data: *AppData, alloc: Allocator) InitVulkanError!void {
    const indicies = try findQueueFamilies(data.*, data.physical_device, alloc);

    var unique_queue_families: [2]u32 = .{ indicies.graphics_family.?, indicies.present_family.? };
    var unique_queue_num: u32 = 0;

    outer: for (unique_queue_families) |queue_family| {
        for (unique_queue_families[0..unique_queue_num]) |existing_unique_queue_family| {
            if (existing_unique_queue_family == queue_family) continue :outer;
        }
        unique_queue_families[unique_queue_num] = queue_family;
        unique_queue_num += 1;
    }

    const queue_create_infos = try alloc.alloc(glfw.VkDeviceQueueCreateInfo, unique_queue_num);
    defer alloc.free(queue_create_infos);

    const queue_priority: f32 = 1;
    for (unique_queue_families[0..unique_queue_num], queue_create_infos) |queue_family, *queue_create_info| {
        queue_create_info.* = .{
            .sType = glfw.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
    }

    const device_features: glfw.VkPhysicalDeviceFeatures = .{};

    var createInfo: glfw.VkDeviceCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pQueueCreateInfos = queue_create_infos.ptr,
        .queueCreateInfoCount = unique_queue_num,
        .pEnabledFeatures = &device_features,
        .ppEnabledExtensionNames = &device_extensions,
        .enabledExtensionCount = @intCast(device_extensions.len),
    };

    if (enable_validation_layers) {
        createInfo.enabledLayerCount = @intCast(validation_layers.len);
        createInfo.ppEnabledLayerNames = &validation_layers;
    } else {
        createInfo.enabledLayerCount = 0;
    }

    if (glfw.vkCreateDevice(data.physical_device, &createInfo, null, &data.device) != glfw.VK_SUCCESS) {
        return InitVulkanError.failed_to_create_logical_device;
    }

    glfw.vkGetDeviceQueue(data.device, indicies.graphics_family.?, 0, &data.graphics_queue);
    glfw.vkGetDeviceQueue(data.device, indicies.present_family.?, 0, &data.present_queue);
}

fn populateDebugMessengerCreateInfo(create_info: *glfw.VkDebugUtilsMessengerCreateInfoEXT) void {
    create_info.* = glfw.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = glfw.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
        .messageType = glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
}

fn setupDebugMessenger(data: *AppData) InitVulkanError!void {
    if (!enable_validation_layers) return;

    var create_info: glfw.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    populateDebugMessengerCreateInfo(&create_info);

    if (CreateDebugUtilsMessengerEXT(data.instance, &create_info, null, &data.debug_messenger) != glfw.VK_SUCCESS) {
        return InitVulkanError.debug_messenger_setup_failed;
    }
}

fn createSurface(data: *AppData) InitVulkanError!void {
    if (glfw.glfwCreateWindowSurface(data.instance, data.window, null, &data.surface) != glfw.VK_SUCCESS) {
        return InitVulkanError.failed_to_create_window_surface;
    }
}

fn createInstance(data: *AppData, alloc: Allocator) InitVulkanError!void {
    if (enable_validation_layers and !try checkValidationLayerSupport(alloc)) {
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
    if (enable_validation_layers) {
        create_info.enabledLayerCount = validation_layers.len;
        create_info.ppEnabledLayerNames = &validation_layers;

        populateDebugMessengerCreateInfo(&debug_create_info);
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
