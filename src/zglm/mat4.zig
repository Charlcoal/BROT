const vec4 = @import("vec4.zig").vec4;

const vf4 = @Vector(4, f32);

pub const mat4 = struct {
    columns: [4]vf4, // stored in columns by default

    pub fn mulv(self: mat4, vec: vec4) vec4 {
        const vx: vf4 = @splat(vec[0]);
        const vy: vf4 = @splat(vec[1]);
        const vz: vf4 = @splat(vec[2]);
        const vw: vf4 = @splat(vec[3]);

        var out = self.columns[0] * vx;
        out = self.columns[1] * vy + out;
        out = self.columns[2] * vz + out;
        out = self.columns[3] * vw + out;

        return vec4{ .data = out };
    }
};

pub const identity = mat4{ .data = [4]vf4{ vf4{ 1, 0, 0, 0 }, vf4{ 0, 1, 0, 0 }, vf4{ 0, 0, 1, 0 }, vf4{ 0, 0, 0, 1 } } };
