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
const cimgui = @import("cimgui_zig");
const Resources = struct {
    shaders: [5][]const u8,
};
const resources: Resources = @import("resources.zon");

fn addIncludePathsToTranslateC(translate_c: *std.Build.Step.TranslateC, lib: *std.Build.Step.Compile) void {
    for (lib.root_module.include_dirs.items) |*included| {
        switch (included.*) {
            .path => translate_c.addIncludePath(included.path),
            .config_header_step => translate_c.addConfigHeader(included.config_header_step),
            .path_system => translate_c.addSystemIncludePath(included.path_system),
            .other_step => addIncludePathsToTranslateC(translate_c, included.other_step),
            else => unreachable,
        }
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platforms = &[_]cimgui.Platform{.GLFW},
        .renderers = &[_]cimgui.Renderer{.Vulkan},
    });

    const glslang = b.dependency("glslang", .{
        .target = target,
        .optimize = optimize,
    });

    const gmp = b.dependency("gmp", .{
        .target = target,
        .optimize = optimize,
    });
    const config_step = b.step("configure", "Configure GMP");

    const config = b.addSystemCommand(&.{"./configure"});
    config.addArg("--build=amd64-pc-linux-gnu");
    config.setCwd(gmp.path("."));

    const make = b.addSystemCommand(&.{"make"});
    make.setCwd(gmp.path("."));

    make.step.dependOn(&config.step);
    config_step.dependOn(&make.step);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("vulkan", .{});
    // translate_c.linkSystemLibrary("gmp", .{});
    translate_c.link_libc = true;
    translate_c.step.dependOn(config_step);
    translate_c.addIncludePath(gmp.path("."));
    translate_c.addIncludePath(glslang.builder.dependency("glslang", .{}).path("."));

    const cimgui_lib = cimgui_dep.artifact("cimgui");
    addIncludePathsToTranslateC(translate_c, cimgui_lib);
    const c_module = translate_c.createModule();
    c_module.linkLibrary(gmp.artifact("gmp"));
    c_module.linkLibrary(cimgui_lib);
    c_module.linkLibrary(glslang.artifact("glslang"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c",
                .module = c_module,
            },
        },
    });

    const exe = b.addExecutable(.{
        .name = "BROT",
        .root_module = root_module,
        .use_llvm = true,
    });

    const install_artifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_artifact.step);

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

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
