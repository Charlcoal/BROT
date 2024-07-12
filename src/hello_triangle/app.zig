const glfw = @import("imports.zig").glfw;
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common_defs.zig");

const window_init = @import("window_init.zig");
const vulkan_init = @import("vulkan_init/all.zig");
const main_loop = @import("main_loop.zig");
const clean_up = @import("cleanup.zig");

pub const Error = common.InitWindowError || common.InitVulkanError;
const Allocator = std.mem.Allocator;

//result of following OOP-based tutorial, change in future
const AppData = common.AppData;

pub fn run(alloc: Allocator) Error!void {
    var app_data = AppData{
        .width = 800,
        .height = 600,
    };

    try window_init.initWindow(&app_data);
    try vulkan_init.initVulkan(&app_data, alloc);
    main_loop.mainLoop(app_data);
    clean_up.cleanup(app_data, alloc);
}
