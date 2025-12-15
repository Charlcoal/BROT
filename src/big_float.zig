// BROT - A fast mandelbrot set explorer
// Copyright (C) 2025  Charles Reischer
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
const c = @import("imports.zig").c;
const Allocator = std.mem.Allocator;

pub fn string_init(str: [:0]const u8) c.mpf_t {
    const e_pos = std.mem.indexOfScalar(u8, str, 'e');
    const e_pos_flt: f64 = @floatFromInt(e_pos orelse str.len);
    const bit_prec: usize = @intFromFloat(e_pos_flt * 3.321928095 + 1.0);

    var out: c.mpf_t = undefined;
    c.mpf_set_default_prec(bit_prec);
    _ = c.mpf_init_set_str(&out, str, 10);

    return out;
}

/// returned string (likely) has null-termination before allocated end
pub fn to_string(allocator: Allocator, digits: usize, val: *const c.mpf_t) Allocator.Error![:0]u8 {
    const str_blank: []u8 = try allocator.alloc(u8, digits + 24);
    str_blank[str_blank.len - 1] = 0;
    var str: [:0]u8 = @ptrCast(str_blank);
    str.len -= 1;

    var exp: c.mp_exp_t = undefined;
    _ = c.mpf_get_str(str[2..], &exp, 10, digits, val);

    if (str[2] == 0) {
        str[1] = '0';
        str[0] = ' ';
        return str;
    }

    const negative = str[2] == '-';
    if (exp == 0) {
        if (negative) {
            str[0] = '-';
            str[1] = '0';
            str[2] = '.';
        } else {
            str[0] = '0';
            str[1] = '.';
        }
        return str;
    }

    if (negative) {
        str[0] = ' ';
        str[1] = '-';
        str[2] = str[3];
        str[3] = '.';
    } else {
        str[0] = ' ';
        str[1] = str[2];
        str[2] = '.';
    }

    const mpf_part: [:0]u8 = std.mem.span(str.ptr);
    if (exp != 1) {
        str[mpf_part.len] = 'e';
        const exp_part = std.fmt.bufPrint(str[mpf_part.len + 1 .. str.len - 1], "{d}", .{exp - 1}) catch unreachable;
        str[exp_part.len + mpf_part.len + 1] = 0;
    }
    return str;
}

test "string test" {
    var a = string_init("0.012871623");
    const a_str = try to_string(std.testing.allocator, 5, &a);
    std.debug.print("{s}\n", .{a_str.ptr});
    std.debug.print("{any}\n", .{a_str});
    c.mpf_clear(&a);
    std.testing.allocator.free(a_str);
    //try std.testing.expect(false);
}
