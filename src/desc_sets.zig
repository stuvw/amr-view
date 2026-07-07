const vk = @import("vulkan");
const Context = @import("./context.zig").Context;

pub fn createDescriptorPool(ctx: *const Context) !vk.DescriptorPool {
    return try ctx.dev.createDescriptorPool(&.{
        .max_sets = 1,
        .pool_size_count = 2,
        .p_pool_sizes = &[_]vk.DescriptorPoolSize{
            .{ .type = .combined_image_sampler, .descriptor_count = 1 },
            .{ .type = .storage_image, .descriptor_count = 1 },
        },
    }, null);
}

pub fn destroyDescriptorPool(ctx: *const Context, desc_pool: vk.DescriptorPool) void {
    ctx.dev.destroyDescriptorPool(desc_pool, null);
}

pub fn createDescriptorSetLayout(ctx: *const Context) !vk.DescriptorSetLayout {
    return try ctx.dev.createDescriptorSetLayout(&.{
        .binding_count = 2,
        .p_bindings = &[_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0, // output image
                .descriptor_type = .storage_image,
                .descriptor_count = 1,
                .stage_flags = .{ .compute_bit = true },
            },
            .{
                .binding = 1, // colormap image
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .stage_flags = .{ .compute_bit = true },
            },
        },
    }, null);
}

pub fn destroyDescriptorSetLayout(ctx: *const Context, desc_layout: vk.DescriptorSetLayout) void {
    ctx.dev.destroyDescriptorSetLayout(desc_layout, null);
}

pub fn updateDescriptorSets(
    ctx: *const Context,
    desc_pool: vk.DescriptorPool,
    desc_layout: vk.DescriptorSetLayout,
    output_image: vk.ImageView,
    nearest_sampler: vk.Sampler,
    cmap_image: vk.ImageView,
) !vk.DescriptorSet {
    var sets: [1]vk.DescriptorSet = undefined;
    try ctx.dev.allocateDescriptorSets(&.{
        .descriptor_pool = desc_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = &[_]vk.DescriptorSetLayout{desc_layout},
    }, &sets);
    const set = sets[0];

    const output_image_info = vk.DescriptorImageInfo{ .image_view = output_image, .image_layout = .general, .sampler = .null_handle };
    const cmap_image_info = vk.DescriptorImageInfo{ .sampler = nearest_sampler, .image_view = cmap_image, .image_layout = .shader_read_only_optimal };

    ctx.dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{
        .{ // Binding 0: Output Storage Image (writeonly image2D)
            .dst_set = set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = &.{output_image_info},
            .p_buffer_info = &.{},
            .p_texel_buffer_view = &.{},
        },
        .{ // Binding 1: Colormap Texture (sampler2D)
            .dst_set = set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &.{cmap_image_info},
            .p_buffer_info = &.{},
            .p_texel_buffer_view = &.{},
        },
    }, &.{});

    return set;
}
