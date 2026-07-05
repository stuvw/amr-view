const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

pub fn createCommandPool(ctx: *const Context) !vk.CommandPool {
    return try ctx.dev.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = ctx.compute_queue.family,
    }, null);
}

pub fn destroyCommandPool(ctx: *const Context, command_pool: vk.CommandPool) void {
    ctx.dev.destroyCommandPool(command_pool, null);
}

pub fn createCommandBuffer(ctx: *const Context, command_pool: vk.CommandPool) !vk.CommandBuffer {
    var command_buffer: vk.CommandBuffer = undefined;
    try ctx.dev.allocateCommandBuffers(&.{
        .command_buffer_count = 1,
        .command_pool = command_pool,
        .level = .primary,
    }, @ptrCast(&command_buffer));
    return command_buffer;
}
