const instance = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
const v_init_common = @import("v_init_common_defs.zig");
const c = common.c;

const Allocator = std.mem.Allocator;

pub const Error = error{
    logical_device_creation_failed,
    image_views_creation_failed,
};

pub const Swapchain = struct {
    vk_swapchain: c.VkSwapchainKHR,
    extent: c.VkExtent2D,
    format: c.VkFormat,
    images: []c.VkImage,
    image_views: []c.VkImageView,

    fn init(alloc: Allocator, inst: instance.Instance, window: *c.GLFWwindow) Error!Swapchain {
        const surface_format = chooseSwapSurfaceFormat(inst.swap_chain_support.formats);
        const present_mode = chooseSwapPresentMode(inst.swap_chain_support.presentModes);
        const extent = chooseSwapExtent(window, &inst.swap_chain_support.capabilities);

        var image_count: u32 = inst.swap_chain_support.capabilities.minImageCount + 1;
        if (inst.swap_chain_support.capabilities.maxImageCount > 0 and image_count > inst.swap_chain_support.capabilities.maxImageCount) {
            image_count = inst.swap_chain_support.capabilities.maxImageCount;
        }

        var create_info: c.VkSwapchainCreateInfoKHR = .{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = inst.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .preTransform = inst.swap_chain_support.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = c.VK_TRUE,
        };

        const indices = try v_init_common.findQueueFamilies(inst.physical_device, alloc, inst.surface);
        const queue_family_indices = [_]u32{ indices.graphics_compute_family.?, indices.present_family.? };

        if (indices.graphics_compute_family != indices.present_family) {
            create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            create_info.queueFamilyIndexCount = 2;
            create_info.pQueueFamilyIndices = &queue_family_indices;
        } else {
            create_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
            create_info.queueFamilyIndexCount = 0;
            create_info.pQueueFamilyIndices = null;
            create_info.oldSwapchain = @ptrCast(c.VK_NULL_HANDLE);
        }

        var vk_swapchain: c.VkSwapchainKHR = undefined;

        if (c.vkCreateSwapchainKHR(inst.device, &create_info, null, &vk_swapchain) != c.VK_SUCCESS) {
            return Error.logical_device_creation_failed;
        }

        _ = c.vkGetSwapchainImagesKHR(inst.device, inst.swap_chain, &image_count, null);
        const images = try alloc.alloc(c.VkImage, image_count);
        _ = c.vkGetSwapchainImagesKHR(inst.device, inst.swap_chain, &image_count, inst.swap_chain_images.ptr);

        var image_views = try alloc.alloc(c.VkImageView, images.len);

        for (images, 0..) |image, i| {
            const view_create_info: c.VkImageViewCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = surface_format.format,
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

            if (c.vkCreateImageView(inst.device, &view_create_info, null, &image_views[i]) != c.VK_SUCCESS) {
                return Error.image_views_creation_failed;
            }
        }
        return Swapchain{
            .vk_swapchain = vk_swapchain,
            .extent = extent,
            .format = surface_format.format,
            .images = images,
            .image_views = image_views,
        };
    }

    fn chooseSwapSurfaceFormat(availible_formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
        for (availible_formats) |format| {
            if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                return format;
            }
        }

        return availible_formats[0];
    }

    fn chooseSwapPresentMode(availible_present_modes: []const c.VkPresentModeKHR) c.VkPresentModeKHR {
        for (availible_present_modes) |mode| {
            if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                return mode;
            }
        }

        //always availible
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }

    fn chooseSwapExtent(window: *c.GLFWwindow, capabilities: *const c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        } else {
            var height: c_int = undefined;
            var width: c_int = undefined;
            c.glfwGetFramebufferSize(window, &width, &height);

            var actualExtent: c.VkExtent2D = .{
                .height = @intCast(height),
                .width = @intCast(width),
            };

            actualExtent.width = std.math.clamp(
                actualExtent.width,
                capabilities.minImageExtent.width,
                capabilities.maxImageExtent.width,
            );
            actualExtent.height = std.math.clamp(
                actualExtent.height,
                capabilities.minImageExtent.height,
                capabilities.maxImageExtent.height,
            );

            return actualExtent;
        }
    }
};
