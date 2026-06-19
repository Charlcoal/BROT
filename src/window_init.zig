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

const std = @import("std");
const common = @import("common_defs.zig");
const c = common.c;
const reference_calc = @import("reference_calc.zig");

pub fn initWindow() void {
    _ = c.glfwInit();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    common.window = c.glfwCreateWindow(common.width, common.height, "BROT", null, null) orelse
        std.debug.panic("Window creation failed!", .{});
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
}

fn scrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    const gio = c.ImGui_GetIO();
    if (gio.*.WantCaptureMouse) return;

    _ = xoffset;
    const scroll_factor: f64 = @exp(0.3 * yoffset);

    var mouse_pos_x: f64 = undefined;
    var mouse_pos_y: f64 = undefined;
    c.glfwGetCursorPos(window, &mouse_pos_x, &mouse_pos_y);

    mouse_pos_x -= @as(f64, @floatFromInt(common.width)) / 2.0;
    mouse_pos_y -= @as(f64, @floatFromInt(common.height)) / 2.0;

    // normalize mouse_pos
    mouse_pos_x = mouse_pos_x / @as(f64, @floatFromInt(common.height));
    mouse_pos_y = mouse_pos_y / @as(f64, @floatFromInt(common.height));

    common.fractal_pos.update_target(mouse_pos_x, mouse_pos_y, scroll_factor);
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    const gio = c.ImGui_GetIO();
    if (gio.*.WantCaptureKeyboard) return;

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

    if (key == c.GLFW_KEY_ESCAPE and action == c.GLFW_PRESS) {
        c.glfwSetWindowShouldClose(window, c.GLFW_TRUE);
    }
}
