const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createRenderPass(data: *common.AppData) InitVulkanError!void {
    const color_attachment: glfw.VkAttachmentDescription = .{
        .format = data.swap_chain_image_format,
        .samples = glfw.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = glfw.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = glfw.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = glfw.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = glfw.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = glfw.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = glfw.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const color_attachment_ref: glfw.VkAttachmentReference = .{
        .attachment = 0,
        .layout = glfw.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const subpass: glfw.VkSubpassDescription = .{
        .pipelineBindPoint = glfw.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
    };

    const dependency: glfw.VkSubpassDependency = .{
        .srcSubpass = glfw.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = glfw.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = glfw.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = glfw.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };

    const render_pass_info: glfw.VkRenderPassCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    if (glfw.vkCreateRenderPass(data.device, &render_pass_info, null, &data.render_pass) != glfw.VK_SUCCESS) {
        return InitVulkanError.render_pass_creation_failed;
    }
}
