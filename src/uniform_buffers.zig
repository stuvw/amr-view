const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

// std140 aligned uniform block for colormap configuration
pub const ColormapInfo = extern struct {
    under_color: [4]f32,
    over_color: [4]f32,
    bad_color: [4]f32,
    min_val: f32,
    max_val: f32,
    pad: u64 = undefined,
};

// std140 aligned uniform block for octree information
pub const OctreeInfo = extern struct {
    root_pos: [3]f32,
    root_size: f32,
    ptr: u64,
};

// std140 aligned uniform block for camera uniform binding
pub const CameraInfo = extern struct {
    camera_pos: [4]f32,
    camera_dir: [4]f32,
    camera_right: [4]f32,
    camera_up: [4]f32,
    camera_fov: f32,
    pad: [3]u32 = .{ undefined, undefined, undefined },
};

pub const UniformBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    ptr: ?*anyopaque,

    pub fn create(self: *@This(), ctx: *const Context, T: type) !void {
        const size = @sizeOf(T);

        self.buffer = try ctx.dev.createBuffer(&.{
            .size = size,
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);

        const reqs = ctx.dev.getBufferMemoryRequirements(self.buffer);
        self.memory = try ctx.allocate(reqs, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        });

        try ctx.dev.bindBufferMemory(self.buffer, self.memory, 0);
        self.ptr = try ctx.dev.mapMemory(self.memory, 0, size, .{});
    }

    pub fn destroy(self: *@This(), ctx: *const Context) void {
        ctx.dev.unmapMemory(self.memory);
        ctx.dev.freeMemory(self.memory, null);
        ctx.dev.destroyBuffer(self.buffer, null);
    }

    pub fn upload(self: *@This(), data: []const u8) void {
        @memcpy(@as([*]u8, @ptrCast(self.ptr)), data);
    }
};
