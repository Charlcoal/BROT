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

pub var context: *c.ImGuiContext = undefined;
pub var frame_shown: bool = false;
pub var descriptor_pool: c.VkDescriptorPool = undefined;

fn vk_loader(name: [*c]const u8, instance: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*const fn () callconv(std.builtin.CallingConvention.c) void {
    return getInstanceProcAddress(@ptrCast(@alignCast(instance)), name);
}

fn checkVkResult(err: c.VkResult) callconv(.c) void {
    if (err == 0) {
        @branchHint(.likely);
        return;
    }

    if (err < 0) std.debug.panic("VULKAN: VkResult = {d}", .{err});
    vulkan.log.err("VkResult = {d}", .{err});
}

pub fn deinit() void {
    c.cImGui_ImplVulkan_Shutdown();
    c.cImGui_ImplGlfw_Shutdown();
    c.ImGui_DestroyContext(context);
    c.vkDestroyDescriptorPool(vulkan.device, descriptor_pool, null);
}

pub fn init() void {
    context = c.ImGui_CreateContext(null) orelse
        std.debug.panic("imgui context creation failed!\n", .{});

    const gio = c.ImGui_GetIO();
    gio.*.IniFilename = null;

    _ = c.cImGui_ImplGlfw_InitForVulkan(window.glfw, true);
    const style = c.ImGui_GetStyle();
    _ = c.ImGui_StyleColorsDark(style);

    _ = c.cImGui_ImplVulkan_LoadFunctions(c.VK_VERSION_1_3, vk_loader);
    var info: c.struct_ImGui_ImplVulkan_InitInfo_t = .{
        .Instance = vulkan.instance,
        .PhysicalDevice = vulkan.physical_device,
        .Device = vulkan.device,
        .QueueFamily = vulkan.queue_families.graphics_family.?,
        .Queue = vulkan.graphics_queue,
        .DescriptorPool = descriptor_pool,
        .MinImageCount = c.IMGUI_IMPL_VULKAN_MINIMUM_IMAGE_SAMPLER_POOL_SIZE,
        .ImageCount = c.IMGUI_IMPL_VULKAN_MINIMUM_IMAGE_SAMPLER_POOL_SIZE,
        .Allocator = null, // TODO
        .PipelineInfoMain = .{
            .RenderPass = vulkan.render_pass,
            .Subpass = 0,
            .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
        },
        .CheckVkResultFn = checkVkResult,
    };
    _ = c.cImGui_ImplVulkan_Init(&info);
}

pub const ScalarInputOptions = struct {
    doubler_divider: bool = false,
    h_align: ?f32 = null,
};
pub fn scalarInput(comptime name: [:0]const u8, desc: ?[:0]const u8, cur_val: anytype, options: ScalarInputOptions) ?@TypeOf(cur_val) {
    c.ImGui_AlignTextToFramePadding();

    c.ImGui_TextUnformatted(name);
    if (options.h_align) |width| {
        c.ImGui_SameLineEx(width, 5.0);
    } else {
        c.ImGui_SameLine();
    }

    if (desc) |d| {
        toolTip(d);
    }

    var new_val = cur_val;
    var updated: bool = false;
    if (options.doubler_divider) {
        if (c.ImGui_Button("÷2##" ++ name)) {
            new_val = @divTrunc(new_val, 2);
            updated = true;
        }
        c.ImGui_SameLineEx(0, 5.0);
        if (c.ImGui_Button("x2##" ++ name)) {
            new_val *= 2;
            updated = true;
        }
        c.ImGui_SameLineEx(0, 5.0);
    }

    const imgui_type = switch (@TypeOf(cur_val)) {
        f32 => c.ImGuiDataType_Float,
        f64 => c.ImGuiDataType_Double,
        i8 => c.ImGuiDataType_S8,
        u8 => c.ImGuiDataType_U8,
        i16 => c.ImGuiDataType_S16,
        u16 => c.ImGuiDataType_U16,
        i32 => c.ImGuiDataType_S32,
        u32 => c.ImGuiDataType_U32,
        i64 => c.ImGuiDataType_S64,
        u64 => c.ImGuiDataType_U64,
        else => @compileError("invalid type in scalarInput!"),
    };
    if (c.ImGui_InputScalar("##" ++ name, imgui_type, &new_val)) updated = true;

    if (updated) return new_val;
    return null;
}

pub fn toolTip(desc: [:0]const u8) void {
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_DelayNormal) and c.ImGui_BeginTooltip()) {
        c.ImGui_PushTextWrapPos(c.ImGui_GetFontSize() * 35.0);
        c.ImGui_TextUnformatted(desc);
        c.ImGui_PopTextWrapPos();
        c.ImGui_EndTooltip();
    }
}

/// deals with gui state, doesn't render on its own
pub fn show(io: std.Io, alloc: Allocator) !void {
    if (frame_shown) return;
    frame_shown = true;
    c.cImGui_ImplVulkan_NewFrame();
    c.cImGui_ImplGlfw_NewFrame();
    c.ImGui_NewFrame();

    defer c.ImGui_End();
    c.ImGui_SetNextWindowSize(.{ .x = 300.0, .y = 400.0 }, c.ImGuiCond_FirstUseEver);
    c.ImGui_SetNextWindowPos(.{ .x = 20.0, .y = 20.0 }, c.ImGuiCond_FirstUseEver);
    if (!c.ImGui_Begin("BROT", null, 0)) return;

    if (c.ImGui_CollapsingHeader("Bailout", 0)) {
        if (scalarInput(
            "Iterations",
            "Caps the number of iterations before giving up",
            common.max_iterations,
            .{ .doubler_divider = true },
        )) |new_max_iterations| {
            common.reference_center_stale = true;
            defer common.reference_center_stale = false;
            if (new_max_iterations > common.allocated_iterations)
                try common.reAllocPerturbation(io, alloc, new_max_iterations);
            common.max_iterations = new_max_iterations;
            common.buffer_invalidated = true;
            reference_calc.update(io, new_max_iterations);
        }
    }
}

pub fn draw(command_buffer: c.VkCommandBuffer) void {
    c.ImGui_Render();
    c.cImGui_ImplVulkan_RenderDrawData(
        c.ImGui_GetDrawData(),
        command_buffer,
    );
    frame_shown = false;
}

const getInstanceProcAddress = c.glfwGetInstanceProcAddress;
const Allocator = std.mem.Allocator;

const std = @import("std");
const common = @import("common_defs.zig");
const window = @import("window.zig");
const reference_calc = @import("reference_calc.zig");
const c = @import("c");
const vulkan = @import("vulkan.zig");
