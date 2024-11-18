const std = @import("std");
const common = @import("../common_defs.zig");
const v_common = @import("v_init_common_defs.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

pub fn createSwapChain(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const swap_chain_support = try v_common.querySwapChainSupport(data.surface, data.physical_device, alloc);
    defer alloc.free(swap_chain_support.formats);
    defer alloc.free(swap_chain_support.presentModes);

    const surface_format = chooseSwapSurfaceFormat(swap_chain_support.formats);
    const present_mode = chooseSwapPresentMode(swap_chain_support.presentModes);
    const extent = chooseSwapExtent(data.*, &swap_chain_support.capabilities);

    var image_count: u32 = swap_chain_support.capabilities.minImageCount + 1;
    if (swap_chain_support.capabilities.maxImageCount > 0 and image_count > swap_chain_support.capabilities.maxImageCount) {
        image_count = swap_chain_support.capabilities.maxImageCount;
    }

    var create_info: c.VkSwapchainCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = data.surface,
        .minImageCount = image_count,
        .imageFormat = surface_format.format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = swap_chain_support.capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = c.VK_TRUE,
    };

    const indices = try v_common.findQueueFamilies(data.physical_device, alloc, data.surface);
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

    if (c.vkCreateSwapchainKHR(data.device, &create_info, null, &data.swap_chain) != c.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    _ = c.vkGetSwapchainImagesKHR(data.device, data.swap_chain, &image_count, null);
    data.swap_chain_images = try alloc.alloc(c.VkImage, image_count);
    _ = c.vkGetSwapchainImagesKHR(data.device, data.swap_chain, &image_count, data.swap_chain_images.ptr);

    data.swap_chain_image_format = surface_format.format;
    data.swap_chain_extent = extent;
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

fn chooseSwapExtent(data: common.AppData, capabilities: *const c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    } else {
        var height: c_int = undefined;
        var width: c_int = undefined;
        c.glfwGetFramebufferSize(data.window, &width, &height);

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
