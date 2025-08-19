const c = @import("imports.zig").c;
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common_defs.zig");

const window_init = @import("window_init.zig");
const vulkan_init = @import("vulkan_init.zig");
const main_loop = @import("main_loop.zig");
const clean_up = @import("cleanup.zig");

pub const Error = common.InitWindowError || common.InitVulkanError || common.MainLoopError || std.Thread.SpawnError;
const Allocator = std.mem.Allocator;

//result of following OOP-based tutorial, change in future
const AppData = common.AppData;

pub fn run(alloc: Allocator) Error!void {
    var app_data = AppData{
        .width = 800,
        .height = 600,
        .current_uniform_state = .{
            .center = .{ 0.0, 0.0 },
            .resolution = .{ 800, 600 },
            .screen_offset = .{ 0, 0 },
            .height_scale = 2.0,
            .resolution_scale_exponent = 0,
        },
        .time = try std.time.Timer.start(),
        .prev_time = 0,
    };

    try window_init.initWindow(&app_data);
    try vulkan_init.initVulkan(&app_data, alloc);
    try main_loop.startComputeManager(&app_data, alloc);
    try main_loop.mainLoop(&app_data, alloc);
    clean_up.cleanup(&app_data, alloc);
}
