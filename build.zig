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
const pkg = @import("build.zig.zon");
const cimgui = @import("cimgui_zig");
const Resources = struct {
    shaders: [5][]const u8,
};
const resources: Resources = @import("resources.zon");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "version", try std.SemanticVersion.parse(pkg.version));

    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig_src = vk_generate_cmd.addOutputFileArg("vk.zig");

    const strip_debug = b.option(bool, "strip-debug", "Emmited executable will not contain debug symbols");

    const standard_target = b.standardTargetOptions(.{});
    const standard_module = try buildRootModuleForTarget(
        b,
        standard_target,
        optimize,
        options,
        vulkan_zig_src,
        strip_debug orelse false,
    );

    const standard_exe = b.addExecutable(.{
        .name = if (optimize != .Debug) b.fmt("BROT-{s}-{s}-{s}", .{
            pkg.version,
            @tagName(standard_target.result.cpu.arch),
            @tagName(standard_target.result.os.tag),
        }) else "BROT_debug",
        .root_module = standard_module,
        .use_llvm = true,
    });

    const standard_install_artifact = b.addInstallArtifact(standard_exe, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&standard_install_artifact.step);

    const run_cmd = b.addRunArtifact(standard_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .name = "top level tests",
        .root_module = standard_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const cross_step = b.step("cross", "Compile for many targets");

    for (targets) |target| {
        const exe = b.addExecutable(.{
            .name = b.fmt("BROT-{s}-{s}-{s}", .{
                pkg.version,
                @tagName(target.cpu_arch.?),
                @tagName(target.os_tag.?),
            }),
            .root_module = try buildRootModuleForTarget(
                b,
                b.resolveTargetQuery(target),
                optimize,
                options,
                vulkan_zig_src,
                strip_debug orelse true,
            ),
            .use_llvm = true,
        });

        const target_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .prefix },
        });

        cross_step.dependOn(&target_output.step);
    }
}

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

fn buildRootModuleForTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    vulkan_zig_src: std.Build.LazyPath,
    strip_debug: bool,
) !*std.Build.Module {
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

    const vulkan_module = b.addModule("vulkan-zig", .{ .root_source_file = vulkan_zig_src });

    const gmp_dep = b.dependency("gmp", .{
        .target = target,
        .optimize = optimize,
    });
    const gmp = try buildGmpStatic(b, gmp_dep.path("."), target);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.link_libc = true;
    translate_c.step.dependOn(gmp.step);
    translate_c.addIncludePath(gmp.include);
    translate_c.addIncludePath(glslang.builder.dependency("glslang", .{}).path("."));

    const cimgui_lib = cimgui_dep.artifact("cimgui");
    addIncludePathsToTranslateC(translate_c, cimgui_lib);
    const c_module = translate_c.createModule();
    c_module.addObjectFile(gmp.archive);
    c_module.linkLibrary(cimgui_lib);
    c_module.linkLibrary(glslang.artifact("glslang"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_debug,
        .imports = &.{
            .{ .name = "c", .module = c_module },
            .{ .name = "vulkan", .module = vulkan_module },
        },
    });
    root_module.addOptions("build_options", options);

    return root_module;
}

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

/// Shells out to GMP's own configure + make, using zig cc/zig ar/
/// zig ranlib as the cross toolchain.
///
/// REQUIRES A POSIX SHELL, MAKE, AND M4 ON BUILD MACHINE!
fn buildGmpStatic(
    b: *std.Build,
    gmp_path: std.Build.LazyPath,
    resolved_target: std.Build.ResolvedTarget,
) !GmpArtifact {
    const info = try gmpTargetInfo(resolved_target.result);

    const zig_exe = b.graph.zig_exe;

    const build_subdir = b.fmt(".gmp-build/{s}", .{info.zig_triple});

    const cc = b.fmt("{s} cc -target {s}", .{ zig_exe, info.zig_triple });
    const ar = b.fmt("{s} ar", .{zig_exe});
    const ranlib = b.fmt("{s} ranlib", .{zig_exe});
    const maybe_fat = if (resolved_target.result.cpu.arch == .x86_64) " --enable-fat" else "";

    // runs GMP's config / make using the zig toolchain for cross-compilation
    const script = b.fmt(
        \\set -e
        \\SRC="$1"
        \\BUILD="{s}"
        \\OUT_ARCHIVE="$2"
        \\OUT_INCLUDE="$3"
        \\mkdir -p "$BUILD"
        \\cd "$BUILD"
        \\CC="{s}" AR="{s}" RANLIB="{s}" "$SRC/configure" \
        \\  --host={s} \
        \\  --disable-shared --enable-static --with-pic --disable-cxx{s} \
        //prevent warnings from making it to zig stdout/stderr
        \\2> /dev/null
        \\make -j MAKEINFO=true PERL=true TEXI2DVI=true
        \\mv .libs/libgmp.a "$OUT_ARCHIVE"
        \\mv gmp.h "$OUT_INCLUDE"
    , .{ build_subdir, cc, ar, ranlib, info.gmp_triple, maybe_fat });

    const run = b.addSystemCommand(&.{ "sh", "-c", script, "sh" });
    run.setCwd(gmp_path);
    run.addDirectoryArg(gmp_path);
    const libgmp = run.addOutputFileArg("libgmp.a"); // explicit output file allows caching
    const include = run.addOutputDirectoryArg("libgmp_include");
    run.setName(b.fmt("configure + make gmp ({s})", .{info.zig_triple}));

    return GmpArtifact{ .include = include, .archive = libgmp, .step = &run.step };
}

fn gmpTargetInfo(t: std.Target) !TargetInfo {
    return switch (t.os.tag) {
        .linux => switch (t.cpu.arch) {
            .x86_64 => TargetInfo{ .zig_triple = "x86_64-linux-gnu", .gmp_triple = "x86_64-unknown-linux-gnu" },
            .aarch64 => TargetInfo{ .zig_triple = "aarch64-linux-gnu", .gmp_triple = "aarch64-unknown-linux-gnu" },
            else => error.UnsupportedTarget,
        },
        .windows => switch (t.cpu.arch) {
            .x86_64 => TargetInfo{ .zig_triple = "x86_64-windows-gnu", .gmp_triple = "x86_64-w64-mingw32" },
            .aarch64 => TargetInfo{ .zig_triple = "aarch64-windows-gnu", .gmp_triple = "aarch64-w64-mingw32" },
            else => error.UnsupportedTarget,
        },
        .macos => switch (t.cpu.arch) {
            .x86_64 => TargetInfo{ .zig_triple = "x86_64-macos", .gmp_triple = "x86_64-apple-darwin" },
            .aarch64 => TargetInfo{ .zig_triple = "aarch64-macos", .gmp_triple = "aarch64-apple-darwin" },
            else => error.UnsupportedTarget,
        },
        else => error.UnsupportedTarget,
    };
}

const GmpArtifact = struct {
    include: std.Build.LazyPath,
    /// actual library artifact (libgmp.a)
    archive: std.Build.LazyPath,
    step: *std.Build.Step,
};

const TargetInfo = struct {
    zig_triple: []const u8,
    gmp_triple: []const u8,
};
