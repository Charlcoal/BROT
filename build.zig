const std = @import("std");
const Resources = struct {
    shaders: [3][]const u8,
};
const resources: Resources = @import("resources.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "Lum",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary2("glfw", .{});
    exe.linkSystemLibrary2("vulkan", .{});
    exe.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "third-party/glfw/include/" } });

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
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.linkLibC();
    exe_unit_tests.linkSystemLibrary2("glfw", .{});
    exe_unit_tests.linkSystemLibrary2("vulkan", .{});
    //exe_unit_tests.linkSystemLibrary2("dl", .{});
    //exe_unit_tests.linkSystemLibrary2("pthread", .{});
    //exe_unit_tests.linkSystemLibrary2("X11", .{});
    //exe_unit_tests.linkSystemLibrary2("Xxf86vm", .{});
    //exe_unit_tests.linkSystemLibrary2("Xrandr", .{});
    //exe_unit_tests.linkSystemLibrary2("Xi", .{});
    exe_unit_tests.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "third-party/glfw/include/" } });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
