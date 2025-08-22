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

const InitWindowError = common.InitWindowError;

pub fn initWindow(data: *common.AppData) InitWindowError!void {
    _ = c.glfwInit();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    data.window = c.glfwCreateWindow(data.width, data.height, "BROT", null, null) orelse return InitWindowError.create_window_failed;
    c.glfwSetWindowUserPointer(data.window, @ptrCast(data));
    _ = c.glfwSetFramebufferSizeCallback(data.window, framebufferResizeCallback);
    _ = c.glfwSetScrollCallback(data.window, scrollCallback);
    _ = c.glfwSetKeyCallback(data.window, keyCallback);
}

fn framebufferResizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    const data: *common.AppData = @alignCast(@ptrCast(c.glfwGetWindowUserPointer(window)));
    data.frame_buffer_needs_resize = true;
    data.width = width;
    data.height = height;
    data.frame_updated = true;
    data.render_start_screen_x = @intCast(@divFloor(width, 2));
    data.render_start_screen_y = @intCast(@divFloor(height, 2));
}

fn scrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.C) void {
    _ = xoffset;
    const data: *common.AppData = @alignCast(@ptrCast(c.glfwGetWindowUserPointer(window)));
    const scroll_factor: f32 = @floatCast(@exp(0.3 * yoffset));

    var mouse_pos_x: f64 = undefined;
    var mouse_pos_y: f64 = undefined;
    c.glfwGetCursorPos(window, &mouse_pos_x, &mouse_pos_y);

    data.render_start_screen_x = @intFromFloat(@round(mouse_pos_x));
    data.render_start_screen_y = @intFromFloat(@round(mouse_pos_y));

    // change mouse_pos to mandelbrot coords
    mouse_pos_x = mouse_pos_x * data.zoom / @as(f64, @floatFromInt(data.height));
    mouse_pos_y = mouse_pos_y * data.zoom / @as(f64, @floatFromInt(data.height));

    data.fractal_pos[0] += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_x));
    data.fractal_pos[1] += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_y));

    data.zoom *= scroll_factor;

    data.frame_updated = true;
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
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
}
