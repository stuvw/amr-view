const std = @import("std");
const vk = @import("vulkan");

const Context = @import("./context.zig").Context;
const Args = @import("./args.zig");
const Pipeline = @import("./pipeline.zig");
const Frame = @import("./frame.zig").Frame;
const Colormap = @import("./colormap.zig").Colormap;
const Sampler = @import("./sampler.zig");
const Descriptor = @import("./desc_sets.zig");
const Commands = @import("./commands.zig");
const PushConstants = @import("./push_constants.zig");
const SVO = @import("./svo.zig");
const Video = @import("./video.zig");
const Path = @import("./path.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ------------------ Arguments / Constants -------------------

    var parser = try Args.getParser(allocator);
    defer parser.deinit();

    try Args.setupArgs(&parser);

    var result = try Args.parseArgs(&parser, init);
    defer result.deinit();

    const args = try Args.getArgs(result);

    const frames_in_flight = 2;

    // -------------------- Initialize Vulkan ---------------------
    std.log.info("Initializing Vulkan...", .{});

    const ctx = try Context.init(allocator, "amr-view");
    defer ctx.deinit();

    // -------------------------- Output --------------------------

    var frame_buffers: [frames_in_flight]Frame = undefined;

    for (0..frames_in_flight) |i| {
        try frame_buffers[i].create(&ctx, args.frame_width, args.frame_height);
    }

    defer for (0..frames_in_flight) |i| {
        frame_buffers[i].destroy(&ctx);
    };

    // ------------------------- Colormap -------------------------

    var cmap: Colormap = undefined;
    try cmap.create(&ctx, 256);
    defer cmap.destroy(&ctx);

    const nearest_sampler = try Sampler.create(&ctx);
    defer Sampler.destroy(&ctx, nearest_sampler);

    // ------------------- Sparse Voxel Octree --------------------

    var metadata: SVO.SVOFileMetadata = undefined;
    try metadata.get(allocator, io, args.data_file);
    defer metadata.destroy(allocator);
    metadata.print();

    var svo: SVO.SVO = undefined;
    try svo.create(&ctx, allocator, metadata.num_nodes);
    defer svo.destroy(&ctx, allocator);

    // ------------------ Shader Binding Layouts ------------------

    const desc_pool = try Descriptor.createDescriptorPool(&ctx);
    defer Descriptor.destroyDescriptorPool(&ctx, desc_pool);

    const desc_layout = try Descriptor.createDescriptorSetLayout(&ctx);
    defer Descriptor.destroyDescriptorSetLayout(&ctx, desc_layout);

    // ------------------- Pipelines & Layouts --------------------

    const pipeline_layout = try Pipeline.createPipelineLayout(&ctx, desc_layout);
    defer Pipeline.destroyPipelineLayout(&ctx, pipeline_layout);

    const pipeline = try Pipeline.createComputePipeline(&ctx, pipeline_layout, args.mode);
    defer Pipeline.destroyPipeline(&ctx, pipeline);

    // ---------------- Commands & Synchronization ----------------

    const command_pool = try Commands.createCommandPool(&ctx);
    defer Commands.destroyCommandPool(&ctx, command_pool);

    var command_buffers: [frames_in_flight]vk.CommandBuffer = undefined;
    var desc_sets: [frames_in_flight]vk.DescriptorSet = undefined;
    var render_fences: [frames_in_flight]vk.Fence = undefined;

    for (0..frames_in_flight) |i| {
        command_buffers[i] = try Commands.createCommandBuffer(&ctx, command_pool);
        desc_sets[i] = try Descriptor.updateDescriptorSets(
            &ctx,
            desc_pool,
            desc_layout,
            frame_buffers[i].img_view_y,
            frame_buffers[i].img_view_u,
            frame_buffers[i].img_view_v,
            nearest_sampler,
            cmap.image_view,
            svo.chunk_ptrs,
        );
        render_fences[i] = try ctx.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    }

    defer for (0..frames_in_flight) |i| {
        ctx.dev.destroyFence(render_fences[i], null);
    };

    // --------------- Data Upload & DMA Transfers ----------------

    {
        const command_buffer = try Commands.createCommandBuffer(&ctx, command_pool);

        std.log.info("Uploading SVO to VRAM...", .{});

        try svo.upload(&ctx, command_buffer, io, args.data_file, metadata.header_size);

        try cmap.upload(&ctx, command_buffer, io, args.cmap_file);
    }

    // ---------------------- Push Constants ----------------------

    var push_constants = PushConstants.PushConstant{
        // Camera info
        .camera_pos = undefined,
        .camera_dir = undefined,
        .camera_right = undefined,
        .camera_up = undefined,
        .camera_fov = std.math.tan(std.math.degreesToRadians(args.fov) / 2.0),
        // Colormap info
        .under_color = args.under_color,
        .over_color = args.over_color,
        .bad_color = args.bad_color,
        .min_val = args.min_val,
        .max_val = args.max_val,
        // Octree info
        .root_pos = args.root_pos ++ .{args.root_size},
        .chunk_shift = svo.chunk_shift,
    };

    // ----------------- Initialize Video Stream ------------------
    var proc = try Video.open(
        init.io,
        allocator,
        args.frame_width,
        args.frame_height,
        args.framerate,
        args.video_file,
        args.encoder,
        args.hwaccel,
    );

    std.log.info("Rendering at {d}x{d}", .{ args.frame_width, args.frame_height });

    // --------------------- Main Render Loop ---------------------

    const camera_path = try Path.load(args.path_file, io, allocator);
    defer allocator.free(camera_path);

    const num_frames = camera_path.len;

    const start_time = std.Io.Clock.awake.now(io);

    for (camera_path, 0..) |cam_point, i| {
        printProgress(start_time, std.Io.Clock.awake.now(io), num_frames, i + 1);

        const frame_idx = i % frames_in_flight;

        const cmdbuf = command_buffers[frame_idx];
        const framebuf = frame_buffers[frame_idx];
        const render_fence = render_fences[frame_idx];
        const desc_set = desc_sets[frame_idx];

        _ = try ctx.dev.waitForFences(&.{render_fence}, .true, std.math.maxInt(u64));

        if (i >= frames_in_flight) {
            const prev_idx = frame_idx;
            const pixel_slice = frame_buffers[prev_idx].getSlice();
            try Video.write(&proc, io, pixel_slice);
        }

        try ctx.dev.resetFences(&[_]vk.Fence{render_fence});

        try ctx.dev.beginCommandBuffer(cmdbuf, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        PushConstants.updateConstants(
            &push_constants,
            &ctx,
            cmdbuf,
            pipeline_layout,
            cam_point[0..3].*,
            cam_point[3..6].*,
            cam_point[6..9].*,
        );

        framebuf.prepareForRender(
            &ctx,
            cmdbuf,
            pipeline,
            pipeline_layout,
            desc_set,
        );
        framebuf.render(&ctx, cmdbuf);
        framebuf.prepareForDownload(&ctx, cmdbuf);
        framebuf.download(&ctx, cmdbuf);
        framebuf.prepareForRead(&ctx, cmdbuf);

        try ctx.dev.endCommandBuffer(cmdbuf);

        try ctx.dev.queueSubmit(ctx.compute_queue.handle, &[_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = &.{cmdbuf},
        }}, render_fence);
    }

    // Flush remaining frames
    const total_written_in_loop = if (num_frames >= frames_in_flight) num_frames - frames_in_flight else 0;
    var j = total_written_in_loop;

    while (j < num_frames) : (j += 1) {
        const frame_idx = j % frames_in_flight;

        _ = try ctx.dev.waitForFences(&.{render_fences[frame_idx]}, .true, std.math.maxInt(u64));

        const pixel_slice = frame_buffers[frame_idx].getSlice();
        try Video.write(&proc, io, pixel_slice);
    }

    try ctx.dev.deviceWaitIdle();

    try Video.close(&proc, init.io);

    std.debug.print("\n", .{});
    std.log.info("Video written to {s}", .{args.video_file});
}

pub fn printProgress(
    start_time: std.Io.Timestamp,
    end_time: std.Io.Timestamp,
    num_frames: usize,
    current_frame: usize,
) void {
    const progress_percentage = (@as(f64, @floatFromInt(current_frame)) / @as(f64, @floatFromInt(num_frames))) * 100.0;

    const progress_bar_size = 40;

    const white_esc = "\x1B[47m";
    const default_esc = "\x1B[49m";

    var progress_buffer = (white_esc ++ " " ** (progress_bar_size + default_esc.len)).*;

    const num_progress_nodes: usize = @trunc(progress_percentage / (100.0 / @as(comptime_float, progress_bar_size)));

    @memcpy(
        progress_buffer[num_progress_nodes + white_esc.len .. num_progress_nodes + white_esc.len + default_esc.len],
        default_esc,
    );

    const raw_elapsed_s: u64 = @intCast(start_time.durationTo(end_time).toSeconds());
    const elapsed_h = raw_elapsed_s / std.time.s_per_hour;
    const elapsed_m = (raw_elapsed_s % std.time.s_per_hour) / std.time.s_per_min;
    const elapsed_s = (raw_elapsed_s % std.time.s_per_hour) % std.time.s_per_min;

    const average_fps = @as(f64, @floatFromInt(current_frame)) / @as(f64, @floatFromInt(raw_elapsed_s));

    const remaining_frames = num_frames - current_frame;
    const raw_remaining_s: u64 = @trunc(@as(f64, @floatFromInt(remaining_frames)) / (average_fps));
    const remaining_h = raw_remaining_s / std.time.s_per_hour;
    const remaining_m = (raw_remaining_s % std.time.s_per_hour) / std.time.s_per_min;
    const remaining_s = (raw_remaining_s % std.time.s_per_hour) % std.time.s_per_min;

    std.debug.print("\r{d:.0}%|{s}| {d}/{d} [ {d:02}:{d:02}:{d:02}<{d:02}:{d:02}:{d:02}, {d:.2}fps ]", .{
        progress_percentage,
        progress_buffer,
        current_frame,
        num_frames,
        elapsed_h,
        elapsed_m,
        elapsed_s,
        remaining_h,
        remaining_m,
        remaining_s,
        average_fps,
    });
}
