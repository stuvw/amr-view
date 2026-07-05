const std = @import("std");
const vk = @import("vulkan");
const args = @import("args");

const Context = @import("./context.zig").Context;
const Pipeline = @import("./pipeline.zig");
const Output = @import("./output.zig");
const Colormap = @import("./colormap.zig");
const Sampler = @import("./sampler.zig");
const Descriptor = @import("./desc_sets.zig");
const Commands = @import("./commands.zig");
const Uniforms = @import("./uniform_buffers.zig");
const SVO = @import("./svo.zig");
const Video = @import("./video.zig");
const Path = @import("./path.zig");
const Math = @import("./math.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --------------------------- Arguments / Constants -----------------------------------

    var parser = try args.ArgumentParser.init(allocator, .{
        .name = "amr-view",
        .version = "0.1.0",
        .description = "A Zig and Vulkan based AMR dataset visualizer.",
    });
    defer parser.deinit();

    try parser.addOption("colormap-file", .{
        .help = "Input colormap file",
        .value_type = .string,
    });

    try parser.addOption("path-file", .{
        .help = "Input camera path file",
        .value_type = .string,
    });

    try parser.addOption("data-file", .{
        .help = "Input simulation data file",
        .value_type = .string,
    });

    try parser.addOption("video-file", .{
        .help = "Output video file",
        .value_type = .string,
        .default = "video.mp4",
    });

    try parser.addOption("width", .{
        .help = "Output video width",
        .value_type = .uint,
        .default = "1920",
    });

    try parser.addOption("height", .{
        .help = "Output video height",
        .value_type = .uint,
        .default = "1080",
    });

    try parser.addOption("framerate", .{
        .help = "Output video framerate",
        .value_type = .uint,
        .default = "60",
    });

    try parser.addOption("min-val", .{
        .help = "Minimum value under which data is discarded",
        .value_type = .float,
        .default = "-3.0",
    });

    try parser.addOption("max-val", .{
        .help = "Maximum value over which data is discarded",
        .value_type = .float,
        .default = "3.0",
    });

    var result = try parser.parseProcess(init);
    defer result.deinit();

    const cmap_file = result.getString("colormap-file");
    const path_file = result.getString("path-file");
    const data_file = result.getString("data-file");
    const video_file = result.getOrString("video-file", "./video.mp4");

    const frame_width: usize = result.getOrUint("width", 1920);
    const frame_height: usize = result.getOrUint("height", 1080);
    const framerate: usize = result.getOrUint("framerate", 30);

    const min_val: f32 = @floatCast(result.getOrFloat("min-val", -3.0));
    const max_val: f32 = @floatCast(result.getOrFloat("max-val", 3.0));

    const under_color = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    const over_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    const bad_color = [4]f32{ 0.0, 0.0, 0.0, 0.0 };

    if (cmap_file == null) {
        std.log.err("Colormap input file not specified (use --colormap-file <filename>)", .{});
        return error.NoCmapInput;
    }
    if (path_file == null) {
        std.log.err("Camera path input file not specified (use --path-file <filename>)", .{});
        return error.NoCamInput;
    }
    if (data_file == null) {
        std.log.err("Simulation data input file not specified (use --data-file <filename>)", .{});
        return error.NoDataInput;
    }

    const fov: f32 = 60.0;

    // --------------------------- Initialize Vulkan -----------------------------------
    std.log.info("Initializing Vulkan...", .{});

    const ctx = try Context.init(allocator, "amr-view");
    defer ctx.deinit();

    std.log.info("Using device: {s}", .{ctx.deviceName()});

    // --------------------------- Output -----------------------------------

    var output_image: Output.OutputImage = undefined;
    try output_image.create(&ctx, frame_width, frame_height);
    defer output_image.destroy(&ctx);

    var output_buffer: Output.OutputBuffer = undefined;
    try output_buffer.create(&ctx, frame_width, frame_height);
    defer output_buffer.destroy(&ctx);

    // --------------------------- Colormap -----------------------------------

    var cmap: Colormap.ColormapImage = undefined;
    try cmap.create(&ctx, 256);
    defer cmap.destroy(&ctx);

    const nearest_sampler = try Sampler.createSampler(&ctx);
    defer Sampler.destroySampler(&ctx, nearest_sampler);

    // --------------------------- Static Uniform Buffers -----------------------------------

    var octree_uniform: Uniforms.UniformBuffer = undefined;
    try octree_uniform.create(&ctx, Uniforms.OctreeInfo);
    defer octree_uniform.destroy(&ctx);

    var colormap_uniform: Uniforms.UniformBuffer = undefined;
    try colormap_uniform.create(&ctx, Uniforms.ColormapInfo);
    defer colormap_uniform.destroy(&ctx);

    // --------------------------- Dynamic Uniform Buffers -----------------------------------

    var camera_uniform: Uniforms.UniformBuffer = undefined;
    try camera_uniform.create(&ctx, Uniforms.CameraInfo);
    defer camera_uniform.destroy(&ctx);

    // --------------------------- Sparse Voxel Octree -----------------------------------

    const metadata = try SVO.getSVOMetadata(io, data_file.?);

    var svo: SVO.SVOBuffer = undefined;
    try svo.create(&ctx, metadata.num_nodes);
    defer svo.destroy(&ctx);

    // --------------------------- Shader Binding Layouts -----------------------------------

    const desc_pool = try Descriptor.createDescriptorPool(&ctx);
    defer Descriptor.destroyDescriptorPool(&ctx, desc_pool);

    const desc_layout = try Descriptor.createDescriptorSetLayout(&ctx);
    defer Descriptor.destroyDescriptorSetLayout(&ctx, desc_layout);

    // --------------------------- Pipelines & Layouts -----------------------------------

    const pipeline_layout = try Pipeline.createPipelineLayout(&ctx, desc_layout);
    defer Pipeline.destroyPipelineLayout(&ctx, pipeline_layout);

    const pipeline = try Pipeline.createComputePipeline(&ctx, pipeline_layout);
    defer Pipeline.destroyPipeline(&ctx, pipeline);

    // --------------------------- Commands & Synchronization -----------------------------------

    const command_pool = try Commands.createCommandPool(&ctx);
    defer Commands.destroyCommandPool(&ctx, command_pool);

    const command_buffer = try Commands.createCommandBuffer(&ctx, command_pool);

    const set = try Descriptor.updateDescriptorSets(
        &ctx,
        desc_pool,
        desc_layout,
        svo.buffer,
        output_image.image_view,
        nearest_sampler,
        cmap.image_view,
        colormap_uniform.buffer,
        camera_uniform.buffer,
        octree_uniform.buffer,
    );

    // --------------------------- Data Upload & DMA Transfers -----------------------------------
    std.log.info("Uploading SVO to VRAM...", .{});

    const color_ubo = Uniforms.ColormapInfo{
        .min_val = min_val,
        .max_val = max_val,
        .under_color = under_color,
        .over_color = over_color,
        .bad_color = bad_color,
    };
    colormap_uniform.upload(std.mem.asBytes(&color_ubo));

    // User should be able to control this
    const octree_ubo = Uniforms.OctreeInfo{
        .root_pos = .{ 0, 0, 0 },
        .root_size = 16.0,
    };
    octree_uniform.upload(std.mem.asBytes(&octree_ubo));

    try cmap.upload(&ctx, command_buffer, io, cmap_file.?);

    try svo.upload(&ctx, command_buffer, io, data_file.?);

    // --------------------------- Initialize Video Stream -----------------------------------
    var proc = try Video.open_ffmpeg(init.io, frame_width, frame_height, framerate, video_file);

    // --------------------------- Main Render Loop -----------------------------------
    const render_fence = try ctx.dev.createFence(&.{ .flags = .{} }, null);
    defer ctx.dev.destroyFence(render_fence, null);

    const frames = try Path.load(path_file.?, io, allocator);
    defer allocator.free(frames);

    const num_frames = frames.len;
    for (frames, 0..) |frame, i| {
        const gpu_start = std.Io.Clock.awake.now(io);

        // 1. Update Camera Uniforms for the current frame
        const cam_pos = frame[0..3].*;
        const cam_dir = frame[3..6].*;
        const cam_up = frame[6..9].*;
        const cam_right = Math.cross(cam_dir, cam_up);

        const camera_ubo = Uniforms.CameraInfo{
            .camera_pos = [4]f32{ cam_pos[0], cam_pos[1], cam_pos[2], 0.0 },
            .camera_dir = [4]f32{ cam_dir[0], cam_dir[1], cam_dir[2], 0.0 },
            .camera_right = [4]f32{ cam_right[0], cam_right[1], cam_right[2], 0.0 },
            .camera_up = [4]f32{ cam_up[0], cam_up[1], cam_up[2], 0.0 },
            .camera_fov = std.math.tan(std.math.degreesToRadians(fov) / 2.0),
        };
        camera_uniform.upload(std.mem.asBytes(&camera_ubo));

        // 2. Start Recording Commands
        try ctx.dev.beginCommandBuffer(command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        // BARRIER 1: Prepare output image layout for Compute Writing
        const barrier_to_compute = vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{ .shader_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = output_image.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        ctx.dev.cmdPipelineBarrier(
            command_buffer,
            .{ .top_of_pipe_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            &.{},
            &.{},
            &.{barrier_to_compute},
        );

        // 3. Bind Resources and Execute Compute Pipeline
        ctx.dev.cmdBindPipeline(command_buffer, .compute, pipeline);
        ctx.dev.cmdBindDescriptorSets(
            command_buffer,
            .compute,
            pipeline_layout,
            0,
            &.{set},
            &.{},
        );

        const group_x: u32 = @intCast((frame_width + 7) / 8);
        const group_y: u32 = @intCast((frame_height + 7) / 8);
        ctx.dev.cmdDispatch(command_buffer, group_x, group_y, 1);

        // BARRIER 2: Wait for compute writes to finish, transition image for readback transfer
        const barrier_to_transfer = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .general,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = output_image.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        ctx.dev.cmdPipelineBarrier(
            command_buffer,
            .{ .compute_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            &.{},
            &.{},
            &.{barrier_to_transfer},
        );

        // 4. Copy VRAM Frame Image to Host-Visible Staging/Readback Buffer
        const copy_region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = vk.Extent3D{ .width = @intCast(frame_width), .height = @intCast(frame_height), .depth = 1 },
        };
        ctx.dev.cmdCopyImageToBuffer(
            command_buffer,
            output_image.image,
            .transfer_src_optimal,
            output_buffer.buffer,
            &.{copy_region},
        );

        // BARRIER 3: Ensure memory transfer completes before Host reads from RAM
        const barrier_to_host = vk.BufferMemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .host_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = output_buffer.buffer,
            .offset = 0,
            .size = vk.WHOLE_SIZE,
        };

        ctx.dev.cmdPipelineBarrier(
            command_buffer,
            .{ .transfer_bit = true },
            .{ .host_bit = true },
            .{},
            &.{},
            &.{barrier_to_host},
            &.{},
        );

        try ctx.dev.endCommandBuffer(command_buffer);

        // 5. Submit Command Buffer and synchronous wait
        try ctx.dev.queueSubmit(ctx.compute_queue.handle, &[_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = &.{command_buffer},
        }}, render_fence);

        // Block the CPU loop until this single frame is completely done processing on the GPU
        _ = try ctx.dev.waitForFences(&.{render_fence}, .true, std.math.maxInt(u64));
        try ctx.dev.resetFences(&[_]vk.Fence{render_fence});

        const gpu_end = std.Io.Clock.awake.now(io);

        const gpu_elapsed: f64 = @floatFromInt(gpu_start.durationTo(gpu_end).nanoseconds);

        const enc_start = std.Io.Clock.awake.now(io);

        // 6. Pipe raw frame data down to FFmpeg
        const pixel_slice: []const u8 = @as([*]const u8, @ptrCast(output_buffer.ptr))[0..output_buffer.size];
        try Video.write(&proc, io, pixel_slice);

        const enc_end = std.Io.Clock.awake.now(io);

        const enc_elapsed: f64 = @floatFromInt(enc_start.durationTo(enc_end).nanoseconds);

        std.debug.print("\rRendered frame {d}/{d}. Time spent: GPU: {d:6.6} | ENC: {d:6.6}", .{ i + 1, num_frames, gpu_elapsed / std.time.ns_per_ms, enc_elapsed / std.time.ns_per_ms });
    }

    std.debug.print("\n", .{});
    try Video.close_ffmpeg(&proc, init.io);
}
