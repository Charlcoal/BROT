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

pub fn main(init: std.process.Init) !void {
    const cwd = std.Io.Dir.cwd();
    const cache_path = if (builtin.mode == .Debug) // for easy removal when developing
        "BROTEXE_cache"
    else if (builtin.os.tag == .windows) // Appdata/Roaming/BROT/Temp
        try std.fs.path.resolveWindows(init.gpa, &.{ init.environ_map.get("APPDATA").?, "BROT", "Temp" })
    else if (builtin.os.tag == .linux) // ~/.cache/BROT
        try std.fs.path.resolvePosix(init.gpa, &.{ init.environ_map.get("HOME").?, ".cache", "BROT" })
    else
        @compileError("OS cache location is not defined!!!");

    const cache_dir = try cwd.createDirPathOpen(init.io, cache_path, .{});
    defer cache_dir.close(init.io);

    try app.run(init.gpa, init.io, cache_dir);
}

pub const std_options: std.Options = .{
    .log_level = std.log.default_level,
    .log_scope_levels = &.{
        .{ .scope = .render_patch, .level = std.log.Level.info },
    },
};

test "includeAllTests" {
    std.testing.refAllDecls(@import("big_float.zig"));
}

const builtin = @import("builtin");
const std = @import("std");
const app = @import("app.zig");
