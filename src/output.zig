const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

pub const OutputImage = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    image_mem: vk.DeviceMemory,

    pub fn create(
        self: *@This(),
        ctx: *const Context,
        width: usize,
        height: usize,
    ) !void {
        self.image = try ctx.dev.createImage(&.{
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = vk.Extent3D{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .storage_bit = true, .transfer_src_bit = true },
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
};

pub const OutputBuffer = struct {
    size: usize,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    ptr: ?*anyopaque,

    pub fn create(self: *@This(), ctx: *const Context, width: usize, height: usize) !void {
        self.size = width * height * 4; // RGBA -> 4B/p

        self.buffer = try ctx.dev.createBuffer(&.{
            .size = self.size,
            .usage = .{ .transfer_dst_bit = true },
            .sharing_mode = .exclusive,
        }, null);

        const reqs = ctx.dev.getBufferMemoryRequirements(self.buffer);
        self.memory = try ctx.allocate(reqs, .{ .host_visible_bit = true });

        try ctx.dev.bindBufferMemory(self.buffer, self.memory, 0);
        self.ptr = try ctx.dev.mapMemory(self.memory, 0, self.size, .{});
    }

    pub fn destroy(self: *@This(), ctx: *const Context) void {
        ctx.dev.unmapMemory(self.memory);
        ctx.dev.freeMemory(self.memory, null);
        ctx.dev.destroyBuffer(self.buffer, null);
    }
};
