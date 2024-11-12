const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createFramebuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.swap_chain_framebuffers = try alloc.alloc(glfw.VkFramebuffer, data.swap_chain_image_views.len);

    for (0..data.swap_chain_image_views.len) |i| {
        const attachments = [_]glfw.VkImageView{
            data.swap_chain_image_views[i],
        };

        const frame_buffer_info: glfw.VkFramebufferCreateInfo = .{
            .sType = glfw.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = data.render_pass,
            .attachmentCount = @intCast(attachments.len),
            .pAttachments = &attachments,
            .width = data.swap_chain_extent.width,
            .height = data.swap_chain_extent.height,
            .layers = 1,
        };

        if (glfw.vkCreateFramebuffer(data.device, &frame_buffer_info, null, &data.swap_chain_framebuffers[i]) != glfw.VK_SUCCESS) {
            return InitVulkanError.framebuffer_creation_failed;
        }
    }
}
