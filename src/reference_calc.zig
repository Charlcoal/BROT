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
const common = @import("common_defs.zig");
const Allocator = std.mem.Allocator;

pub fn init(alloc: Allocator) Allocator.Error!void {
    common.perturbation_vals = try alloc.alloc(@Vector(2, f32), common.max_iterations);
}

pub fn update() void {
    c.mpf_set_d(&common.ref_calc_x, 0.0);
    c.mpf_set_d(&common.ref_calc_y, 0.0);

    for (0..common.max_iterations) |i| {
        // ------- z^2 --------
        // z = a + bi
        c.mpf_mul(&common.mpf_intermediates[0], &common.ref_calc_x, &common.ref_calc_y); // ab
        c.mpf_pow_ui(&common.mpf_intermediates[1], &common.ref_calc_x, 2); // a^2
        c.mpf_pow_ui(&common.mpf_intermediates[2], &common.ref_calc_y, 2); // b^2

        c.mpf_mul_ui(&common.ref_calc_y, &common.mpf_intermediates[0], 2); // 2ab
        c.mpf_sub(&common.ref_calc_x, &common.mpf_intermediates[1], &common.mpf_intermediates[2]); // a^2-b^2

        // ------ add c -------
        c.mpf_add(&common.mpf_intermediates[0], &common.ref_calc_x, &common.fractal_pos_x);
        c.mpf_add(&common.mpf_intermediates[1], &common.ref_calc_y, &common.fractal_pos_y);
        c.mpf_swap(&common.mpf_intermediates[0], &common.ref_calc_x);
        c.mpf_swap(&common.mpf_intermediates[1], &common.ref_calc_y);

        const real: f32 = @floatCast(c.mpf_get_d(&common.ref_calc_x));
        const imag: f32 = @floatCast(c.mpf_get_d(&common.ref_calc_y));

        common.perturbation_vals[i][0] = real;
        common.perturbation_vals[i][1] = imag;

        if (real * real + imag * imag > 1.0e8) break;
    }

    var mapped_data: [*]@Vector(2, f32) = undefined;
    _ = c.vkMapMemory(
        common.device,
        common.perturbation_staging_buffer_memory,
        0,
        2 * @sizeOf(f32) * common.max_iterations,
        0,
        @ptrCast(&mapped_data),
    );
    @memcpy(mapped_data, common.perturbation_vals);
    _ = c.vkUnmapMemory(common.device, common.perturbation_staging_buffer_memory);

    common.gpu_interface_semaphore.wait();
    common.copyBuffer(
        common.perturbation_buffer,
        common.perturbation_staging_buffer,
        2 * @sizeOf(f32) * common.max_iterations,
    );
    common.gpu_interface_semaphore.post();
}
