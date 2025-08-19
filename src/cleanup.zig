const std = @import("std");
const common = @import("common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

pub fn cleanupSwapChain(data: common.AppData, alloc: Allocator) void {
    for (data.swap_chain_framebuffers) |framebuffer| {
        c.vkDestroyFramebuffer(data.device, framebuffer, null);
    }
    alloc.free(data.swap_chain_framebuffers);

    for (data.swap_chain_image_views) |view| {
        c.vkDestroyImageView(data.device, view, null);
    }
    alloc.free(data.swap_chain_image_views);

    c.vkDestroySwapchainKHR(data.device, data.swap_chain, null);
    alloc.free(data.swap_chain_images);
}

pub fn cleanup(data: *common.AppData, alloc: Allocator) void {
    data.compute_manager_should_close = true;
    data.compute_manager_thread.join();
    //vulkan
    for (0..data.swap_chain_images.len) |i| {
        c.vkDestroySemaphore(data.device, data.image_availible_semaphores[i], null);
    }
    c.vkDestroyFence(data.device, data.in_flight_fence, null);
    c.vkDestroyFence(data.device, data.compute_fence, null);
    for (data.render_finished_semaphores) |sem| {
        c.vkDestroySemaphore(data.device, sem, null);
    }
    alloc.free(data.image_availible_semaphores);
    alloc.free(data.render_finished_semaphores);

    c.vkDestroyCommandPool(data.device, data.command_pool, null);

    cleanupSwapChain(data.*, alloc);

    c.vkDestroyBuffer(data.device, data.uniform_buffer, null);
    c.vkFreeMemory(data.device, data.uniform_buffer_memory, null);

    c.vkDestroyBuffer(data.device, data.storage_buffer, null);
    c.vkFreeMemory(data.device, data.storage_buffer_memory, null);

    c.vkDestroyDescriptorPool(data.device, data.descriptor_pool, null);
    c.vkDestroyDescriptorSetLayout(data.device, data.descriptor_set_layout, null);

    c.vkDestroyPipeline(data.device, data.graphics_pipeline, null);
    c.vkDestroyPipeline(data.device, data.compute_pipeline, null);
    c.vkDestroyPipelineLayout(data.device, data.pipeline_layout, null);
    c.vkDestroyPipelineLayout(data.device, data.compute_pipeline_layout, null);

    c.vkDestroyRenderPass(data.device, data.render_pass, null);

    c.vkDestroyDevice(data.device, null);

    if (common.enable_validation_layers) {
        destroyDebugUtilsMessengerEXT(data.instance, data.debug_messenger, null);
    }

    c.vkDestroySurfaceKHR(data.instance, data.surface, null);
    c.vkDestroyInstance(data.instance, null);

    // ---------------------------------------------------------------------------------------------

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
