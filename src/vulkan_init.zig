const std = @import("std");
const common = @import("common_defs.zig");
const cleanup = @import("cleanup.zig");
const c = common.c;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

const vert_code align(4) = @embedFile("triangle_vert_shader").*;
const frag_code align(4) = @embedFile("triangle_frag_shader").*;
const comp_code align(4) = @embedFile("mandelbrot_comp_shader").*;

pub fn initVulkan(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    try createInstance(data, alloc);
    try setupDebugMessenger(data);

    if (c.glfwCreateWindowSurface(data.instance, data.window, null, &data.surface) != c.VK_SUCCESS) {
        return InitVulkanError.window_surface_creation_failed;
    }

    try pickPhysicalDevice(data, alloc);
    try createLogicalDevice(data, alloc);
    try createSwapChain(data, alloc);
    try createImageViews(data, alloc);
    try createRenderPass(data);
    try createDescriptorSetLayout(data);
    try createGraphicsPipeline(data);
    try createComputePipeline(data);
    try createFrameBuffers(data, alloc);
    try createCommandPool(data, alloc);
    try createStorageBuffer(data);
    try createUniformBuffers(data);
    try createDescriptorPool(data);
    try createDescriptorSets(data, alloc);
    try createComputeCommandBuffer(data);
    try createCommandBuffers(data);
    try createSyncObjects(data, alloc);
}

pub fn recreateSwapChain(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(data.window, &width, &height);
    while (width == 0 or height == 0) {
        if (c.glfwWindowShouldClose(data.window) != 0) return; // for closing while minimized
        c.glfwGetFramebufferSize(data.window, &width, &height);
        c.glfwWaitEvents();
    }

    _ = c.vkDeviceWaitIdle(data.device);

    cleanup.cleanupSwapChain(data.*, alloc);

    try createSwapChain(data, alloc);
    try createImageViews(data, alloc);
    try createFrameBuffers(data, alloc);
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

fn findQueueFamilies(data: common.AppData, device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!QueueFamilyIndices {
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
        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), data.surface, &present_support);

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
    data: *common.AppData,
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

    if (c.vkCreateBuffer(data.device, &buffer_info, null, buffer) != c.VK_SUCCESS) {
        return common.InitVulkanError.buffer_creation_failed;
    }

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(data.device, buffer.*, &mem_requirements);

    const alloc_info: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(data, mem_requirements.memoryTypeBits, properties),
    };

    if (c.vkAllocateMemory(data.device, &alloc_info, null, buffer_memory) != c.VK_SUCCESS) {
        return common.InitVulkanError.buffer_memory_allocation_failed;
    }

    _ = c.vkBindBufferMemory(data.device, buffer.*, buffer_memory.*, 0);
}

pub fn findMemoryType(data: *common.AppData, type_filter: u32, properties: c.VkMemoryPropertyFlags) common.InitVulkanError!u32 {
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(data.physical_device, &mem_properties);

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
    p_callback_data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.C) c.VkBool32 {
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

    std.debug.print("{s}\n", .{p_callback_data.*.pMessage});
    _ = p_user_data;

    return c.VK_FALSE;
}

fn createCommandBuffers(data: *common.AppData) InitVulkanError!void {
    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = data.graphics_command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    if (c.vkAllocateCommandBuffers(data.device, &alloc_info, &data.graphics_command_buffer) != c.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}

fn createComputeCommandBuffer(data: *common.AppData) InitVulkanError!void {
    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = data.graphics_command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    if (c.vkAllocateCommandBuffers(data.device, &alloc_info, &data.compute_command_buffer) != c.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}

fn createCommandPool(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const queue_family_indices = try findQueueFamilies(data.*, data.physical_device, alloc);

    const pool_info: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.graphics_family.?,
    };

    if (c.vkCreateCommandPool(data.device, &pool_info, null, &data.graphics_command_pool) != c.VK_SUCCESS) {
        return InitVulkanError.command_pool_creation_failed;
    }
}

fn createComputeCommandPool(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const queue_family_indices = try findQueueFamilies(data.*, data.physical_device, alloc);

    const pool_info: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.compute_family.?,
    };

    if (c.vkCreateCommandPool(data.device, &pool_info, null, &data.compute_command_pool) != c.VK_SUCCESS) {
        return InitVulkanError.command_pool_creation_failed;
    }
}

fn setupDebugMessenger(data: *common.AppData) InitVulkanError!void {
    if (!common.enable_validation_layers) return;

    var create_info: c.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    populateDebugMessengerCreateInfo(&create_info);

    if (createDebugUtilsMessengerEXT(data.instance, &create_info, null, &data.debug_messenger) != c.VK_SUCCESS) {
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

fn createDescriptorPool(data: *common.AppData) InitVulkanError!void {
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{
            .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = @intCast(data.swap_chain_images.len),
        },
        .{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = @intCast(data.swap_chain_images.len),
        },
        //.{
        //    .type = glfw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        //    .descriptorCount = @intCast(common.max_frames_in_flight),
        //}
    };

    const pool_info: c.VkDescriptorPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = @intCast(pool_sizes.len),
        .pPoolSizes = &pool_sizes,
        .maxSets = @intCast(data.swap_chain_images.len),
    };

    if (c.vkCreateDescriptorPool(data.device, &pool_info, null, &data.descriptor_pool) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_pool_creation_failed;
    }
}

fn createDescriptorSetLayout(data: *common.AppData) InitVulkanError!void {
    const bindings = [_]c.VkDescriptorSetLayoutBinding{ .{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    }, .{
        .binding = 1,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    } };

    var layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };

    if (c.vkCreateDescriptorSetLayout(data.device, &layout_info, null, &data.descriptor_set_layout) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_set_layout_creation_failed;
    }
}

fn createDescriptorSets(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const layouts: []c.VkDescriptorSetLayout = try alloc.alloc(c.VkDescriptorSetLayout, data.swap_chain_images.len);
    defer alloc.free(layouts);
    for (0..data.swap_chain_images.len) |i| {
        layouts[i] = data.descriptor_set_layout;
    }

    const alloc_info: c.VkDescriptorSetAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = data.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = layouts.ptr,
    };

    if (c.vkAllocateDescriptorSets(data.device, &alloc_info, &data.descriptor_set) != c.VK_SUCCESS) {
        return InitVulkanError.descriptor_sets_allocation_failed;
    }

    const uniform_buffer_info: c.VkDescriptorBufferInfo = .{
        .buffer = data.uniform_buffer,
        .offset = 0,
        .range = @sizeOf(common.UniformBufferObject),
    };

    const storage_buffer_info: c.VkDescriptorBufferInfo = .{
        .buffer = data.storage_buffer,
        .offset = 0,
        .range = data.storage_buffer_size,
    };

    //const image_info: glfw.VkDescriptorImageInfo = .{
    //    .imageLayout = glfw.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    //    .imageView = data.texture_image_view,
    //    .sampler = data.texture_sampler,
    //};

    const descriptor_writes = [_]c.VkWriteDescriptorSet{
        .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = data.descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &uniform_buffer_info,
            .pImageInfo = null,
            .pTexelBufferView = null,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = data.descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &storage_buffer_info,
        },
        //.{
        //    .sType = glfw.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        //    .dstSet = data.descriptor_sets[i],
        //    .dstBinding = 1,
        //    .dstArrayElement = 0,
        //    .descriptorType = glfw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        //    .descriptorCount = 1,
        //    .pImageInfo = &image_info,
        //}
    };

    c.vkUpdateDescriptorSets(data.device, @intCast(descriptor_writes.len), &descriptor_writes, 0, null);
}

fn createFrameBuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.swap_chain_framebuffers = try alloc.alloc(c.VkFramebuffer, data.swap_chain_image_views.len);

    for (0..data.swap_chain_image_views.len) |i| {
        const attachments = [_]c.VkImageView{
            data.swap_chain_image_views[i],
        };

        const frame_buffer_info: c.VkFramebufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = data.render_pass,
            .attachmentCount = @intCast(attachments.len),
            .pAttachments = &attachments,
            .width = data.swap_chain_extent.width,
            .height = data.swap_chain_extent.height,
            .layers = 1,
        };

        if (c.vkCreateFramebuffer(data.device, &frame_buffer_info, null, &data.swap_chain_framebuffers[i]) != c.VK_SUCCESS) {
            return InitVulkanError.framebuffer_creation_failed;
        }
    }
}

fn createComputePipeline(data: *common.AppData) InitVulkanError!void {
    const comp_shader_module = try createShaderModule(data.*, &comp_code);
    defer _ = c.vkDestroyShaderModule(data.device, comp_shader_module, null);

    const comp_shader_stage_info: c.VkPipelineShaderStageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = comp_shader_module,
        .pName = "main",
    };

    const push_constant_range: c.VkPushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.UniformBufferObject),
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
    };

    const pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &data.descriptor_set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    };
    if (c.vkCreatePipelineLayout(data.device, &pipeline_layout_info, null, &data.compute_pipeline_layout) != c.VK_SUCCESS) {
        return InitVulkanError.pipeline_layout_creation_failed;
    }

    const pipeline_info: c.VkComputePipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = data.compute_pipeline_layout,
        .stage = comp_shader_stage_info,
    };

    if (c.vkCreateComputePipelines(data.device, @ptrCast(c.VK_NULL_HANDLE), 1, &pipeline_info, null, &data.compute_pipeline) != c.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createGraphicsPipeline(data: *common.AppData) InitVulkanError!void {
    const vert_shader_module = try createShaderModule(data.*, &vert_code);
    const frag_shader_module = try createShaderModule(data.*, &frag_code);
    defer _ = c.vkDestroyShaderModule(data.device, vert_shader_module, null);
    defer _ = c.vkDestroyShaderModule(data.device, frag_shader_module, null);

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

    const pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &data.descriptor_set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    if (c.vkCreatePipelineLayout(data.device, &pipeline_layout_info, null, &data.pipeline_layout) != c.VK_SUCCESS) {
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
        .layout = data.pipeline_layout,
        .renderPass = data.render_pass,
        .subpass = 0,
        .basePipelineHandle = @ptrCast(c.VK_NULL_HANDLE),
        .basePipelineIndex = -1,
    };

    if (c.vkCreateGraphicsPipelines(data.device, @ptrCast(c.VK_NULL_HANDLE), 1, &pipeline_info, null, &data.graphics_pipeline) != c.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createShaderModule(data: common.AppData, code: []align(4) const u8) InitVulkanError!c.VkShaderModule {
    const create_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(code.ptr),
    };
    var shader_module: c.VkShaderModule = undefined;
    if (c.vkCreateShaderModule(data.device, &create_info, null, &shader_module) != c.VK_SUCCESS) {
        return InitVulkanError.shader_module_creation_failed;
    }
    return shader_module;
}

fn createImageViews(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
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

fn createInstance(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
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

    const result = c.vkCreateInstance(&create_info, null, &data.instance);
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

fn createLogicalDevice(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const indicies = try findQueueFamilies(data.*, data.physical_device, alloc);

    var unique_queue_families = [_]u32{ indicies.graphics_family.?, indicies.compute_family.?, indicies.present_family.? };
    const max_queues = [unique_queue_families.len]u32{ indicies.graphics_max_queues, indicies.compute_max_queues, indicies.present_max_queues };
    var num_required_queues = [unique_queue_families.len]u32{ 1, 1, 1 };
    var unique_queue_num: u32 = 0;

    var queue_family_property_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(data.physical_device, &queue_family_property_count, null);

    const queue_family_properties = try alloc.alloc(c.VkQueueFamilyProperties, queue_family_property_count);
    defer alloc.free(queue_family_properties);
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(data.physical_device, &queue_family_property_count, queue_family_properties.ptr);

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

    if (c.vkCreateDevice(data.physical_device, &createInfo, null, &data.device) != c.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    c.vkGetDeviceQueue(data.device, indicies.graphics_family.?, 0, &data.graphics_queue);
    c.vkGetDeviceQueue(data.device, indicies.present_family.?, 0, &data.present_queue);
    if (indicies.graphics_family.? == indicies.compute_family.? and indicies.graphics_max_queues >= 2) {
        c.vkGetDeviceQueue(data.device, indicies.compute_family.?, 1, &data.compute_queue);
    } else {
        c.vkGetDeviceQueue(data.device, indicies.compute_family.?, 0, &data.compute_queue);
    }
}

fn pickPhysicalDevice(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    var device_count: u32 = 0;
    _ = c.vkEnumeratePhysicalDevices(data.instance, &device_count, null);

    if (device_count == 0) {
        return InitVulkanError.gpu_with_vulkan_support_not_found;
    }

    const devices = try alloc.alloc(c.VkPhysicalDevice, device_count);
    defer alloc.free(devices);
    _ = c.vkEnumeratePhysicalDevices(data.instance, &device_count, devices.ptr);

    for (devices) |device| {
        if (try deviceIsSuitable(data.*, device, alloc)) {
            data.physical_device = device;
            break;
        }
    } else {
        return InitVulkanError.suitable_gpu_not_found;
    }
}

fn deviceIsSuitable(data: common.AppData, device: c.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    const indices = try findQueueFamilies(data, device, alloc);

    const extensions_supported: bool = try checkDeviceExtensionSupport(device, alloc);

    var swap_chain_adequate: bool = false;
    if (extensions_supported) {
        const swap_chain_support = try querySwapChainSupport(data.surface, device, alloc);
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

pub fn createRenderPass(data: *common.AppData) InitVulkanError!void {
    const color_attachment: c.VkAttachmentDescription = .{
        .format = data.swap_chain_image_format,
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

    if (c.vkCreateRenderPass(data.device, &render_pass_info, null, &data.render_pass) != c.VK_SUCCESS) {
        return InitVulkanError.render_pass_creation_failed;
    }
}

fn createSwapChain(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const swap_chain_support = try querySwapChainSupport(data.surface, data.physical_device, alloc);
    defer alloc.free(swap_chain_support.formats);
    defer alloc.free(swap_chain_support.presentModes);

    const surface_format = chooseSwapSurfaceFormat(swap_chain_support.formats);
    const present_mode = chooseSwapPresentMode(swap_chain_support.presentModes);
    const extent = chooseSwapExtent(data.*, &swap_chain_support.capabilities);

    data.swap_chain_images.len = swap_chain_support.capabilities.minImageCount + 1;
    if (swap_chain_support.capabilities.maxImageCount > 0 and data.swap_chain_images.len > swap_chain_support.capabilities.maxImageCount) {
        data.swap_chain_images.len = swap_chain_support.capabilities.maxImageCount;
    }

    var create_info: c.VkSwapchainCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = data.surface,
        .minImageCount = @intCast(data.swap_chain_images.len),
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

    const indices = try findQueueFamilies(data.*, data.physical_device, alloc);
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

    if (c.vkCreateSwapchainKHR(data.device, &create_info, null, &data.swap_chain) != c.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    _ = c.vkGetSwapchainImagesKHR(data.device, data.swap_chain, @ptrCast(&data.swap_chain_images.len), null);
    data.swap_chain_images = try alloc.alloc(c.VkImage, data.swap_chain_images.len);
    _ = c.vkGetSwapchainImagesKHR(data.device, data.swap_chain, @ptrCast(&data.swap_chain_images.len), data.swap_chain_images.ptr);

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

fn createSyncObjects(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.image_availible_semaphores = try alloc.alloc(c.VkSemaphore, data.swap_chain_images.len);
    data.render_finished_semaphores = try alloc.alloc(c.VkSemaphore, data.swap_chain_images.len);

    const semaphore_info: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fence_info: c.VkFenceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    if (c.vkCreateFence(data.device, &fence_info, null, &data.compute_fence) != c.VK_SUCCESS) {
        return InitVulkanError.semaphore_creation_failed;
    }

    for (0..data.swap_chain_images.len) |i| {
        if (c.vkCreateSemaphore(data.device, &semaphore_info, null, &data.image_availible_semaphores[i]) != c.VK_SUCCESS) {
            return InitVulkanError.semaphore_creation_failed;
        }
    }
    if (c.vkCreateFence(data.device, &fence_info, null, &data.in_flight_fence) != c.VK_SUCCESS) {
        return InitVulkanError.semaphore_creation_failed;
    }

    for (data.render_finished_semaphores) |*sem| {
        if (c.vkCreateSemaphore(data.device, &semaphore_info, null, sem) != c.VK_SUCCESS) {
            return InitVulkanError.semaphore_creation_failed;
        }
    }
}

fn createUniformBuffers(data: *common.AppData) InitVulkanError!void {
    const buffer_size: c.VkDeviceSize = @sizeOf(common.UniformBufferObject);

    try createBuffer(
        data,
        buffer_size,
        c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &data.uniform_buffer,
        &data.uniform_buffer_memory,
    );

    _ = c.vkMapMemory(
        data.device,
        data.uniform_buffer_memory,
        0,
        buffer_size,
        0,
        @ptrCast(&data.uniform_buffer_mapped),
    );
}

fn createStorageBuffer(data: *common.AppData) InitVulkanError!void {
    const video_mode = c.glfwGetVideoMode(c.glfwGetPrimaryMonitor());
    data.storage_buffer_size = @intCast(video_mode.?.*.width * video_mode.?.*.height * @sizeOf(u32));

    try createBuffer(
        data,
        data.storage_buffer_size,
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &data.storage_buffer,
        &data.storage_buffer_memory,
    );
}
