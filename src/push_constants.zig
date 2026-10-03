const vk = @import("vulkan");
const Context = @import("context.zig").Context;
const Math = @import("./math.zig");

pub const PushConstant = extern struct {
    camera_pos: [3]f32,
    pad_1: u8 = undefined,
    camera_dir: [3]f32,
    pad_2: u8 = undefined,
    camera_right: [3]f32,
    pad_3: u8 = undefined,
    camera_up: [3]f32,
    pad_4: u8 = undefined,
    root_pos: [4]f32, // xyz + size
    under_color: [4]f32,
    over_color: [4]f32,
    bad_color: [4]f32,
    chunk_shift: u64,
    camera_fov: f32,
    min_val: f32,
    max_val: f32,
};

pub fn updateConstants(
    push_constant: *PushConstant,
    ctx: *const Context,
    cmdbuf: vk.CommandBuffer,
    pipeline_layout: vk.PipelineLayout,
    cam_pos: [3]f32,
    cam_dir: [3]f32,
    cam_up: [3]f32,
) void {
    push_constant.camera_pos = cam_pos;
    push_constant.camera_dir = cam_dir;
    push_constant.camera_up = cam_up;
    push_constant.camera_right = Math.cross(cam_dir, cam_up);

    ctx.dev.cmdPushConstants(
        cmdbuf,
        pipeline_layout,
        .{ .compute_bit = true },
        0,
        @sizeOf(PushConstant),
        @ptrCast(push_constant),
    );
}
