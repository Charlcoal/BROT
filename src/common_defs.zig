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
pub const c = @import("imports.zig").c;
const builtin = @import("builtin");

// ------------------- settings -------------------------

pub const enable_validation_layers = dbg;

pub const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

pub const device_extensions = [_][*:0]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};

pub const target_frame_rate: f64 = 60;
pub const max_frames_in_flight: u32 = 2;
const num_active_render_patches = 6;
const patch_buffer_factor = 4; // should be >= 3

// ------------------- program defs ---------------------

pub const dbg = builtin.mode == std.builtin.OptimizeMode.Debug;

pub const RenderingConstants = extern struct {
    center_screen_pos: @Vector(2, u32),
    screen_offset: @Vector(2, u32),
    height_scale_exp: i32,
    resolution_scale_exponent: i32,
    cur_height: u32,
};

pub const ColoringConstants = extern struct {
    cur_resolution: @Vector(2, u32),
    center_position: @Vector(2, u32),
    max_width: u32,
    zoom_diff: f32,
};

pub const PatchPlaceConstants = extern struct {
    buffer_offset: u32,
    max_width: u32,
    resolution_scale_exponent: i32,
};

pub const BufferRemapConstants = extern struct {
    dst_offset: @Vector(2, u32),
    src_offset: @Vector(2, u32),
    buf_size: @Vector(2, u32),
    scale_diff: i32,
};

pub const RenderPatch = struct {
    resolution_scale_exponent: u32,
    x_pos: u32,
    y_pos: u32,
};

pub const Pos = struct {
    x: u32 = 0,
    y: u32 = 0,
    pub fn shft(pos: @This(), arg: i6) @This() {
        return if (arg < 0) .{
            .x = pos.x >> @intCast(-arg),
            .y = pos.y >> @intCast(-arg),
        } else .{
            .x = pos.x << @intCast(arg),
            .y = pos.y << @intCast(arg),
        };
    }
};

pub const RenderPatchStatus = enum {
    empty,
    rendering,
    cancelled,
    complete,
    placing,
};

pub const InitWindowError = error{create_window_failed};
pub const InitVulkanError = error{
    instance_creation_failed,
    validation_layer_unavailible,
    debug_messenger_setup_failed,
    window_surface_creation_failed,
    gpu_with_vulkan_support_not_found,
    suitable_gpu_not_found,
    logical_device_creation_failed,
    swap_chain_creation_failed,
    image_views_creation_failed,
    shader_module_creation_failed,
    render_pass_creation_failed,
    pipeline_layout_creation_failed,
    graphics_pipeline_creation_failed,
    framebuffer_creation_failed,
    command_pool_creation_failed,
    command_buffer_allocation_failed,
    semaphore_creation_failed,
    fence_creation_failed,
    descriptor_set_layout_creation_failed,
    descriptor_pool_creation_failed,
    descriptor_sets_allocation_failed,
    buffer_creation_failed,
    buffer_memory_allocation_failed,
    suitable_memory_type_not_found,
} || ReadFileError;
pub const MainLoopError = error{
    command_buffer_recording_begin_failed,
    command_buffer_record_failed,
    draw_command_buffer_submit_failed,
    swap_chain_image_acquisition_failed,
} || InitVulkanError || std.time.Timer.Error;

const Allocator = std.mem.Allocator;
//result of following OOP-based tutorial, maybe change in future
//globals...
pub var window: *c.GLFWwindow = undefined;
pub var height: i32 = 600;
pub var width: i32 = 800;
pub var surface: c.VkSurfaceKHR = null;

pub var instance: c.VkInstance = null;
pub var debug_messenger: c.VkDebugUtilsMessengerEXT = null;
pub var physical_device: c.VkPhysicalDevice = null;
pub var device: c.VkDevice = null;

pub var graphics_queue: c.VkQueue = null;
pub var compute_queue: c.VkQueue = null;
pub var present_queue: c.VkQueue = null;

pub var render_pass: c.VkRenderPass = undefined;
pub var coloring_pipeline_layout: c.VkPipelineLayout = undefined;
pub var rendering_pipeline_layout: c.VkPipelineLayout = undefined;
pub var patch_place_pipeline_layout: c.VkPipelineLayout = undefined;
pub var buffer_remap_pipeline_layout: c.VkPipelineLayout = undefined;
pub var coloring_pipeline: c.VkPipeline = undefined;
pub var rendering_pipeline: c.VkPipeline = undefined;
pub var patch_place_pipeline: c.VkPipeline = undefined;
pub var buffer_remap_pipeline: c.VkPipeline = undefined;

pub var graphics_command_pool: c.VkCommandPool = undefined;
pub var compute_command_pool: c.VkCommandPool = undefined;
pub var graphics_command_buffers: []c.VkCommandBuffer = undefined;
pub var rendering_command_buffers: [num_active_render_patches]c.VkCommandBuffer = undefined;
pub var rnd_buffer_write_command_buffer: c.VkCommandBuffer = undefined;

pub var swap_chain: c.VkSwapchainKHR = null;
pub var swap_chain_images: []c.VkImage = undefined;
pub var swap_chain_image_format: c.VkFormat = undefined;
pub var swap_chain_extent: c.VkExtent2D = undefined;
pub var swap_chain_image_views: []c.VkImageView = undefined;
pub var swap_chain_framebuffers: []c.VkFramebuffer = undefined;
pub var current_frame: u32 = 0;
pub var frame_buffer_needs_resize: bool = false;
pub var frame_buffer_just_resized: bool = false;

pub var image_availible_semaphores: []c.VkSemaphore = undefined;
pub var render_finished_semaphores: []c.VkSemaphore = undefined;
pub var in_flight_fences: []c.VkFence = undefined;
pub var rendering_fences: [num_active_render_patches]c.VkFence = undefined;
pub var render_buffer_write_fence: c.VkFence = undefined;

pub var compute_manager_thread: std.Thread = undefined;
pub var gpu_interface_lock: std.Thread.Mutex = .{};
pub var compute_manager_should_close: bool = false;

pub var render_patch_mutex: std.Thread.Mutex = .{};
pub var resolutions_complete: [num_distinct_res_scales][][]bool = undefined;
pub var res_complete_tmp: [num_distinct_res_scales][][]bool = undefined;
pub var render_patches_saturated: bool = false;
pub var buffer_invalidated: bool = true;
pub var reference_center_stale: bool = false;
pub var remap_needed: bool = false;

pub var escape_potential_buffer_block_num_x: u32 = undefined;
pub var escape_potential_buffer_block_num_y: u32 = undefined;

pub var escape_potential_buffer_size: u32 = undefined;
pub var escape_potential_buffer: c.VkBuffer = undefined;
pub var escape_potential_buffer_memory: c.VkDeviceMemory = undefined;

pub var render_patch_buffer: c.VkBuffer = undefined;
pub var render_patch_buffer_memory: c.VkDeviceMemory = undefined;

pub var placing_patches: bool = false;
pub var remapping_buffer: bool = false;

pub var perturbation_vals: []@Vector(2, f32) = undefined;
pub var max_iterations: u32 = 20000;
pub var perturbation_buffer: c.VkBuffer = undefined;
pub var perturbation_buffer_memory: c.VkDeviceMemory = undefined;
pub var perturbation_staging_buffer: c.VkBuffer = undefined;
pub var perturbation_staging_buffer_memory: c.VkDeviceMemory = undefined;

pub var descriptor_pool: c.VkDescriptorPool = undefined;

pub var render_patch_descriptor_set_layout: c.VkDescriptorSetLayout = undefined;
pub var render_patch_descriptor_sets: [patch_buffer_factor * num_active_render_patches]c.VkDescriptorSet = undefined;

pub var current_render_to_coloring_descriptor_index: usize = 0;
pub var render_to_coloring_descriptor_set_layout: c.VkDescriptorSetLayout = undefined;
pub var render_to_coloring_descriptor_sets: [2]c.VkDescriptorSet = undefined;

pub var current_cpu_to_render_descriptor_index: usize = 0;
pub var cpu_to_render_descriptor_set_layout: c.VkDescriptorSetLayout = undefined;
pub var cpu_to_render_descriptor_sets: [2]c.VkDescriptorSet = undefined;

pub var render_patches: [patch_buffer_factor * num_active_render_patches]RenderPatch = undefined;
pub var render_patches_status = [1]RenderPatchStatus{.empty} **
    (patch_buffer_factor * num_active_render_patches);
pub var fence_to_patch_index = [1]?usize{null} ** num_active_render_patches;

pub var remap_x: i32 = 0;
pub var remap_y: i32 = 0;
pub var remap_exp: i32 = 0;

pub var zoom_exp: i32 = 1;
pub var zoom_diff: f32 = 1.0;
pub var fractal_x_diff: f32 = 0.0;
pub var fractal_y_diff: f32 = 0.0;
// where the center of the screen is in the fractal
pub var fractal_pos_x: c.mpf_t = undefined;
pub var fractal_pos_y: c.mpf_t = undefined;
pub var max_resolution: @Vector(2, u32) = undefined;
pub var render_start_screen_x: u32 = 0;
pub var render_start_screen_y: u32 = 0;

pub var ref_calc_x: c.mpf_t = undefined;
pub var ref_calc_y: c.mpf_t = undefined;
pub var mpf_intermediates: [3]c.mpf_t = undefined;

pub var time: std.time.Timer = undefined;
pub var prev_time: u64 = 0;

pub fn str_eq(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return true;
    }
    return false;
}

// in terms of buffer coordinates
pub fn getScreenCenter() struct { x: f32, y: f32 } {
    return .{
        .x = @max(0, @as(f32, @floatFromInt((renderPatchSize(max_res_scale_exponent) *
            escape_potential_buffer_block_num_x) / 2)) +
            @as(f32, @floatFromInt(height)) * fractal_x_diff),
        .y = @max(0, @as(f32, @floatFromInt((renderPatchSize(max_res_scale_exponent) *
            escape_potential_buffer_block_num_y) / 2)) +
            @as(f32, @floatFromInt(height)) * fractal_y_diff),
    };
}

// readToEndAlloc doesn't provide error type :/
pub const ReadFileError = Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.GetSeekPosError;

/// caller owns slice, slice contains entire file exactly. File limited to 100kB
pub fn readFile(file_name: []const u8, alloc: Allocator, comptime alignment: u29) ReadFileError![]align(alignment) u8 {
    const file = try std.fs.cwd().openFile(file_name, .{});
    const num: u64 = try file.getEndPos();
    const out = try alloc.alignedAlloc(u8, alignment, @intCast(num));
    _ = try file.readAll(out);
    return out;
}

pub const max_res_scale_exponent = 3;
pub const num_distinct_res_scales = max_res_scale_exponent + 1;
/// per workgroup, needs to be same as compute shader
pub const sqrt_invocation_num = 8;
pub const sqrt_workgroup_num = 8;

pub fn renderPatchSize(mip_map_exp: u5) u32 {
    var render_patch_size: u32 = @as(u32, 1) << mip_map_exp;
    render_patch_size *= sqrt_invocation_num;
    render_patch_size *= sqrt_workgroup_num;
    return render_patch_size;
}
