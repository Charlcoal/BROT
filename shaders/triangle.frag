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
    uvec2 cur_res;
    uint max_width;
    float zoom_diff;
} ubo;
layout(std430, binding = 1) readonly buffer storage {
    float potential_vals[];
};

void main() {
    //uvec2 true_loc = ivec2((gl_FragCoord.xy - (vec2(ubo.cur_res)/2.0)) * ubo.zoom_diff) + ubo.cur_res;
    //float potential_val = potential_vals[true_loc.x + true_loc.y * ubo.max_width.x];
    
    ivec2 zoom_out_loc = ivec2((gl_FragCoord.xy - (vec2(ubo.cur_res)/2.0)) * ubo.zoom_diff) * 2 + ivec2(ubo.cur_res);

    float potential_val;
    if (zoom_out_loc.x >= 2 * ubo.cur_res.x || zoom_out_loc.x < 0 || zoom_out_loc.y >= 2 * ubo.cur_res.y || zoom_out_loc.y < 0) {
        potential_val = -1;
    } else {
        potential_val = potential_vals[zoom_out_loc.x + zoom_out_loc.y * ubo.max_width.x];
    }

    if (uint(gl_FragCoord.x) == ubo.cur_res.x/4 || uint(gl_FragCoord.x) == 3 * ubo.cur_res.x/4 || uint(gl_FragCoord.y) == ubo.cur_res.y/4 || uint(gl_FragCoord.y) == 3 * ubo.cur_res.y/4) {
        outColor = vec4(0.0, 0.0, 1.0, 1.0);
        return;
    }

    if (potential_val == -1) {
    	outColor = vec4(0.0, 0.0, 0.0, 1.0);
    } else {
        float r = sin(potential_val * 2.0 - 1.1f) / 2.0f;
        float g = sin(potential_val * 2.0 - 1.9f) / 2.0f;
    	outColor = vec4(r+0.5f, g+0.5f, g*0.5f +0.5f, 1.0);
        outColor = outColor * outColor;
	}

}
