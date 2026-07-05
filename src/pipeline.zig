const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

// Ensure compiled SPIR-V bytecode is correctly aligned for Vulkan's ingestion
const shader_src align(@alignOf(u32)) = @embedFile("./shaders/spirv/octree_traversal.spv").*;

pub fn createPipelineLayout(ctx: *const Context, desc_layout: vk.DescriptorSetLayout) !vk.PipelineLayout {
    return try ctx.dev.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = &.{desc_layout},
    }, null);
}

pub fn destroyPipelineLayout(ctx: *const Context, pipeline_layout: vk.PipelineLayout) void {
    ctx.dev.destroyPipelineLayout(pipeline_layout, null);
}

pub fn createComputePipeline(
    ctx: *const Context,
    layout: vk.PipelineLayout,
) !vk.Pipeline {

    // ------------------------ Shader Modules -------------------------------------
    const shader_module = try ctx.dev.createShaderModule(&.{
        .code_size = shader_src.len,
        .p_code = @ptrCast(&shader_src),
    }, null);
    defer ctx.dev.destroyShaderModule(shader_module, null);

    // ---------------------------- Pipeline Configuration ----------------------------------------
    const create_info = [_]vk.ComputePipelineCreateInfo{
        .{
            .flags = .{},
            .layout = layout,
            .base_pipeline_index = -1,
            .base_pipeline_handle = .null_handle,
            .stage = .{
                .flags = .{},
                .stage = .{ .compute_bit = true },
                .module = shader_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
        },
    };

    var pipeline: vk.Pipeline = undefined;

    _ = try ctx.dev.createComputePipelines(
        .null_handle,
        create_info[0..1],
        null,
        (&pipeline)[0..1],
    );

    return pipeline;
}

pub fn destroyPipeline(ctx: *const Context, pipeline: vk.Pipeline) void {
    ctx.dev.destroyPipeline(pipeline, null);
}
