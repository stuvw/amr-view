const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

/// Create nearest sampler used to sample the colormap in the coloring stage
pub fn createSampler(ctx: *const Context) !vk.Sampler {
    return try ctx.dev.createSampler(&.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1.0,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0.0,
        .max_lod = 1.0,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = .false,
    }, null);
}

pub fn destroySampler(ctx: *const Context, sampler: vk.Sampler) void {
    ctx.dev.destroySampler(sampler, null);
}
