// BROT - A fast mandelbrot set explorer Copyright (C) 2025  Charles Reischer
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
const cimgui = @import("cimgui_zig");
const Resources = struct {
    shaders: [3][]const u8,
};
const resources: Resources = @import("resources.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "BROT",
        .root_module = root_module,
        .use_llvm = true,
    });

    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = cimgui.Platform.GLFW,
        .renderer = cimgui.Renderer.Vulkan,
    });

    exe.root_module.link_libc = true;
    exe.linkLibrary(cimgui_dep.artifact("cimgui"));
    exe.root_module.linkSystemLibrary("vulkan", .{});
    exe.root_module.linkSystemLibrary("gmp", .{});

    exe.addIncludePath(b.path("include"));

    b.installArtifact(exe);

    // compile shaders at build time
    // (e.g.  "triangle.frag" -> "triangle_frag_shader" (internally "triangle_frag.spv"))
    var spv_buffer: [256]u8 = undefined;
    var fullpath_buffer: [256]u8 = undefined;
    var spv_stream = std.io.fixedBufferStream(&spv_buffer);
    var fullpath_stream = std.io.fixedBufferStream(&fullpath_buffer);
    var final_name_buf: [resources.shaders.len][256]u8 = undefined;
    for (resources.shaders, &final_name_buf) |shader_name, *final_name| {
        // create "___.spv" file name
        spv_stream.reset();
        _ = try spv_stream.write(shader_name);
        for (spv_stream.getWritten()) |*char| {
            if (char.* == '.') char.* = '_';
        }
        _ = try spv_stream.write(".spv");

        const glslc_cmd = b.addSystemCommand(&.{
            "glslc",
            "--target-env=vulkan1.3",
            "-o",
        });
        const shader_spv = glslc_cmd.addOutputFileArg(spv_stream.getWritten());

        // create "shaders/___" name
        fullpath_stream.reset();
        _ = try fullpath_stream.write("shaders/");
        _ = try fullpath_stream.write(shader_name);
        glslc_cmd.addFileArg(b.path(fullpath_stream.getWritten()));

        std.mem.copyForwards(u8, final_name, shader_name);
        for (final_name[0..shader_name.len]) |*char| {
            if (char.* == '.') char.* = '_';
        }
        std.mem.copyForwards(u8, final_name[shader_name.len..256], "_shader");
        exe.root_module.addAnonymousImport(final_name[0..(shader_name.len + 7)], .{ .root_source_file = shader_spv });
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .name = "top level tests",
        .root_module = root_module,
    });
    exe_unit_tests.linkSystemLibrary2("vulkan", .{});

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
