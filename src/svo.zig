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

pub const SVOBuffer = struct {
    size: usize,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    ptr: u64,

    pub fn create(self: *@This(), ctx: *const Context, size: usize) !void {
        self.size = size;
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

pub const SVOFileMetadata = struct {
    version: extern struct { major: u8, minor: u8, patch: u8 },
    num_nodes: u64,
    num_branches: u64,
    num_leaves: u64,
    max_depth: u64,
    root_size: f32,
    root_pos: [3]f32,
    simulation_name: ?[]u8,
    field: ?[]u8,
    weight: ?[]u8,
    header_size: u64,

    pub fn get(self: *@This(), allocator: std.mem.Allocator, io: Io, filename: []const u8) !void {
        if (!std.mem.endsWith(u8, filename, ".amrv")) {
            return error.InvalidFormat;
        }

        self.simulation_name = null;
        self.field = null;
        self.weight = null;

        const cwd = Io.Dir.cwd();

        const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
        defer file.close(io);

        var reader = file.reader(io, &.{});
        var interface = &reader.interface;

        const magic = "AMR-VIEW";
        var magic_buf: [magic.len]u8 = undefined;

        try interface.readSliceAll(&magic_buf);

        if (!std.mem.eql(u8, magic, &magic_buf)) {
            return error.InvalidFormat;
        }

        try interface.readSliceAll(std.mem.asBytes(&self.version));

        switch (self.version.major) {
            0 => {
                try switch (self.version.minor) {
                    1 => {
                        try interface.discardAll(5);
                        try interface.readSliceAll(std.mem.asBytes(&self.num_nodes));
                        try interface.readSliceAll(std.mem.asBytes(&self.num_branches));
                        try interface.readSliceAll(std.mem.asBytes(&self.num_leaves));
                        try interface.readSliceAll(std.mem.asBytes(&self.max_depth));
                        try interface.readSliceAll(std.mem.asBytes(&self.root_size));
                        try interface.readSliceAll(std.mem.asBytes(&self.root_pos));
                        self.header_size = reader.pos;
                    },
                    2 => {
                        try interface.readSliceAll(std.mem.asBytes(&self.num_nodes));
                        try interface.readSliceAll(std.mem.asBytes(&self.num_branches));
                        try interface.readSliceAll(std.mem.asBytes(&self.num_leaves));
                        try interface.readSliceAll(std.mem.asBytes(&self.max_depth));
                        try interface.readSliceAll(std.mem.asBytes(&self.root_size));
                        try interface.readSliceAll(std.mem.asBytes(&self.root_pos));

                        var sim_name_size: u64 = undefined;
                        try interface.readSliceAll(std.mem.asBytes(&sim_name_size));
                        self.simulation_name = try allocator.alloc(u8, sim_name_size);
                        try interface.readSliceAll(self.simulation_name.?);

                        var field_size: u64 = undefined;
                        try interface.readSliceAll(std.mem.asBytes(&field_size));
                        self.field = try allocator.alloc(u8, field_size);
                        try interface.readSliceAll(self.field.?);

                        var weight_size: u64 = undefined;
                        try interface.readSliceAll(std.mem.asBytes(&weight_size));
                        self.weight = try allocator.alloc(u8, weight_size);
                        try interface.readSliceAll(self.weight.?);

                        self.header_size = reader.pos;
                    },
                    else => error.UnsupportedFile,
                };
            },
            else => return error.UnsupportedFile,
        }

        const stat = try file.stat(io);

        if (stat.size != self.header_size + self.num_nodes * @sizeOf(OctreeNode)) {
            return error.CorruptedFile;
        }
    }

    pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.simulation_name) |n| {
            allocator.free(n);
        }
        if (self.field) |f| {
            allocator.free(f);
        }
        if (self.weight) |w| {
            allocator.free(w);
        }
    }

    pub fn print(self: *@This()) void {
        std.log.info("File version: {d}.{d}.{d}", .{
            self.version.major,
            self.version.minor,
            self.version.patch,
        });
        std.log.info("{d} nodes ({d} branches + {d} leaves)", .{
            self.num_nodes,
            self.num_branches,
            self.num_leaves,
        });
        std.log.info("Cutout center: ({d},{d},{d})", .{
            self.root_pos[0],
            self.root_pos[1],
            self.root_pos[2],
        });
        std.log.info(
            "Cutout edge width: {d}",
            .{self.root_size},
        );
        std.log.info(
            "Max node depth: {d}",
            .{self.max_depth},
        );
        if (self.simulation_name) |name| {
            std.log.info("Simulation: {s}", .{name});
        }
        if (self.field) |field| {
            std.log.info("Field: {s}", .{field});
        }
        if (self.weight) |weight| {
            std.log.info("Weight: {s}", .{weight});
        }
        std.log.info("Header size: {Bi}", .{self.header_size});
    }
};
