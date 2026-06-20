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

/// Only change when no GMP objects are active!
/// (just don't touch after calling GMP / big_float functions)
pub var allocator: Allocator = undefined;

/// converts a decimal string representation of a number (possibly in scientific notation)
/// into an mpf_t number, with enough underlying bits to properly represent the number
/// (+/-1 in least significant decimal place).
pub fn stringInit(str: [:0]const u8) c.mpf_t {
    const dec_pow_to_bin_pow = @log2(@as(f64, 10));
    var e_pos = std.mem.indexOfScalar(u8, str, 'e') orelse str.len;
    e_pos -= std.mem.findAny(u8, str, &.{ '1', '2', '3', '4', '5', '6', '7', '8', '9' }) orelse (str.len);
    const e_pos_flt: f64 = @floatFromInt(e_pos);
    const bit_prec: usize = @trunc(e_pos_flt * dec_pow_to_bin_pow + 1.0);

    var out: c.mpf_t = undefined;
    c.mpf_set_default_prec(bit_prec);
    _ = c.mpf_init_set_str(&out, str, 10);

    return out;
}

/// Only call when no GMP objects are active! (just call before anything else)
pub fn setAllocator(alloc: Allocator) void {
    allocator = alloc;
    c.mp_set_memory_functions(
        gmpAlloc,
        gmpRealloc,
        gmpFree,
    );
}

/// Ensures val has at least prec_bits of precision, increasing its precision if not.
/// Returns true if val's precision was increased
pub fn ensurePrecision(val: *c.mpf_t, prec_bits: usize) bool {
    if (prec_bits > c.mpf_get_prec(val)) {
        c.mpf_set_prec(val, prec_bits);
        return true;
    }
    return false;
}

/// Converts mpf_t to string, NOT in scientific notation
/// (i.e. 0.000876 instead of 8.76e-4)
///
/// Returned string is owned by called and must be freed by
/// the same allocator set with set_allocator.
///
/// max_digits is the maximum number of non-trailing-zero non-leading-zero digits returned,
/// while max_size is the total maximum size of the returned string
/// (to prevent huge allocation attempts at high magnitude, for example).
///
/// The actual output will be reduced by trailing zeros in digits (e.g. 6.70 with max_digits == 3 becomes 6.7),
/// and by limited precision in the underlying representation (mpf default behaviour)
pub fn toStringFlat(max_digits: usize, max_size: usize, val: *const c.mpf_t) (error{too_big} || Allocator.Error)![]u8 {
    var exp: c.mp_exp_t = undefined;
    const digits_raw = c.mpf_get_str(null, &exp, 10, max_digits, val);
    const digits: [:0]u8 = @ptrCast(digits_raw[0..std.mem.len(digits_raw)]);
    defer allocator.free(digits);
    const num_digits: c_long = @intCast(digits.len);

    const needed_padding: usize = @intCast(if (exp <= 0)
        @as(c_long, @intCast(@abs(exp) + 2)) // 1 for leading 0, 1 for decimal point, @abs(exp) for zeros after decimal point
    else if (exp < num_digits)
        1 // 1 for decimal point inserted between digits
    else
        exp - num_digits); // trailing zeros, no decimal point

    if (needed_padding + digits.len > max_size) return error.too_big;
    const out: []u8 = try allocator.alloc(u8, digits.len + needed_padding);

    var wi: usize = 0; // write index
    if (digits[0] == '-') {
        out[wi] = '-';
        wi += 1;
    }

    if (exp <= 0) { // 0.00XXXXX
        const abs_exp: usize = @as(usize, @intCast(@abs(exp)));
        out[wi] = '0';
        out[wi + 1] = '.';
        wi += 2;
        @memset(out[wi .. wi + abs_exp], '0');
        wi += abs_exp;
        @memcpy(out[wi..], digits);
    } else if (exp < num_digits) { // XX.XXXXXX
        const exp_usize: usize = @intCast(exp);
        @memcpy(out[wi .. wi + exp_usize], digits[0..exp_usize]);
        wi += exp_usize;
        out[wi] = '.';
        wi += 1;
        @memcpy(out[wi..], digits[exp_usize..]);
    } else { // XXXXXXXX0000
        @memcpy(out[wi .. wi + digits.len], digits);
        wi += digits.len;
        @memset(out[wi..], '0');
    }

    return out;
}

// GMP is unable to handle allocation errors gracefully, must panic
fn gmpAlloc(size: usize) callconv(.c) ?*anyopaque {
    return (allocator.alloc(u8, size) catch std.debug.panic("GMP allocation failed!", .{})).ptr;
}

fn gmpRealloc(ptr: ?*anyopaque, old_size: usize, new_size: usize) callconv(.c) ?*anyopaque {
    const old_slice = @as([*]u8, @ptrCast(ptr))[0..old_size];
    return (allocator.remap(old_slice, new_size) orelse blk: {
        const min_size = @min(old_size, new_size);
        const new_slice: []u8 = allocator.alloc(u8, new_size) catch std.debug.panic("GMP allocation failed!", .{});
        @memcpy(new_slice[0..min_size], old_slice[0..min_size]);
        allocator.free(old_slice);
        break :blk new_slice;
    }).ptr;
}

fn gmpFree(ptr: ?*anyopaque, size: usize) callconv(.c) void {
    const old_slice = @as([*]u8, @ptrCast(ptr))[0..size];
    allocator.free(old_slice);
}

test "stringTest" {
    setAllocator(std.testing.allocator);

    var a = stringInit("0.09287162330897862879");
    defer c.mpf_clear(&a);
    const a_str = try toStringFlat(19, 1024, &a);
    defer allocator.free(a_str);
    try std.testing.expectEqualStrings("0.09287162330897862879", a_str);
    try std.testing.expectEqual(64, c.mpf_get_prec(&a));
}

test toStringFlat {
    setAllocator(std.testing.allocator);

    var a = stringInit("0.012871623");
    defer c.mpf_clear(&a);
    const a_str = try toStringFlat(5, 1024, &a);
    defer allocator.free(a_str);
    try std.testing.expectEqualStrings("0.012872", a_str);

    var b = stringInit("12871623");
    defer c.mpf_clear(&b);
    const b_str = try toStringFlat(3, 1024, &b);
    defer allocator.free(b_str);
    try std.testing.expectEqualStrings("12900000", b_str);

    var d = stringInit("2034.986");
    defer c.mpf_clear(&d);
    const d_str = try toStringFlat(6, 1024, &d);
    defer allocator.free(d_str);
    try std.testing.expectEqualStrings("2034.99", d_str);

    // test trailing zeros
    var a_z = stringInit("0.012871");
    defer c.mpf_clear(&a_z);
    const a_z_str = try toStringFlat(9, 1024, &a_z);
    defer allocator.free(a_z_str);
    try std.testing.expectEqualStrings("0.012871", a_z_str);

    var b_z = stringInit("1287");
    defer c.mpf_clear(&b_z);
    const b_z_str = try toStringFlat(8, 1024, &b_z);
    defer allocator.free(b_z_str);
    try std.testing.expectEqualStrings("1287", b_z_str);

    var d_z = stringInit("2034.1996");
    defer c.mpf_clear(&d_z);
    const d_z_str = try toStringFlat(7, 1024, &d_z);
    defer allocator.free(d_z_str);
    try std.testing.expectEqualStrings("2034.2", d_z_str);
}

const Allocator = std.mem.Allocator;

const std = @import("std");
const c = @import("c");
