const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

const vert_code align(4) = @embedFile("triangle_vert_shader").*;
const frag_code align(4) = @embedFile("triangle_frag_shader").*;

pub fn createGraphicsPipeline(data: *common.AppData) InitVulkanError!void {
    const vert_shader_module = try createShaderModule(data.*, &vert_code);
    const frag_shader_module = try createShaderModule(data.*, &frag_code);
    defer _ = glfw.vkDestroyShaderModule(data.device, vert_shader_module, null);
    defer _ = glfw.vkDestroyShaderModule(data.device, frag_shader_module, null);

    const vert_shader_stage_info: glfw.VkPipelineShaderStageCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = glfw.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vert_shader_module,
        .pName = "main",
    };
    const frag_shader_stage_info: glfw.VkPipelineShaderStageCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = glfw.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader_module,
        .pName = "main",
    };

    const shader_stages = [_]glfw.VkPipelineShaderStageCreateInfo{
        vert_shader_stage_info,
        frag_shader_stage_info,
    };

    const dynamic_states = [_]glfw.VkDynamicState{
        glfw.VK_DYNAMIC_STATE_VIEWPORT,
        glfw.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dynamic_state: glfw.VkPipelineDynamicStateCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = @intCast(dynamic_states.len),
        .pDynamicStates = &dynamic_states,
    };

    const vertex_input_info: glfw.VkPipelineVertexInputStateCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    const input_assembly: glfw.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = glfw.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = glfw.VK_FALSE,
    };

    const viewport_state: glfw.VkPipelineViewportStateCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    const rasterizer: glfw.VkPipelineRasterizationStateCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = glfw.VK_FALSE,
        .rasterizerDiscardEnable = glfw.VK_FALSE,
        .polygonMode = glfw.VK_POLYGON_MODE_FILL,
        .lineWidth = 1,
        .cullMode = glfw.VK_CULL_MODE_BACK_BIT,
        .frontFace = glfw.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = glfw.VK_FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
    };

    const multisampling: glfw.VkPipelineMultisampleStateCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = glfw.VK_FALSE,
        .rasterizationSamples = glfw.VK_SAMPLE_COUNT_1_BIT,
        .minSampleShading = 1,
        .pSampleMask = null,
        .alphaToCoverageEnable = glfw.VK_FALSE,
        .alphaToOneEnable = glfw.VK_FALSE,
    };

    const color_blend_attachment: glfw.VkPipelineColorBlendAttachmentState = .{
        .colorWriteMask = glfw.VK_COLOR_COMPONENT_R_BIT | glfw.VK_COLOR_COMPONENT_G_BIT | glfw.VK_COLOR_COMPONENT_B_BIT | glfw.VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = glfw.VK_FALSE,
        .srcColorBlendFactor = glfw.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = glfw.VK_BLEND_FACTOR_ZERO,
        .colorBlendOp = glfw.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = glfw.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = glfw.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = glfw.VK_BLEND_OP_ADD,
    };

    const color_blending: glfw.VkPipelineColorBlendStateCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = glfw.VK_FALSE,
        .logicOp = glfw.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };

    const pipeline_layout_info: glfw.VkPipelineLayoutCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &data.descriptor_set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    if (glfw.vkCreatePipelineLayout(data.device, &pipeline_layout_info, null, &data.pipeline_layout) != glfw.VK_SUCCESS) {
        return InitVulkanError.pipeline_layout_creation_failed;
    }

    const pipeline_info: glfw.VkGraphicsPipelineCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = data.pipeline_layout,
        .renderPass = data.render_pass,
        .subpass = 0,
        .basePipelineHandle = @ptrCast(glfw.VK_NULL_HANDLE),
        .basePipelineIndex = -1,
    };

    if (glfw.vkCreateGraphicsPipelines(data.device, @ptrCast(glfw.VK_NULL_HANDLE), 1, &pipeline_info, null, &data.graphics_pipeline) != glfw.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createShaderModule(data: common.AppData, code: []align(4) const u8) InitVulkanError!glfw.VkShaderModule {
    const create_info: glfw.VkShaderModuleCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(code.ptr),
    };
    var shader_module: glfw.VkShaderModule = undefined;
    if (glfw.vkCreateShaderModule(data.device, &create_info, null, &shader_module) != glfw.VK_SUCCESS) {
        return InitVulkanError.shader_module_creation_failed;
    }
    return shader_module;
}
