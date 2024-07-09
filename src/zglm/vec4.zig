pub const vec4 = struct {
    data: @Vector(4, f32),

    pub fn from_scalar(scalar: f32) vec4 {
        return @splat(scalar);
    }
};
