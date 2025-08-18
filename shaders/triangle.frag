#version 450

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform UniformBufferObject {
    vec2 center;
    uvec2 resolution;
    float height_scale;
} ubo;
layout(std430, binding = 1) readonly buffer storage {
    float neg_log_potentials[];
};

void main() {
    const int max_count = 5000;
    float neg_log_potential = neg_log_potentials[uint(gl_FragCoord.x) + uint(gl_FragCoord.y) * ubo.resolution.x];

    if (neg_log_potential == -1) {
    	outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
		float portion = neg_log_potential / float(max_count);
    	outColor = vec4(sin(portion * 60.0f - 0.8f) / 2.0f + 0.5f, sin(portion * 60.0f - 1.6f) / 2.0f + 0.5f, 0.0, 1.0);
        outColor = outColor * outColor;
	}

}
