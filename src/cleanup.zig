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

pub fn cleanupSwapChain(alloc: Allocator) void {
    for (common.swap_chain_framebuffers) |framebuffer| {
        c.vkDestroyFramebuffer(common.device, framebuffer, null);
    }
    alloc.free(common.swap_chain_framebuffers);

    for (common.swap_chain_image_views) |view| {
        c.vkDestroyImageView(common.device, view, null);
    }
    alloc.free(common.swap_chain_image_views);

    c.vkDestroySwapchainKHR(common.device, common.swap_chain, null);
    alloc.free(common.swap_chain_images);
}

pub fn cleanup(alloc: Allocator) void {
    common.compute_manager_should_close = true;
    common.compute_manager_thread.join();
    //vulkan
    for (0..common.max_frames_in_flight) |i| {
        c.vkDestroySemaphore(common.device, common.image_availible_semaphores[i], null);
        c.vkDestroyFence(common.device, common.in_flight_fences[i], null);
    }
    for (common.compute_fences) |fence| {
        c.vkDestroyFence(common.device, fence, null);
    }

    for (common.render_finished_semaphores) |sem| {
        c.vkDestroySemaphore(common.device, sem, null);
    }
    alloc.free(common.image_availible_semaphores);
    alloc.free(common.render_finished_semaphores);
    alloc.free(common.in_flight_fences);

    c.vkDestroyCommandPool(common.device, common.graphics_command_pool, null);
    c.vkDestroyCommandPool(common.device, common.compute_command_pool, null);
    alloc.free(common.graphics_command_buffers);

    cleanupSwapChain(alloc);

    c.vkDestroyBuffer(common.device, common.escape_potential_buffer, null);
    c.vkFreeMemory(common.device, common.escape_potential_buffer_memory, null);

    c.vkDestroyBuffer(common.device, common.perturbation_buffer, null);
    c.vkFreeMemory(common.device, common.perturbation_buffer_memory, null);

    c.vkDestroyBuffer(common.device, common.perturbation_staging_buffer, null);
    c.vkFreeMemory(common.device, common.perturbation_staging_buffer_memory, null);

    c.vkDestroyDescriptorPool(common.device, common.descriptor_pool, null);
    c.vkDestroyDescriptorSetLayout(common.device, common.descriptor_set_layout, null);
    alloc.free(common.descriptor_sets);

    c.vkDestroyPipeline(common.device, common.graphics_pipeline, null);
    c.vkDestroyPipeline(common.device, common.compute_pipeline, null);
    c.vkDestroyPipelineLayout(common.device, common.render_pipeline_layout, null);
    c.vkDestroyPipelineLayout(common.device, common.compute_pipeline_layout, null);

    c.vkDestroyRenderPass(common.device, common.render_pass, null);

    c.vkDestroyDevice(common.device, null);

    if (common.enable_validation_layers) {
        destroyDebugUtilsMessengerEXT(common.instance, common.debug_messenger, null);
    }

    c.vkDestroySurfaceKHR(common.instance, common.surface, null);
    c.vkDestroyInstance(common.instance, null);

    // ---------------------------------------------------------------------------------------------

    // glfw
    c.glfwDestroyWindow(common.window);
    c.glfwTerminate();

    // gmp
    c.mpf_clear(&common.fractal_pos_x);
    c.mpf_clear(&common.fractal_pos_y);
    c.mpf_clear(&common.ref_calc_x);
    c.mpf_clear(&common.ref_calc_y);
    for (&common.mpf_intermediates) |*intermediate| {
        c.mpf_clear(intermediate);
    }

    alloc.free(common.perturbation_vals);
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
