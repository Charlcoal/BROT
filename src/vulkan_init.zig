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

const std = @import("std");
const common = @import("common_defs.zig");
const cleanup = @import("cleanup.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

const vert_code align(4) = @embedFile("triangle_vert_shader").*;
const frag_code align(4) = @embedFile("triangle_frag_shader").*;
const render_code align(4) = @embedFile("mandelbrot_comp_shader").*;
const patch_place_code align(4) = @embedFile("patch_place_comp_shader").*;
const buffer_remap_code align(4) = @embedFile("buffer_remap_comp_shader").*;

pub fn initVulkan(alloc: Allocator) InitVulkanError!void {
    try createInstance(alloc);
    try setupDebugMessenger();

    if (c.glfwCreateWindowSurface(common.instance, common.window, null, &common.surface) != c.VK_SUCCESS) {
        return InitVulkanError.window_surface_creation_failed;
    }

    try pickPhysicalDevice(alloc);
    try createLogicalDevice(alloc);
    try createSwapChain(alloc);
    try createImageViews(alloc);
    try createRenderPass();
    try createRenderPatchDescriptorSetLayout();
    try createCpuToRndDescriptorSetLayout();
    try createRndToClrDescriptorSetLayout();
    try createBufferRemapPipeline();
    try createPatchPlacePipeline();
    try createColoringPipeline();
    try createRendingPipeline();
    try createFrameBuffers(alloc);
    try createGraphicsCommandPool(alloc);
    try createComputeCommandPool(alloc);
    try createBuffers();
    try createDescriptorPool();
    try createRenderPatchDescriptorSets();
    try createCpuToRndDescriptorSets();
    try createRndToClrDescriptorSets();
    try createRenderCommandBuffers();
    try createPatchPlaceCommandBuffer();
    try createColoringCommandBuffers(alloc);
    try createSyncObjects(alloc);
}

pub fn recreateSwapChain(alloc: Allocator) InitVulkanError!void {
    common.frame_buffer_just_resized = true;

    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(common.window, &width, &height);
    while (width == 0 or height == 0) {
        if (c.glfwWindowShouldClose(common.window) != 0) return; // for closing while minimized
        c.glfwGetFramebufferSize(common.window, &width, &height);
        c.glfwWaitEvents();
    }

    _ = c.vkDeviceWaitIdle(common.device);

    cleanup.cleanupSwapChain(alloc);

    try createSwapChain(alloc);
    try createImageViews(alloc);
    try createFrameBuffers(alloc);
}

const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: []c.VkSurfaceFormatKHR,
    presentModes: []c.VkPresentModeKHR,
};

fn populateDebugMessengerCreateInfo(create_info: *c.VkDebugUtilsMessengerCreateInfoEXT) void {
    create_info.* = c.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
        .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
}

const QueueFamilyIndices = struct {
    graphics_family: ?u32,
    graphics_max_queues: u32,
    compute_family: ?u32,
    compute_max_queues: u32,
    present_family: ?u32,
    present_max_queues: u32,

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_family != null and self.present_family != null and self.compute_family != null;
    }
};

fn findQueueFamilies(device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!QueueFamilyIndices {
    var indices = QueueFamilyIndices{
        .graphics_family = null,
        .compute_family = null,
        .present_family = null,
        .graphics_max_queues = 0,
        .present_max_queues = 0,
        .compute_max_queues = 0,
    };

    var queue_family_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try alloc.alloc(c.VkQueueFamilyProperties, queue_family_count);
    defer alloc.free(queue_families);
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queueFamily, i| {
        if ((queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) and indices.graphics_family == null) {
            indices.graphics_family = @intCast(i);
            indices.graphics_max_queues = queueFamily.queueCount;
        }

        if ((queueFamily.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0) and (indices.compute_family == null or
            ((queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) and (queue_families[indices.compute_family.?].queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0))))
        {
            indices.compute_family = @intCast(i);
            indices.compute_max_queues = queueFamily.queueCount;
        }

        var present_support: c.VkBool32 = c.VK_FALSE;
        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), common.surface, &present_support);

        if ((present_support != c.VK_FALSE) and indices.present_family == null) {
            indices.present_family = @intCast(i);
            indices.present_max_queues = queueFamily.queueCount;
        }
    }
    return indices;
}

fn querySwapChainSupport(surface: c.VkSurfaceKHR, device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!SwapChainSupportDetails {
    var details: SwapChainSupportDetails = .{
        .formats = undefined,
        .capabilities = undefined,
        .presentModes = undefined,
    };

    _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities);

    var format_count: u32 = undefined;
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

    details.formats = try alloc.alloc(c.VkSurfaceFormatKHR, format_count);
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, details.formats.ptr);

    var present_mode_count: u32 = undefined;
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

    details.presentModes = try alloc.alloc(c.VkPresentModeKHR, present_mode_count);
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, details.presentModes.ptr);

    return details;
}

fn createBuffer(
    size: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    buffer: *c.VkBuffer,
    buffer_memory: *c.VkDeviceMemory,
) common.InitVulkanError!void {
    const buffer_info: c.VkBufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    if (c.vkCreateBuffer(common.device, &buffer_info, null, buffer) != c.VK_SUCCESS) {
        return common.InitVulkanError.buffer_creation_failed;
    }

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(common.device, buffer.*, &mem_requirements);

    const alloc_info: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(mem_requirements.memoryTypeBits, properties),
    };

    if (c.vkAllocateMemory(common.device, &alloc_info, null, buffer_memory) != c.VK_SUCCESS) {
        return common.InitVulkanError.buffer_memory_allocation_failed;
    }

    _ = c.vkBindBufferMemory(common.device, buffer.*, buffer_memory.*, 0);
}

pub fn findMemoryType(type_filter: u32, properties: c.VkMemoryPropertyFlags) common.InitVulkanError!u32 {
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(common.physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
            return @intCast(i);
        }
    }

    return common.InitVulkanError.suitable_memory_type_not_found;
}

fn debugCallback(
    message_severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: c.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_common: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_common: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    if (message_severity >= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        std.debug.print("ERROR ", .{});
    } else if (message_severity >= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        std.debug.print("WARNING ", .{});
    }

    if (message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT != 0) {
        std.debug.print("[performance] ", .{});
    }
    if (message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT != 0) {
        std.debug.print("[validation] ", .{});
    }
    if (message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT != 0) {
        std.debug.print("[general] ", .{});
    }

    std.debug.print("{s}\n", .{p_callback_common.*.pMessage});
    _ = p_user_common;

    return c.VK_FALSE;
}

fn createColoringCommandBuffers(alloc: Allocator) InitVulkanError!void {
    common.graphics_command_buffers = try alloc.alloc(c.VkCommandBuffer, common.max_frames_in_flight);

    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = common.graphics_command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = @intCast(common.graphics_command_buffers.len),
    };

    if (c.vkAllocateCommandBuffers(common.device, &alloc_info, common.graphics_command_buffers.ptr) != c.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}

fn createPatchPlaceCommandBuffer() InitVulkanError!void {
    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = common.compute_command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    if (c.vkAllocateCommandBuffers(common.device, &alloc_info, &common.rnd_buffer_write_command_buffer) != c.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}

fn createRenderCommandBuffers() InitVulkanError!void {
    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = common.compute_command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = common.rendering_command_buffers.len,
    };

    if (c.vkAllocateCommandBuffers(common.device, &alloc_info, &common.rendering_command_buffers) != c.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}

fn createGraphicsCommandPool(alloc: Allocator) InitVulkanError!void {
    const queue_family_indices = try findQueueFamilies(common.physical_device, alloc);

    const pool_info: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.graphics_family.?,
    };

    if (c.vkCreateCommandPool(common.device, &pool_info, null, &common.graphics_command_pool) != c.VK_SUCCESS) {
        return InitVulkanError.command_pool_creation_failed;
    }
}

fn createComputeCommandPool(alloc: Allocator) InitVulkanError!void {
    const queue_family_indices = try findQueueFamilies(common.physical_device, alloc);

    const pool_info: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.compute_family.?,
    };

    if (c.vkCreateCommandPool(common.device, &pool_info, null, &common.compute_command_pool) != c.VK_SUCCESS) {
        return InitVulkanError.command_pool_creation_failed;
    }
}

fn setupDebugMessenger() InitVulkanError!void {
    if (!common.enable_validation_layers) return;

    var create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    populateDebugMessengerCreateInfo(&create_info);

    if (createDebugUtilsMessengerEXT(common.instance, &create_info, null, &common.debug_messenger) != c.VK_SUCCESS) {
        return InitVulkanError.debug_messenger_setup_failed;
    }
}

fn createDebugUtilsMessengerEXT(
    instance: c.VkInstance,
    p_create_info: [*c]const c.VkDebugUtilsMessengerCreateInfoEXT,
    p_vulkan_alloc: [*c]const c.VkAllocationCallbacks,
    p_debug_messenger: *c.VkDebugUtilsMessengerEXT,
) c.VkResult {
    const func: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    if (func) |ptr| {
        return ptr(instance, p_create_info, p_vulkan_alloc, p_debug_messenger);
    } else {
        return c.VK_ERROR_EXTENSION_NOT_PRESENT;
    }
}

fn createDescriptorPool() InitVulkanError!void {
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = @intCast(common.render_to_coloring_descriptor_sets.len),
        },
        .{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = @intCast(common.cpu_to_render_descriptor_sets.len),
        },
        .{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = @intCast(common.render_patch_descriptor_sets.len),
        },
    };

    const pool_info: c.VkDescriptorPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = @intCast(pool_sizes.len),
        .pPoolSizes = &pool_sizes,
        .maxSets = @intCast(common.render_to_coloring_descriptor_sets.len +
            common.cpu_to_render_descriptor_sets.len +
            common.render_patch_descriptor_sets.len),
    };

    if (c.vkCreateDescriptorPool(common.device, &pool_info, null, &common.descriptor_pool) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_pool_creation_failed;
    }
}

fn createRenderPatchDescriptorSetLayout() InitVulkanError!void {
    const bindings = [_]c.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    }};

    var layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };

    if (c.vkCreateDescriptorSetLayout(common.device, &layout_info, null, &common.render_patch_descriptor_set_layout) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_set_layout_creation_failed;
    }
}

fn createCpuToRndDescriptorSetLayout() InitVulkanError!void {
    const bindings = [_]c.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    }};

    var layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };

    if (c.vkCreateDescriptorSetLayout(common.device, &layout_info, null, &common.cpu_to_render_descriptor_set_layout) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_set_layout_creation_failed;
    }
}

fn createRndToClrDescriptorSetLayout() InitVulkanError!void {
    const bindings = [_]c.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    }};

    var layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };

    if (c.vkCreateDescriptorSetLayout(common.device, &layout_info, null, &common.render_to_coloring_descriptor_set_layout) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_set_layout_creation_failed;
    }
}

fn createRenderPatchDescriptorSets() InitVulkanError!void {
    var layouts: [common.render_patch_descriptor_sets.len]c.VkDescriptorSetLayout = undefined;
    for (&layouts) |*layout| {
        layout.* = common.render_patch_descriptor_set_layout;
    }

    const alloc_info: c.VkDescriptorSetAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = common.descriptor_pool,
        .descriptorSetCount = layouts.len,
        .pSetLayouts = &layouts,
    };

    if (c.vkAllocateDescriptorSets(common.device, &alloc_info, &common.render_patch_descriptor_sets) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_sets_allocation_failed;
    }

    const patch_size: usize =
        @sizeOf(f32) * common.renderPatchSize(0) * common.renderPatchSize(0);

    for (0..common.render_patch_descriptor_sets.len) |i| {
        const perturbation_buffer_info: c.VkDescriptorBufferInfo = .{
            .buffer = common.render_patch_buffer,
            .offset = i * patch_size,
            .range = patch_size,
        };

        const descriptor_writes = [_]c.VkWriteDescriptorSet{
            .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = common.render_patch_descriptor_sets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &perturbation_buffer_info,
            },
        };

        c.vkUpdateDescriptorSets(common.device, @intCast(descriptor_writes.len), &descriptor_writes, 0, null);
    }
}

fn createCpuToRndDescriptorSets() InitVulkanError!void {
    var layouts: [common.cpu_to_render_descriptor_sets.len]c.VkDescriptorSetLayout = undefined;
    for (&layouts) |*layout| {
        layout.* = common.cpu_to_render_descriptor_set_layout;
    }

    const alloc_info: c.VkDescriptorSetAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = common.descriptor_pool,
        .descriptorSetCount = layouts.len,
        .pSetLayouts = &layouts,
    };

    if (c.vkAllocateDescriptorSets(common.device, &alloc_info, &common.cpu_to_render_descriptor_sets) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_sets_allocation_failed;
    }

    for (0..common.cpu_to_render_descriptor_sets.len) |i| {
        const perturbation_buffer_info: c.VkDescriptorBufferInfo = .{
            .buffer = common.perturbation_buffer,
            .offset = common.max_iterations * 2 * @sizeOf(f32) * i,
            .range = common.max_iterations * 2 * @sizeOf(f32),
        };

        const descriptor_writes = [_]c.VkWriteDescriptorSet{
            .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = common.cpu_to_render_descriptor_sets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &perturbation_buffer_info,
            },
        };

        c.vkUpdateDescriptorSets(common.device, @intCast(descriptor_writes.len), &descriptor_writes, 0, null);
    }
}

fn createRndToClrDescriptorSets() InitVulkanError!void {
    var layouts: [common.render_to_coloring_descriptor_sets.len]c.VkDescriptorSetLayout = undefined;
    for (&layouts) |*layout| {
        layout.* = common.render_to_coloring_descriptor_set_layout;
    }

    const alloc_info: c.VkDescriptorSetAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = common.descriptor_pool,
        .descriptorSetCount = layouts.len,
        .pSetLayouts = &layouts,
    };

    if (c.vkAllocateDescriptorSets(common.device, &alloc_info, &common.render_to_coloring_descriptor_sets) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_sets_allocation_failed;
    }

    for (0..common.render_to_coloring_descriptor_sets.len) |i| {
        const escape_potential_buffer_info: c.VkDescriptorBufferInfo = .{
            .buffer = common.escape_potential_buffer,
            .offset = i * common.escape_potential_buffer_size,
            .range = common.escape_potential_buffer_size,
        };

        const descriptor_writes = [_]c.VkWriteDescriptorSet{
            .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = common.render_to_coloring_descriptor_sets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &escape_potential_buffer_info,
            },
        };

        c.vkUpdateDescriptorSets(common.device, @intCast(descriptor_writes.len), &descriptor_writes, 0, null);
    }
}

fn createFrameBuffers(alloc: Allocator) InitVulkanError!void {
    common.swap_chain_framebuffers = try alloc.alloc(c.VkFramebuffer, common.swap_chain_image_views.len);

    for (0..common.swap_chain_image_views.len) |i| {
        const attachments = [_]c.VkImageView{
            common.swap_chain_image_views[i],
        };

        const frame_buffer_info: c.VkFramebufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = common.render_pass,
            .attachmentCount = @intCast(attachments.len),
            .pAttachments = &attachments,
            .width = common.swap_chain_extent.width,
            .height = common.swap_chain_extent.height,
            .layers = 1,
        };

        if (c.vkCreateFramebuffer(common.device, &frame_buffer_info, null, &common.swap_chain_framebuffers[i]) != c.VK_SUCCESS) {
            return InitVulkanError.framebuffer_creation_failed;
        }
    }
}

fn createBufferRemapPipeline() InitVulkanError!void {
    const shader_module = try createShaderModule(&buffer_remap_code);
    defer _ = c.vkDestroyShaderModule(common.device, shader_module, null);

    const shader_stage_info: c.VkPipelineShaderStageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader_module,
        .pName = "main",
    };

    const push_constant_range: c.VkPushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.BufferRemapConstants),
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
    };

    const descriptor_sets = [_]c.VkDescriptorSetLayout{
        common.render_to_coloring_descriptor_set_layout,
        common.render_to_coloring_descriptor_set_layout,
    };

    const pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = descriptor_sets.len,
        .pSetLayouts = &descriptor_sets,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };
    if (c.vkCreatePipelineLayout(
        common.device,
        &pipeline_layout_info,
        null,
        &common.buffer_remap_pipeline_layout,
    ) != c.VK_SUCCESS) {
        return InitVulkanError.pipeline_layout_creation_failed;
    }

    const pipeline_info: c.VkComputePipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = common.buffer_remap_pipeline_layout,
        .stage = shader_stage_info,
    };

    if (c.vkCreateComputePipelines(
        common.device,
        @ptrCast(c.VK_NULL_HANDLE),
        1,
        &pipeline_info,
        null,
        &common.buffer_remap_pipeline,
    ) != c.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createPatchPlacePipeline() InitVulkanError!void {
    const shader_module = try createShaderModule(&patch_place_code);
    defer _ = c.vkDestroyShaderModule(common.device, shader_module, null);

    const shader_stage_info: c.VkPipelineShaderStageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader_module,
        .pName = "main",
    };

    const push_constant_range: c.VkPushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.PatchPlaceConstants),
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
    };

    const descriptor_sets = [_]c.VkDescriptorSetLayout{
        common.render_patch_descriptor_set_layout,
        common.render_to_coloring_descriptor_set_layout,
    };

    const pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = descriptor_sets.len,
        .pSetLayouts = &descriptor_sets,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };
    if (c.vkCreatePipelineLayout(common.device, &pipeline_layout_info, null, &common.patch_place_pipeline_layout) != c.VK_SUCCESS) {
        return InitVulkanError.pipeline_layout_creation_failed;
    }

    const pipeline_info: c.VkComputePipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = common.patch_place_pipeline_layout,
        .stage = shader_stage_info,
    };

    if (c.vkCreateComputePipelines(common.device, @ptrCast(c.VK_NULL_HANDLE), 1, &pipeline_info, null, &common.patch_place_pipeline) != c.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createRendingPipeline() InitVulkanError!void {
    const comp_shader_module = try createShaderModule(&render_code);
    defer _ = c.vkDestroyShaderModule(common.device, comp_shader_module, null);

    const comp_shader_stage_info: c.VkPipelineShaderStageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = comp_shader_module,
        .pName = "main",
    };

    const push_constant_range: c.VkPushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.RenderingConstants),
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
    };

    const descriptor_sets = [_]c.VkDescriptorSetLayout{
        common.render_patch_descriptor_set_layout,
        common.cpu_to_render_descriptor_set_layout,
    };

    const pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = descriptor_sets.len,
        .pSetLayouts = &descriptor_sets,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };
    if (c.vkCreatePipelineLayout(common.device, &pipeline_layout_info, null, &common.rendering_pipeline_layout) != c.VK_SUCCESS) {
        return InitVulkanError.pipeline_layout_creation_failed;
    }

    const pipeline_info: c.VkComputePipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = common.rendering_pipeline_layout,
        .stage = comp_shader_stage_info,
    };

    if (c.vkCreateComputePipelines(common.device, @ptrCast(c.VK_NULL_HANDLE), 1, &pipeline_info, null, &common.rendering_pipeline) != c.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createColoringPipeline() InitVulkanError!void {
    const vert_shader_module = try createShaderModule(&vert_code);
    const frag_shader_module = try createShaderModule(&frag_code);
    defer _ = c.vkDestroyShaderModule(common.device, vert_shader_module, null);
    defer _ = c.vkDestroyShaderModule(common.device, frag_shader_module, null);

    const vert_shader_stage_info: c.VkPipelineShaderStageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vert_shader_module,
        .pName = "main",
    };
    const frag_shader_stage_info: c.VkPipelineShaderStageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader_module,
        .pName = "main",
    };

    const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
        vert_shader_stage_info,
        frag_shader_stage_info,
    };

    const dynamic_states = [_]c.VkDynamicState{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dynamic_state: c.VkPipelineDynamicStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = @intCast(dynamic_states.len),
        .pDynamicStates = &dynamic_states,
    };

    const vertex_input_info: c.VkPipelineVertexInputStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    const input_assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.VK_FALSE,
    };

    const viewport_state: c.VkPipelineViewportStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    const rasterizer: c.VkPipelineRasterizationStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = c.VK_FALSE,
        .rasterizerDiscardEnable = c.VK_FALSE,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .lineWidth = 1,
        .cullMode = c.VK_CULL_MODE_BACK_BIT,
        .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = c.VK_FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
    };

    const multisampling: c.VkPipelineMultisampleStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = c.VK_FALSE,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        .minSampleShading = 1,
        .pSampleMask = null,
        .alphaToCoverageEnable = c.VK_FALSE,
        .alphaToOneEnable = c.VK_FALSE,
    };

    const color_blend_attachment: c.VkPipelineColorBlendAttachmentState = .{
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = c.VK_FALSE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
    };

    const color_blending: c.VkPipelineColorBlendStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = c.VK_FALSE,
        .logicOp = c.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };

    const push_constant_range: c.VkPushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.ColoringConstants),
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    const pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &common.render_to_coloring_descriptor_set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };
    if (c.vkCreatePipelineLayout(common.device, &pipeline_layout_info, null, &common.coloring_pipeline_layout) != c.VK_SUCCESS) {
        return InitVulkanError.pipeline_layout_creation_failed;
    }

    const pipeline_info: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = shader_stages.len,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = common.coloring_pipeline_layout,
        .renderPass = common.render_pass,
        .subpass = 0,
        .basePipelineHandle = @ptrCast(c.VK_NULL_HANDLE),
        .basePipelineIndex = -1,
    };

    if (c.vkCreateGraphicsPipelines(common.device, @ptrCast(c.VK_NULL_HANDLE), 1, &pipeline_info, null, &common.coloring_pipeline) != c.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createShaderModule(code: []align(4) const u8) InitVulkanError!c.VkShaderModule {
    //std.debug.print("shader module at: {x}\n", .{@intFromPtr(code.ptr)});
    const create_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(code.ptr),
    };
    var shader_module: c.VkShaderModule = undefined;
    if (c.vkCreateShaderModule(common.device, &create_info, null, &shader_module) != c.VK_SUCCESS) {
        return InitVulkanError.shader_module_creation_failed;
    }
    return shader_module;
}

fn createImageViews(alloc: Allocator) InitVulkanError!void {
    common.swap_chain_image_views = try alloc.alloc(c.VkImageView, common.swap_chain_images.len);

    for (common.swap_chain_images, 0..) |image, i| {
        const create_info: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = common.swap_chain_image_format,
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

        if (c.vkCreateImageView(common.device, &create_info, null, &common.swap_chain_image_views[i]) != c.VK_SUCCESS) {
            return InitVulkanError.image_views_creation_failed;
        }
    }
}

fn createInstance(alloc: Allocator) InitVulkanError!void {
    if (common.enable_validation_layers and !try checkValidationLayerSupport(alloc)) {
        return InitVulkanError.validation_layer_unavailible;
    }

    const app_info = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Hello Triangle",
        .applicationVersion = c.VK_MAKE_API_VERSION(0, 1, 3, 0),
        .pEngineName = "No Engine",
        .engineVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0),
        .apiVersion = c.VK_API_VERSION_1_3,
    };

    var create_info = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
    };

    const extensions = try getRequiredExtensions(alloc);
    defer alloc.free(extensions);
    create_info.enabledExtensionCount = @intCast(extensions.len);
    create_info.ppEnabledExtensionNames = extensions.ptr;

    var debug_create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    if (common.enable_validation_layers) {
        create_info.enabledLayerCount = common.validation_layers.len;
        create_info.ppEnabledLayerNames = &common.validation_layers;

        populateDebugMessengerCreateInfo(&debug_create_info);
        create_info.pNext = @ptrCast(&debug_create_info);
    } else {
        create_info.enabledLayerCount = 0;

        create_info.pNext = null;
    }

    const result = c.vkCreateInstance(&create_info, null, &common.instance);
    if (result != c.VK_SUCCESS) {
        return InitVulkanError.instance_creation_failed;
    }
}

fn checkValidationLayerSupport(alloc: Allocator) Allocator.Error!bool {
    var layer_count: u32 = undefined;
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, null);

    const availible_layers = try alloc.alloc(c.VkLayerProperties, layer_count);
    defer alloc.free(availible_layers);
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, availible_layers.ptr);

    for (common.validation_layers) |v_layer| {
        var layer_found: bool = false;

        for (availible_layers) |a_layer| {
            if (common.str_eq(v_layer, @as([*:0]const u8, @ptrCast(&a_layer.layerName)))) {
                layer_found = true;
                break;
            }
        }

        if (!layer_found) return false;
    }

    return true;
}

fn getRequiredExtensions(alloc: Allocator) Allocator.Error![][*c]const u8 {
    var glfw_extension_count: u32 = 0;
    const glfw_extensions: [*c]const [*c]const u8 = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count);

    const out = try alloc.alloc([*c]const u8, glfw_extension_count + if (common.enable_validation_layers) 1 else 0);
    for (0..glfw_extension_count) |i| {
        out[i] = glfw_extensions[i];
    }
    if (common.enable_validation_layers) {
        out[glfw_extension_count] = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    }

    return out;
}

fn createLogicalDevice(alloc: Allocator) InitVulkanError!void {
    const indicies = try findQueueFamilies(common.physical_device, alloc);

    var unique_queue_families = [_]u32{ indicies.graphics_family.?, indicies.compute_family.?, indicies.present_family.? };
    const max_queues = [unique_queue_families.len]u32{ indicies.graphics_max_queues, indicies.compute_max_queues, indicies.present_max_queues };
    var num_required_queues = [unique_queue_families.len]u32{ 1, 1, 1 };
    var unique_queue_num: u32 = 0;

    var queue_family_property_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(common.physical_device, &queue_family_property_count, null);

    const queue_family_properties = try alloc.alloc(c.VkQueueFamilyProperties, queue_family_property_count);
    defer alloc.free(queue_family_properties);
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(common.physical_device, &queue_family_property_count, queue_family_properties.ptr);

    outer: for (unique_queue_families, &num_required_queues, max_queues) |queue_family, *num_req_queues, max_queue| {
        for (unique_queue_families[0..unique_queue_num], num_required_queues[0..unique_queue_num]) |existing_unique_queue_family, *existing_num_req_queues| {
            if (existing_unique_queue_family == queue_family) {
                existing_num_req_queues.* += num_req_queues.*;
                existing_num_req_queues.* = @min(existing_num_req_queues.*, max_queue);
                num_req_queues.* = 0;
                continue :outer;
            }
        }
        num_required_queues[unique_queue_num] = @min(num_req_queues.*, max_queue);
        unique_queue_families[unique_queue_num] = queue_family;
        unique_queue_num += 1;
    }

    const queue_create_infos = try alloc.alloc(c.VkDeviceQueueCreateInfo, unique_queue_num);
    defer alloc.free(queue_create_infos);

    const queue_priority: [2]f32 = .{ 1, 0 };
    for (unique_queue_families[0..unique_queue_num], queue_create_infos, num_required_queues[0..unique_queue_num]) |queue_family, *queue_create_info, num_queues| {
        queue_create_info.* = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family,
            .queueCount = num_queues,
            .pQueuePriorities = if (queue_family == indicies.compute_family and queue_family != indicies.graphics_family) &queue_priority[1] else &queue_priority,
        };
    }

    const device_features: c.VkPhysicalDeviceFeatures = .{};

    var createInfo: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pQueueCreateInfos = queue_create_infos.ptr,
        .queueCreateInfoCount = unique_queue_num,
        .pEnabledFeatures = &device_features,
        .ppEnabledExtensionNames = &common.device_extensions,
        .enabledExtensionCount = @intCast(common.device_extensions.len),
    };

    if (common.enable_validation_layers) {
        createInfo.enabledLayerCount = @intCast(common.validation_layers.len);
        createInfo.ppEnabledLayerNames = &common.validation_layers;
    } else {
        createInfo.enabledLayerCount = 0;
    }

    if (c.vkCreateDevice(common.physical_device, &createInfo, null, &common.device) != c.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    c.vkGetDeviceQueue(common.device, indicies.graphics_family.?, 0, &common.graphics_queue);
    c.vkGetDeviceQueue(common.device, indicies.present_family.?, 0, &common.present_queue);
    if (indicies.graphics_family.? == indicies.compute_family.? and indicies.graphics_max_queues >= 2) {
        c.vkGetDeviceQueue(common.device, indicies.compute_family.?, 1, &common.compute_queue);
    } else {
        c.vkGetDeviceQueue(common.device, indicies.compute_family.?, 0, &common.compute_queue);
    }
}

fn pickPhysicalDevice(alloc: Allocator) InitVulkanError!void {
    var device_count: u32 = 0;
    _ = c.vkEnumeratePhysicalDevices(common.instance, &device_count, null);

    if (device_count == 0) {
        return InitVulkanError.gpu_with_vulkan_support_not_found;
    }

    const devices = try alloc.alloc(c.VkPhysicalDevice, device_count);
    defer alloc.free(devices);
    _ = c.vkEnumeratePhysicalDevices(common.instance, &device_count, devices.ptr);

    for (devices) |device| {
        if (try deviceIsSuitable(device, alloc)) {
            common.physical_device = device;
            break;
        }
    } else {
        return InitVulkanError.suitable_gpu_not_found;
    }
}

fn deviceIsSuitable(device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    const indices = try findQueueFamilies(device, alloc);

    const extensions_supported: bool = try checkDeviceExtensionSupport(device, alloc);

    var swap_chain_adequate: bool = false;
    if (extensions_supported) {
        const swap_chain_support = try querySwapChainSupport(common.surface, device, alloc);
        defer alloc.free(swap_chain_support.presentModes);
        defer alloc.free(swap_chain_support.formats);
        swap_chain_adequate = (swap_chain_support.formats.len != 0) and (swap_chain_support.presentModes.len != 0);
    }

    return indices.isComplete() and extensions_supported and swap_chain_adequate;
}

fn checkDeviceExtensionSupport(device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    var extension_count: u32 = undefined;
    _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);

    const availibleExtensions = try alloc.alloc(c.VkExtensionProperties, extension_count);
    defer alloc.free(availibleExtensions);
    _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, availibleExtensions.ptr);

    outer: for (common.device_extensions) |extension| {
        for (availibleExtensions) |availible| {
            if (common.str_eq(extension, @ptrCast(&availible.extensionName))) continue :outer;
        }
        return false;
    }

    return true;
}

pub fn createRenderPass() InitVulkanError!void {
    const color_attachment: c.VkAttachmentDescription = .{
        .format = common.swap_chain_image_format,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const color_attachment_ref: c.VkAttachmentReference = .{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const subpass: c.VkSubpassDescription = .{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
    };

    const dependency: c.VkSubpassDependency = .{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };

    const render_pass_info: c.VkRenderPassCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    if (c.vkCreateRenderPass(common.device, &render_pass_info, null, &common.render_pass) != c.VK_SUCCESS) {
        return InitVulkanError.render_pass_creation_failed;
    }
}

fn createSwapChain(alloc: Allocator) InitVulkanError!void {
    const swap_chain_support = try querySwapChainSupport(common.surface, common.physical_device, alloc);
    defer alloc.free(swap_chain_support.formats);
    defer alloc.free(swap_chain_support.presentModes);

    const surface_format = chooseSwapSurfaceFormat(swap_chain_support.formats);
    const present_mode = chooseSwapPresentMode(swap_chain_support.presentModes);
    const extent = chooseSwapExtent(&swap_chain_support.capabilities);

    common.swap_chain_images.len = swap_chain_support.capabilities.minImageCount + 1;
    if (swap_chain_support.capabilities.maxImageCount > 0 and common.swap_chain_images.len > swap_chain_support.capabilities.maxImageCount) {
        common.swap_chain_images.len = swap_chain_support.capabilities.maxImageCount;
    }

    var create_info: c.VkSwapchainCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = common.surface,
        .minImageCount = @intCast(common.swap_chain_images.len),
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

    const indices = try findQueueFamilies(common.physical_device, alloc);
    const queue_family_indices = [_]u32{ indices.graphics_family.?, indices.present_family.? };

    if (indices.graphics_family != indices.present_family) {
        create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        create_info.queueFamilyIndexCount = 2;
        create_info.pQueueFamilyIndices = &queue_family_indices;
    } else {
        create_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        create_info.queueFamilyIndexCount = 0;
        create_info.pQueueFamilyIndices = null;
        create_info.oldSwapchain = @ptrCast(c.VK_NULL_HANDLE);
    }

    if (c.vkCreateSwapchainKHR(common.device, &create_info, null, &common.swap_chain) != c.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    _ = c.vkGetSwapchainImagesKHR(common.device, common.swap_chain, @ptrCast(&common.swap_chain_images.len), null);
    common.swap_chain_images = try alloc.alloc(c.VkImage, common.swap_chain_images.len);
    _ = c.vkGetSwapchainImagesKHR(common.device, common.swap_chain, @ptrCast(&common.swap_chain_images.len), common.swap_chain_images.ptr);

    common.swap_chain_image_format = surface_format.format;
    common.swap_chain_extent = extent;
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

fn chooseSwapExtent(capabilities: *const c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    } else {
        var height: c_int = undefined;
        var width: c_int = undefined;
        c.glfwGetFramebufferSize(common.window, &width, &height);

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

fn createSyncObjects(alloc: Allocator) InitVulkanError!void {
    common.image_availible_semaphores = try alloc.alloc(c.VkSemaphore, common.max_frames_in_flight);
    common.render_finished_semaphores = try alloc.alloc(c.VkSemaphore, common.swap_chain_images.len);
    common.in_flight_fences = try alloc.alloc(c.VkFence, common.max_frames_in_flight);

    const semaphore_info: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fence_info: c.VkFenceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    if (c.vkCreateFence(common.device, &fence_info, null, &common.render_buffer_write_fence) != c.VK_SUCCESS) {
        return InitVulkanError.fence_creation_failed;
    }

    for (&common.rendering_fences) |*fence| {
        if (c.vkCreateFence(common.device, &fence_info, null, fence) != c.VK_SUCCESS) {
            return InitVulkanError.fence_creation_failed;
        }
    }

    for (0..common.max_frames_in_flight) |i| {
        if (c.vkCreateSemaphore(common.device, &semaphore_info, null, &common.image_availible_semaphores[i]) != c.VK_SUCCESS or
            c.vkCreateFence(common.device, &fence_info, null, &common.in_flight_fences[i]) != c.VK_SUCCESS)
        {
            return InitVulkanError.semaphore_creation_failed;
        }
    }

    for (common.render_finished_semaphores) |*sem| {
        if (c.vkCreateSemaphore(common.device, &semaphore_info, null, sem) != c.VK_SUCCESS) {
            return InitVulkanError.semaphore_creation_failed;
        }
    }
}

fn createBuffers() InitVulkanError!void {
    const video_mode = c.glfwGetVideoMode(c.glfwGetPrimaryMonitor());
    common.escape_potential_buffer_block_num_x =
        @as(u32, @intCast(2 * video_mode.?.*.width)) / common.renderPatchSize(common.max_res_scale_exponent) + 2;
    common.escape_potential_buffer_block_num_y =
        @as(u32, @intCast(2 * video_mode.?.*.height)) / common.renderPatchSize(common.max_res_scale_exponent) + 2;

    // ensure even numbers for easier remapping. ideally this would not be done as it wastes some gpu memory
    if (common.escape_potential_buffer_block_num_x % 2 == 1) common.escape_potential_buffer_block_num_x += 1;
    if (common.escape_potential_buffer_block_num_y % 2 == 1) common.escape_potential_buffer_block_num_y += 1;

    common.escape_potential_buffer_size =
        @sizeOf(f32) * common.renderPatchSize(common.max_res_scale_exponent) *
        common.renderPatchSize(common.max_res_scale_exponent) *
        common.escape_potential_buffer_block_num_x * common.escape_potential_buffer_block_num_y;

    const render_patch_buffer_size: usize = common.render_patch_descriptor_sets.len *
        @sizeOf(f32) * common.renderPatchSize(0) * common.renderPatchSize(0);

    try createBuffer(
        render_patch_buffer_size,
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &common.render_patch_buffer,
        &common.render_patch_buffer_memory,
    );

    try createBuffer(
        common.escape_potential_buffer_size * common.render_to_coloring_descriptor_sets.len,
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &common.escape_potential_buffer,
        &common.escape_potential_buffer_memory,
    );

    try createBuffer(
        common.max_iterations * 2 * @sizeOf(f32) * common.cpu_to_render_descriptor_sets.len,
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &common.perturbation_buffer,
        &common.perturbation_buffer_memory,
    );

    try createBuffer(
        common.max_iterations * 2 * @sizeOf(f32),
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &common.perturbation_staging_buffer,
        &common.perturbation_staging_buffer_memory,
    );
}
