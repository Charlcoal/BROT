const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn pickPhysicalDevice(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    var device_count: u32 = 0;
    _ = glfw.vkEnumeratePhysicalDevices(data.instance, &device_count, null);

    if (device_count == 0) {
        return InitVulkanError.gpu_with_vulkan_support_not_found;
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
        return InitVulkanError.suitable_gpu_not_found;
    }
}

fn deviceIsSuitable(data: common.AppData, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    const indices = try v_common.findQueueFamilies(data, device, alloc);

    const extensions_supported: bool = try checkDeviceExtensionSupport(device, alloc);

    var swap_chain_adequate: bool = false;
    if (extensions_supported) {
        const swap_chain_support = try v_common.querySwapChainSupport(data.surface, device, alloc);
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

    outer: for (common.device_extensions) |extension| {
        for (availibleExtensions) |availible| {
            if (common.str_eq(extension, @ptrCast(&availible.extensionName))) continue :outer;
        }
        return false;
    }

    return true;
}
