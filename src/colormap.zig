const std = @import("std");
const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

pub const ColormapImage = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    image_mem: vk.DeviceMemory,

    size: usize,

    pub fn create(
        self: *@This(),
        ctx: *const Context,
        size: usize,
    ) !void {
        self.size = size * 4; // RGBA -> 4B/p

        self.image = try ctx.dev.createImage(&.{
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = vk.Extent3D{ .width = @intCast(size), .height = 1, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);

        const mem_reqs = ctx.dev.getImageMemoryRequirements(self.image);
        self.image_mem = try ctx.allocate(mem_reqs, .{ .device_local_bit = true });
        try ctx.dev.bindImageMemory(self.image, self.image_mem, 0);

        self.image_view = try ctx.dev.createImageView(&.{
            .image = self.image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    }

    pub fn destroy(self: *@This(), ctx: *const Context) void {
        ctx.dev.destroyImageView(self.image_view, null);
        ctx.dev.freeMemory(self.image_mem, null);
        ctx.dev.destroyImage(self.image, null);
    }

    pub fn upload(self: *@This(), ctx: *const Context, cmdbuf: vk.CommandBuffer, io: std.Io, filename: []const u8) !void {
        try ctx.dev.beginCommandBuffer(cmdbuf, &.{ .flags = .{ .one_time_submit_bit = true } });

        const staging_buffer = try ctx.dev.createBuffer(&.{
            .size = self.size,
            .usage = .{
                .transfer_src_bit = true,
            },
            .sharing_mode = .exclusive,
        }, null);
        defer ctx.dev.destroyBuffer(staging_buffer, null);

        const reqs = ctx.dev.getBufferMemoryRequirements(staging_buffer);
        const mem = try ctx.allocate(reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        defer ctx.dev.freeMemory(mem, null);
        try ctx.dev.bindBufferMemory(staging_buffer, mem, 0);

        const staging_ptr = try ctx.dev.mapMemory(mem, 0, self.size, .{});
        defer ctx.dev.unmapMemory(mem);
        const staging_slice = @as([*]u8, @ptrCast(staging_ptr));

        try loadColormapFile(io, filename, self.size, staging_slice);

        const barrier_to_transfer = vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        ctx.dev.cmdPipelineBarrier(
            cmdbuf,
            .{ .top_of_pipe_bit = true },
            .{ .transfer_bit = true },
            .{},
            &.{},
            &.{},
            &.{barrier_to_transfer},
        );

        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = vk.Extent3D{ .width = @intCast(self.size / 4), .height = 1, .depth = 1 },
        };
        ctx.dev.cmdCopyBufferToImage(
            cmdbuf,
            staging_buffer,
            self.image,
            .transfer_dst_optimal,
            &.{region},
        );

        const barrier = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        ctx.dev.cmdPipelineBarrier(
            cmdbuf,
            .{ .transfer_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            &.{},
            &.{},
            &.{barrier},
        );

        try ctx.dev.endCommandBuffer(cmdbuf);

        const upload_fence = try ctx.dev.createFence(&.{}, null);
        defer ctx.dev.destroyFence(upload_fence, null);

        try ctx.dev.queueSubmit(ctx.compute_queue.handle, &[_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = &.{cmdbuf},
        }}, upload_fence);

        _ = try ctx.dev.waitForFences(&[_]vk.Fence{upload_fence}, .true, std.math.maxInt(u64));
        _ = try ctx.dev.queueWaitIdle(ctx.compute_queue.handle);
    }
};

fn loadColormapFile(io: std.Io, filename: []const u8, size: usize, buffer: [*]u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);

    var reader = file.reader(io, &.{});

    try reader.interface.readSliceAll(buffer[0..size]);
}
