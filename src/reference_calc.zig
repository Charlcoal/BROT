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

pub fn init(alloc: Allocator) Allocator.Error!void {
    common.perturbation_vals = try alloc.alloc(@Vector(2, f32), common.allocated_iterations);
}

pub fn update(io: std.Io, max_iterations: u32) !void {
    _ = big_float.ensurePrecision(&common.ref_calc_x, c.mpf_get_prec(&common.fractal_pos.x));
    _ = big_float.ensurePrecision(&common.ref_calc_y, c.mpf_get_prec(&common.fractal_pos.y));

    c.mpf_set_d(&common.ref_calc_x, 0.0);
    c.mpf_set_d(&common.ref_calc_y, 0.0);

    for (0..max_iterations) |i| {
        const real: f32 = @floatCast(c.mpf_get_d(&common.ref_calc_x));
        const imag: f32 = @floatCast(c.mpf_get_d(&common.ref_calc_y));

        common.perturbation_vals[i][0] = real;
        common.perturbation_vals[i][1] = imag;

        if (real * real + imag * imag > 1.0e12) break;

        // ------- z^2 --------
        // z = a + bi
        c.mpf_mul(&common.mpf_intermediates[0], &common.ref_calc_x, &common.ref_calc_y); // ab
        c.mpf_pow_ui(&common.mpf_intermediates[1], &common.ref_calc_x, 2); // a^2
        c.mpf_pow_ui(&common.mpf_intermediates[2], &common.ref_calc_y, 2); // b^2

        c.mpf_mul_ui(&common.ref_calc_y, &common.mpf_intermediates[0], 2); // 2ab
        c.mpf_sub(&common.ref_calc_x, &common.mpf_intermediates[1], &common.mpf_intermediates[2]); // a^2-b^2

        // ------ add c -------
        c.mpf_add(&common.mpf_intermediates[0], &common.ref_calc_x, &common.fractal_pos.x);
        c.mpf_add(&common.mpf_intermediates[1], &common.ref_calc_y, &common.fractal_pos.y);
        c.mpf_swap(&common.mpf_intermediates[0], &common.ref_calc_x);
        c.mpf_swap(&common.mpf_intermediates[1], &common.ref_calc_y);
    }

    const mapped_data: ?[*]@Vector(2, f32) = @ptrCast(@alignCast(try vulkan.device.mapMemory(
        common.perturbation_staging_buffer_memory,
        0,
        2 * @sizeOf(f32) * common.allocated_iterations,
        .{},
    )));
    @memcpy(mapped_data.?, common.perturbation_vals);
    _ = vulkan.device.unmapMemory(common.perturbation_staging_buffer_memory);

    const next_index: usize = (common.current_cpu_to_render_descriptor_index + 1) % 2;

    common.gpu_interface_lock.lockUncancelable(io);
    defer common.gpu_interface_lock.unlock(io);
    try copyBuffer(
        common.perturbation_buffer,
        common.perturbation_staging_buffer,
        2 * @sizeOf(f32) * common.allocated_iterations,
        .{ .dst_offset = next_index * 2 * @sizeOf(f32) * common.allocated_iterations },
    );
    common.current_cpu_to_render_descriptor_index = next_index;
}

const CopyBufferOptions = struct {
    src_offset: u64 = 0,
    dst_offset: u64 = 0,
};

fn copyBuffer(dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize, options: CopyBufferOptions) !void {
    var command_buffer: vk.CommandBuffer = undefined;
    try vulkan.device.allocateCommandBuffers(&.{
        .level = .primary,
        .command_pool = common.graphics_command_pool,
        .command_buffer_count = 1,
    }, (&command_buffer)[0..1]);

    defer vulkan.device.freeCommandBuffers(
        common.graphics_command_pool,
        (&command_buffer)[0..1],
    );

    try vulkan.device.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    const copy_region: vk.BufferCopy = .{
        .src_offset = options.src_offset,
        .dst_offset = options.dst_offset,
        .size = size,
    };
    vulkan.device.cmdCopyBuffer(command_buffer, src, dst, (&copy_region)[0..1]);
    try vulkan.device.endCommandBuffer(command_buffer);

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = (&command_buffer)[0..1],
    };
    _ = try vulkan.device.queueSubmit(vulkan.graphics_queue, (&submit_info)[0..1], .null_handle);
    _ = try vulkan.device.queueWaitIdle(vulkan.graphics_queue);
}

const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const std = @import("std");
const c = @import("c");
const common = @import("common_defs.zig");
const vulkan = @import("vulkan.zig");
const big_float = @import("big_float.zig");
