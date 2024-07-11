const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createGraphicsPipeline(data: *common.AppData, alloc: Allocator) Allocator.Error!void {
    _ = data;
    _ = alloc;
}
