const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

const instance = @import("instance.zig");
const createSwapChain = @import("swap_chain.zig").createSwapChain;
const createImageViews = @import("image_views.zig").createImageViews;
const createFrameBuffers = @import("framebuffers.zig").createFramebuffers;
const createSyncObjects = @import("sync_objects.zig").createSyncObjects;
const createDescriptorSetLayout = @import("descriptor_set_layout.zig").createDescriptorSetLayout;
//const uniform_buffer = @import("uniform_buffer.zig");
//const descriptor_pool = @import("descriptor_pool.zig");
const descriptors = @import("descriptors.zig");
const createDescriptorSets = @import("descriptor_sets.zig").createDescriptorSets;
const cleanup = @import("../cleanup.zig");
const screen_rend = @import("screen_renderer.zig");

pub fn initVulkan(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    var inst = try instance.Instance.init(alloc, .{}, data.window);
    data.instance = inst.vk_instance;
    data.debug_messenger = inst.debug_messenger;
    data.surface = inst.surface;
    data.physical_device = inst.physical_device;
    data.device = inst.logical_device;
    data.graphics_compute_queue = inst.graphics_compute_queue;
    data.present_queue = inst.present_queue;

    defer inst.swap_chain_support.deinit();

    var ubo1 = try descriptors.UniformBuffer(common.UniformBufferObject).blueprint(inst);
    data.descriptor_set_layout = ubo1.descriptor_set_layout;

    const screen_renderer = try screen_rend.ScreenRenderer.init(alloc, inst, data.window, &.{ubo1.descriptor_set_layout});
    const swapchain = screen_renderer.swapchain;
    data.swap_chain = swapchain.vk_swapchain;
    data.swap_chain_extent = swapchain.extent;
    data.swap_chain_image_format = swapchain.format;
    data.swap_chain_images = swapchain.images;
    data.swap_chain_image_views = swapchain.image_views;
    data.render_pass = screen_renderer.render_pass;
    data.graphics_pipeline = screen_renderer.graphics_pipeline;
    data.pipeline_layout = screen_renderer.pipeline_layout;
    data.swap_chain_framebuffers = screen_renderer.swapchain.framebuffers;
    data.command_pool = screen_renderer.command_pool;
    data.command_buffers = screen_renderer.command_buffers;

    try ubo1.create(inst, alloc);
    data.uniform_buffers = ubo1.gpu_buffers;
    data.uniform_buffers_memory = ubo1.gpu_memory;
    data.uniform_buffers_mapped = ubo1.gpu_memory_mapped;

    const descriptor_set = try descriptors.DescriptorSet(
        &.{descriptors.UniformBuffer(common.UniformBufferObject)},
        &.{common.UniformBufferObject},
    ).allocateDescriptorPool(inst, common.max_frames_in_flight);

    //const descript_pool = try descriptor_pool.DescriptorPool.init(
    //    inst,
    //    &.{.{
    //        .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    //        .descriptorCount = @intCast(common.max_frames_in_flight),
    //    }},
    //    common.max_frames_in_flight,
    //);

    data.descriptor_pool = descriptor_set.descriptor_pool;
    try createDescriptorSets(data, alloc);

    try createSyncObjects(data, alloc);
}

pub fn recreateSwapChain(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(data.window, &width, &height);
    while (width == 0 or height == 0) {
        c.glfwGetFramebufferSize(data.window, &width, &height);
        c.glfwWaitEvents();
    }

    _ = c.vkDeviceWaitIdle(data.device);

    cleanup.cleanupSwapChain(data.*, alloc);

    try createSwapChain(data, alloc);
    try createImageViews(data, alloc);
    try createFrameBuffers(data, alloc);
}
