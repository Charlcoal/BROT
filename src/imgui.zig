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

const getInstanceProcAddress = c.glfwGetInstanceProcAddress;

fn loader(name: [*c]const u8, instance: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*const fn () callconv(std.builtin.CallingConvention.c) void {
    return getInstanceProcAddress(@ptrCast(@alignCast(instance)), name);
}

fn checkVkResult(err: c.VkResult) callconv(.c) void {
    if (err == 0) {
        @branchHint(.likely);
        return;
    }

    if (err < 0) std.debug.panic("[vulkan] Fatal Error: VkResult = {d}\n", .{err});
    // TODO: change to log
    std.debug.print("[vulkan] Error: VkResult = {d}\n", .{err});
}

pub fn deinit() void {
    c.cImGui_ImplVulkan_Shutdown();
    c.cImGui_ImplGlfw_Shutdown();
    c.ImGui_DestroyContext(common.cimgui.context);
}

pub fn init() void {
    common.cimgui.context = c.ImGui_CreateContext(null) orelse
        std.debug.panic("imgui context creation failed!\n", .{});

    _ = c.cImGui_ImplGlfw_InitForVulkan(common.window, true);
    const style = c.ImGui_GetStyle();
    _ = c.ImGui_StyleColorsDark(style);

    _ = c.cImGui_ImplVulkan_LoadFunctions(c.VK_VERSION_1_3, loader);
    var info: c.struct_ImGui_ImplVulkan_InitInfo_t = .{
        .Instance = common.instance,
        .PhysicalDevice = common.physical_device,
        .Device = common.device,
        .QueueFamily = common.queue_families.graphics_family.?,
        .Queue = common.graphics_queue,
        .DescriptorPool = common.gui_descriptor_pool,
        .MinImageCount = c.IMGUI_IMPL_VULKAN_MINIMUM_IMAGE_SAMPLER_POOL_SIZE,
        .ImageCount = c.IMGUI_IMPL_VULKAN_MINIMUM_IMAGE_SAMPLER_POOL_SIZE,
        .Allocator = null, // TODO
        .PipelineInfoMain = .{
            .RenderPass = common.render_pass,
            .Subpass = 0,
            .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
        },
        .CheckVkResultFn = checkVkResult,
    };
    _ = c.cImGui_ImplVulkan_Init(&info);
}
