const std = @import("std");
const common = @import("common_defs.zig");
const c = common.c;

const InitWindowError = common.InitWindowError;

pub fn initWindow(data: *common.AppData) InitWindowError!void {
    _ = c.glfwInit();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    data.window = c.glfwCreateWindow(data.width, data.height, "Vulkan", null, null) orelse return InitWindowError.create_window_failed;
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
    data.current_uniform_state.height_scale = data.zoom / @as(f32, @floatFromInt(height));
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
    mouse_pos_x = mouse_pos_x * data.current_uniform_state.height_scale;
    mouse_pos_y = mouse_pos_y * data.current_uniform_state.height_scale;

    data.current_uniform_state.center[0] += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_x));
    data.current_uniform_state.center[1] += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_y));

    data.current_uniform_state.height_scale *= scroll_factor;
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
