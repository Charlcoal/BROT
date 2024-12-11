const std = @import("std");
const common = @import("common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

pub fn cleanup(data: *common.AppData, alloc: Allocator) void {
    //vulkan

    data.screen_rend.deinit(data.inst, alloc);
    data.ubo.deinit(data.inst, alloc);
    data.descriptor_set.deinit(data.inst, alloc);

    for (data.image_availible_semaphores, data.render_finished_semaphores, data.in_flight_fences) |im_sem, rend_sem, fence| {
        c.vkDestroySemaphore(data.inst.logical_device, im_sem, null);
        c.vkDestroySemaphore(data.inst.logical_device, rend_sem, null);
        c.vkDestroyFence(data.inst.logical_device, fence, null);
    }
    alloc.free(data.image_availible_semaphores);
    alloc.free(data.render_finished_semaphores);
    alloc.free(data.in_flight_fences);

    data.inst.deinit();

    //glfw
    c.glfwDestroyWindow(data.window);
    c.glfwTerminate();
}

fn destroyDebugUtilsMessengerEXT(
    instance: c.VkInstance,
    debug_messenger: c.VkDebugUtilsMessengerEXT,
    p_vulkan_alloc: [*c]const c.VkAllocationCallbacks,
) void {
    const func: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT"));
    if (func) |fptr| {
        fptr(
            instance,
            debug_messenger,
            p_vulkan_alloc,
        );
    }
}
