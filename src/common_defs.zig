const std = @import("std");
pub const c = @import("imports.zig").c;
const builtin = @import("builtin");
const instance = @import("vulkan_init/instance.zig");
const screen_renderer = @import("vulkan_init/screen_renderer.zig");
const descriptors = @import("vulkan_init/descriptors.zig");

// ------------------- settings -------------------------

pub const max_frames_in_flight: i32 = 2;

pub const enable_validation_layers = dbg;

pub const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

pub const device_extensions = [_][*:0]const u8{
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};

pub const UniformBufferObject = extern struct {
    center_x: f32 align(2 * @alignOf(f32)), // x component of vec2 on glsl side
    center_y: f32,
    height_scale: f32,
    width_to_height_ratio: f32,
};

pub const target_frame_rate: f64 = 60;

// ------------------- program defs ---------------------

pub const dbg = builtin.mode == std.builtin.Mode.Debug;

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
pub const AppData = struct {
    window: *c.GLFWwindow = undefined,
    height: i32,
    width: i32,
    inst: instance.Instance = undefined,
    screen_rend: screen_renderer.ScreenRenderer = undefined,
    ubo: descriptors.UniformBuffer(UniformBufferObject) = undefined,
    descriptor_set: descriptors.DescriptorSet(
        &.{descriptors.UniformBuffer(UniformBufferObject)},
        &.{UniformBufferObject},
    ) = undefined,
    image_availible_semaphores: []c.VkSemaphore = undefined,
    render_finished_semaphores: []c.VkSemaphore = undefined,
    in_flight_fences: []c.VkFence = undefined,
    current_frame: u32 = 0,
    frame_buffer_resized: bool = false,

    time: std.time.Timer,
    prev_time: u64,
};

pub fn str_eq(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return true;
    }
    return false;
}

pub const ReadFileError = Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.GetSeekPosError;

// readToEndAlloc doesn't provide error type :/
/// caller owns slice, slice contains entire file exactly. File limited to 100kB
pub fn readFile(file_name: []const u8, alloc: Allocator, comptime alignment: u29) ReadFileError![]align(alignment) u8 {
    const file = try std.fs.cwd().openFile(file_name, .{});
    const num: u64 = try file.getEndPos();
    const out = try alloc.alignedAlloc(u8, alignment, @intCast(num));
    _ = try file.readAll(out);
    return out;
}
