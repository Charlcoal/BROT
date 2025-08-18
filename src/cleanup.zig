const std = @import("std");
const common = @import("common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

pub fn cleanupSwapChain(data: common.AppData, alloc: Allocator) void {
    for (data.swap_chain_framebuffers) |framebuffer| {
        glfw.vkDestroyFramebuffer(data.device, framebuffer, null);
    }
    alloc.free(data.swap_chain_framebuffers);

    for (data.swap_chain_image_views) |view| {
        glfw.vkDestroyImageView(data.device, view, null);
    }
    alloc.free(data.swap_chain_image_views);

    glfw.vkDestroySwapchainKHR(data.device, data.swap_chain, null);
    alloc.free(data.swap_chain_images);
}

pub fn cleanup(data: common.AppData, alloc: Allocator) void {
    //vulkan
    for (0..common.max_frames_in_flight) |i| {
        glfw.vkDestroySemaphore(data.device, data.image_availible_semaphores[i], null);
    }
    glfw.vkDestroyFence(data.device, data.in_flight_fence, null);
    glfw.vkDestroyFence(data.device, data.compute_fence, null);
    for (data.render_finished_semaphores) |sem| {
        glfw.vkDestroySemaphore(data.device, sem, null);
    }
    alloc.free(data.image_availible_semaphores);
    alloc.free(data.render_finished_semaphores);

    glfw.vkDestroyCommandPool(data.device, data.command_pool, null);

    cleanupSwapChain(data, alloc);

    glfw.vkDestroyBuffer(data.device, data.uniform_buffer, null);
    glfw.vkFreeMemory(data.device, data.uniform_buffer_memory, null);

    glfw.vkDestroyBuffer(data.device, data.storage_buffer, null);
    glfw.vkFreeMemory(data.device, data.storage_buffer_memory, null);

    glfw.vkDestroyDescriptorPool(data.device, data.descriptor_pool, null);
    glfw.vkDestroyDescriptorSetLayout(data.device, data.descriptor_set_layout, null);

    glfw.vkDestroyPipeline(data.device, data.graphics_pipeline, null);
    glfw.vkDestroyPipeline(data.device, data.compute_pipeline, null);
    glfw.vkDestroyPipelineLayout(data.device, data.pipeline_layout, null);
    glfw.vkDestroyPipelineLayout(data.device, data.compute_pipeline_layout, null);

    glfw.vkDestroyRenderPass(data.device, data.render_pass, null);

    glfw.vkDestroyDevice(data.device, null);

    if (common.enable_validation_layers) {
        destroyDebugUtilsMessengerEXT(data.instance, data.debug_messenger, null);
    }

    glfw.vkDestroySurfaceKHR(data.instance, data.surface, null);
    glfw.vkDestroyInstance(data.instance, null);

    // ---------------------------------------------------------------------------------------------

    //glfw
    glfw.glfwDestroyWindow(data.window);
    glfw.glfwTerminate();
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
