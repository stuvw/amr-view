const std = @import("std");
const vk = @import("vulkan");
const args = @import("args");

const Context = @import("./context.zig").Context;
const Args = @import("./args.zig");
const Pipeline = @import("./pipeline.zig");
const Frame = @import("./frame.zig").Frame;
const Colormap = @import("./colormap.zig").Colormap;
const Sampler = @import("./sampler.zig");
const Descriptor = @import("./desc_sets.zig");
const Commands = @import("./commands.zig");
const PushConstant = @import("./push_constants.zig").PushConstant;
const SVO = @import("./svo.zig");
const Video = @import("./video.zig");
const Path = @import("./path.zig");
const Math = @import("./math.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ------------------ Arguments / Constants -------------------

    var parser = try args.ArgumentParser.init(allocator, .{
        .name = "amr-view",
        .version = "0.2.0",
        .description = "A Zig and Vulkan based AMR dataset visualizer.",
    });
    defer parser.deinit();

    var result = try Args.parseArgs(&parser, init);

    defer result.deinit();

    const cmap_file = result.getString("colormap-file").?;
    const path_file = result.getString("path-file").?;
    const data_file = result.getString("data-file").?;
    const video_file = result.getOrString("video-file", "./video.mp4");

    const frame_width: usize = Math.roundEven(result.getOrUint("width", 1920));
    const frame_height: usize = Math.roundEven(result.getOrUint("height", 1080));
    const fov: f32 = @floatCast(result.getOrFloat("fov", 60));
    const framerate: usize = result.getOrUint("framerate", 30);

    const min_val: f32 = @floatCast(result.getOrFloat("min-val", -3.0));
    const max_val: f32 = @floatCast(result.getOrFloat("max-val", 3.0));

    const under_color = try Args.parseArray(result.getArray("under-color"), 4, .{ 0.0, 0.0, 0.0, 1.0 });
    const over_color = try Args.parseArray(result.getArray("over-color"), 4, .{ 1.0, 1.0, 1.0, 1.0 });
    const bad_color = try Args.parseArray(result.getArray("bad-color"), 4, .{ 0.0, 0.0, 0.0, 0.0 });

    const root_pos = try Args.parseArray(result.getArray("root-pos"), 3, .{ 0.0, 0.0, 0.0 });
    const root_size: f32 = @floatCast(result.getOrFloat("root-size", 1.0));

    const encoder = result.getEnum(Video.Encoder, "encoder") orelse .x264;
    const hwaccel = result.getEnum(Video.HWAccel, "hwaccel") orelse .none;

    const mode = result.getEnum(Pipeline.Mode, "mode") orelse .normal;

    const frames_in_flight = 2;

    // -------------------- Initialize Vulkan ---------------------
    std.log.info("Initializing Vulkan...", .{});

    const ctx = try Context.init(allocator, "amr-view");
    defer ctx.deinit();

    // -------------------------- Output --------------------------

    var frame_buffers: [frames_in_flight]Frame = undefined;

    for (0..frames_in_flight) |i| {
        try frame_buffers[i].create(&ctx, frame_width, frame_height);
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
    try metadata.get(allocator, io, data_file);
    defer metadata.destroy(allocator);
    metadata.print();

    var svo: SVO.SVOBuffers = undefined;

    const chunk_size_bytes: u64 = @as(u64, 1) << @intCast(std.math.log2(ctx.max_alloc_size));

    try svo.create(&ctx, allocator, metadata.num_nodes, chunk_size_bytes);
    defer svo.destroy(&ctx, allocator);

    const chunk_ptr_buffer = try ctx.dev.createBuffer(&.{
        .size = @sizeOf(u64) * svo.buffers.len,
        .usage = .{ .storage_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer ctx.dev.destroyBuffer(chunk_ptr_buffer, null);

    const chunk_ptr_buffer_reqs = ctx.dev.getBufferMemoryRequirements(chunk_ptr_buffer);
    const chunk_ptr_buffer_mem = try ctx.allocate(chunk_ptr_buffer_reqs, .{
        .host_coherent_bit = true,
        .host_visible_bit = true,
    });
    defer ctx.dev.freeMemory(chunk_ptr_buffer_mem, null);

    try ctx.dev.bindBufferMemory(chunk_ptr_buffer, chunk_ptr_buffer_mem, 0);
    const chunk_ptr_buffer_ptr = try ctx.dev.mapMemory(chunk_ptr_buffer_mem, 0, @sizeOf(u64) * svo.buffers.len, .{});
    defer ctx.dev.unmapMemory(chunk_ptr_buffer_mem);

    for (svo.buffers, @as([*]u64, @ptrCast(@alignCast(chunk_ptr_buffer_ptr)))) |src, *dest| {
        dest.* = src.ptr;
    }

    // ------------------ Shader Binding Layouts ------------------

    const desc_pool = try Descriptor.createDescriptorPool(&ctx);
    defer Descriptor.destroyDescriptorPool(&ctx, desc_pool);

    const desc_layout = try Descriptor.createDescriptorSetLayout(&ctx);
    defer Descriptor.destroyDescriptorSetLayout(&ctx, desc_layout);

    // ------------------- Pipelines & Layouts --------------------

    const pipeline_layout = try Pipeline.createPipelineLayout(&ctx, desc_layout);
    defer Pipeline.destroyPipelineLayout(&ctx, pipeline_layout);

    const pipeline = try Pipeline.createComputePipeline(&ctx, pipeline_layout, mode);
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
            chunk_ptr_buffer,
        );
        render_fences[i] = try ctx.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    }

    defer for (0..frames_in_flight) |i| {
        ctx.dev.destroyFence(render_fences[i], null);
    };

    // '--------------- Data Upload & DMA Transfers ----------------

    {
        const command_buffer = try Commands.createCommandBuffer(&ctx, command_pool);

        std.log.info("Uploading SVO to VRAM...", .{});

        try svo.upload(&ctx, command_buffer, io, data_file, metadata.header_size);

        try cmap.upload(&ctx, command_buffer, io, cmap_file);
    }

    // ---------------------- Push Constants ----------------------

    var push_constants = PushConstant{
        // Camera info
        .camera_pos = undefined,
        .camera_dir = undefined,
        .camera_right = undefined,
        .camera_up = undefined,
        .camera_fov = std.math.tan(std.math.degreesToRadians(fov) / 2.0),
        // Colormap info
        .under_color = under_color,
        .over_color = over_color,
        .bad_color = bad_color,
        .min_val = min_val,
        .max_val = max_val,
        // Octree info
        .root_pos = root_pos ++ .{root_size},
        .chunk_shift = std.math.log2(chunk_size_bytes / @sizeOf(SVO.OctreeNode)),
    };

    // ----------------- Initialize Video Stream ------------------
    var proc = try Video.open(
        init.io,
        allocator,
        frame_width,
        frame_height,
        framerate,
        video_file,
        encoder,
        hwaccel,
    );

    std.log.info("Rendering at {d}x{d}", .{ frame_width, frame_height });

    // --------------------- Main Render Loop ---------------------

    const camera_path = try Path.load(path_file, io, allocator);
    defer allocator.free(camera_path);

    const num_frames = camera_path.len;

    const start_time = std.Io.Clock.awake.now(io);

    for (camera_path, 0..) |cam_point, i| {
        printProgress(start_time, std.Io.Clock.awake.now(io), num_frames, i + 1);

        const frame_idx = i % frames_in_flight;

        _ = try ctx.dev.waitForFences(&.{render_fences[frame_idx]}, .true, std.math.maxInt(u64));

        if (i >= frames_in_flight) {
            const prev_idx = frame_idx;
            const pixel_slice: []const u8 = frame_buffers[prev_idx].getSlice();
            try Video.write(&proc, io, pixel_slice);
        }

        try ctx.dev.resetFences(&[_]vk.Fence{render_fences[frame_idx]});

        try ctx.dev.beginCommandBuffer(command_buffers[frame_idx], &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        const cam_pos = cam_point[0..3].*;
        const cam_dir = cam_point[3..6].*;
        const cam_up = cam_point[6..9].*;
        const cam_right = Math.cross(cam_dir, cam_up);

        push_constants.camera_pos = cam_pos;
        push_constants.camera_dir = cam_dir;
        push_constants.camera_right = cam_right;
        push_constants.camera_up = cam_up;

        ctx.dev.cmdPushConstants(
            command_buffers[frame_idx],
            pipeline_layout,
            .{ .compute_bit = true },
            0,
            @sizeOf(PushConstant),
            @ptrCast(&push_constants),
        );

        const cmdbuf = command_buffers[frame_idx];
        const framebuf = frame_buffers[frame_idx];

        framebuf.prepareForRender(
            &ctx,
            cmdbuf,
            pipeline,
            pipeline_layout,
            desc_sets[frame_idx],
        );
        framebuf.render(&ctx, cmdbuf);
        framebuf.prepareForDownload(&ctx, cmdbuf);
        framebuf.download(&ctx, cmdbuf);
        framebuf.prepareForRead(&ctx, cmdbuf);

        try ctx.dev.endCommandBuffer(cmdbuf);

        try ctx.dev.queueSubmit(ctx.compute_queue.handle, &[_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = &.{cmdbuf},
        }}, render_fences[frame_idx]);
    }

    // Flush remaining frames
    const total_written_in_loop = if (num_frames >= frames_in_flight) num_frames - frames_in_flight else 0;
    var j = total_written_in_loop;

    while (j < num_frames) : (j += 1) {
        const frame_idx = j % frames_in_flight;

        _ = try ctx.dev.waitForFences(&.{render_fences[frame_idx]}, .true, std.math.maxInt(u64));

        const pixel_slice: []const u8 = frame_buffers[frame_idx].getSlice();
        try Video.write(&proc, io, pixel_slice);
    }

    try ctx.dev.deviceWaitIdle();

    try Video.close(&proc, init.io);

    std.debug.print("\n", .{});
    std.log.info("Video written to {s}", .{video_file});
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
