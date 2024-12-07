const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

const instance = @import("instance.zig");
const createSwapChain = @import("swap_chain.zig").createSwapChain;
const createImageViews = @import("image_views.zig").createImageViews;
const createRenderPass = @import("render_pass.zig").createRenderPass;
const createGraphicsPipeline = @import("graphics_pipeline.zig").createGraphicsPipeline;
const createFrameBuffers = @import("framebuffers.zig").createFramebuffers;
const createCommandPool = @import("command_pool.zig").createCommandPool;
const createCommandBuffers = @import("command_buffer.zig").createCommandBuffers;
const createSyncObjects = @import("sync_objects.zig").createSyncObjects;
const createDescriptorSetLayout = @import("descriptor_set_layout.zig").createDescriptorSetLayout;
const uniformBuffers = @import("uniform_buffers.zig");
const createDescriptorPool = @import("descriptor_pool.zig").createDescriptorPool;
const createDescriptorSets = @import("descriptor_sets.zig").createDescriptorSets;
const cleanup = @import("../cleanup.zig");
const render_pipeline = @import("render_pipeline.zig");

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

    const ubo1 = try uniformBuffers.UniformBuffer(common.UniformBufferObject).blueprint(inst);
    data.descriptor_set_layout = ubo1.descriptor_set_layout;

    // "RenderPipeline" ??
    const swapchain = try render_pipeline.Swapchain.init(alloc, inst, data.window);
    data.swap_chain = swapchain.vk_swapchain;
    data.swap_chain_extent = swapchain.extent;
    data.swap_chain_image_format = swapchain.format;
    data.swap_chain_images = swapchain.images;
    data.swap_chain_image_views = swapchain.image_views;
    try createRenderPass(data);
    try createGraphicsPipeline(data, alloc);
    try createFrameBuffers(data, alloc);
    try createCommandPool(data, alloc);
    try createCommandBuffers(data, alloc);

    try uniformBuffers.createUniformBuffers(data, alloc);
    try createDescriptorPool(data);
    try createDescriptorSets(data, alloc);
    // ---------------------------------

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
