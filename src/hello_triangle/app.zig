const glfw = @import("imports.zig").glfw;
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common_defs.zig");

const window_init = @import("window_init.zig");
const vulkan_init = @import("vulkan_init/all.zig");
const main_loop = @import("main_loop.zig");
const clean_up = @import("cleanup.zig");

const dbg = builtin.mode == std.builtin.Mode.Debug;
const enable_validation_layers = dbg;

const InitWindowError = common.InitWindowError;
const InitVulkanError = common.InitVulkanError;
pub const Error = window_init.InitWindowError || InitVulkanError;

const Allocator = std.mem.Allocator;

const validation_layers = common.validation_layers;
const device_extensions = common.device_extensions;

const SwapChainSupportDetails = common.SwapChainSupportDetails;
//result of following OOP-based tutorial, change in future
const AppData = common.AppData;

pub fn run(alloc: Allocator) Error!void {
    var app_data = AppData{
        .width = 800,
        .height = 600,
        .window = undefined,
        .instance = null,
        .debug_messenger = null,
        .surface = null,
        .physical_device = null,
        .device = null,
        .graphics_queue = null,
        .present_queue = null,
        .swap_chain = null,
        .swap_chain_images = undefined,
        .swap_chain_image_format = undefined,
        .swap_chain_extent = undefined,
        .swap_chain_image_views = undefined,
    };

    try window_init.initWindow(&app_data);
    try vulkan_init.initVulkan(&app_data, alloc);
    main_loop.mainLoop(app_data);
    clean_up.cleanup(app_data, alloc);
}
