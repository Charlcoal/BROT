const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createSurface(data: *common.AppData) InitVulkanError!void {
    if (c.glfwCreateWindowSurface(data.instance, data.window, null, &data.surface) != c.VK_SUCCESS) {
        return InitVulkanError.window_surface_creation_failed;
    }
}
