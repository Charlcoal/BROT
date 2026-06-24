// BROT - A fast mandelbrot set explorer
// Copyright (C) 2025 - 2026 Charles Reischer
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

pub var base: vk.BaseWrapper = undefined;
pub var instance: vk.InstanceProxy = undefined;

pub var debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle;
pub var physical_device: vk.PhysicalDevice = .null_handle;
pub var device: vk.DeviceProxy = undefined;

pub var queue_families: QueueFamilyIndices = undefined;
pub var graphics_queue: vk.Queue = .null_handle;
pub var compute_queue: vk.Queue = .null_handle;
pub var present_queue: vk.Queue = .null_handle;

pub var render_pass: vk.RenderPass = undefined;

// -------------- comptime settings --------------

pub const vk_version = vk.API_VERSION_1_3;

pub const enable_validation_layers = common.dbg;
const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
const required_layers = if (enable_validation_layers) validation_layers else [0][*:0]const u8{};

pub const device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};

pub const target_frame_rate: f64 = 60;
pub const max_frames_in_flight: u32 = 2;

// -----------------------------------------------

pub fn init(alloc: Allocator, io: std.Io) !void {
    base = vk.BaseWrapper.load(getGlfwInstanceProcAddr);

    try createInstance(alloc);
    setupDebugMessenger();

    if (@as(vk.Result, @enumFromInt(c.glfwCreateWindowSurface(
        @ptrFromInt(@intFromEnum(instance.handle)),
        window.glfw,
        null,
        @ptrCast(&window.surface),
    ))) != .success) {
        std.debug.panic("Window surface creation failed!", .{});
    }

    try pickPhysicalDevice(alloc);
    queue_families = try findQueueFamilies(physical_device, alloc);
    try createLogicalDevice(alloc);
    try createSwapChain(alloc);
    try createImageViews(alloc);

    try createRenderPass();
    try createRenderPatchDescriptorSetLayout();
    try createCpuToRndDescriptorSetLayout();
    try createRndToClrDescriptorSetLayout();
    try createBufferRemapPipeline(alloc, io);
    try createPatchPlacePipeline(alloc, io);
    try createColoringPipeline(alloc, io);
    try createRendingPipeline(alloc, io);
    try createFrameBuffers(alloc);

    common.graphics_command_pool = try device.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_families.graphics_family.?,
    }, null);
    common.compute_command_pool = try device.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_families.compute_family.?,
    }, null);

    try createBuffers();
    try createDescriptorPool();
    try createGuiDescriptorPool();
    try createDescriptorSets(alloc);

    try device.allocateCommandBuffers(&.{
        .command_pool = common.compute_command_pool,
        .level = .primary,
        .command_buffer_count = common.rendering_command_buffers.len,
    }, &common.rendering_command_buffers);
    try device.allocateCommandBuffers(&.{
        .command_pool = common.compute_command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, (&common.rnd_buffer_write_command_buffer)[0..1]);
    common.graphics_command_buffers = try alloc.alloc(vk.CommandBuffer, max_frames_in_flight);
    try device.allocateCommandBuffers(&.{
        .command_pool = common.graphics_command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(common.graphics_command_buffers.len),
    }, common.graphics_command_buffers.ptr);

    try createSyncObjects(alloc);
}

pub fn recreateSwapChain(alloc: Allocator) !void {
    common.frame_buffer_just_resized = true;

    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(window.glfw, &width, &height);
    while (width == 0 or height == 0) {
        if (c.glfwWindowShouldClose(window.glfw) != 0) return; // for closing while minimized
        c.glfwGetFramebufferSize(window.glfw, &width, &height);
        c.glfwWaitEvents();
    }

    try device.deviceWaitIdle();
    cleanup.cleanupSwapChain(alloc);

    try createSwapChain(alloc);
    try createImageViews(alloc);
    try createFrameBuffers(alloc);
}

fn createDescriptorSets(alloc: Allocator) !void {
    const patch_size: usize =
        @sizeOf(f32) * common.renderPatchSize(0) * common.renderPatchSize(0);
    try createMultiBufferDescriptorSets(
        alloc,
        common.render_patch_descriptor_set_layout,
        common.render_patch_descriptor_sets[0..],
        common.descriptor_pool,
        common.render_patch_buffer,
        patch_size,
    );
    try createMultiBufferDescriptorSets(
        alloc,
        common.cpu_to_render_descriptor_set_layout,
        common.cpu_to_render_descriptor_sets[0..],
        common.descriptor_pool,
        common.perturbation_buffer,
        common.allocated_iterations * 2 * @sizeOf(f32),
    );
    try createMultiBufferDescriptorSets(
        alloc,
        common.render_to_coloring_descriptor_set_layout,
        common.render_to_coloring_descriptor_sets[0..],
        common.descriptor_pool,
        common.escape_potential_buffer,
        common.escape_potential_buffer_size,
    );
    try createMultiBufferDescriptorSets(
        alloc,
        common.render_patch_descriptor_set_layout,
        common.back_r2c_descriptor_sets[0..],
        common.descriptor_pool,
        common.back_r2c_buffer,
        patch_size,
    );
}

fn findQueueFamilies(
    prospective_physical_device: vk.PhysicalDevice,
    alloc: Allocator,
) Allocator.Error!QueueFamilyIndices {
    var indices = QueueFamilyIndices{
        .graphics_family = null,
        .compute_family = null,
        .present_family = null,
        .graphics_max_queues = 0,
        .present_max_queues = 0,
        .compute_max_queues = 0,
    };

    const all_queue_families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
        prospective_physical_device,
        alloc,
    );
    defer alloc.free(all_queue_families);

    for (all_queue_families, 0..) |queue_family, i| {
        const family: u32 = @intCast(i);
        if (queue_family.queue_flags.graphics_bit and indices.graphics_family == null) {
            indices.graphics_family = family;
            indices.graphics_max_queues = queue_family.queue_count;
        }

        if (queue_family.queue_flags.compute_bit and (indices.compute_family == null or
            (!queue_family.queue_flags.graphics_bit and (all_queue_families[indices.compute_family.?].queue_flags.graphics_bit))))
        {
            indices.compute_family = family;
            indices.compute_max_queues = queue_family.queue_count;
        }

        const present_support = instance.getPhysicalDeviceSurfaceSupportKHR(
            prospective_physical_device,
            family,
            window.surface,
        ) catch std.debug.panic("Present support unavailable!", .{});
        if ((present_support == .true) and indices.present_family == null) {
            indices.present_family = family;
            indices.present_max_queues = queue_family.queue_count;
        }
    }
    return indices;
}

pub fn createBuffer(
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    properties: vk.MemoryPropertyFlags,
    vk_alloc: [*c]const vk.AllocationCallbacks,
) !@Tuple(&.{ vk.Buffer, vk.DeviceMemory }) {
    const buffer = try device.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, vk_alloc);

    const mem_requirements = device.getBufferMemoryRequirements(buffer);
    const buffer_mem = try device.allocateMemory(&.{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try findMemoryType(mem_requirements.memory_type_bits, properties),
    }, vk_alloc);

    try device.bindBufferMemory(buffer, buffer_mem, 0);
    return .{ buffer, buffer_mem };
}

pub fn findMemoryType(type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const mem_properties = instance.getPhysicalDeviceMemoryProperties(physical_device);

    for (0..mem_properties.memory_type_count) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and
            mem_properties.memory_types[i].property_flags.contains(properties))
            return @intCast(i);
    }

    return error.suitable_memory_type_not_found;
}

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_common: [*c]const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_common: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    const type_str = if (msg_type.general_bit_ext)
        "[general]"
    else if (msg_type.validation_bit_ext)
        "[validation]"
    else if (msg_type.performance_bit_ext)
        "[performance]"
    else if (msg_type.device_address_binding_bit_ext)
        "[device addr]"
    else
        "[unknown]";

    const msg = if (p_callback_common == null or p_callback_common.*.p_message == null)
        "<<NO MESSAGE>>"
    else
        p_callback_common.*.p_message.?;

    if (message_severity.verbose_bit_ext) {
        log.debug("{s} {s}", .{ type_str, msg });
    } else if (message_severity.info_bit_ext) {
        log.info("{s} {s}", .{ type_str, msg });
    } else if (message_severity.warning_bit_ext) {
        log.warn("{s} {s}", .{ type_str, msg });
    } else if (message_severity.error_bit_ext) {
        log.err("{s} {s}", .{ type_str, msg });
    } else {
        log.err(" <<UNKNOWN SEVERITY>> {s} {s}", .{ type_str, msg });
    }

    _ = p_user_common;
    return .false;
}

fn setupDebugMessenger() void {
    if (!enable_validation_layers) return;

    debug_messenger = instance.createDebugUtilsMessengerEXT(&.{
        .message_severity = .{
            //.verbose_bit_ext = true,
            //.info_bit_ext = true,
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = &debugCallback,
        .p_user_data = null,
    }, null) catch @panic("Failed to create debug messenger!");
}

fn createDebugUtilsMessengerEXT(
    p_create_info: [*c]const vk.DebugUtilsMessengerCreateInfoEXT,
    p_vulkan_alloc: [*c]const vk.AllocationCallbacks,
    p_debug_messenger: *vk.DebugUtilsMessengerEXT,
) vk.Result {
    const func: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT"));
    if (func) |ptr| {
        return ptr(instance, p_create_info, p_vulkan_alloc, p_debug_messenger);
    } else {
        return vk.ERROR_EXTENSION_NOT_PRESENT;
    }
}

fn createDescriptorPool() !void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .storage_buffer, .descriptor_count = @intCast(common.render_to_coloring_descriptor_sets.len) },
        .{ .type = .storage_buffer, .descriptor_count = @intCast(common.cpu_to_render_descriptor_sets.len) },
        .{ .type = .storage_buffer, .descriptor_count = @intCast(common.back_r2c_descriptor_sets.len) },
        .{ .type = .storage_buffer, .descriptor_count = @intCast(common.render_patch_descriptor_sets.len) },
    };

    common.descriptor_pool = try device.createDescriptorPool(&.{
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = &pool_sizes,
        .max_sets = @intCast(common.render_to_coloring_descriptor_sets.len +
            common.cpu_to_render_descriptor_sets.len +
            common.back_r2c_descriptor_sets.len +
            common.render_patch_descriptor_sets.len),
    }, null);
}

fn createGuiDescriptorPool() !void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .combined_image_sampler, .descriptor_count = c.IMGUI_IMPL_VULKAN_MINIMUM_IMAGE_SAMPLER_POOL_SIZE },
    };

    var count: u32 = 0;
    for (pool_sizes) |ps| count += ps.descriptor_count;

    gui.descriptor_pool = try device.createDescriptorPool(&.{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = count,
        .p_pool_sizes = &pool_sizes,
        .pool_size_count = @intCast(pool_sizes.len),
    }, null);
}

fn createRenderPatchDescriptorSetLayout() !void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true, .fragment_bit = true },
        .p_immutable_samplers = null,
    }};

    common.render_patch_descriptor_set_layout = try device.createDescriptorSetLayout(&.{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);
}

fn createCpuToRndDescriptorSetLayout() !void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true },
        .p_immutable_samplers = null,
    }};

    common.cpu_to_render_descriptor_set_layout = try device.createDescriptorSetLayout(&.{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);
}

fn createRndToClrDescriptorSetLayout() !void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true, .fragment_bit = true },
        .p_immutable_samplers = null,
    }};

    common.render_to_coloring_descriptor_set_layout = try device.createDescriptorSetLayout(&.{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);
}

fn createMultiBufferDescriptorSets(
    alloc: Allocator,
    layout: vk.DescriptorSetLayout,
    sets: []vk.DescriptorSet,
    pool: vk.DescriptorPool,
    buffer: vk.Buffer,
    chunk_size: usize,
) !void {
    const layouts = try alloc.alloc(vk.DescriptorSetLayout, sets.len);
    defer alloc.free(layouts);
    @memset(layouts, layout);

    try device.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = @intCast(layouts.len),
        .p_set_layouts = layouts.ptr,
    }, sets.ptr);

    for (0..sets.len) |i| {
        const buffer_info: vk.DescriptorBufferInfo = .{
            .buffer = buffer,
            .offset = chunk_size * i,
            .range = chunk_size,
        };

        const descriptor_writes = [_]vk.WriteDescriptorSet{.{
            .dst_set = sets[i],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .p_buffer_info = (&buffer_info)[0..1],
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        }};

        device.updateDescriptorSets(descriptor_writes[0..], null);
    }
}
pub fn updateMultiBufferDescriptorSets(
    sets: []vk.DescriptorSet,
    buffer: vk.Buffer,
    chunk_size: usize,
) !void {
    for (0..sets.len) |i| {
        const buffer_info: vk.DescriptorBufferInfo = .{
            .buffer = buffer,
            .offset = chunk_size * i,
            .range = chunk_size,
        };

        const descriptor_writes = [_]vk.WriteDescriptorSet{.{
            .dst_set = sets[i],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .p_buffer_info = (&buffer_info)[0..1],
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        }};

        device.updateDescriptorSets(descriptor_writes[0..], null);
    }
}

fn createFrameBuffers(alloc: Allocator) !void {
    common.swap_chain_framebuffers = try alloc.alloc(vk.Framebuffer, common.swap_chain_image_views.len);

    for (0..common.swap_chain_image_views.len) |i| {
        const attachments = [_]vk.ImageView{
            common.swap_chain_image_views[i],
        };

        common.swap_chain_framebuffers[i] = try device.createFramebuffer(&.{
            .render_pass = render_pass,
            .attachment_count = @intCast(attachments.len),
            .p_attachments = &attachments,
            .width = common.swap_chain_extent.width,
            .height = common.swap_chain_extent.height,
            .layers = 1,
        }, null);
    }
}

fn createBufferRemapPipeline(alloc: Allocator, io: std.Io) !void {
    const push_constant_range: vk.PushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.BufferRemapConstants),
        .stage_flags = .{ .compute_bit = true },
    };

    const descriptor_sets = [_]vk.DescriptorSetLayout{
        common.render_to_coloring_descriptor_set_layout,
        common.render_to_coloring_descriptor_set_layout,
    };

    const module = try createShaderModule(alloc, io, null, c.GLSLANG_STAGE_COMPUTE, buffer_remap_glsl, "buffer_remap.comp", true);
    defer device.destroyShaderModule(module, null);
    common.buffer_remap_pipeline, common.buffer_remap_pipeline_layout = try createComputePipeline(
        module,
        null,
        descriptor_sets[0..],
        .{ .push_constant_ranges = &.{push_constant_range} },
    );
}

const ComputePipelineOptions = struct {
    push_constant_ranges: []const vk.PushConstantRange = &.{},
};

fn createComputePipeline(
    shader_module: vk.ShaderModule,
    vk_alloc: [*c]const vk.AllocationCallbacks,
    descriptor_set_layouts: []const vk.DescriptorSetLayout,
    options: ComputePipelineOptions,
) !@Tuple(&.{ vk.Pipeline, vk.PipelineLayout }) {
    const shader_stage_info: vk.PipelineShaderStageCreateInfo = .{
        .stage = .{ .compute_bit = true },
        .module = shader_module,
        .p_name = "main",
    };

    const pipeline_layout = try device.createPipelineLayout(&.{
        .set_layout_count = @intCast(descriptor_set_layouts.len),
        .p_set_layouts = descriptor_set_layouts.ptr,
        .push_constant_range_count = @intCast(options.push_constant_ranges.len),
        .p_push_constant_ranges = options.push_constant_ranges.ptr,
    }, vk_alloc);

    const pipeline_info: vk.ComputePipelineCreateInfo = .{
        .layout = pipeline_layout,
        .stage = shader_stage_info,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try device.createComputePipelines(
        .null_handle,
        (&pipeline_info)[0..1],
        vk_alloc,
        (&pipeline)[0..1],
    );

    return .{ pipeline, pipeline_layout };
}

fn createPatchPlacePipeline(alloc: Allocator, io: std.Io) !void {
    const push_constant_range: vk.PushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.PatchPlaceConstants),
        .stage_flags = .{ .compute_bit = true },
    };

    const descriptor_sets = [_]vk.DescriptorSetLayout{
        common.render_patch_descriptor_set_layout,
        common.render_to_coloring_descriptor_set_layout,
    };

    const module = try createShaderModule(alloc, io, null, c.GLSLANG_STAGE_COMPUTE, patch_place_glsl, "patch_place.comp", true);
    defer device.destroyShaderModule(module, null);
    common.patch_place_pipeline, common.patch_place_pipeline_layout = try createComputePipeline(
        module,
        null,
        descriptor_sets[0..],
        .{ .push_constant_ranges = &.{push_constant_range} },
    );
}

fn createRendingPipeline(alloc: Allocator, io: std.Io) !void {
    const push_constant_range: vk.PushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.RenderingConstants),
        .stage_flags = .{ .compute_bit = true },
    };

    const descriptor_sets = [_]vk.DescriptorSetLayout{
        common.render_patch_descriptor_set_layout,
        common.cpu_to_render_descriptor_set_layout,
    };

    const module = try createShaderModule(alloc, io, null, c.GLSLANG_STAGE_COMPUTE, render_glsl, "render.comp", true);
    defer device.destroyShaderModule(module, null);
    common.rendering_pipeline, common.rendering_pipeline_layout = try createComputePipeline(
        module,
        null,
        descriptor_sets[0..],
        .{ .push_constant_ranges = &.{push_constant_range} },
    );
}

fn createColoringPipeline(alloc: Allocator, io: std.Io) !void {
    const vert_shader_module = try createShaderModule(alloc, io, null, c.GLSLANG_STAGE_VERTEX, dummy_vert_glsl, "triangle.vert", true);
    const frag_shader_module = try createShaderModule(alloc, io, null, c.GLSLANG_STAGE_FRAGMENT, color_glsl, "triangle.frag", true);
    defer _ = device.destroyShaderModule(vert_shader_module, null);
    defer _ = device.destroyShaderModule(frag_shader_module, null);

    const vert_shader_stage_info: vk.PipelineShaderStageCreateInfo = .{
        .stage = .{ .vertex_bit = true },
        .module = vert_shader_module,
        .p_name = "main",
    };
    const frag_shader_stage_info: vk.PipelineShaderStageCreateInfo = .{
        .stage = .{ .fragment_bit = true },
        .module = frag_shader_module,
        .p_name = "main",
    };

    const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
        vert_shader_stage_info,
        frag_shader_stage_info,
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = @intCast(dynamic_states.len),
        .p_dynamic_states = &dynamic_states,
    };

    const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = null,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = null,
    };

    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const viewport_state: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const rasterizer: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .line_width = 1,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const multisampling: vk.PipelineMultisampleStateCreateInfo = .{
        .sample_shading_enable = .false,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const color_blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    };

    const color_blending: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = (&color_blend_attachment)[0..1],
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const push_constant_range: vk.PushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(common.ColoringConstants),
        .stage_flags = .{ .fragment_bit = true },
    };

    const descriptor_sets = [_]vk.DescriptorSetLayout{
        common.render_to_coloring_descriptor_set_layout,
        common.render_patch_descriptor_set_layout,
    };

    common.coloring_pipeline_layout = try device.createPipelineLayout(&.{
        .set_layout_count = descriptor_sets.len,
        .p_set_layouts = &descriptor_sets,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&push_constant_range)[0..1],
    }, null);

    const pipeline_info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = shader_stages.len,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &color_blending,
        .p_dynamic_state = &dynamic_state,
        .layout = common.coloring_pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    _ = try device.createGraphicsPipelines(
        .null_handle,
        (&pipeline_info)[0..1],
        null,
        (&common.coloring_pipeline)[0..1],
    );
}

const ShaderCreationError = error{ preprocessing_failed, parsing_failed, linking_failed, vulkan_module_creation_failed } || Allocator.Error;
/// Compiles glsl source code. If expect_success is true, a message will be
/// printed to log.err on glsl compile error.
fn createShaderModule(
    alloc: Allocator,
    io: std.Io,
    vk_alloc: [*c]const vk.AllocationCallbacks,
    stage: c.glslang_stage_t,
    shader_source: [:0]const u8,
    file_name_for_debug: []const u8,
    expect_success: bool,
) ShaderCreationError!vk.ShaderModule {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // filename safe base64
    const encoder = std.base64.Base64Encoder{
        .alphabet_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-".*,
        .pad_char = '=',
    };

    hasher.update(shader_source);
    const hash = hasher.finalResult();
    var hash_64: [encoder.calcSize(hash.len)]u8 = @splat('=');
    _ = encoder.encode(hash_64[0..], hash[0..]);
    const file_name = "shader_" ++ hash_64 ++ ".spirv_v1.5";

    const existing_spirv: ?[]const u32 = blk: {
        const stats = common.cache_dir.statFile(io, file_name, .{}) catch break :blk null;
        const size = std.math.divExact(usize, @intCast(stats.size), 4) catch break :blk null;
        const out = try alloc.alloc(u32, size);
        _ = common.cache_dir.readFile(io, file_name, @ptrCast(out)) catch {
            alloc.free(out);
            break :blk null;
        };
        break :blk out;
    };

    const spirv = if (existing_spirv) |spirv| spirv else blk: {
        const input: c.glslang_input_t = .{
            .language = c.GLSLANG_SOURCE_GLSL,
            .stage = stage,
            .client = c.GLSLANG_CLIENT_VULKAN,
            .client_version = c.GLSLANG_TARGET_VULKAN_1_3,
            .target_language = c.GLSLANG_TARGET_SPV,
            .target_language_version = c.GLSLANG_TARGET_SPV_1_5,
            .code = shader_source.ptr,
            .default_version = 450,
            .default_profile = c.GLSLANG_NO_PROFILE,
            .force_default_version_and_profile = c.false,
            .forward_compatible = c.false,
            .messages = c.GLSLANG_MSG_DEFAULT_BIT,
            .resource = c.glslang_default_resource(),
        };

        const shader: ?*c.glslang_shader_t = c.glslang_shader_create(&input);
        defer c.glslang_shader_delete(shader);

        if (c.glslang_shader_preprocess(shader, &input) == c.false) {
            if (expect_success)
                log.err("GLSL preprocessing failed {s}\n{s}\n{s}\n{s}", .{
                    file_name_for_debug,
                    c.glslang_shader_get_info_log(shader),
                    c.glslang_shader_get_info_debug_log(shader),
                    input.code,
                });

            return ShaderCreationError.preprocessing_failed;
        }

        if (c.glslang_shader_parse(shader, &input) == c.false) {
            if (expect_success)
                log.err("GLSL parsing failed {s}\n{s}\n{s}\n{s}", .{
                    file_name_for_debug,
                    c.glslang_shader_get_info_log(shader),
                    c.glslang_shader_get_info_debug_log(shader),
                    c.glslang_shader_get_preprocessed_code(shader),
                });
            return ShaderCreationError.parsing_failed;
        }

        const program: ?*c.glslang_program_t = c.glslang_program_create();
        defer c.glslang_program_delete(program);
        c.glslang_program_add_shader(program, shader);

        if (c.glslang_program_link(program, c.GLSLANG_MSG_SPV_RULES_BIT | c.GLSLANG_MSG_VULKAN_RULES_BIT) == c.false) {
            if (expect_success)
                log.err("GLSL linking failed {s}\n{s}\n{s}", .{
                    file_name_for_debug,
                    c.glslang_shader_get_info_log(shader),
                    c.glslang_shader_get_info_debug_log(shader),
                });
            return ShaderCreationError.linking_failed;
        }

        c.glslang_program_SPIRV_generate(program, stage);

        const out_size: usize = c.glslang_program_SPIRV_get_size(program);
        const spirv_code = try alloc.alloc(u32, out_size);
        errdefer alloc.free(spirv_code);
        c.glslang_program_SPIRV_get(program, spirv_code.ptr);

        const spirv_messages = c.glslang_program_SPIRV_get_messages(program);
        if (spirv_messages != null)
            std.log.info("({s}) {s}", .{ file_name_for_debug, spirv_messages });

        break :blk spirv_code;
    };
    defer alloc.free(spirv);

    var maybe_future: ?std.Io.Future(std.Io.Dir.WriteFileError!void) = if (existing_spirv == null) io.async(
        std.Io.Dir.writeFile,
        .{ common.cache_dir, io, std.Io.Dir.WriteFileOptions{ .sub_path = file_name, .data = @ptrCast(spirv) } },
    ) else null;
    defer if (maybe_future) |*future| future.await(io) catch {};

    return device.createShaderModule(&.{
        .code_size = spirv.len * @sizeOf(u32),
        .p_code = @ptrCast(spirv.ptr),
    }, vk_alloc) catch return ShaderCreationError.vulkan_module_creation_failed;
}

fn createImageViews(alloc: Allocator) !void {
    common.swap_chain_image_views = try alloc.alloc(vk.ImageView, common.swap_chain_images.len);

    for (common.swap_chain_images, 0..) |image, i| {
        common.swap_chain_image_views[i] = try device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = common.swap_chain_image_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    }
}

fn createInstance(alloc: Allocator) !void {
    if (try checkLayerSupport(base, alloc) == false) return error.MissingLayer;

    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(alloc);

    var glfw_exts_count: u32 = 0;
    const glfw_exts = c.glfwGetRequiredInstanceExtensions(&glfw_exts_count);
    try extension_names.appendSlice(alloc, @ptrCast(glfw_exts[0..glfw_exts_count]));

    if (enable_validation_layers) try extension_names.append(alloc, vk.extensions.ext_debug_utils.name);
    // the following extensions are to support vulkan in mac os
    // see https://github.com/glfw/glfw/issues/2335
    try extension_names.append(alloc, vk.extensions.khr_portability_enumeration.name);
    try extension_names.append(alloc, vk.extensions.khr_get_physical_device_properties_2.name);

    const app_version = vk.makeApiVersion(
        0,
        @intCast(build_options.version.major),
        @intCast(build_options.version.minor),
        @intCast(build_options.version.patch),
    );

    const instance_sans_wrapper = try base.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "BROT",
            .application_version = app_version.toU32(),
            .p_engine_name = "BROT",
            .engine_version = app_version.toU32(),
            .api_version = vk_version.toU32(),
        },
        .enabled_layer_count = required_layers.len,
        .pp_enabled_layer_names = @ptrCast(&required_layers),
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = extension_names.items.ptr,
        // enumerate_portability_bit_khr to support vulkan in mac os
        // see https://github.com/glfw/glfw/issues/2335
        .flags = .{ .enumerate_portability_bit_khr = true },
    }, null);

    const instance_wrapper = try alloc.create(vk.InstanceWrapper);
    errdefer alloc.destroy(instance_wrapper);
    instance_wrapper.* = vk.InstanceWrapper.load(instance_sans_wrapper, base.dispatch.vkGetInstanceProcAddr.?);
    instance = .init(instance_sans_wrapper, instance_wrapper);
}

fn checkValidationLayerSupport(alloc: Allocator) Allocator.Error!bool {
    var layer_count: u32 = undefined;
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, null);

    const availible_layers = try alloc.alloc(vk.LayerProperties, layer_count);
    defer alloc.free(availible_layers);
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, availible_layers.ptr);

    for (validation_layers) |v_layer| {
        var layer_found: bool = false;

        for (availible_layers) |a_layer| {
            if (std.mem.eq(u8, v_layer, @as([*:0]const u8, @ptrCast(&a_layer.layerName)))) {
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

    const out = try alloc.alloc([*c]const u8, glfw_extension_count + if (enable_validation_layers) 1 else 0);
    for (0..glfw_extension_count) |i| {
        out[i] = glfw_extensions[i];
    }
    if (enable_validation_layers) {
        out[glfw_extension_count] = vk.EXT_DEBUG_UTILS_EXTENSION_NAME;
    }

    return out;
}

fn createLogicalDevice(alloc: Allocator) !void {
    var unique_queue_families = [_]u32{
        queue_families.graphics_family.?,
        queue_families.compute_family.?,
        queue_families.present_family.?,
    };
    const max_queues = [unique_queue_families.len]u32{
        queue_families.graphics_max_queues,
        queue_families.compute_max_queues,
        queue_families.present_max_queues,
    };
    var num_required_queues = [unique_queue_families.len]u32{ 1, 1, 1 };
    var unique_queue_num: u32 = 0;

    const queue_family_properties = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, alloc);
    defer alloc.free(queue_family_properties);

    outer: for (
        unique_queue_families,
        &num_required_queues,
        max_queues,
    ) |queue_family, *num_req_queues, max_queue| {
        for (
            unique_queue_families[0..unique_queue_num],
            num_required_queues[0..unique_queue_num],
        ) |existing_unique_queue_family, *existing_num_req_queues| {
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

    const queue_create_infos = try alloc.alloc(vk.DeviceQueueCreateInfo, unique_queue_num);
    defer alloc.free(queue_create_infos);

    const queue_priority: [2]f32 = .{ 1, 0 };
    for (
        unique_queue_families[0..unique_queue_num],
        queue_create_infos,
        num_required_queues[0..unique_queue_num],
    ) |queue_family, *queue_create_info, num_queues| {
        queue_create_info.* = .{
            .queue_family_index = queue_family,
            .queue_count = num_queues,
            .p_queue_priorities = if (queue_family == queue_families.compute_family and
                queue_family != queue_families.graphics_family)
                queue_priority[1..]
            else
                &queue_priority,
        };
    }

    const device_sans_wrapper = try instance.createDevice(physical_device, &.{
        .queue_create_info_count = @intCast(queue_create_infos.len),
        .p_queue_create_infos = queue_create_infos.ptr,
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = &device_extensions,
    }, null);

    const vkd = try alloc.create(vk.DeviceWrapper);
    errdefer alloc.destroy(vkd);
    vkd.* = vk.DeviceWrapper.load(device_sans_wrapper, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    device = .init(device_sans_wrapper, vkd);
    errdefer device.destroyDevice(null);

    graphics_queue = device.getDeviceQueue(queue_families.graphics_family.?, 0);
    present_queue = device.getDeviceQueue(queue_families.present_family.?, 0);
    if (queue_families.graphics_family.? == queue_families.compute_family.? and
        queue_families.graphics_max_queues >= 2)
    {
        compute_queue = device.getDeviceQueue(queue_families.compute_family.?, 1);
    } else {
        compute_queue = device.getDeviceQueue(queue_families.compute_family.?, 0);
    }
}

fn pickPhysicalDevice(alloc: Allocator) !void {
    const prospective_pdevices = try instance.enumeratePhysicalDevicesAlloc(alloc);
    defer alloc.free(prospective_pdevices);

    for (prospective_pdevices) |prospective_physical_device| {
        if (try deviceIsSuitable(prospective_physical_device, alloc)) {
            physical_device = prospective_physical_device;
            break;
        }
    } else {
        return error.SuitableGpuNotFound;
    }
}

fn deviceIsSuitable(prospective_physical_device: vk.PhysicalDevice, alloc: Allocator) !bool {
    if (!try checkDeviceExtensionSupport(prospective_physical_device, alloc)) return false;

    var format_count: u32 = undefined;
    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(prospective_physical_device, window.surface, &format_count, null);
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(prospective_physical_device, window.surface, &present_mode_count, null);
    if (format_count == 0 or present_mode_count == 0) return false;

    const indices = try findQueueFamilies(prospective_physical_device, alloc);
    return indices.isComplete();
}

fn checkDeviceExtensionSupport(prospective_physical_device: vk.PhysicalDevice, alloc: Allocator) !bool {
    const availible_extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(
        prospective_physical_device,
        null,
        alloc,
    );
    defer alloc.free(availible_extensions);

    for (device_extensions) |extension| {
        const ext_slice = extension[0..std.mem.findSentinel(u8, 0, extension)];
        for (availible_extensions) |availible| {
            if (ext_slice.len == availible.extension_name.len) {
                if (std.mem.eql(u8, ext_slice, &availible.extension_name)) break;
            } else {
                const sentinel_index = std.mem.findSentinel(u8, 0, @ptrCast(&availible.extension_name));
                if (std.mem.eql(u8, ext_slice, availible.extension_name[0..sentinel_index])) break;
            }
        } else return false;
    }

    return true;
}

pub fn createRenderPass() !void {
    const color_attachment: vk.AttachmentDescription = .{
        .format = common.swap_chain_image_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref: vk.AttachmentReference = .{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = &.{color_attachment_ref},
    };

    const dependency: vk.SubpassDependency = .{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };

    const render_pass_info: vk.RenderPassCreateInfo = .{
        .attachment_count = 1,
        .p_attachments = &.{color_attachment},
        .subpass_count = 1,
        .p_subpasses = &.{subpass},
        .dependency_count = 1,
        .p_dependencies = &.{dependency},
    };

    render_pass = try device.createRenderPass(&render_pass_info, null);
}

fn createSwapChain(alloc: Allocator) !void {
    const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, window.surface, alloc);
    defer alloc.free(formats);
    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(physical_device, window.surface, alloc);
    defer alloc.free(present_modes);
    const capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, window.surface);

    const surface_format = chooseSwapSurfaceFormat(formats);
    const present_mode = chooseSwapPresentMode(present_modes);
    const extent = chooseSwapExtent(&capabilities);

    common.swap_chain_images.len = capabilities.min_image_count + 1;
    if (capabilities.max_image_count > 0 and common.swap_chain_images.len > capabilities.max_image_count) {
        common.swap_chain_images.len = capabilities.max_image_count;
    }

    var create_info: vk.SwapchainCreateInfoKHR = .{
        .surface = window.surface,
        .min_image_count = @intCast(common.swap_chain_images.len),
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_sharing_mode = undefined,
        .image_usage = .{ .color_attachment_bit = true },
        .pre_transform = capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
    };

    const queue_family_indices = [_]u32{
        queue_families.graphics_family.?,
        queue_families.present_family.?,
    };

    if (queue_families.graphics_family != queue_families.present_family) {
        create_info.image_sharing_mode = .concurrent;
        create_info.queue_family_index_count = 2;
        create_info.p_queue_family_indices = &queue_family_indices;
    } else {
        create_info.image_sharing_mode = .exclusive;
        create_info.queue_family_index_count = 0;
        create_info.p_queue_family_indices = null;
        create_info.old_swapchain = .null_handle;
    }

    common.swap_chain = try device.createSwapchainKHR(&create_info, null);
    common.swap_chain_images = try device.getSwapchainImagesAllocKHR(common.swap_chain, alloc);
    common.swap_chain_image_format = surface_format.format;
    common.swap_chain_extent = extent;
}

fn chooseSwapSurfaceFormat(availible_formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (availible_formats) |format| {
        if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
            return format;
        }
    }

    return availible_formats[0];
}

fn chooseSwapPresentMode(availible_present_modes: []const vk.PresentModeKHR) vk.PresentModeKHR {
    for (availible_present_modes) |mode| {
        if (mode == .mailbox_khr) {
            return mode;
        }
    }

    //always availible
    return .fifo_khr;
}

fn chooseSwapExtent(capabilities: *const vk.SurfaceCapabilitiesKHR) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) {
        return capabilities.current_extent;
    } else {
        var height: c_int = undefined;
        var width: c_int = undefined;
        c.glfwGetFramebufferSize(window.glfw, &width, &height);

        var actual_extent: vk.Extent2D = .{
            .height = @intCast(height),
            .width = @intCast(width),
        };

        actual_extent.width = std.math.clamp(
            actual_extent.width,
            capabilities.min_image_extent.width,
            capabilities.max_image_extent.width,
        );
        actual_extent.height = std.math.clamp(
            actual_extent.height,
            capabilities.min_image_extent.height,
            capabilities.max_image_extent.height,
        );

        return actual_extent;
    }
}

fn createSyncObjects(alloc: Allocator) !void {
    common.image_availible_semaphores = try alloc.alloc(vk.Semaphore, max_frames_in_flight);
    common.render_finished_semaphores = try alloc.alloc(vk.Semaphore, common.swap_chain_images.len);
    common.in_flight_fences = try alloc.alloc(vk.Fence, max_frames_in_flight);

    common.render_buffer_write_fence = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    for (&common.rendering_fences) |*fence|
        fence.* = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);

    for (common.image_availible_semaphores, common.in_flight_fences) |*sem, *fence| {
        sem.* = try device.createSemaphore(&.{}, null);
        fence.* = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    }

    for (common.render_finished_semaphores) |*sem|
        sem.* = try device.createSemaphore(&.{}, null);
}

fn createBuffers() !void {
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

    const render_patch_size: usize = @sizeOf(f32) * common.renderPatchSize(0) * common.renderPatchSize(0);
    const render_patch_buffer_size: usize = common.render_patch_descriptor_sets.len * render_patch_size;

    common.render_patch_buffer, common.render_patch_buffer_memory = try createBuffer(
        render_patch_buffer_size,
        .{ .storage_buffer_bit = true },
        .{ .device_local_bit = true },
        null,
    );

    common.escape_potential_buffer, common.escape_potential_buffer_memory = try createBuffer(
        common.escape_potential_buffer_size * common.render_to_coloring_descriptor_sets.len,
        .{ .storage_buffer_bit = true },
        .{ .device_local_bit = true },
        null,
    );

    common.back_r2c_buffer, common.back_r2c_buffer_memory = try createBuffer(
        render_patch_size * common.back_r2c_descriptor_sets.len,
        .{ .storage_buffer_bit = true },
        .{ .device_local_bit = true },
        null,
    );

    common.perturbation_buffer, common.perturbation_buffer_memory = try createBuffer(
        common.allocated_iterations * 2 * @sizeOf(f32) * common.cpu_to_render_descriptor_sets.len,
        .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
        .{ .device_local_bit = true },
        null,
    );

    common.perturbation_staging_buffer, common.perturbation_staging_buffer_memory = try createBuffer(
        common.allocated_iterations * 2 * @sizeOf(f32),
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        null,
    );
}

fn getGlfwInstanceProcAddr(inst: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction {
    return @ptrCast(c.glfwGetInstanceProcAddress(
        @ptrFromInt(@intFromEnum(inst)),
        procname,
    ));
}

fn checkLayerSupport(vkb: vk.BaseWrapper, alloc: Allocator) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(alloc);
    defer alloc.free(available_layers);
    for (required_layers) |required_layer| {
        for (available_layers) |layer| {
            if (std.mem.eql(u8, std.mem.span(required_layer), std.mem.sliceTo(&layer.layer_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

pub const QueueFamilyIndices = struct {
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

const dummy_vert_glsl = @embedFile("shaders/triangle.vert");
const color_glsl = @embedFile("shaders/triangle.frag");
const render_glsl = @embedFile("shaders/mandelbrot.comp");
const patch_place_glsl = @embedFile("shaders/patch_place.comp");
const buffer_remap_glsl = @embedFile("shaders/buffer_remap.comp");

pub const log = std.log.scoped(.vulkan);
const Allocator = std.mem.Allocator;

const build_options = @import("build_options");
const vk = @import("vulkan");
const std = @import("std");
const common = @import("common_defs.zig");
const cleanup = @import("cleanup.zig");
const window = @import("window.zig");
const c = @import("c");
const gui = @import("gui.zig");
