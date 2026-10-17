const std = @import("std");
const vk = @import("vulkan");
const Context = @import("./context.zig").Context;
const ComputePipeline = @import("./pipeline.zig").ComputePipeline;
const PushConstants = @import("./push_constants.zig");

pub const Frame = struct {
    size: usize,
    width: usize,
    height: usize,

    image: vk.Image,
    img_mem: vk.DeviceMemory,
    img_view_y: vk.ImageView,
    img_view_u: vk.ImageView,
    img_view_v: vk.ImageView,

    buffer: vk.Buffer,
    buf_mem: vk.DeviceMemory,
    ptr: ?*anyopaque,

    cmdbuf: vk.CommandBuffer,
    desc_set: vk.DescriptorSet,
    fence: vk.Fence,

    pub fn create(
        self: *@This(),
        ctx: *const Context,
        width: usize,
        height: usize,
        pipeline: ComputePipeline,
        cmap_sampler: vk.Sampler,
        cmap_image: vk.ImageView,
        chunk_ptrs: vk.Buffer,
    ) !void {
        self.width = width;
        self.height = height;
        self.size = self.width * self.height + self.width * self.height / 2; // yuv420p -> 1.5Bpp

        try self.createImage(ctx);
        try self.createImageViews(ctx);
        try self.createBuffer(ctx);

        self.desc_set = try pipeline.createDescriptorSet(
            ctx,
            self.img_view_y,
            self.img_view_u,
            self.img_view_v,
            cmap_sampler,
            cmap_image,
            chunk_ptrs,
        );
        self.fence = try ctx.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        self.cmdbuf = try pipeline.createCommandBuffer(ctx);
    }

    pub fn destroy(self: *const @This(), ctx: *const Context) void {
        ctx.dev.destroyFence(self.fence, null);

        self.destroyBuffer(ctx);
        self.destroyImageViews(ctx);
        self.destroyImage(ctx);
    }

    fn createImage(self: *@This(), ctx: *const Context) !void {
        self.image = try ctx.dev.createImage(&.{
            .image_type = .@"2d",
            .format = .g8_b8_r8_3plane_420_unorm,
            .extent = .{ .width = @intCast(self.width), .height = @intCast(self.height), .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .storage_bit = true, .transfer_src_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
            .flags = .{ .mutable_format_bit = true, .extended_usage_bit = true },
        }, null);

        self.img_mem = try ctx.allocate(
            ctx.dev.getImageMemoryRequirements(self.image),
            .{
                .device_local_bit = true,
            },
        );

        try ctx.dev.bindImageMemory(self.image, self.img_mem, 0);
    }

    fn destroyImage(self: *const @This(), ctx: *const Context) void {
        ctx.dev.freeMemory(self.img_mem, null);
        ctx.dev.destroyImage(self.image, null);
    }

    fn createImageViews(self: *@This(), ctx: *const Context) !void {
        self.img_view_y = try ctx.dev.createImageView(&.{
            .image = self.image,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{
                    .plane_0_bit = true,
                },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        self.img_view_u = try ctx.dev.createImageView(&.{
            .image = self.image,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{
                    .plane_1_bit = true,
                },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        self.img_view_v = try ctx.dev.createImageView(&.{
            .image = self.image,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{
                    .plane_2_bit = true,
                },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    }

    fn destroyImageViews(self: *const @This(), ctx: *const Context) void {
        ctx.dev.destroyImageView(self.img_view_y, null);
        ctx.dev.destroyImageView(self.img_view_u, null);
        ctx.dev.destroyImageView(self.img_view_v, null);
    }

    fn createBuffer(self: *@This(), ctx: *const Context) !void {
        self.buffer = try ctx.dev.createBuffer(&.{
            .size = self.size,
            .sharing_mode = .exclusive,
            .usage = .{
                .transfer_dst_bit = true,
            },
        }, null);

        self.buf_mem = try ctx.allocate(
            ctx.dev.getBufferMemoryRequirements(self.buffer),
            .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            },
        );

        try ctx.dev.bindBufferMemory(self.buffer, self.buf_mem, 0);
        self.ptr = try ctx.dev.mapMemory(self.buf_mem, 0, self.size, .{});
    }

    fn destroyBuffer(self: *const @This(), ctx: *const Context) void {
        ctx.dev.unmapMemory(self.buf_mem);
        ctx.dev.freeMemory(self.buf_mem, null);
        ctx.dev.destroyBuffer(self.buffer, null);
    }

    pub fn render(self: *const @This(), ctx: *const Context, pipeline: ComputePipeline, pc: *PushConstants.PushConstant, cam_point: [9]f32) !void {
        try ctx.dev.resetFences(&[_]vk.Fence{self.fence});

        try ctx.dev.beginCommandBuffer(self.cmdbuf, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        PushConstants.updateConstants(pc, ctx, self.cmdbuf, pipeline.pipeline_layout, cam_point);

        self.prepareForRender(ctx, pipeline.pipeline, pipeline.pipeline_layout);
        self.dispatchRender(ctx);
        self.prepareForDownload(ctx);
        self.download(ctx);
        self.prepareForRead(ctx);

        try ctx.dev.endCommandBuffer(self.cmdbuf);

        try ctx.dev.queueSubmit(ctx.compute_queue.handle, &[_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = &.{self.cmdbuf},
        }}, self.fence);
    }

    fn prepareForRender(self: *const @This(), ctx: *const Context, pipeline: vk.Pipeline, pipeline_layout: vk.PipelineLayout) void {
        const barrier_to_compute = vk.ImageMemoryBarrier{
            .image = self.image,
            .old_layout = .undefined,
            .new_layout = .general,
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_write_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        ctx.dev.cmdPipelineBarrier(
            self.cmdbuf,
            .{ .top_of_pipe_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            &.{},
            &.{},
            &.{barrier_to_compute},
        );

        ctx.dev.cmdBindPipeline(
            self.cmdbuf,
            .compute,
            pipeline,
        );

        ctx.dev.cmdBindDescriptorSets(
            self.cmdbuf,
            .compute,
            pipeline_layout,
            0,
            &.{self.desc_set},
            &.{},
        );
    }

    fn dispatchRender(self: *const @This(), ctx: *const Context) void {
        const group_x: u32 = @intCast((self.width + 7) / 8);
        const group_y: u32 = @intCast((self.height + 7) / 8);
        ctx.dev.cmdDispatch(self.cmdbuf, group_x, group_y, 1);
    }

    fn prepareForDownload(self: *const @This(), ctx: *const Context) void {
        const barrier_to_transfer = vk.ImageMemoryBarrier{
            .image = self.image,
            .old_layout = .general,
            .new_layout = .transfer_src_optimal,
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        ctx.dev.cmdPipelineBarrier(
            self.cmdbuf,
            .{ .compute_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            &.{},
            &.{},
            &.{barrier_to_transfer},
        );
    }

    fn download(self: *const @This(), ctx: *const Context) void {
        const copy_regions = [3]vk.BufferImageCopy{
            .{
                .image_extent = .{ .width = @intCast(self.width), .height = @intCast(self.height), .depth = 1 },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .plane_0_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            },
            .{
                .image_extent = .{ .width = @intCast(self.width / 2), .height = @intCast(self.height / 2), .depth = 1 },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .buffer_offset = self.width * self.height,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .plane_1_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            },
            .{
                .image_extent = .{ .width = @intCast(self.width / 2), .height = @intCast(self.height / 2), .depth = 1 },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .buffer_offset = self.width * self.height + (self.width / 2) * (self.height / 2),
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .plane_2_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            },
        };

        ctx.dev.cmdCopyImageToBuffer(
            self.cmdbuf,
            self.image,
            .transfer_src_optimal,
            self.buffer,
            &copy_regions,
        );
    }

    fn prepareForRead(self: *const @This(), ctx: *const Context) void {
        const barrier_to_host = vk.BufferMemoryBarrier{
            .size = vk.WHOLE_SIZE,
            .offset = 0,
            .buffer = self.buffer,
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .host_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        };

        ctx.dev.cmdPipelineBarrier(
            self.cmdbuf,
            .{ .transfer_bit = true },
            .{ .host_bit = true },
            .{},
            &.{},
            &.{barrier_to_host},
            &.{},
        );
    }

    pub fn getSlice(self: *const @This()) []const u8 {
        return @as([*]const u8, @ptrCast(self.ptr))[0..self.size];
    }
};
