const std = @import("std");
const common = @import("common_defs.zig");
const c = common.c;

pub const Error = error{create_window_failed};

pub fn initWindow(data: *common.AppData) Error!void {
    _ = c.glfwInit();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    data.window = c.glfwCreateWindow(@intCast(data.width), @intCast(data.height), "Vulkan", null, null) orelse return Error.create_window_failed;
    c.glfwSetWindowUserPointer(data.window, @ptrCast(data));
    _ = c.glfwSetFramebufferSizeCallback(data.window, framebufferResizeCallback);
    _ = c.glfwSetScrollCallback(data.window, scrollCallback);
}

fn framebufferResizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    const data: *common.AppData = @alignCast(@ptrCast(c.glfwGetWindowUserPointer(window)));
    data.frame_buffer_resized = true;
    data.width = @intCast(width);
    data.height = @intCast(height);
    data.ubo.cpu_state.width_to_height_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
}

fn scrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.C) void {
    _ = xoffset;
    const data: *common.AppData = @alignCast(@ptrCast(c.glfwGetWindowUserPointer(window)));
    const scroll_factor: f32 = @floatCast(@exp(0.3 * yoffset));

    var mouse_pos_x: f64 = undefined;
    var mouse_pos_y: f64 = undefined;
    c.glfwGetCursorPos(window, &mouse_pos_x, &mouse_pos_y);

    // change mouse_pos to Vulkan coords
    mouse_pos_x = 2.0 * mouse_pos_x / @as(f64, @floatFromInt(data.width)) - 1.0;
    mouse_pos_y = 2.0 * mouse_pos_y / @as(f64, @floatFromInt(data.height)) - 1.0;

    // change mouse_pos to mandelbrot coords
    mouse_pos_x = mouse_pos_x * data.ubo.cpu_state.height_scale * data.ubo.cpu_state.width_to_height_ratio;
    mouse_pos_y = mouse_pos_y * data.ubo.cpu_state.height_scale;

    data.ubo.cpu_state.center_x += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_x));
    data.ubo.cpu_state.center_y += @as(f32, @floatCast((1.0 - scroll_factor) * mouse_pos_y));

    data.ubo.cpu_state.height_scale *= scroll_factor;
}
