const std = @import("std");
const Io = std.Io;

pub const Encoder = enum { x264, x265, av1 };
pub const HWAccel = enum { none, nvenc, amf, qsv, vtb };

pub fn write(process: *std.process.Child, io: Io, buffer: []const u8) !void {
    try process.stdin.?.writeStreamingAll(io, buffer);
}

pub fn open(
    io: Io,
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    framerate: usize,
    video_file: []const u8,
    encoder: Encoder,
    hwaccel: HWAccel,
) !std.process.Child {
    var size_buf: [64]u8 = undefined;
    var fps_buf: [32]u8 = undefined;

    const cmd = [_][]const u8{
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-v",
        "error",
        "-f",
        "rawvideo",
        "-vcodec",
        "rawvideo",
        "-s",
        try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ width, height }),
        "-pix_fmt",
        "yuv420p",
        "-r",
        try std.fmt.bufPrint(&fps_buf, "{d}", .{framerate}),
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
        "-color_range",
        "pc",
        "-i",
        "-",
        "-pix_fmt",
        "yuv420p",
        "-threads",
        "0",
    };

    const enc: []const []const u8 = switch (hwaccel) {
        .none => switch (encoder) {
            .x264 => &.{ "-c:v", "libx264", "-crf", "22", "-preset", "fast" },
            .x265 => &.{ "-c:v", "libx265", "-crf", "22", "-preset", "fast" },
            .av1 => &.{ "-c:v", "libsvtav1", "-crf", "25", "-preset", "11", "-svtav1-params", "lp=6" },
        },
        .nvenc => switch (encoder) {
            .x264 => &.{ "-c:v", "h264_nvenc", "-cq", "23", "-rc", "vbr", "-qmin", "23", "-qmax", "30", "-preset", "p7", "-tune", "hq" },
            .x265 => &.{ "-c:v", "hevc_nvenc", "-cq", "23", "-rc", "vbr", "-qmin", "23", "-qmax", "30", "-preset", "p7", "-tune", "hq" },
            .av1 => &.{ "-c:v", "av1_nvenc", "-cq", "25", "-rc", "vbr", "-qmin", "25", "-qmax", "30", "-preset", "p7", "-tune", "hq" },
        },
        .amf => switch (encoder) {
            .x264 => &.{ "-c:v", "h264_amf", "-usage", "high_quality", "-quality", "quality", "-preset", "quality", "-rc", "cqp", "-qp_i", "22", "-qp_p", "22", "-qp_b", "22" },
            .x265 => &.{ "-c:v", "hevc_amf", "-usage", "high_quality", "-quality", "quality", "-preset", "quality", "-rc", "cqp", "-qp_i", "22", "-qp_p", "22" },
            .av1 => &.{ "-c:v", "av1_amf", "-usage", "high_quality", "-quality", "high_quality", "-preset", "quality", "-rc", "cqp", "-qp_i", "25", "-qp_p", "25", "-qp_b", "25" },
        },
        .qsv => switch (encoder) {
            .x264 => &.{ "-c:v", "h264_qsv", "-preset", "veryslow", "-global_quality", "22" },
            .x265 => &.{ "-c:v", "hevc_qsv", "-preset", "veryslow", "-global_quality", "22" },
            .av1 => &.{ "-c:v", "av1_qsv", "-preset", "veryslow", "-global_quality", "22" },
        },
        .vtb => switch (encoder) {
            .x264 => &.{ "-c:v", "h264_videotoolbox" },
            .x265 => &.{ "-c:v", "hevc_videotoolbox" },
            .av1 => return error.UnsupportedEncoder,
        },
    };

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &cmd);

    try args.appendSlice(allocator, enc);

    try args.append(allocator, video_file);

    return std.process.spawn(io, .{
        .argv = args.items,
        .stdin = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("FFmpeg not found. Make sure it is installed and on PATH", .{});
            return err;
        },
        else => return err,
    };
}

pub fn close(
    process: *std.process.Child,
    io: Io,
) !void {
    if (process.stdin) |stdin| {
        stdin.close(io);
        process.stdin = null;
    }

    _ = try process.wait(io);
    process.kill(io);
}
