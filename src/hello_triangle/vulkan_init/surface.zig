const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createSurface(data: *common.AppData) InitVulkanError!void {
    if (glfw.glfwCreateWindowSurface(data.instance, data.window, null, &data.surface) != glfw.VK_SUCCESS) {
        return InitVulkanError.failed_to_create_window_surface;
    }
}
