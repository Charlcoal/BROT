const std = @import("std");
const common = @import("common_defs.zig");
const cleanup = @import("cleanup.zig");
const glfw = common.glfw;
const Allocator = std.mem.Allocator;

const InitVulkanError = common.InitVulkanError;

const vert_code align(4) = @embedFile("triangle_vert_shader").*;
const frag_code align(4) = @embedFile("triangle_frag_shader").*;
const comp_code align(4) = @embedFile("mandelbrot_comp_shader").*;

pub fn initVulkan(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    try createInstance(data, alloc);
    try setupDebugMessenger(data);

    if (glfw.glfwCreateWindowSurface(data.instance, data.window, null, &data.surface) != glfw.VK_SUCCESS) {
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
    try createUniformBuffers(data, alloc);
    try createDescriptorPool(data);
    try createDescriptorSets(data, alloc);
    try createComputeCommandBuffer(data);
    try createCommandBuffers(data, alloc);
    try createSyncObjects(data, alloc);
}

pub fn recreateSwapChain(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    var width: c_int = 0;
    var height: c_int = 0;
    glfw.glfwGetFramebufferSize(data.window, &width, &height);
    while (width == 0 or height == 0) {
        if (glfw.glfwWindowShouldClose(data.window) != 0) return; // for closing while minimized
        glfw.glfwGetFramebufferSize(data.window, &width, &height);
        glfw.glfwWaitEvents();
    }

    _ = glfw.vkDeviceWaitIdle(data.device);

    cleanup.cleanupSwapChain(data.*, alloc);

    try createSwapChain(data, alloc);
    try createImageViews(data, alloc);
    try createFrameBuffers(data, alloc);
}

const SwapChainSupportDetails = struct {
    capabilities: glfw.VkSurfaceCapabilitiesKHR,
    formats: []glfw.VkSurfaceFormatKHR,
    presentModes: []glfw.VkPresentModeKHR,
};

fn populateDebugMessengerCreateInfo(create_info: *glfw.VkDebugUtilsMessengerCreateInfoEXT) void {
    create_info.* = glfw.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = glfw.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
        .messageType = glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
}

const QueueFamilyIndices = struct {
    graphics_and_compute_family: ?u32,
    present_family: ?u32,

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_and_compute_family != null and self.present_family != null;
    }
};

fn findQueueFamilies(data: common.AppData, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!QueueFamilyIndices {
    var indices = QueueFamilyIndices{
        .graphics_and_compute_family = null,
        .present_family = null,
    };

    var queue_family_count: u32 = 0;
    _ = glfw.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try alloc.alloc(glfw.VkQueueFamilyProperties, queue_family_count);
    defer alloc.free(queue_families);
    _ = glfw.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queueFamily, i| {
        if ((queueFamily.queueFlags & glfw.VK_QUEUE_GRAPHICS_BIT != 0) and (queueFamily.queueFlags & glfw.VK_QUEUE_COMPUTE_BIT != 0)) {
            indices.graphics_and_compute_family = @intCast(i);
        }

        var present_support: glfw.VkBool32 = glfw.VK_FALSE;
        _ = glfw.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), data.surface, &present_support);

        if (present_support != glfw.VK_FALSE) {
            indices.present_family = @intCast(i);
        }

        if (indices.isComplete()) break;
    }
    return indices;
}

fn querySwapChainSupport(surface: glfw.VkSurfaceKHR, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!SwapChainSupportDetails {
    var details: SwapChainSupportDetails = .{
        .formats = undefined,
        .capabilities = undefined,
        .presentModes = undefined,
    };

    _ = glfw.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities);

    var format_count: u32 = undefined;
    _ = glfw.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

    details.formats = try alloc.alloc(glfw.VkSurfaceFormatKHR, format_count);
    _ = glfw.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, details.formats.ptr);

    var present_mode_count: u32 = undefined;
    _ = glfw.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

    details.presentModes = try alloc.alloc(glfw.VkPresentModeKHR, present_mode_count);
    _ = glfw.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, details.presentModes.ptr);

    return details;
}

fn createBuffer(
    data: *common.AppData,
    size: glfw.VkDeviceSize,
    usage: glfw.VkBufferUsageFlags,
    properties: glfw.VkMemoryPropertyFlags,
    buffer: *glfw.VkBuffer,
    buffer_memory: *glfw.VkDeviceMemory,
) common.InitVulkanError!void {
    const buffer_info: glfw.VkBufferCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = glfw.VK_SHARING_MODE_EXCLUSIVE,
    };

    if (glfw.vkCreateBuffer(data.device, &buffer_info, null, buffer) != glfw.VK_SUCCESS) {
        return common.InitVulkanError.buffer_creation_failed;
    }

    var mem_requirements: glfw.VkMemoryRequirements = undefined;
    glfw.vkGetBufferMemoryRequirements(data.device, buffer.*, &mem_requirements);

    const alloc_info: glfw.VkMemoryAllocateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(data, mem_requirements.memoryTypeBits, properties),
    };

    if (glfw.vkAllocateMemory(data.device, &alloc_info, null, buffer_memory) != glfw.VK_SUCCESS) {
        return common.InitVulkanError.buffer_memory_allocation_failed;
    }

    _ = glfw.vkBindBufferMemory(data.device, buffer.*, buffer_memory.*, 0);
}

pub fn findMemoryType(data: *common.AppData, type_filter: u32, properties: glfw.VkMemoryPropertyFlags) common.InitVulkanError!u32 {
    var mem_properties: glfw.VkPhysicalDeviceMemoryProperties = undefined;
    glfw.vkGetPhysicalDeviceMemoryProperties(data.physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
            return @intCast(i);
        }
    }

    return common.InitVulkanError.suitable_memory_type_not_found;
}

fn debugCallback(
    message_severity: glfw.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: glfw.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_data: [*c]const glfw.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.C) glfw.VkBool32 {
    if (message_severity >= glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        std.debug.print("ERROR ", .{});
    } else if (message_severity >= glfw.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        std.debug.print("WARNING ", .{});
    }

    if (message_type & glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT != 0) {
        std.debug.print("[performance] ", .{});
    }
    if (message_type & glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT != 0) {
        std.debug.print("[validation] ", .{});
    }
    if (message_type & glfw.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT != 0) {
        std.debug.print("[general] ", .{});
    }

    std.debug.print("{s}\n", .{p_callback_data.*.pMessage});
    _ = p_user_data;

    return glfw.VK_FALSE;
}

fn createCommandBuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    data.command_buffers = try alloc.alloc(glfw.VkCommandBuffer, common.max_frames_in_flight);

    const alloc_info: glfw.VkCommandBufferAllocateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = data.command_pool,
        .level = glfw.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = @intCast(data.command_buffers.len),
    };

    if (glfw.vkAllocateCommandBuffers(data.device, &alloc_info, data.command_buffers.ptr) != glfw.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}

fn createComputeCommandBuffer(data: *common.AppData) InitVulkanError!void {
    const alloc_info: glfw.VkCommandBufferAllocateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = data.command_pool,
        .level = glfw.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    if (glfw.vkAllocateCommandBuffers(data.device, &alloc_info, &data.compute_command_buffer) != glfw.VK_SUCCESS) {
        return InitVulkanError.command_buffer_allocation_failed;
    }
}

fn createCommandPool(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const queue_family_indices = try findQueueFamilies(data.*, data.physical_device, alloc);

    const pool_info: glfw.VkCommandPoolCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = glfw.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.graphics_and_compute_family.?,
    };

    if (glfw.vkCreateCommandPool(data.device, &pool_info, null, &data.command_pool) != glfw.VK_SUCCESS) {
        return InitVulkanError.command_pool_creation_failed;
    }
}

fn setupDebugMessenger(data: *common.AppData) InitVulkanError!void {
    if (!common.enable_validation_layers) return;

    var create_info: glfw.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    populateDebugMessengerCreateInfo(&create_info);

    if (createDebugUtilsMessengerEXT(data.instance, &create_info, null, &data.debug_messenger) != glfw.VK_SUCCESS) {
        return InitVulkanError.debug_messenger_setup_failed;
    }
}

fn createDebugUtilsMessengerEXT(
    instance: glfw.VkInstance,
    p_create_info: [*c]const glfw.VkDebugUtilsMessengerCreateInfoEXT,
    p_vulkan_alloc: [*c]const glfw.VkAllocationCallbacks,
    p_debug_messenger: *glfw.VkDebugUtilsMessengerEXT,
) glfw.VkResult {
    const func: glfw.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(glfw.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    if (func) |ptr| {
        return ptr(instance, p_create_info, p_vulkan_alloc, p_debug_messenger);
    } else {
        return glfw.VK_ERROR_EXTENSION_NOT_PRESENT;
    }
}

fn createDescriptorPool(data: *common.AppData) InitVulkanError!void {
    const pool_sizes = [_]glfw.VkDescriptorPoolSize{
        .{
            .type = glfw.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = @intCast(common.max_frames_in_flight),
        },
        .{
            .type = glfw.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = @intCast(common.max_frames_in_flight),
        },
        //.{
        //    .type = glfw.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        //    .descriptorCount = @intCast(common.max_frames_in_flight),
        //}
    };

    const pool_info: glfw.VkDescriptorPoolCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = @intCast(pool_sizes.len),
        .pPoolSizes = &pool_sizes,
        .maxSets = common.max_frames_in_flight,
    };

    if (glfw.vkCreateDescriptorPool(data.device, &pool_info, null, &data.descriptor_pool) != glfw.VK_SUCCESS) {
        return InitVulkanError.descriptor_pool_creation_failed;
    }
}

fn createDescriptorSetLayout(data: *common.AppData) InitVulkanError!void {
    const bindings = [_]glfw.VkDescriptorSetLayoutBinding{ .{
        .binding = 0,
        .descriptorType = glfw.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = glfw.VK_SHADER_STAGE_FRAGMENT_BIT | glfw.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    }, .{
        .binding = 1,
        .descriptorType = glfw.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = glfw.VK_SHADER_STAGE_FRAGMENT_BIT | glfw.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    } };

    var layout_info: glfw.VkDescriptorSetLayoutCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };

    if (glfw.vkCreateDescriptorSetLayout(data.device, &layout_info, null, &data.descriptor_set_layout) != glfw.VK_SUCCESS) {
        return InitVulkanError.descriptor_set_layout_creation_failed;
    }
}

fn createDescriptorSets(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const layouts: []glfw.VkDescriptorSetLayout = try alloc.alloc(glfw.VkDescriptorSetLayout, common.max_frames_in_flight);
    defer alloc.free(layouts);
    for (0..common.max_frames_in_flight) |i| {
        layouts[i] = data.descriptor_set_layout;
    }

    const alloc_info: glfw.VkDescriptorSetAllocateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = data.descriptor_pool,
        .descriptorSetCount = @intCast(common.max_frames_in_flight),
        .pSetLayouts = layouts.ptr,
    };

    data.descriptor_sets = try alloc.alloc(glfw.VkDescriptorSet, common.max_frames_in_flight);
    if (glfw.vkAllocateDescriptorSets(data.device, &alloc_info, data.descriptor_sets.ptr) != glfw.VK_SUCCESS) {
        return InitVulkanError.descriptor_sets_allocation_failed;
    }

    for (0..common.max_frames_in_flight) |i| {
        const uniform_buffer_info: glfw.VkDescriptorBufferInfo = .{
            .buffer = data.uniform_buffers[i],
            .offset = 0,
            .range = @sizeOf(common.UniformBufferObject),
        };

        const storage_buffer_info: glfw.VkDescriptorBufferInfo = .{
            .buffer = data.storage_buffer,
            .offset = 0,
            .range = data.storage_buffer_size,
        };

        //const image_info: glfw.VkDescriptorImageInfo = .{
        //    .imageLayout = glfw.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        //    .imageView = data.texture_image_view,
        //    .sampler = data.texture_sampler,
        //};

        const descriptor_writes = [_]glfw.VkWriteDescriptorSet{
            .{
                .sType = glfw.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = data.descriptor_sets[i],
                .dstBinding = 0,
                .dstArrayElement = 0,
                .descriptorType = glfw.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &uniform_buffer_info,
                .pImageInfo = null,
                .pTexelBufferView = null,
            },
            .{
                .sType = glfw.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = data.descriptor_sets[i],
                .dstBinding = 1,
                .dstArrayElement = 0,
                .descriptorType = glfw.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
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

        glfw.vkUpdateDescriptorSets(data.device, @intCast(descriptor_writes.len), &descriptor_writes, 0, null);
    }
}

fn createFrameBuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
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

fn createComputePipeline(data: *common.AppData) InitVulkanError!void {
    const comp_shader_module = try createShaderModule(data.*, &comp_code);
    defer _ = glfw.vkDestroyShaderModule(data.device, comp_shader_module, null);

    const comp_shader_stage_info: glfw.VkPipelineShaderStageCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = glfw.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = comp_shader_module,
        .pName = "main",
    };

    const pipeline_layout_info: glfw.VkPipelineLayoutCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &data.descriptor_set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    if (glfw.vkCreatePipelineLayout(data.device, &pipeline_layout_info, null, &data.compute_pipeline_layout) != glfw.VK_SUCCESS) {
        return InitVulkanError.pipeline_layout_creation_failed;
    }

    const pipeline_info: glfw.VkComputePipelineCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .layout = data.compute_pipeline_layout,
        .stage = comp_shader_stage_info,
    };

    if (glfw.vkCreateComputePipelines(data.device, @ptrCast(glfw.VK_NULL_HANDLE), 1, &pipeline_info, null, &data.compute_pipeline) != glfw.VK_SUCCESS) {
        return InitVulkanError.graphics_pipeline_creation_failed;
    }
}

fn createGraphicsPipeline(data: *common.AppData) InitVulkanError!void {
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

fn createImageViews(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
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

fn createInstance(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    if (common.enable_validation_layers and !try checkValidationLayerSupport(alloc)) {
        return InitVulkanError.validation_layer_unavailible;
    }

    const app_info = glfw.VkApplicationInfo{
        .sType = glfw.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Hello Triangle",
        .applicationVersion = glfw.VK_MAKE_API_VERSION(0, 1, 3, 0),
        .pEngineName = "No Engine",
        .engineVersion = glfw.VK_MAKE_API_VERSION(0, 1, 0, 0),
        .apiVersion = glfw.VK_API_VERSION_1_3,
    };

    var create_info = glfw.VkInstanceCreateInfo{
        .sType = glfw.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
    };

    const extensions = try getRequiredExtensions(alloc);
    defer alloc.free(extensions);
    create_info.enabledExtensionCount = @intCast(extensions.len);
    create_info.ppEnabledExtensionNames = extensions.ptr;

    var debug_create_info: glfw.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    if (common.enable_validation_layers) {
        create_info.enabledLayerCount = common.validation_layers.len;
        create_info.ppEnabledLayerNames = &common.validation_layers;

        populateDebugMessengerCreateInfo(&debug_create_info);
        create_info.pNext = @ptrCast(&debug_create_info);
    } else {
        create_info.enabledLayerCount = 0;

        create_info.pNext = null;
    }

    const result = glfw.vkCreateInstance(&create_info, null, &data.instance);
    if (result != glfw.VK_SUCCESS) {
        return InitVulkanError.instance_creation_failed;
    }
}

fn checkValidationLayerSupport(alloc: Allocator) Allocator.Error!bool {
    var layer_count: u32 = undefined;
    _ = glfw.vkEnumerateInstanceLayerProperties(&layer_count, null);

    const availible_layers = try alloc.alloc(glfw.VkLayerProperties, layer_count);
    defer alloc.free(availible_layers);
    _ = glfw.vkEnumerateInstanceLayerProperties(&layer_count, availible_layers.ptr);

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
    const glfw_extensions: [*c]const [*c]const u8 = glfw.glfwGetRequiredInstanceExtensions(&glfw_extension_count);

    const out = try alloc.alloc([*c]const u8, glfw_extension_count + if (common.enable_validation_layers) 1 else 0);
    for (0..glfw_extension_count) |i| {
        out[i] = glfw_extensions[i];
    }
    if (common.enable_validation_layers) {
        out[glfw_extension_count] = glfw.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    }

    return out;
}

fn createLogicalDevice(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const indicies = try findQueueFamilies(data.*, data.physical_device, alloc);

    var unique_queue_families = [_]u32{ indicies.graphics_and_compute_family.?, indicies.present_family.? };
    var unique_queue_num: u32 = 0;

    outer: for (unique_queue_families) |queue_family| {
        for (unique_queue_families[0..unique_queue_num]) |existing_unique_queue_family| {
            if (existing_unique_queue_family == queue_family) continue :outer;
        }
        unique_queue_families[unique_queue_num] = queue_family;
        unique_queue_num += 1;
    }

    const queue_create_infos = try alloc.alloc(glfw.VkDeviceQueueCreateInfo, unique_queue_num);
    defer alloc.free(queue_create_infos);

    const queue_priority: f32 = 1;
    for (unique_queue_families[0..unique_queue_num], queue_create_infos) |queue_family, *queue_create_info| {
        queue_create_info.* = if (queue_family == indicies.graphics_and_compute_family.?) gcqci: {
            const queue_priorities = [_]f32{ 0, 1 };
            break :gcqci .{
                .sType = glfw.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = queue_family,
                .queueCount = queue_priorities.len,
                .pQueuePriorities = &queue_priorities,
            };
        } else .{
            .sType = glfw.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
    }

    const device_features: glfw.VkPhysicalDeviceFeatures = .{};

    var createInfo: glfw.VkDeviceCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
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

    if (glfw.vkCreateDevice(data.physical_device, &createInfo, null, &data.device) != glfw.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    glfw.vkGetDeviceQueue(data.device, indicies.graphics_and_compute_family.?, 0, &data.graphics_queue);
    glfw.vkGetDeviceQueue(data.device, indicies.graphics_and_compute_family.?, 1, &data.compute_queue);
    glfw.vkGetDeviceQueue(data.device, indicies.present_family.?, 0, &data.present_queue);
}

fn pickPhysicalDevice(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    var device_count: u32 = 0;
    _ = glfw.vkEnumeratePhysicalDevices(data.instance, &device_count, null);

    if (device_count == 0) {
        return InitVulkanError.gpu_with_vulkan_support_not_found;
    }

    const devices = try alloc.alloc(glfw.VkPhysicalDevice, device_count);
    defer alloc.free(devices);
    _ = glfw.vkEnumeratePhysicalDevices(data.instance, &device_count, devices.ptr);

    for (devices) |device| {
        if (try deviceIsSuitable(data.*, device, alloc)) {
            data.physical_device = device;
            break;
        }
    } else {
        return InitVulkanError.suitable_gpu_not_found;
    }
}

fn deviceIsSuitable(data: common.AppData, device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
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

fn checkDeviceExtensionSupport(device: glfw.VkPhysicalDevice, alloc: Allocator) Allocator.Error!bool {
    var extension_count: u32 = undefined;
    _ = glfw.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);

    const availibleExtensions = try alloc.alloc(glfw.VkExtensionProperties, extension_count);
    defer alloc.free(availibleExtensions);
    _ = glfw.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, availibleExtensions.ptr);

    outer: for (common.device_extensions) |extension| {
        for (availibleExtensions) |availible| {
            if (common.str_eq(extension, @ptrCast(&availible.extensionName))) continue :outer;
        }
        return false;
    }

    return true;
}

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

fn createSwapChain(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const swap_chain_support = try querySwapChainSupport(data.surface, data.physical_device, alloc);
    defer alloc.free(swap_chain_support.formats);
    defer alloc.free(swap_chain_support.presentModes);

    const surface_format = chooseSwapSurfaceFormat(swap_chain_support.formats);
    const present_mode = chooseSwapPresentMode(swap_chain_support.presentModes);
    const extent = chooseSwapExtent(data.*, &swap_chain_support.capabilities);

    var image_count: u32 = swap_chain_support.capabilities.minImageCount + 1;
    if (swap_chain_support.capabilities.maxImageCount > 0 and image_count > swap_chain_support.capabilities.maxImageCount) {
        image_count = swap_chain_support.capabilities.maxImageCount;
    }

    var create_info: glfw.VkSwapchainCreateInfoKHR = .{
        .sType = glfw.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = data.surface,
        .minImageCount = image_count,
        .imageFormat = surface_format.format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = glfw.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = swap_chain_support.capabilities.currentTransform,
        .compositeAlpha = glfw.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = glfw.VK_TRUE,
    };

    const indices = try findQueueFamilies(data.*, data.physical_device, alloc);
    const queue_family_indices = [_]u32{ indices.graphics_and_compute_family.?, indices.present_family.? };

    if (indices.graphics_and_compute_family != indices.present_family) {
        create_info.imageSharingMode = glfw.VK_SHARING_MODE_CONCURRENT;
        create_info.queueFamilyIndexCount = 2;
        create_info.pQueueFamilyIndices = &queue_family_indices;
    } else {
        create_info.imageSharingMode = glfw.VK_SHARING_MODE_EXCLUSIVE;
        create_info.queueFamilyIndexCount = 0;
        create_info.pQueueFamilyIndices = null;
        create_info.oldSwapchain = @ptrCast(glfw.VK_NULL_HANDLE);
    }

    if (glfw.vkCreateSwapchainKHR(data.device, &create_info, null, &data.swap_chain) != glfw.VK_SUCCESS) {
        return InitVulkanError.logical_device_creation_failed;
    }

    _ = glfw.vkGetSwapchainImagesKHR(data.device, data.swap_chain, &image_count, null);
    data.swap_chain_images = try alloc.alloc(glfw.VkImage, image_count);
    _ = glfw.vkGetSwapchainImagesKHR(data.device, data.swap_chain, &image_count, data.swap_chain_images.ptr);

    data.swap_chain_image_format = surface_format.format;
    data.swap_chain_extent = extent;
}

fn chooseSwapSurfaceFormat(availible_formats: []const glfw.VkSurfaceFormatKHR) glfw.VkSurfaceFormatKHR {
    for (availible_formats) |format| {
        if (format.format == glfw.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == glfw.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return format;
        }
    }

    return availible_formats[0];
}

fn chooseSwapPresentMode(availible_present_modes: []const glfw.VkPresentModeKHR) glfw.VkPresentModeKHR {
    for (availible_present_modes) |mode| {
        if (mode == glfw.VK_PRESENT_MODE_MAILBOX_KHR) {
            return mode;
        }
    }

    //always availible
    return glfw.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(data: common.AppData, capabilities: *const glfw.VkSurfaceCapabilitiesKHR) glfw.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    } else {
        var height: c_int = undefined;
        var width: c_int = undefined;
        glfw.glfwGetFramebufferSize(data.window, &width, &height);

        var actualExtent: glfw.VkExtent2D = .{
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
    data.image_availible_semaphores = try alloc.alloc(glfw.VkSemaphore, common.max_frames_in_flight);
    data.render_finished_semaphores = try alloc.alloc(glfw.VkSemaphore, data.swap_chain_images.len);
    data.in_flight_fences = try alloc.alloc(glfw.VkFence, common.max_frames_in_flight);

    const semaphore_info: glfw.VkSemaphoreCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fence_info: glfw.VkFenceCreateInfo = .{
        .sType = glfw.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = glfw.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    if (glfw.vkCreateFence(data.device, &fence_info, null, &data.compute_fence) != glfw.VK_SUCCESS) {
        return InitVulkanError.semaphore_creation_failed;
    }

    for (0..common.max_frames_in_flight) |i| {
        if (glfw.vkCreateSemaphore(data.device, &semaphore_info, null, &data.image_availible_semaphores[i]) != glfw.VK_SUCCESS or
            glfw.vkCreateFence(data.device, &fence_info, null, &data.in_flight_fences[i]) != glfw.VK_SUCCESS)
        {
            return InitVulkanError.semaphore_creation_failed;
        }
    }

    for (data.render_finished_semaphores) |*sem| {
        if (glfw.vkCreateSemaphore(data.device, &semaphore_info, null, sem) != glfw.VK_SUCCESS) {
            return InitVulkanError.semaphore_creation_failed;
        }
    }
}

fn createUniformBuffers(data: *common.AppData, alloc: Allocator) InitVulkanError!void {
    const buffer_size: glfw.VkDeviceSize = @sizeOf(common.UniformBufferObject);

    data.uniform_buffers = try alloc.alloc(glfw.VkBuffer, common.max_frames_in_flight);
    data.uniform_buffers_memory = try alloc.alloc(glfw.VkDeviceMemory, common.max_frames_in_flight);
    data.uniform_buffers_mapped = try alloc.alloc(?*align(@alignOf(common.UniformBufferObject)) anyopaque, common.max_frames_in_flight);

    for (0..common.max_frames_in_flight) |i| {
        try createBuffer(
            data,
            buffer_size,
            glfw.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            glfw.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | glfw.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &data.uniform_buffers[i],
            &data.uniform_buffers_memory[i],
        );

        _ = glfw.vkMapMemory(
            data.device,
            data.uniform_buffers_memory[i],
            0,
            buffer_size,
            0,
            @ptrCast(&data.uniform_buffers_mapped[i]),
        );
    }
}

fn createStorageBuffer(data: *common.AppData) InitVulkanError!void {
    const video_mode = glfw.glfwGetVideoMode(glfw.glfwGetPrimaryMonitor());
    data.storage_buffer_size = @intCast(video_mode.?.*.width * video_mode.?.*.height * @sizeOf(u32));

    try createBuffer(
        data,
        data.storage_buffer_size,
        glfw.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        glfw.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        &data.storage_buffer,
        &data.storage_buffer_memory,
    );
}
