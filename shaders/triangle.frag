#version 450

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform UniformBufferObject {
    vec2 center;
    uvec2 resolution;
    float height_scale;
} ubo;
layout(std430, binding = 1) readonly buffer storage {
    float potential_vals[];
};

void main() {
    float potential_val = potential_vals[uint(gl_FragCoord.x) + uint(gl_FragCoord.y) * ubo.resolution.x];

    if (potential_val == -1) {
    	outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
    	outColor = vec4(sin(potential_val * 2.0 - 1.1f) / 2.0f + 0.5f, sin(potential_val * 2.0 - 1.9f) / 2.0f + 0.5f, 0.0, 1.0);
        outColor = outColor * outColor;
	}

}
