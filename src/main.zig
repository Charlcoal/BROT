const std = @import("std");
//const imports = @import("imports.zig");
//const glfw = imports.glfw;
//const mat4 = @import("zglm/mat4.zig");
const app = @import("hello_triangle/app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    try app.run(alloc);
}
