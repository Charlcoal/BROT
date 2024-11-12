const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createLogicalDevice(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const indicies = try v_common.findQueueFamilies(data.*, data.physical_device, alloc);

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

    if (c.vkCreateDevice(data.physical_device, &createInfo, null, &data.device) != c.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    c.vkGetDeviceQueue(data.device, indicies.graphics_compute_family.?, 0, &data.graphics_compute_queue);
    c.vkGetDeviceQueue(data.device, indicies.present_family.?, 0, &data.present_queue);
}
