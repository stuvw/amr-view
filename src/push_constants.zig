const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

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
