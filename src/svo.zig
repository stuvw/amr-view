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

pub const SVO = struct {
    size: usize,
    buffer: vk.Buffer,
    memory: []vk.DeviceMemory,
    ptr: u64,

    pub fn create(self: *@This(), ctx: *const Context, allocator: std.mem.Allocator, size: usize) !void {
        self.size = size * @sizeOf(OctreeNode);

        self.buffer = try ctx.dev.createBuffer(&.{
            .size = self.size,
            .sharing_mode = .exclusive,
            .usage = .{
                .shader_device_address_bit = true,
                .storage_buffer_bit = true,
                .transfer_dst_bit = true, // Might be unnecessary, tbd
            },
            .flags = .{ .sparse_binding_bit = true },
        }, null);

        const reqs = ctx.dev.getBufferMemoryRequirements(self.buffer);

        // Round down to nearest alignment
        const max_alloc_size_aligned = (ctx.max_alloc_size / reqs.alignment) * reqs.alignment;

        // Number of full size buffers
        const num_full = self.size / max_alloc_size_aligned;

        // Round up remaining size to alignment
        const remaining = (((self.size % max_alloc_size_aligned) + reqs.alignment - 1) / reqs.alignment) * reqs.alignment;

        var num_allocs = num_full;
        if (remaining != 0) {
            num_allocs += 1;
        }

        self.memory = try allocator.alloc(vk.DeviceMemory, num_allocs);

        for (0..num_full) |i| {
            self.memory[i] = try ctx.allocate_bda_size(max_alloc_size_aligned, reqs, .{ .device_local_bit = true });
        }

        if (remaining != 0) {
            self.memory[num_allocs - 1] = try ctx.allocate_bda_size(remaining, reqs, .{ .device_local_bit = true });
        }

        const fence = try ctx.dev.createFence(&.{}, null);
        defer ctx.dev.destroyFence(fence, null);

        const mem_binds = try allocator.alloc(vk.SparseMemoryBind, num_allocs);
        defer allocator.free(mem_binds);

        for (0..num_full) |i| {
            mem_binds[i] = .{
                .memory_offset = 0,
                .resource_offset = i * max_alloc_size_aligned,
                .memory = self.memory[i],
                .size = max_alloc_size_aligned,
            };
        }

        if (remaining != 0) {
            mem_binds[num_allocs - 1] = .{
                .memory_offset = 0,
                .resource_offset = num_full * max_alloc_size_aligned,
                .memory = self.memory[num_allocs - 1],
                .size = remaining,
            };
        }

        try ctx.dev.queueBindSparse(ctx.compute_queue.handle, &[_]vk.BindSparseInfo{
            .{
                .buffer_bind_count = 1,
                .p_buffer_binds = &[_]vk.SparseBufferMemoryBindInfo{
                    .{
                        .buffer = self.buffer,
                        .bind_count = @intCast(num_allocs),
                        .p_binds = @ptrCast(mem_binds.ptr),
                    },
                },
            },
        }, fence);
        _ = try ctx.dev.waitForFences(&[_]vk.Fence{fence}, .true, std.math.maxInt(u64));
        _ = try ctx.dev.queueWaitIdle(ctx.compute_queue.handle);

        self.ptr = ctx.dev.getBufferDeviceAddress(&.{ .buffer = self.buffer });
    }

    pub fn upload(self: @This(), ctx: *const Context, cmdbuf: vk.CommandBuffer, io: Io, filename: []const u8, header_size: usize) !void {
        const cwd = Io.Dir.cwd();

        const file = try cwd.openFile(io, filename, .{ .mode = .read_only });
        defer file.close(io);

        var reader = file.reader(io, &.{});

        try reader.interface.discardAll(header_size);

        const staging_buf_size = 128 * 1024 * 1024; // 128 MiB

        const staging_buffer = try ctx.dev.createBuffer(&.{
            .size = staging_buf_size,
            .sharing_mode = .exclusive,
            .usage = .{
                .transfer_src_bit = true,
            },
        }, null);
        defer ctx.dev.destroyBuffer(staging_buffer, null);

        const staging_mem = try ctx.allocate(
            ctx.dev.getBufferMemoryRequirements(staging_buffer),
            .{
                .host_coherent_bit = true,
                .host_visible_bit = true,
            },
        );
        defer ctx.dev.freeMemory(staging_mem, null);

        try ctx.dev.bindBufferMemory(staging_buffer, staging_mem, 0);

        const staging_slice = @as([*]u8, @ptrCast(try ctx.dev.mapMemory(staging_mem, 0, staging_buf_size, .{})))[0..staging_buf_size];
        defer ctx.dev.unmapMemory(staging_mem);

        var num_bytes_left = self.size;
        var offset: usize = 0;

        const fence = try ctx.dev.createFence(&.{}, null);
        defer ctx.dev.destroyFence(fence, null);

        while (num_bytes_left > 0) {
            const num_bytes_to_copy = @min(staging_buf_size, num_bytes_left);

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

            try ctx.dev.resetFences(&[_]vk.Fence{fence});
            try ctx.dev.queueSubmit(ctx.compute_queue.handle, &[_]vk.SubmitInfo{.{
                .command_buffer_count = 1,
                .p_command_buffers = &.{cmdbuf},
            }}, fence);

            _ = try ctx.dev.waitForFences(&[_]vk.Fence{fence}, .true, std.math.maxInt(u64));

            num_bytes_left -= num_bytes_to_copy;
            offset += num_bytes_to_copy;
        }
    }

    pub fn destroy(self: @This(), ctx: *const Context, allocator: std.mem.Allocator) void {
        for (self.memory) |mem| {
            ctx.dev.freeMemory(mem, null);
        }
        allocator.free(self.memory);
        ctx.dev.destroyBuffer(self.buffer, null);
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
