#version 450

layout(location = 0) in vec2 fragLoc;
layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform UniformBufferObject {
    vec2 center;
    float height_scale;
    float width_to_height_ratio;
} ubo;

float fMod(float x, float M) {
    return x - int(x/M)*M;
}

void main() {
    const int max_count = 1000;
    const float R = 1000000;
    vec2 a = fragLoc * ubo.height_scale;
    a.x *= ubo.width_to_height_ratio;
    a += ubo.center;
    vec2 pos = vec2(0.0, 0.0);

    int count = 0;
    float x_sqr = pos.x * pos.x;
    float y_sqr = pos.y * pos.y;
    while (x_sqr + y_sqr < 4.0 && count < max_count) {
        pos.y = 2.0 * pos.x * pos.y + a.y;
        pos.x = x_sqr - y_sqr + a.x;
        x_sqr = pos.x * pos.x;
        y_sqr = pos.y * pos.y;
        count++;
    }

    if (count == max_count) {
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    for (int i = 0; i < 100 && x_sqr + y_sqr < R*R; i++) {
        pos.y = 2.0 * pos.x * pos.y + a.y;
        pos.x = x_sqr - y_sqr + a.x;
        x_sqr = pos.x * pos.x;
        y_sqr = pos.y * pos.y;
        count++;
    }
    float f_count = float(count + 1) - log2(log(x_sqr + y_sqr)/2);

    outColor = vec4(fMod(10*f_count, max_count) / float(max_count), f_count / float(max_count), 0.0, 1.0);
}
