// BROT - A fast mandelbrot set explorer
// Copyright (C) 2025 - 2026 Charles Reischer
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

pub fn cleanupSwapChain(alloc: Allocator) void {
    for (common.swap_chain_framebuffers) |framebuffer| {
        vulkan.device.destroyFramebuffer(framebuffer, null);
    }
    alloc.free(common.swap_chain_framebuffers);

    for (common.swap_chain_image_views) |view| {
        vulkan.device.destroyImageView(view, null);
    }
    alloc.free(common.swap_chain_image_views);

    vulkan.device.destroySwapchainKHR(common.swap_chain, null);
    alloc.free(common.swap_chain_images);
}

pub fn cleanup(alloc: Allocator, io: std.Io) void {
    common.compute_manager_should_close = true;
    common.compute_manager_future.await(io) catch {};

    gui.deinit();

    // vulkan
    for (0..vulkan.max_frames_in_flight) |i| {
        vulkan.device.destroySemaphore(common.image_availible_semaphores[i], null);
        vulkan.device.destroyFence(common.in_flight_fences[i], null);
    }
    for (common.rendering_fences) |fence| {
        vulkan.device.destroyFence(fence, null);
    }
    vulkan.device.destroyFence(common.render_buffer_write_fence, null);

    for (common.render_finished_semaphores) |sem| {
        vulkan.device.destroySemaphore(sem, null);
    }
    alloc.free(common.image_availible_semaphores);
    alloc.free(common.render_finished_semaphores);
    alloc.free(common.in_flight_fences);

    vulkan.device.destroyCommandPool(common.graphics_command_pool, null);
    vulkan.device.destroyCommandPool(common.compute_command_pool, null);
    alloc.free(common.graphics_command_buffers);

    cleanupSwapChain(alloc);

    vulkan.device.destroyBuffer(common.render_patch_buffer, null);
    vulkan.device.freeMemory(common.render_patch_buffer_memory, null);

    vulkan.device.destroyBuffer(common.escape_potential_buffer, null);
    vulkan.device.freeMemory(common.escape_potential_buffer_memory, null);

    vulkan.device.destroyBuffer(common.back_r2c_buffer, null);
    vulkan.device.freeMemory(common.back_r2c_buffer_memory, null);

    vulkan.device.destroyBuffer(common.perturbation_buffer, null);
    vulkan.device.freeMemory(common.perturbation_buffer_memory, null);

    vulkan.device.destroyBuffer(common.perturbation_staging_buffer, null);
    vulkan.device.freeMemory(common.perturbation_staging_buffer_memory, null);

    vulkan.device.destroyDescriptorPool(common.descriptor_pool, null);
    vulkan.device.destroyDescriptorSetLayout(common.render_patch_descriptor_set_layout, null);
    vulkan.device.destroyDescriptorSetLayout(common.render_to_coloring_descriptor_set_layout, null);
    vulkan.device.destroyDescriptorSetLayout(common.cpu_to_render_descriptor_set_layout, null);

    vulkan.device.destroyPipeline(common.coloring_pipeline, null);
    vulkan.device.destroyPipeline(common.rendering_pipeline, null);
    vulkan.device.destroyPipeline(common.patch_place_pipeline, null);
    vulkan.device.destroyPipeline(common.buffer_remap_pipeline, null);
    vulkan.device.destroyPipelineLayout(common.coloring_pipeline_layout, null);
    vulkan.device.destroyPipelineLayout(common.rendering_pipeline_layout, null);
    vulkan.device.destroyPipelineLayout(common.patch_place_pipeline_layout, null);
    vulkan.device.destroyPipelineLayout(common.buffer_remap_pipeline_layout, null);

    vulkan.device.destroyRenderPass(vulkan.render_pass, null);

    vulkan.device.destroyDevice(null);
    alloc.destroy(vulkan.device.wrapper);

    if (vulkan.enable_validation_layers) {
        vulkan.instance.destroyDebugUtilsMessengerEXT(vulkan.debug_messenger, null);
    }

    vulkan.instance.destroySurfaceKHR(window.surface, null);
    vulkan.instance.destroyInstance(null);
    alloc.destroy(vulkan.instance.wrapper);

    // ---------------------------------------------------------------------------------------------

    // glfw
    c.glfwDestroyWindow(window.glfw);
    c.glfwTerminate();

    // gmp
    c.mpf_clear(&common.ref_calc_x);
    c.mpf_clear(&common.ref_calc_y);
    for (&common.mpf_intermediates) |*intermediate| {
        c.mpf_clear(intermediate);
    }

    alloc.free(common.perturbation_vals);
}

const std = @import("std");
const common = @import("common_defs.zig");
const window = @import("window.zig");
const vulkan = @import("vulkan.zig");
const gui = @import("gui.zig");
const c = @import("c");
const Allocator = std.mem.Allocator;
