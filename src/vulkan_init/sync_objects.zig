const instance = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub const Error = error{ semaphore_creation_failed, fence_creation_failed } || Allocator.Error;

pub fn createSemaphores(inst: instance.Instance, alloc: Allocator, num: usize) Error![]c.VkSemaphore {
    var out = try alloc.alloc(c.VkSemaphore, num);

    const semaphore_info: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    for (0..num) |i| {
        if (c.vkCreateSemaphore(inst.logical_device, &semaphore_info, null, &out[i]) != c.VK_SUCCESS) {
            return Error.semaphore_creation_failed;
        }
    }

    return out;
}

pub fn createFences(inst: instance.Instance, alloc: Allocator, num: usize) Error![]c.VkFence {
    var out = try alloc.alloc(c.VkFence, num);

    const fence_info: c.VkFenceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    for (0..num) |i| {
        if (c.vkCreateFence(inst.logical_device, &fence_info, null, &out[i]) != c.VK_SUCCESS) {
            return Error.fence_creation_failed;
        }
    }

    return out;
}

pub fn createSyncObjects(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.image_availible_semaphores = try alloc.alloc(c.VkSemaphore, common.max_frames_in_flight);
    data.render_finished_semaphores = try alloc.alloc(c.VkSemaphore, common.max_frames_in_flight);
    data.in_flight_fences = try alloc.alloc(c.VkFence, common.max_frames_in_flight);

    const semaphore_info: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fence_info: c.VkFenceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    for (0..common.max_frames_in_flight) |i| {
        if (c.vkCreateSemaphore(data.device, &semaphore_info, null, &data.image_availible_semaphores[i]) != c.VK_SUCCESS or
            c.vkCreateSemaphore(data.device, &semaphore_info, null, &data.render_finished_semaphores[i]) != c.VK_SUCCESS or
            c.vkCreateFence(data.device, &fence_info, null, &data.in_flight_fences[i]) != c.VK_SUCCESS)
        {
            return InitVulkanError.semaphore_creation_failed;
        }
    }
}
