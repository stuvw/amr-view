const std = @import("std");
const Io = std.Io;

pub const Encoder = enum { x264, x265, av1 };
pub const HWAccel = enum { none, nvenc, amf, qsv };

pub fn write(process: *std.process.Child, io: Io, buffer: []const u8) !void {
    try process.stdin.?.writeStreamingAll(io, buffer);
}

pub fn open_ffmpeg(
    io: Io,
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    fps: usize,
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
        "rgba",
        "-r",
        try std.fmt.bufPrint(&fps_buf, "{d}", .{fps}),
        "-i",
        "-",
        "-pix_fmt",
        "yuv420p",
    };

    const enc: []const []const u8 = switch (hwaccel) {
        .none => switch (encoder) {
            .x264 => &.{ "-c:v", "libx264", "-crf", "22", "-preset", "fast" },
            .x265 => &.{ "-c:v", "libx265", "-crf", "22", "-preset", "fast" },
            .av1 => &.{ "-c:v", "libsvtav1", "-crf", "25", "-preset", "11", "-svtav1-params", "lp=6" },
        },
        .nvenc => switch (encoder) {
            .x264 => &.{ "-c:v", "h264_nvenc", "-qp", "22", "-rc", "constqp", "-preset", "p7", "-tune", "hq" },
            .x265 => &.{ "-c:v", "hevc_nvenc", "-qp", "22", "-rc", "constqp", "-preset", "p7", "-tune", "hq" },
            .av1 => &.{ "-c:v", "av1_nvenc", "-qp", "25", "-rc", "constqp", "-preset", "p7", "-tune", "hq" },
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
    };

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &cmd);

    try args.appendSlice(allocator, enc);

    try args.append(allocator, video_file);

    return try std.process.spawn(
        io,
        .{
            .argv = args.items,
            .stdin = .pipe,
        },
    );
}

pub fn close_ffmpeg(
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
