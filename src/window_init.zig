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

const std = @import("std");
const common = @import("common_defs.zig");
const c = common.c;
const reference_calc = @import("reference_calc.zig");

const InitWindowError = common.InitWindowError;

pub fn initWindow() InitWindowError!void {
    _ = c.glfwInit();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    common.window = c.glfwCreateWindow(common.width, common.height, "BROT", null, null) orelse return InitWindowError.create_window_failed;
    _ = c.glfwSetFramebufferSizeCallback(common.window, framebufferResizeCallback);
    _ = c.glfwSetScrollCallback(common.window, scrollCallback);
    _ = c.glfwSetKeyCallback(common.window, keyCallback);
}

fn framebufferResizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    _ = window;
    common.frame_buffer_needs_resize = true;
    common.width = width;
    common.height = height;
    common.buffer_invalidated = true;
    common.render_start_screen_x = @intCast(@divFloor(width, 2));
    common.render_start_screen_y = @intCast(@divFloor(height, 2));
}

fn scrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = xoffset;
    const scroll_factor: f64 = @exp(0.3 * yoffset);

    var mouse_pos_x: f64 = undefined;
    var mouse_pos_y: f64 = undefined;
    c.glfwGetCursorPos(window, &mouse_pos_x, &mouse_pos_y);

    common.render_start_screen_x = @intFromFloat(@round(mouse_pos_x));
    common.render_start_screen_y = @intFromFloat(@round(mouse_pos_y));

    mouse_pos_x -= @as(f64, @floatFromInt(common.width)) / 2.0;
    mouse_pos_y -= @as(f64, @floatFromInt(common.height)) / 2.0;

    // change mouse_pos to mandelbrot coords
    mouse_pos_x = mouse_pos_x * common.zoom_diff / @as(f64, @floatFromInt(common.height));
    mouse_pos_y = mouse_pos_y * common.zoom_diff / @as(f64, @floatFromInt(common.height));

    const needed_prec: usize = 32 + @abs(common.zoom_exp);
    if (needed_prec > c.mpf_get_prec(&common.mpf_intermediates[0])) {
        for (&common.mpf_intermediates) |*intermediate| {
            c.mpf_set_prec(intermediate, needed_prec);
        }
        c.mpf_set_prec(&common.fractal_pos_x, needed_prec);
        c.mpf_set_prec(&common.fractal_pos_y, needed_prec);
        c.mpf_set_prec(&common.ref_calc_x, needed_prec);
        c.mpf_set_prec(&common.ref_calc_y, needed_prec);
        std.debug.print("set precision to: {}\n", .{c.mpf_get_prec(&common.mpf_intermediates[0])});
    }

    const diff_x: f64 = (1.0 - scroll_factor) * mouse_pos_x;
    const diff_y: f64 = (1.0 - scroll_factor) * mouse_pos_y;

    common.fractal_x_diff += @floatCast(diff_x);
    common.fractal_y_diff += @floatCast(diff_y);

    common.zoom_diff *= @as(f32, @floatCast(scroll_factor));

    const block_size = common.renderPatchSize(common.max_res_scale_exponent);
    const fractal_to_block_scale: f64 = @as(f64, @floatFromInt(common.height)) / @as(f64, @floatFromInt(block_size));
    const block_x_diff = common.fractal_x_diff * fractal_to_block_scale;
    const block_y_diff = common.fractal_y_diff * fractal_to_block_scale;

    var updated_state: bool = false;

    var remap_x: i32 = 0;
    var remap_y: i32 = 0;
    var remap_exp: i32 = 0;

    if (@abs(block_x_diff) > 0.5 or @abs(block_y_diff) > 0.5) {
        updated_state = true;
        //std.debug.print("moving buffer...\n", .{});
        const adjustment_x: f64 = @round(block_x_diff) / fractal_to_block_scale;
        const adjustment_y: f64 = @round(block_y_diff) / fractal_to_block_scale;

        remap_x = @intFromFloat(@round(block_x_diff));
        remap_y = @intFromFloat(@round(block_y_diff));

        common.fractal_x_diff -= @floatCast(adjustment_x);
        common.fractal_y_diff -= @floatCast(adjustment_y);

        var tmp: c.mpf_t = undefined;
        c.mpf_init2(&tmp, 32);
        defer c.mpf_clear(&tmp);

        c.mpf_set_d(&tmp, adjustment_x);
        if (common.zoom_exp < 0) {
            c.mpf_div_2exp(&common.mpf_intermediates[1], &tmp, @intCast(-common.zoom_exp));
        } else {
            c.mpf_mul_2exp(&common.mpf_intermediates[1], &tmp, @intCast(common.zoom_exp));
        }
        c.mpf_add(&common.mpf_intermediates[0], &common.fractal_pos_x, &common.mpf_intermediates[1]);
        c.mpf_swap(&common.mpf_intermediates[0], &common.fractal_pos_x);

        c.mpf_set_d(&tmp, adjustment_y);
        if (common.zoom_exp < 0) {
            c.mpf_div_2exp(&common.mpf_intermediates[1], &tmp, @intCast(-common.zoom_exp));
        } else {
            c.mpf_mul_2exp(&common.mpf_intermediates[1], &tmp, @intCast(common.zoom_exp));
        }
        c.mpf_add(&common.mpf_intermediates[0], &common.fractal_pos_y, &common.mpf_intermediates[1]);
        c.mpf_swap(&common.mpf_intermediates[0], &common.fractal_pos_y);
    }

    if (common.zoom_diff >= 2.0) {
        common.zoom_diff /= 2.0;
        common.zoom_exp += 1;
        common.fractal_x_diff *= 0.5;
        common.fractal_y_diff *= 0.5;
        remap_exp = 1;
        updated_state = true;
    }
    if (common.zoom_diff < 1.0) {
        common.zoom_diff *= 2.0;
        common.zoom_exp -= 1;
        common.fractal_x_diff *= 2.0;
        common.fractal_y_diff *= 2.0;
        remap_exp = -1;
        updated_state = true;
    }

    if (updated_state) {
        common.remap_x = remap_x;
        common.remap_y = remap_y;
        common.remap_exp = remap_exp;

        //common.buffer_invalidated = true;
        common.remap_needed = true;

        common.reference_center_stale = true;
        reference_calc.update();
        common.reference_center_stale = false;
    }
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;
    _ = scancode;
    if (key == c.GLFW_KEY_F and action == c.GLFW_PRESS) {
        if (c.glfwGetWindowMonitor(window) == null) { // windowed -> fullscreen
            const monitor = c.glfwGetPrimaryMonitor();
            const mode = c.glfwGetVideoMode(monitor);
            c.glfwSetWindowMonitor(window, c.glfwGetPrimaryMonitor(), 0, 0, mode.*.width, mode.*.height, mode.*.refreshRate);
        } else { // fullscreen -> windowed
            c.glfwSetWindowMonitor(window, null, 100, 100, 800, 600, 0);
        }
    }

    if (key == c.GLFW_KEY_SPACE and action == c.GLFW_PRESS) {
        for (0.., common.perturbation_vals[0..1000]) |i, val| {
            std.debug.print("{}: {}, {}\n", .{ i, val[0], val[1] });
        }
    }
}
