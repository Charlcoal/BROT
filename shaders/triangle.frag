#version 450

layout(location = 0) in vec2 fragLoc;
layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform UniformBufferObject {
    vec2 center;
    float height_scale;
    float width_to_height_ratio;
} ubo;

void main() {
    const int max_count = 5000;
	const float escape_radius = 1e8;
	const float interior_test_e_sqr = 1e-6;
    vec2 c = fragLoc * ubo.height_scale + ubo.center;
    c.x *= ubo.width_to_height_ratio;
    vec2 pos = c;

    int count = 1;
    float x_sqr = pos.x * pos.x;
    float y_sqr = pos.y * pos.y;
	float rad_sqr = x_sqr + y_sqr;
	float interior_test_sqr = rad_sqr;
    while (rad_sqr < escape_radius * escape_radius && count < max_count && interior_test_sqr > interior_test_e_sqr) {
        pos.y = 2.0 * pos.x * pos.y + c.y;
        pos.x = x_sqr - y_sqr + c.x;
        x_sqr = pos.x * pos.x;
        y_sqr = pos.y * pos.y;
		rad_sqr = x_sqr + y_sqr;
		interior_test_sqr *= 4.0 * rad_sqr;
        count++;
    }

    if (count == max_count || interior_test_sqr <= interior_test_e_sqr) {
    	outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
		float neg_log_potential = max(0, count - log2(log2(x_sqr + y_sqr) / 2.0f));
		float portion = neg_log_potential / float(max_count);
    	outColor = vec4(sin(portion * 60.0f - 0.8f) / 2.0f + 0.5f, sin(portion * 60.0f - 1.6f) / 2.0f + 0.5f, 0.0, 1.0);
	}

}
