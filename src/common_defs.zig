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

pub const UniformBufferObject = extern struct {
    center: @Vector(2, f32),
    resolution: @Vector(2, u32),
    screen_offset: @Vector(2, u32),
    height_scale: f32,
    resolution_scale_exponent: i32,
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
    instance: c.VkInstance = null,
    debug_messenger: c.VkDebugUtilsMessengerEXT = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    graphics_queue: c.VkQueue = null,
    compute_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    swap_chain: c.VkSwapchainKHR = null,
    swap_chain_images: []c.VkImage = undefined,
    swap_chain_image_format: c.VkFormat = undefined,
    swap_chain_extent: c.VkExtent2D = undefined,
    swap_chain_image_views: []c.VkImageView = undefined,
    render_pass: c.VkRenderPass = undefined,
    pipeline_layout: c.VkPipelineLayout = undefined,
    compute_pipeline_layout: c.VkPipelineLayout = undefined,
    graphics_pipeline: c.VkPipeline = undefined,
    compute_pipeline: c.VkPipeline = undefined,
    swap_chain_framebuffers: []c.VkFramebuffer = undefined,
    command_pool: c.VkCommandPool = undefined,
    graphics_command_buffer: c.VkCommandBuffer = undefined,
    compute_command_buffer: c.VkCommandBuffer = undefined,
    image_availible_semaphores: []c.VkSemaphore = undefined,
    render_finished_semaphores: []c.VkSemaphore = undefined,
    in_flight_fence: c.VkFence = undefined,
    compute_fence: c.VkFence = undefined,
    current_swap_image: u32 = 0,
    num_swap_images: u32 = 0,
    frame_buffer_resized: bool = false,

    compute_manager_thread: std.Thread = undefined,
    gpu_interface_semaphore: std.Thread.Semaphore = .{ .permits = 1 },
    compute_manager_should_close: bool = false,
    compute_idle: bool = false,

    current_uniform_state: UniformBufferObject,
    uniform_buffer: c.VkBuffer = undefined,
    uniform_buffer_memory: c.VkDeviceMemory = undefined,
    uniform_buffer_mapped: ?*align(@alignOf(UniformBufferObject)) anyopaque = undefined,

    storage_buffer_size: u32 = undefined,
    storage_buffer: c.VkBuffer = undefined,
    storage_buffer_memory: c.VkDeviceMemory = undefined,

    descriptor_set_layout: c.VkDescriptorSetLayout = undefined,
    descriptor_pool: c.VkDescriptorPool = undefined,
    descriptor_set: c.VkDescriptorSet = undefined,

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
