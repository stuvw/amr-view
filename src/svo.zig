const std = @import("std");
const Io = std.Io;
const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

pub const OctreeBranch = extern struct {
    child_idx: u32,
    child_mask: u32,
};

pub const OctreeLeaf = extern struct {
    qty: f32,
    w: f32,
};

pub const OctreeNode = extern union {
    branch: OctreeBranch,
    leaf: OctreeLeaf,
    raw: u64,
};

pub const SVOFileMetadata = extern struct {
    version: [3]u8,
    pad: [5]u8,
    num_nodes: u64,
    num_branches: u64,
    num_leaves: u64,
    max_depth: u64,
    root_size: f32,
    root_pos: [3]f32,
};

pub const SVOBuffer = struct {
    size: usize,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    ptr: u64,

    pub fn create(self: *@This(), ctx: *const Context, size: usize) !void {
        self.size = size;
        std.log.debug("Creating octree chunk of size {d} bytes", .{size});
        self.buffer = try ctx.dev.createBuffer(&.{
            .size = size,
            .usage = .{
                .transfer_dst_bit = true,
                .storage_buffer_bit = true,
                .shader_device_address_bit = true,
            },
            .sharing_mode = .exclusive,
        }, null);
        const mem_reqs = ctx.dev.getBufferMemoryRequirements(self.buffer);
        self.memory = try ctx.allocate_bda(mem_reqs, .{ .device_local_bit = true });
        try ctx.dev.bindBufferMemory(self.buffer, self.memory, 0);
        self.ptr = ctx.dev.getBufferDeviceAddress(&.{ .buffer = self.buffer });
    }

    pub fn destroy(self: *@This(), ctx: *const Context) void {
        ctx.dev.freeMemory(self.memory, null);
        ctx.dev.destroyBuffer(self.buffer, null);
    }

    pub fn upload(self: *@This(), ctx: *const Context, cmdbuf: vk.CommandBuffer, reader: *std.Io.File.Reader, staging_buffer: vk.Buffer, staging_slice: []u8) !void {
        var num_bytes_left = self.size;
        var offset: usize = 0;

        const upload_fence = try ctx.dev.createFence(&.{}, null);
        defer ctx.dev.destroyFence(upload_fence, null);

        while (num_bytes_left > 0) {
            const num_bytes_to_copy = @min(staging_slice.len, num_bytes_left);

            try reader.interface.readSliceAll(staging_slice[0..num_bytes_to_copy]);

            std.log.debug("Copying {d} bytes. {d} bytes left to copy.", .{ num_bytes_to_copy, num_bytes_left });

            // NOTE: cmdbuf has the reset_command_buffer_bit set, no need to manually reset it here
            try ctx.dev.beginCommandBuffer(cmdbuf, &.{ .flags = .{ .one_time_submit_bit = true } });

            ctx.dev.cmdCopyBuffer(cmdbuf, staging_buffer, self.buffer, &[_]vk.BufferCopy{.{
                .src_offset = 0,
                .dst_offset = offset,
                .size = num_bytes_to_copy,
            }});

            const buffer_barrier = vk.BufferMemoryBarrier{
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = self.buffer,
                .offset = offset,
                .size = num_bytes_to_copy,
            };

            ctx.dev.cmdPipelineBarrier(
                cmdbuf,
                .{ .transfer_bit = true },
                .{ .compute_shader_bit = true },
                .{},
                &.{},
                &.{buffer_barrier},
                &.{},
            );

            try ctx.dev.endCommandBuffer(cmdbuf);

            try ctx.dev.resetFences(&[_]vk.Fence{upload_fence});
            try ctx.dev.queueSubmit(ctx.compute_queue.handle, &[_]vk.SubmitInfo{.{
                .command_buffer_count = 1,
                .p_command_buffers = &.{cmdbuf},
            }}, upload_fence);

            _ = try ctx.dev.waitForFences(&[_]vk.Fence{upload_fence}, .true, std.math.maxInt(u64));

            num_bytes_left -= num_bytes_to_copy;
            offset += num_bytes_to_copy;
        }

        _ = try ctx.dev.queueWaitIdle(ctx.compute_queue.handle);
    }
};

pub const SVOBuffers = struct {
    buffers: []SVOBuffer,

    pub fn create(
        self: *@This(),
        ctx: *const Context,
        allocator: std.mem.Allocator,
        num_nodes: usize,
        max_buf_size: usize,
    ) !void {
        const size = num_nodes * @sizeOf(OctreeNode);
        const num_full_buffers = size / max_buf_size;
        const last_buf_size = size % max_buf_size;

        var num_buffers = num_full_buffers;
        if (last_buf_size != 0) {
            num_buffers += 1;
        }

        std.log.debug("Attempting to read {d} bytes from file", .{size});
        std.log.debug("Created {d} octree chunks", .{num_buffers});

        self.buffers = try allocator.alloc(SVOBuffer, num_buffers);

        for (0..num_full_buffers) |i| {
            try self.buffers[i].create(ctx, max_buf_size);
        }

        if (last_buf_size != 0) {
            try self.buffers[num_buffers - 1].create(ctx, last_buf_size);
        }
    }

    pub fn destroy(self: *@This(), ctx: *const Context, allocator: std.mem.Allocator) void {
        for (self.buffers) |*buffer| {
            buffer.destroy(ctx);
        }
        allocator.free(self.buffers);
    }

    pub fn upload(self: *@This(), ctx: *const Context, cmdbuf: vk.CommandBuffer, io: std.Io, filename: []const u8, header_size: usize) !void {
        const cwd = Io.Dir.cwd();

        const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
        defer file.close(io);

        var reader = file.reader(io, &.{});

        try reader.interface.discardAll(header_size);

        const staging_buf_size = 128 * 1024 * 1024; // 128 MiB

        const staging_buffer = try ctx.dev.createBuffer(&.{
            .size = staging_buf_size,
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        defer ctx.dev.destroyBuffer(staging_buffer, null);

        const reqs = ctx.dev.getBufferMemoryRequirements(staging_buffer);
        const mem = try ctx.allocate(reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        defer ctx.dev.freeMemory(mem, null);
        try ctx.dev.bindBufferMemory(staging_buffer, mem, 0);

        const staging_ptr = try ctx.dev.mapMemory(mem, 0, staging_buf_size, .{});
        defer ctx.dev.unmapMemory(mem);
        const staging_slice = @as([*]u8, @ptrCast(staging_ptr))[0..staging_buf_size];

        for (self.buffers) |*buffer| {
            try buffer.upload(ctx, cmdbuf, &reader, staging_buffer, staging_slice);
        }
    }
};

pub fn getSVOMetadata(io: Io, filename: []const u8) !SVOFileMetadata {
    const cwd = Io.Dir.cwd();

    const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);

    var reader = file.reader(io, &.{});

    const magic = "AMR-VIEW";

    const header_size = magic.len + @sizeOf(SVOFileMetadata);

    var header_buffer: [header_size]u8 = undefined;

    const num_bytes_read = try reader.interface.readSliceShort(&header_buffer);

    if (num_bytes_read != header_size) {
        return error.InvalidFormat;
    }

    if (!std.mem.eql(u8, magic, header_buffer[0..magic.len])) {
        return error.InvalidFormat;
    }

    return std.mem.bytesToValue(SVOFileMetadata, header_buffer[magic.len..]);
}
