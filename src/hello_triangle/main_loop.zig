const std = @import("std");
const common = @import("common_defs.zig");
const glfw = common.glfw;

pub fn mainLoop(data: common.AppData) void {
    while (glfw.glfwWindowShouldClose(data.window) == 0) {
        glfw.glfwPollEvents();
    }
}
