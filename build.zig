const std = @import("std");

pub fn build(b: *std.Build) void {
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
    exe.linkSystemLibrary2("dl", .{});
    exe.linkSystemLibrary2("pthread", .{});
    exe.linkSystemLibrary2("X11", .{});
    exe.linkSystemLibrary2("Xxf86vm", .{});
    exe.linkSystemLibrary2("Xrandr", .{});
    exe.linkSystemLibrary2("Xi", .{});
    exe.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "third-party/glfw/include/" } });

    b.installArtifact(exe);
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
    exe_unit_tests.linkSystemLibrary2("dl", .{});
    exe_unit_tests.linkSystemLibrary2("pthread", .{});
    exe_unit_tests.linkSystemLibrary2("X11", .{});
    exe_unit_tests.linkSystemLibrary2("Xxf86vm", .{});
    exe_unit_tests.linkSystemLibrary2("Xrandr", .{});
    exe_unit_tests.linkSystemLibrary2("Xi", .{});
    exe_unit_tests.addIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "third-party/glfw/include/" } });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
