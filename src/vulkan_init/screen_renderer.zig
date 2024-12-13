const instance = @import("instance.zig");
const std = @import("std");
const common = @import("../common_defs.zig");
const c = common.c;

const Allocator = std.mem.Allocator;

pub const Error = error{
    logical_device_creation_failed,
    image_views_creation_failed,
    render_pass_creation_failed,
    shader_module_creation_failed,
    pipeline_layout_creation_failed,
    graphics_pipeline_creation_failed,
    framebuffer_creation_failed,
    command_pool_creation_failed,
    command_buffer_allocation_failed,
} || Allocator.Error || common.ReadFileError;

pub const ScreenRenderer = struct {
    swapchain: Swapchain,
    render_pass: c.VkRenderPass,
    graphics_pipeline: c.VkPipeline,
    pipeline_layout: c.VkPipelineLayout,
    command_pool: c.VkCommandPool,
    command_buffers: []c.VkCommandBuffer,

    pub fn init(alloc: Allocator, inst: instance.Instance, window: *c.GLFWwindow, descriptor_set_layout: c.VkDescriptorSetLayout) Error!ScreenRenderer {
        var render_pipeline: ScreenRenderer = undefined;

        render_pipeline.swapchain = try Swapchain.initSansFramebuffers(alloc, inst, window);
        render_pipeline.render_pass = try createRenderPass(inst, render_pipeline.swapchain);

        const graphics_pipeline_and_layout = try createGraphicsPipeline(inst, alloc, descriptor_set_layout, render_pipeline.render_pass);
        render_pipeline.graphics_pipeline = graphics_pipeline_and_layout.pipeline;
        render_pipeline.pipeline_layout = graphics_pipeline_and_layout.layout;

        try render_pipeline.swapchain.initFramebuffers(alloc, inst, render_pipeline.render_pass);
        render_pipeline.command_pool = try createCommandPool(inst, alloc);
        render_pipeline.command_buffers = try createCommandBuffers(inst, alloc, render_pipeline.command_pool);

        return render_pipeline;
    }

    pub fn recreateSwapchain(screen_renderer: *ScreenRenderer, inst: instance.Instance, alloc: Allocator, window: *c.GLFWwindow) Error!void {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(window, &width, &height);
        while (width == 0 or height == 0) {
            c.glfwGetFramebufferSize(window, &width, &height);
            c.glfwWaitEvents();
        }

        _ = c.vkDeviceWaitIdle(inst.logical_device);

        screen_renderer.swapchain.deinit(inst, alloc);
        screen_renderer.swapchain = try Swapchain.initSansFramebuffers(alloc, inst, window);
        try screen_renderer.swapchain.initFramebuffers(alloc, inst, screen_renderer.render_pass);
    }

    pub fn deinit(self: *ScreenRenderer, inst: instance.Instance, alloc: Allocator) void {
        self.swapchain.deinit(inst, alloc);

        c.vkDestroyPipeline(inst.logical_device, self.graphics_pipeline, null);
        c.vkDestroyPipelineLayout(inst.logical_device, self.pipeline_layout, null);

        c.vkDestroyRenderPass(inst.logical_device, self.render_pass, null);
        c.vkDestroyCommandPool(inst.logical_device, self.command_pool, null);
        alloc.free(self.command_buffers);
    }
};

fn createCommandBuffers(inst: instance.Instance, alloc: Allocator, command_pool: c.VkCommandPool) Error![]c.VkCommandBuffer {
    const command_buffers = try alloc.alloc(c.VkCommandBuffer, common.max_frames_in_flight);

    const alloc_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = @intCast(command_buffers.len),
    };

    if (c.vkAllocateCommandBuffers(inst.logical_device, &alloc_info, command_buffers.ptr) != c.VK_SUCCESS) {
        return Error.command_buffer_allocation_failed;
    }

    return command_buffers;
}

fn createCommandPool(inst: instance.Instance, alloc: Allocator) Error!c.VkCommandPool {
    const queue_family_indices = try findQueueFamilies(inst.physical_device, alloc, inst.surface);

    const pool_info: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.graphics_compute_family.?,
    };

    var out: c.VkCommandPool = undefined;

    if (c.vkCreateCommandPool(inst.logical_device, &pool_info, null, &out) != c.VK_SUCCESS) {
        return Error.command_pool_creation_failed;
    }

    return out;
}

fn createGraphicsPipeline(
    inst: instance.Instance,
    alloc: Allocator,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    render_pass: c.VkRenderPass,
) Error!struct { pipeline: c.VkPipeline, layout: c.VkPipelineLayout } {
    const vert_code = try common.readFile("src/shaders/triangle_vert.spv", alloc, 4);
    const frag_code = try common.readFile("src/shaders/triangle_frag.spv", alloc, 4);
    defer alloc.free(vert_code);
    defer alloc.free(frag_code);

    const vert_shader_module = try createShaderModule(inst, vert_code);
    const frag_shader_module = try createShaderModule(inst, frag_code);
    defer _ = c.vkDestroyShaderModule(inst.logical_device, vert_shader_module, null);
    defer _ = c.vkDestroyShaderModule(inst.logical_device, frag_shader_module, null);

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
        .pSetLayouts = &descriptor_set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };

    var pipeline_layout: c.VkPipelineLayout = undefined;

    if (c.vkCreatePipelineLayout(inst.logical_device, &pipeline_layout_info, null, &pipeline_layout) != c.VK_SUCCESS) {
        return Error.pipeline_layout_creation_failed;
    }

    const pipeline_info: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
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
        .layout = pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = @ptrCast(c.VK_NULL_HANDLE),
        .basePipelineIndex = -1,
    };

    var pipeline: c.VkPipeline = undefined;

    if (c.vkCreateGraphicsPipelines(inst.logical_device, @ptrCast(c.VK_NULL_HANDLE), 1, &pipeline_info, null, &pipeline) != c.VK_SUCCESS) {
        return Error.graphics_pipeline_creation_failed;
    }

    return .{ .pipeline = pipeline, .layout = pipeline_layout };
}

fn createShaderModule(inst: instance.Instance, code: []align(4) const u8) Error!c.VkShaderModule {
    const create_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(code.ptr),
    };
    var shader_module: c.VkShaderModule = undefined;
    if (c.vkCreateShaderModule(inst.logical_device, &create_info, null, &shader_module) != c.VK_SUCCESS) {
        return Error.shader_module_creation_failed;
    }
    return shader_module;
}

pub fn createRenderPass(inst: instance.Instance, swapchain: Swapchain) Error!c.VkRenderPass {
    const color_attachment: c.VkAttachmentDescription = .{
        .format = swapchain.format,
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

    var render_pass: c.VkRenderPass = undefined;

    if (c.vkCreateRenderPass(inst.logical_device, &render_pass_info, null, &render_pass) != c.VK_SUCCESS) {
        return Error.render_pass_creation_failed;
    }

    return render_pass;
}

pub const Swapchain = struct {
    vk_swapchain: c.VkSwapchainKHR,
    extent: c.VkExtent2D,
    format: c.VkFormat,
    images: []c.VkImage,
    image_views: []c.VkImageView,
    framebuffers: []c.VkFramebuffer,

    /// doesn't initiallize framebuffers
    pub fn initSansFramebuffers(alloc: Allocator, inst: instance.Instance, window: *c.GLFWwindow) Error!Swapchain {
        var out: Swapchain = .{
            .vk_swapchain = undefined,
            .extent = undefined,
            .format = undefined,
            .images = undefined,
            .image_views = undefined,
            .framebuffers = &.{}, //empty slice that points to nothing (size 0)
        };
        try createVkSwapchain(inst, alloc, window, &out);
        try createSwapchainImageViews(inst, alloc, &out);
        return out;
    }

    pub fn initFramebuffers(swapchain: *Swapchain, alloc: Allocator, inst: instance.Instance, render_pass: c.VkRenderPass) Error!void {
        // nested function to avoid many indents
        try createFramebuffers(inst, alloc, swapchain, render_pass);
    }

    pub fn deinit(swapchain: *Swapchain, inst: instance.Instance, alloc: Allocator) void {
        for (swapchain.framebuffers) |framebuffer| {
            c.vkDestroyFramebuffer(inst.logical_device, framebuffer, null);
        }
        alloc.free(swapchain.framebuffers);

        for (swapchain.image_views) |view| {
            c.vkDestroyImageView(inst.logical_device, view, null);
        }
        alloc.free(swapchain.image_views);

        c.vkDestroySwapchainKHR(inst.logical_device, swapchain.vk_swapchain, null);
        alloc.free(swapchain.images);
    }
};

fn createVkSwapchain(inst: instance.Instance, alloc: Allocator, window: *c.GLFWwindow, swapchain: *Swapchain) Error!void {
    const surface_format = chooseSwapSurfaceFormat(inst.swap_chain_support.formats);
    const present_mode = chooseSwapPresentMode(inst.swap_chain_support.presentModes);
    swapchain.extent = chooseSwapExtent(window, &inst.swap_chain_support.capabilities);

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
        .imageExtent = swapchain.extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = inst.swap_chain_support.capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = c.VK_TRUE,
    };

    const indices = try findQueueFamilies(inst.physical_device, alloc, inst.surface);
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

    if (c.vkCreateSwapchainKHR(inst.logical_device, &create_info, null, &swapchain.vk_swapchain) != c.VK_SUCCESS) {
        return Error.logical_device_creation_failed;
    }

    _ = c.vkGetSwapchainImagesKHR(inst.logical_device, swapchain.vk_swapchain, &image_count, null);
    swapchain.images = try alloc.alloc(c.VkImage, image_count);
    _ = c.vkGetSwapchainImagesKHR(inst.logical_device, swapchain.vk_swapchain, &image_count, swapchain.images.ptr);

    swapchain.format = surface_format.format;
}

fn createSwapchainImageViews(inst: instance.Instance, alloc: Allocator, swapchain: *Swapchain) Error!void {
    swapchain.image_views = try alloc.alloc(c.VkImageView, swapchain.images.len);

    for (swapchain.images, 0..) |image, i| {
        const view_create_info: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = swapchain.format,
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

        if (c.vkCreateImageView(inst.logical_device, &view_create_info, null, &swapchain.image_views[i]) != c.VK_SUCCESS) {
            return Error.image_views_creation_failed;
        }
    }
}

fn createFramebuffers(inst: instance.Instance, alloc: Allocator, swapchain: *Swapchain, render_pass: c.VkRenderPass) Error!void {
    swapchain.framebuffers = try alloc.alloc(c.VkFramebuffer, swapchain.image_views.len);

    for (0..swapchain.image_views.len) |i| {
        const attachments = [_]c.VkImageView{
            swapchain.image_views[i],
        };

        const frame_buffer_info: c.VkFramebufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = render_pass,
            .attachmentCount = @intCast(attachments.len),
            .pAttachments = &attachments,
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        };

        if (c.vkCreateFramebuffer(inst.logical_device, &frame_buffer_info, null, &swapchain.framebuffers[i]) != c.VK_SUCCESS) {
            return Error.framebuffer_creation_failed;
        }
    }
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

pub const QueueFamilyIndices = struct {
    graphics_compute_family: ?u32,
    present_family: ?u32,

    pub fn isComplete(self: QueueFamilyIndices) bool {
        return self.graphics_compute_family != null and self.present_family != null;
    }
};

pub fn findQueueFamilies(device: c.VkPhysicalDevice, alloc: Allocator, surface: c.VkSurfaceKHR) Allocator.Error!QueueFamilyIndices {
    var indices = QueueFamilyIndices{
        .graphics_compute_family = null,
        .present_family = null,
    };

    var queue_family_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try alloc.alloc(c.VkQueueFamilyProperties, queue_family_count);
    defer alloc.free(queue_families);
    _ = c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queueFamily, i| {
        if (queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0 and queueFamily.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0) {
            indices.graphics_compute_family = @intCast(i);
        }

        var present_support: c.VkBool32 = c.VK_FALSE;
        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &present_support);

        if (present_support != c.VK_FALSE) {
            indices.present_family = @intCast(i);
        }

        if (indices.isComplete()) break;
    }
    return indices;
}
