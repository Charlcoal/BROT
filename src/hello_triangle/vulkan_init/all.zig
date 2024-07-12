const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

const createInstance = @import("instance.zig").createInstance;
const setupDebugMessenger = @import("debug_messenger.zig").setupDebugMessenger;
const createSurface = @import("surface.zig").createSurface;
const pickPhysicalDevice = @import("physical_device.zig").pickPhysicalDevice;
const createLogicalDevice = @import("logical_device.zig").createLogicalDevice;
const createSwapChain = @import("swap_chain.zig").createSwapChain;
const createImageViews = @import("image_views.zig").createImageViews;
const createRenderPass = @import("render_pass.zig").createRenderPass;
const createGraphicsPipeline = @import("graphics_pipeline.zig").createGraphicsPipeline;

pub fn initVulkan(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    try createInstance(data, alloc);
    try setupDebugMessenger(data);
    try createSurface(data);
    try pickPhysicalDevice(data, alloc);
    try createLogicalDevice(data, alloc);
    try createSwapChain(data, alloc);
    try createImageViews(data, alloc);
    try createRenderPass(data, alloc);
    try createGraphicsPipeline(data, alloc);
}
