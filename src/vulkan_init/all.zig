const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const instance = @import("instance.zig");
const sync_objects = @import("sync_objects.zig");
const descriptors = @import("descriptors.zig");
const screen_rend = @import("screen_renderer.zig");

pub const Error = instance.Error || sync_objects.Error || descriptors.Error || screen_rend.Error;

pub fn initVulkan(data: *common.AppData, alloc: Allocator) Error!void {
    data.inst = try instance.Instance.init(alloc, .{}, data.window);

    try data.ubo.blueprint(data.inst);

    data.screen_rend = try screen_rend.ScreenRenderer.init(alloc, data.inst, data.window, &.{data.ubo.descriptor_set_layout});

    try data.ubo.create(data.inst, alloc);

    data.descriptor_set = try descriptors.DescriptorSet(
        &.{descriptors.UniformBuffer(common.UniformBufferObject)},
        &.{common.UniformBufferObject},
    ).allocatePool(data.inst, common.max_frames_in_flight);

    try data.descriptor_set.createSets(data.inst, .{ .a = data.ubo }, alloc, common.max_frames_in_flight);

    data.image_availible_semaphores = try sync_objects.createSemaphores(data.inst, alloc, common.max_frames_in_flight);
    data.render_finished_semaphores = try sync_objects.createSemaphores(data.inst, alloc, common.max_frames_in_flight);
    data.in_flight_fences = try sync_objects.createFences(data.inst, alloc, common.max_frames_in_flight);
}
