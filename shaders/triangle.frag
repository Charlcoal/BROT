#version 450

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform UniformBufferObject {
    vec2 center;
    uvec2 max_resolution;
    uvec2 screen_offset;
    float height_scale;
    int res_scale_exp;
} ubo;
layout(std430, binding = 1) readonly buffer storage {
    float potential_vals[];
};

void main() {
    float potential_val = potential_vals[uint(gl_FragCoord.x) + uint(gl_FragCoord.y) * ubo.max_resolution.x];

    if (potential_val == -1) {
    	outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
    	outColor = vec4(sin(potential_val * 1.0 - 1.1f) / 2.0f + 0.5f, sin(potential_val * 1.0 - 1.9f) / 2.0f + 0.5f, 0.0, 1.0);
        outColor = outColor * outColor;
	}

}
