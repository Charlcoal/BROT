const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createRenderPass(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    _ = data;
    _ = alloc;
}
