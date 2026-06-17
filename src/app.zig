// BROT - A fast mandelbrot set explorer
// Copyright (C) 2025 - 2026 Charles Reischer
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

const c = @import("c");
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common_defs.zig");

const window_init = @import("window_init.zig");
const vulkan_init = @import("vulkan_init.zig");
const imgui = @import("imgui.zig");
const ref_calc = @import("reference_calc.zig");
const main_loop = @import("main_loop.zig");
const clean_up = @import("cleanup.zig");
const big_float = @import("big_float.zig");

pub const Error = std.Io.ConcurrentError || common.InitWindowError ||
    common.InitVulkanError || common.MainLoopError || std.Thread.SpawnError;

const Allocator = std.mem.Allocator;

//result of following OOP-based tutorial, change in future
const AppData = common.AppData;

pub fn run(alloc: Allocator, io: std.Io) Error!void {
    common.width = 800;
    common.height = 600;

    common.fractal_pos.x = big_float.string_init("-0.5");
    common.fractal_pos.y = big_float.string_init("-0.0");
    defer c.mpf_clear(&common.fractal_pos.x);
    defer c.mpf_clear(&common.fractal_pos.y);

    for (&common.mpf_intermediates) |*intermediate| {
        c.mpf_init2(intermediate, 32);
    }
    c.mpf_init2(&common.ref_calc_x, 32);
    c.mpf_init2(&common.ref_calc_y, 32);

    try window_init.initWindow();
    try vulkan_init.initVulkan(alloc);
    imgui.init();
    try ref_calc.init(alloc);
    ref_calc.update(io, common.max_iterations);
    common.compute_manager_future = try io.concurrent(
        main_loop.computeManage,
        .{ alloc, io },
    );
    try main_loop.mainLoop(alloc, io);
    clean_up.cleanup(alloc, io);
}
