const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

// Ensure compiled SPIR-V bytecode is correctly aligned for Vulkan's ingestion
const normal_shader_src align(@alignOf(u32)) = @embedFile("./shaders/spirv/octree_traversal_normal.spv").*;
const vr180_shader_src align(@alignOf(u32)) = @embedFile("./shaders/spirv/octree_traversal_vr180.spv").*;
const vr360_shader_src align(@alignOf(u32)) = @embedFile("./shaders/spirv/octree_traversal_vr360.spv").*;

pub const Mode = enum {
    normal,
    vr180,
    vr360,
};

pub const ComputePipeline = struct {
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    desc_pool: vk.DescriptorPool,
    desc_set_layout: vk.DescriptorSetLayout,
    command_pool: vk.CommandPool,

    pub fn create(self: *@This(), ctx: *const Context, mode: Mode, frames_in_flight: u32) !void {
        try self.createDescriptorPool(ctx, frames_in_flight);
        try self.createDescriptorSetLayout(ctx);
        try self.createPipelineLayout(ctx);
        try self.createPipeline(ctx, mode);
        try self.createCommandPool(ctx);
    }

    pub fn destroy(self: *const @This(), ctx: *const Context) void {
        self.destroyCommandPool(ctx);
        self.destroyPipeline(ctx);
        self.destroyPipelineLayout(ctx);
        self.destroyDescriptorSetLayout(ctx);
        self.destroyDescriptorPool(ctx);
    }

    fn createDescriptorPool(self: *@This(), ctx: *const Context, max_sets: u32) !void {
        self.desc_pool = try ctx.dev.createDescriptorPool(&.{
            .max_sets = max_sets,
            .pool_size_count = 3,
            .p_pool_sizes = &[_]vk.DescriptorPoolSize{
                .{ .type = .combined_image_sampler, .descriptor_count = max_sets },
                .{ .type = .storage_image, .descriptor_count = 3 * max_sets },
                .{ .type = .storage_buffer, .descriptor_count = max_sets },
            },
        }, null);
    }

    fn destroyDescriptorPool(self: *const @This(), ctx: *const Context) void {
        ctx.dev.destroyDescriptorPool(self.desc_pool, null);
    }

    fn createDescriptorSetLayout(self: *@This(), ctx: *const Context) !void {
        self.desc_set_layout = try ctx.dev.createDescriptorSetLayout(&.{
            .binding_count = 5,
            .p_bindings = &[_]vk.DescriptorSetLayoutBinding{
                .{
                    .binding = 0, // Y plane
                    .descriptor_type = .storage_image,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
                .{
                    .binding = 1, // U plane
                    .descriptor_type = .storage_image,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
                .{
                    .binding = 2, // V plane
                    .descriptor_type = .storage_image,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
                .{
                    .binding = 3, // colormap
                    .descriptor_type = .combined_image_sampler,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
                .{
                    .binding = 4, // chunk pointers
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
            },
        }, null);
    }

    fn destroyDescriptorSetLayout(self: *const @This(), ctx: *const Context) void {
        ctx.dev.destroyDescriptorSetLayout(self.desc_set_layout, null);
    }

    fn createPipelineLayout(self: *@This(), ctx: *const Context) !void {
        self.pipeline_layout = try ctx.dev.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = &.{self.desc_set_layout},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{
                vk.PushConstantRange{
                    .stage_flags = .{ .compute_bit = true },
                    .offset = 0,
                    .size = @sizeOf(@import("./push_constants.zig").PushConstant),
                },
            },
        }, null);
    }

    fn destroyPipelineLayout(self: *const @This(), ctx: *const Context) void {
        ctx.dev.destroyPipelineLayout(self.pipeline_layout, null);
    }

    fn createPipeline(self: *@This(), ctx: *const Context, mode: Mode) !void {
        const shader_module = try ctx.dev.createShaderModule(&.{
            .code_size = switch (mode) {
                .normal => normal_shader_src.len,
                .vr180 => vr180_shader_src.len,
                .vr360 => vr360_shader_src.len,
            },
            .p_code = switch (mode) {
                .normal => @ptrCast(&normal_shader_src),
                .vr180 => @ptrCast(&vr180_shader_src),
                .vr360 => @ptrCast(&vr360_shader_src),
            },
        }, null);
        defer ctx.dev.destroyShaderModule(shader_module, null);

        _ = try ctx.dev.createComputePipelines(
            .null_handle,
            &[_]vk.ComputePipelineCreateInfo{
                .{
                    .flags = .{},
                    .layout = self.pipeline_layout,
                    .base_pipeline_index = -1,
                    .base_pipeline_handle = .null_handle,
                    .stage = .{
                        .flags = .{},
                        .stage = .{ .compute_bit = true },
                        .module = shader_module,
                        .p_name = "main",
                        .p_specialization_info = null,
                    },
                },
            },
            null,
            (&self.pipeline)[0..1],
        );
    }

    fn destroyPipeline(self: *const @This(), ctx: *const Context) void {
        ctx.dev.destroyPipeline(self.pipeline, null);
    }

    fn createCommandPool(self: *@This(), ctx: *const Context) !void {
        self.command_pool = try ctx.dev.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = ctx.compute_queue.family,
        }, null);
    }

    fn destroyCommandPool(self: *const @This(), ctx: *const Context) void {
        ctx.dev.destroyCommandPool(self.command_pool, null);
    }

    pub fn createDescriptorSet(
        self: *const @This(),
        ctx: *const Context,
        y_img: vk.ImageView,
        u_img: vk.ImageView,
        v_img: vk.ImageView,
        cmap_sampler: vk.Sampler,
        cmap_image: vk.ImageView,
        chunk_ptrs: vk.Buffer,
    ) !vk.DescriptorSet {
        var set: vk.DescriptorSet = undefined;
        try ctx.dev.allocateDescriptorSets(&.{
            .descriptor_pool = self.desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self.desc_set_layout},
        }, @ptrCast(&set));

        const y_plane_img_info = vk.DescriptorImageInfo{ .image_view = y_img, .image_layout = .general, .sampler = .null_handle };
        const u_plane_img_info = vk.DescriptorImageInfo{ .image_view = u_img, .image_layout = .general, .sampler = .null_handle };
        const v_plane_img_info = vk.DescriptorImageInfo{ .image_view = v_img, .image_layout = .general, .sampler = .null_handle };
        const cmap_img_info = vk.DescriptorImageInfo{ .sampler = cmap_sampler, .image_view = cmap_image, .image_layout = .shader_read_only_optimal };
        const chunk_ptrs_buf_info = vk.DescriptorBufferInfo{ .buffer = chunk_ptrs, .offset = 0, .range = vk.WHOLE_SIZE };

        ctx.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{
            .{ // Binding 0: Output Y plane Image (writeonly image2D)
                .dst_set = set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_image,
                .p_image_info = &.{y_plane_img_info},
                .p_buffer_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{ // Binding 1: Output U plane Image (writeonly image2D)
                .dst_set = set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_image,
                .p_image_info = &.{u_plane_img_info},
                .p_buffer_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{ // Binding 2: Output V plane Image (writeonly image2D)
                .dst_set = set,
                .dst_binding = 2,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_image,
                .p_image_info = &.{v_plane_img_info},
                .p_buffer_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{ // Binding 3: Colormap Texture (sampler2D)
                .dst_set = set,
                .dst_binding = 3,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = &.{cmap_img_info},
                .p_buffer_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{ // Binding 4: Octree Chunk Pointers
                .dst_set = set,
                .dst_binding = 4,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &.{chunk_ptrs_buf_info},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
        }, &.{});

        return set;
    }

    pub fn createCommandBuffer(self: *const @This(), ctx: *const Context) !vk.CommandBuffer {
        var command_buffer: vk.CommandBuffer = undefined;
        try ctx.dev.allocateCommandBuffers(&.{
            .command_buffer_count = 1,
            .command_pool = self.command_pool,
            .level = .primary,
        }, @ptrCast(&command_buffer));
        return command_buffer;
    }
};
