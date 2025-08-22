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

#version 450

layout(location = 0) out vec4 outColor;

layout(push_constant) uniform UniformBufferObject {
    uint max_width;
} ubo;
layout(std430, binding = 1) readonly buffer storage {
    float potential_vals[];
};

void main() {
    float potential_val = potential_vals[uint(gl_FragCoord.x) + uint(gl_FragCoord.y) * ubo.max_width.x];

    if (potential_val == -1) {
    	outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
    	outColor = vec4(sin(potential_val * 2.0 - 1.1f) / 2.0f + 0.5f, sin(potential_val * 2.0 - 1.9f) / 2.0f + 0.5f, 0.0, 1.0);
        outColor = outColor * outColor;
	}

}
