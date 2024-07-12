const std = @import("std");
const common = @import("../common_defs.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createImageViews(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.swap_chain_image_views = try alloc.alloc(glfw.VkImageView, data.swap_chain_images.len);

    for (data.swap_chain_images, 0..) |image, i| {
        const create_info: glfw.VkImageViewCreateInfo = .{
            .sType = glfw.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = glfw.VK_IMAGE_VIEW_TYPE_2D,
            .format = data.swap_chain_image_format,
            .components = .{
                .r = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = glfw.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = glfw.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        if (glfw.vkCreateImageView(data.device, &create_info, null, &data.swap_chain_image_views[i]) != glfw.VK_SUCCESS) {
            return InitVulkanError.image_views_creation_failed;
        }
    }
}
