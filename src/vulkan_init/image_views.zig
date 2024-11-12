const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createImageViews(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.swap_chain_image_views = try alloc.alloc(c.VkImageView, data.swap_chain_images.len);

    for (data.swap_chain_images, 0..) |image, i| {
        const create_info: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = data.swap_chain_image_format,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        if (c.vkCreateImageView(data.device, &create_info, null, &data.swap_chain_image_views[i]) != c.VK_SUCCESS) {
            return InitVulkanError.image_views_creation_failed;
        }
    }
}
