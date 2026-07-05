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

    pub fn create(self: *@This(), ctx: *const Context, num_nodes: usize) !void {
        self.size = num_nodes * @sizeOf(OctreeNode);
        self.buffer = try ctx.dev.createBuffer(&.{
            .size = self.size,
            .usage = .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        const mem_reqs = ctx.dev.getBufferMemoryRequirements(self.buffer);
        self.memory = try ctx.allocate(mem_reqs, .{ .device_local_bit = true });
        try ctx.dev.bindBufferMemory(self.buffer, self.memory, 0);
    }

    pub fn destroy(self: *@This(), ctx: *const Context) void {
        ctx.dev.freeMemory(self.memory, null);
        ctx.dev.destroyBuffer(self.buffer, null);
    }

    pub fn upload(self: *@This(), ctx: *const Context, cmdbuf: vk.CommandBuffer, io: Io, filename: []const u8) !void {
        try ctx.dev.beginCommandBuffer(cmdbuf, &.{ .flags = .{ .one_time_submit_bit = true } });

        const staging_buffer = try ctx.dev.createBuffer(&.{
            .size = self.size,
            .usage = .{ .transfer_src_bit = true },
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

        try loadSVOFile(io, filename, self.size, staging_slice);

        ctx.dev.cmdCopyBuffer(cmdbuf, staging_buffer, self.buffer, &[_]vk.BufferCopy{.{
            .src_offset = 0,
            .dst_offset = 0,
            .size = self.size,
        }});

        const buffer_barrier = vk.BufferMemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = self.buffer,
            .offset = 0,
            .size = self.size,
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

fn loadSVOFile(io: Io, filename: []const u8, size: usize, buf: [*]u8) !void {
    const cwd = Io.Dir.cwd();

    const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);

    var reader = file.reader(io, &.{});

    const header_size = 8 + @sizeOf(SVOFileMetadata);

    try reader.interface.discardAll(header_size);

    try reader.interface.readSliceAll(buf[0..size]);
}
