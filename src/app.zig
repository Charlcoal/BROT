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
        .render_start_screen_x = 400,
        .render_start_screen_y = 300,
        .fractal_pos = .{ -1.0, -1.0 },
        .zoom = 2.0,
        .time = try std.time.Timer.start(),
        .prev_time = 0,
    };

    try window_init.initWindow(&app_data);
    try vulkan_init.initVulkan(&app_data, alloc);
    try main_loop.startComputeManager(&app_data, alloc);
    try main_loop.mainLoop(&app_data, alloc);
    clean_up.cleanup(&app_data, alloc);
}
