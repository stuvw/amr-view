const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

pub const PushConstant = extern struct {
    camera_pos: [4]f32,
    camera_dir: [4]f32,
    camera_right: [4]f32,
    camera_up: [4]f32,
    root_pos: [4]f32, // xyz + size
    under_color: [4]f32,
    over_color: [4]f32,
    bad_color: [4]f32,
    nodes_per_chunk: u64,
    camera_fov: f32,
    min_val: f32,
    max_val: f32,
};
