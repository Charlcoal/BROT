const std = @import("std");
const FixedPoint = @This();

internal_int: std.math.big.int.Managed,
limbs_after_point: usize,

const limb_bits: comptime_int = @typeInfo(std.math.big.Limb).int.bits;

pub fn init(alloc: std.mem.Allocator, limbs_after_point: usize) !FixedPoint {
    return .{
        .internal_int = try .init(alloc),
        .limbs_after_point = limbs_after_point,
    };
}

pub fn deinit(fixed_point: *FixedPoint) void {
    fixed_point.internal_int.deinit();
}

/// rma = a * b. rma, a, and b may alias, but it will be faster if rma is not aliased
pub fn mul(rma: *FixedPoint, a: FixedPoint, b: FixedPoint) !void {
    try rma.internal_int.ensureMulCapacity(a.internal_int.toConst(), b.internal_int.toConst());
    //std.debug.print("before ------- \nrma: {any}\na: {any}\nb: {any}\n\n", .{ rma.internal_int, a.internal_int, b.internal_int });
    try rma.internal_int.mul(&a.internal_int, &b.internal_int);
    //std.debug.print("after ------- \nrma: {any}\na: {any}\nb: {any}\n\n", .{ rma.internal_int, a.internal_int, b.internal_int });
    try rma.internal_int.shiftRight(&rma.internal_int, limb_bits * @min(a.limbs_after_point, b.limbs_after_point));
    //std.debug.print("after ------- \nrma: {any}\na: {any}\nb: {any}\n\n", .{ rma.internal_int, a.internal_int, b.internal_int });
    rma.limbs_after_point = @max(a.limbs_after_point, b.limbs_after_point);
}

/// r = a + b. r, a, and b may alias
pub fn add(r: *FixedPoint, a: *FixedPoint, b: *FixedPoint) !void {
    //std.debug.print("a: {any}\nb: {any}\n\n", .{ a.*, b.* });
    try a.extend(b.limbs_after_point);
    try b.extend(a.limbs_after_point);
    //std.debug.print("a: {any}\nb: {any}\n\n\n", .{ a.*, b.* });
    try r.internal_int.ensureAddCapacity(a.internal_int.toConst(), b.internal_int.toConst());
    try r.internal_int.add(&a.internal_int, &b.internal_int);
    r.limbs_after_point = a.limbs_after_point;
}

/// entends the precision
pub fn extend(a: *FixedPoint, new_limbs_after_point: usize) !void {
    if (new_limbs_after_point <= a.limbs_after_point) return;

    const increase: usize = new_limbs_after_point - a.limbs_after_point;
    try a.internal_int.shiftLeft(&a.internal_int, limb_bits * increase);
    a.limbs_after_point = new_limbs_after_point;
}

/// currently only handles normal float values (not subnormal / Nan / Inf)
pub fn fromFloat(alloc: std.mem.Allocator, val: f64) !FixedPoint {
    //std.debug.print("\n", .{});
    const float_bits: packed struct {
        mantissa: u52,
        exponent: u11,
        sign: u1,
    } = @bitCast(val);

    //std.debug.print("mantissa: {x}\n", .{float_bits.mantissa});

    if (float_bits.mantissa == 0 and float_bits.exponent == 0) {
        return .{ .internal_int = try .init(alloc), .limbs_after_point = 0 };
    }

    const true_exponent: i32 = @as(i32, float_bits.exponent) - 1023; // also greatest_bit_pos_absolute
    const true_mantissa: u64 = @as(u64, float_bits.mantissa) + (1 << 52);
    const lowest_bit_pos_absolute: i32 = true_exponent - 52;

    //std.debug.print("exponent: {}\n", .{true_exponent});

    const greatest_limb_pos_absolute: i32 = @divFloor(true_exponent, limb_bits);
    const least_limb_pos_absolute: i32 = @min(0, @divFloor(lowest_bit_pos_absolute, limb_bits));
    const limb_len: usize = @intCast(greatest_limb_pos_absolute - least_limb_pos_absolute + 1);

    //std.debug.print("range: {}.{}\n", .{ greatest_limb_pos_absolute, least_limb_pos_absolute });

    const mantissa_offset: usize = @intCast(lowest_bit_pos_absolute - limb_bits * least_limb_pos_absolute);
    const mantissa_shift_offset: i32 = @intCast(mantissa_offset % limb_bits);

    //std.debug.print("offset: {}\n", .{mantissa_offset});

    const least_mantissa_limb_pos: usize = @divFloor(mantissa_offset, limb_bits);
    const greatest_mantissa_limb_pos: usize = @intCast(greatest_limb_pos_absolute - least_limb_pos_absolute);
    const num_mantissa_limbs: usize = @intCast(greatest_mantissa_limb_pos - least_mantissa_limb_pos + 1);

    //std.debug.print("limb_len: {}\n", .{limb_len});

    var out: FixedPoint = .{
        .internal_int = try .initCapacity(alloc, limb_len),
        .limbs_after_point = @intCast(-least_limb_pos_absolute),
    };

    for (out.internal_int.limbs[least_mantissa_limb_pos .. greatest_mantissa_limb_pos + 1], 0..num_mantissa_limbs) |*limb, i| {
        const shft: i32 = mantissa_shift_offset - (limb_bits * @as(i32, @intCast(i)));
        if (shft < 0) {
            limb.* = @truncate(true_mantissa >> @intCast(-shft));
        } else {
            limb.* = @truncate(true_mantissa << @intCast(shft));
        }
        //std.debug.print("index: {}, shift: {}, limb: {x}\n", .{ i, shft, limb.* });
    }

    out.internal_int.setLen(limb_len);

    if (float_bits.sign == 1) out.internal_int.setSign(false);
    return out;
}

pub fn toFloat(val: FixedPoint) f64 {
    const naive_float: f64 = val.internal_int.toFloat(f64);

    var float_bits: packed struct {
        mantissa: u52,
        exponent: u11,
        sign: u1,
    } = @bitCast(naive_float);
    //std.debug.print("toFloat mantissa: {x}\n", .{float_bits.mantissa});
    //std.debug.print("exponent: {} -> {}\n", .{ float_bits.exponent, @as(i32, float_bits.exponent) - @as(i32, @intCast(limb_bits * val.limbs_after_point)) });
    float_bits.exponent = @intCast(@as(i32, float_bits.exponent) - @as(i32, @intCast(limb_bits * val.limbs_after_point)));

    return @bitCast(float_bits);
}

test "0 f64 -> FixedPoint -> f64" {
    const alloc = std.testing.allocator;

    var zero = try FixedPoint.fromFloat(alloc, 0);
    defer zero.deinit();

    try std.testing.expectEqual(zero.toFloat(), 0);
}

test "f64 -> FixedPoint -> f64" {
    const alloc = std.testing.allocator;

    var a = try FixedPoint.fromFloat(alloc, 1.9998652e-2);
    defer a.deinit();
    try std.testing.expectEqual(1.9998652e-2, a.toFloat());

    var b = try FixedPoint.fromFloat(alloc, 2e-100);
    defer b.deinit();
    try std.testing.expectEqual(2e-100, b.toFloat());

    var c = try FixedPoint.fromFloat(alloc, 1e+100);
    defer c.deinit();
    try std.testing.expectEqual(1e+100, c.toFloat());

    var d = try FixedPoint.fromFloat(alloc, -9.7661523e-23);
    defer d.deinit();
    try std.testing.expectEqual(-9.7661523e-23, d.toFloat());
}

test "limits f64 -> FixedPoint -> f64" {
    const alloc = std.testing.allocator;

    var a = try FixedPoint.fromFloat(alloc, -1.2908723746012398476452879);
    defer a.deinit();
    try std.testing.expectEqual(-1.2908723746012398476452879, a.toFloat());

    var b = try FixedPoint.fromFloat(alloc, 1e-333);
    defer b.deinit();
    try std.testing.expectEqual(1e-333, b.toFloat());

    var c = try FixedPoint.fromFloat(alloc, 1e+333);
    defer c.deinit();
    try std.testing.expectEqual(1e+333, c.toFloat());
}

test "extend precision" {
    const alloc = std.testing.allocator;

    var a = try FixedPoint.fromFloat(alloc, 1.9998652e-2);
    try a.extend(2);
    defer a.deinit();
    try std.testing.expectEqual(1.9998652e-2, a.toFloat());

    var b = try FixedPoint.fromFloat(alloc, 2e-100);
    defer b.deinit();
    try b.extend(8);
    try std.testing.expectEqual(2e-100, b.toFloat());
}

test "add - equal precision" {
    const alloc = std.testing.allocator;

    const float_a: f64 = 1.9998652;
    const float_b: f64 = -9.7661523;

    var a = try FixedPoint.fromFloat(alloc, float_a);
    var b = try FixedPoint.fromFloat(alloc, float_b);
    defer a.deinit();
    defer b.deinit();
    try a.add(&a, &b);
    try std.testing.expectEqual(float_a + float_b, a.toFloat());
}

test "add - different precision" {
    const alloc = std.testing.allocator;

    const float_a: f64 = 1.9998652e-2;
    const float_b: f64 = -9.7661523e-23;

    var a = try FixedPoint.fromFloat(alloc, float_a);
    var b = try FixedPoint.fromFloat(alloc, float_b);
    defer a.deinit();
    defer b.deinit();
    try a.add(&a, &b);
    try std.testing.expectEqual(float_a + float_b, a.toFloat());
}

test "mul - equal precision" {
    const alloc = std.testing.allocator;

    const float_a: f64 = 1.9998652;
    const float_b: f64 = -9.7661523;

    var a = try FixedPoint.fromFloat(alloc, float_a);
    var b = try FixedPoint.fromFloat(alloc, float_b);
    var r = try FixedPoint.init(alloc, 0);
    defer a.deinit();
    defer b.deinit();
    defer r.deinit();
    try r.mul(a, b);
    try std.testing.expect(std.math.approxEqRel(f64, float_a * float_b, r.toFloat(), 10 * std.math.floatEps(f64)));
}

test "mul - different precision" {
    const alloc = std.testing.allocator;

    const float_a: f64 = 1.9998652e-2;
    const float_b: f64 = -9.7661523e-23;

    var a = try FixedPoint.fromFloat(alloc, float_a);
    var b = try FixedPoint.fromFloat(alloc, float_b);
    var r = try FixedPoint.init(alloc, 0);
    defer a.deinit();
    defer b.deinit();
    defer r.deinit();
    try r.mul(a, b);
    try std.testing.expect(std.math.approxEqRel(f64, float_a * float_b, r.toFloat(), 10 * std.math.floatEps(f64)));
}
