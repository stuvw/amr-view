const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

pub const Mode = enum {
    normal,
    vr180,
    vr360,
};

// Ensure compiled SPIR-V bytecode is correctly aligned for Vulkan's ingestion
const normal_shader_src align(@alignOf(u32)) = @embedFile("./shaders/spirv/octree_traversal_normal.spv").*;
const vr180_shader_src align(@alignOf(u32)) = @embedFile("./shaders/spirv/octree_traversal_vr180.spv").*;
const vr360_shader_src align(@alignOf(u32)) = @embedFile("./shaders/spirv/octree_traversal_vr360.spv").*;

pub fn createPipelineLayout(ctx: *const Context, desc_layout: vk.DescriptorSetLayout, pc_size: u32) !vk.PipelineLayout {
    return try ctx.dev.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = &.{desc_layout},
        .push_constant_range_count = 1,
        .p_push_constant_ranges = &.{
            vk.PushConstantRange{
                .stage_flags = .{ .compute_bit = true },
                .offset = 0,
                .size = pc_size,
            },
        },
    }, null);
}

pub fn destroyPipelineLayout(ctx: *const Context, pipeline_layout: vk.PipelineLayout) void {
    ctx.dev.destroyPipelineLayout(pipeline_layout, null);
}

pub fn createComputePipeline(ctx: *const Context, layout: vk.PipelineLayout, mode: Mode) !vk.Pipeline {

    // ---------------------- Shader Module -----------------------
    const shader_module = try ctx.dev.createShaderModule(&.{
        .code_size = switch (mode) {
            .normal => normal_shader_src.len,
            .vr180 => vr180_shader_src.len,
            .vr360 => vr360_shader_src.len,
        },
        .p_code = switch (mode) {
            .normal => @ptrCast(&normal_shader_src),
            .vr180 => @ptrCast(&vr180_shader_src),
            .vr360 => @ptrCast(&vr360_shader_src),
        },
    }, null);
    defer ctx.dev.destroyShaderModule(shader_module, null);

    // ------------------ Pipeline Configuration ------------------
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
