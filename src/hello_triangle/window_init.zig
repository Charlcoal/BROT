const std = @import("std");
const common = @import("common_defs.zig");
const glfw = common.glfw;

const InitWindowError = common.InitWindowError;

pub fn initWindow(data: *common.AppData) InitWindowError!void {
    _ = glfw.glfwInit();

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);

    data.window = glfw.glfwCreateWindow(data.width, data.height, "Vulkan", null, null) orelse return InitWindowError.create_window_failed;
    glfw.glfwSetWindowUserPointer(data.window, @ptrCast(data));
    _ = glfw.glfwSetFramebufferSizeCallback(data.window, framebufferResizeCallback);
}

fn framebufferResizeCallback(window: ?*glfw.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    const data: *common.AppData = @alignCast(@ptrCast(glfw.glfwGetWindowUserPointer(window)));
    data.frame_buffer_resized = true;
    data.width = width;
    data.height = height;
    data.current_uniform_state.width_to_height_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
}
