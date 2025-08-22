// BROT - A fast mandelbrot set explorer
// Copyright (C) 2025  Charles Reischer
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

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
    for (0..common.max_frames_in_flight) |i| {
        c.vkDestroySemaphore(data.device, data.image_availible_semaphores[i], null);
        c.vkDestroyFence(data.device, data.in_flight_fences[i], null);
    }
    for (data.compute_fences) |fence| {
        c.vkDestroyFence(data.device, fence, null);
    }

    for (data.render_finished_semaphores) |sem| {
        c.vkDestroySemaphore(data.device, sem, null);
    }
    alloc.free(data.image_availible_semaphores);
    alloc.free(data.render_finished_semaphores);
    alloc.free(data.in_flight_fences);

    c.vkDestroyCommandPool(data.device, data.graphics_command_pool, null);
    c.vkDestroyCommandPool(data.device, data.compute_command_pool, null);
    alloc.free(data.graphics_command_buffers);

    cleanupSwapChain(data.*, alloc);

    c.vkDestroyBuffer(data.device, data.storage_buffer, null);
    c.vkFreeMemory(data.device, data.storage_buffer_memory, null);

    c.vkDestroyDescriptorPool(data.device, data.descriptor_pool, null);
    c.vkDestroyDescriptorSetLayout(data.device, data.descriptor_set_layout, null);
    alloc.free(data.descriptor_sets);

    c.vkDestroyPipeline(data.device, data.graphics_pipeline, null);
    c.vkDestroyPipeline(data.device, data.compute_pipeline, null);
    c.vkDestroyPipelineLayout(data.device, data.render_pipeline_layout, null);
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
