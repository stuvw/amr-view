const std = @import("std");
const Io = std.Io;

pub fn write(process: *std.process.Child, io: Io, buffer: []const u8) !void {
    try process.stdin.?.writeStreamingAll(io, buffer);
}

pub fn open_ffmpeg(
    io: Io,
    width: usize,
    height: usize,
    fps: usize,
    video_file: []const u8,
) !std.process.Child {
    var size_buf: [64]u8 = undefined;
    var fps_buf: [32]u8 = undefined;

    const args = [_][]const u8{
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
        "-c:v",
        "hevc_nvenc",
        "-qp",
        "22",
        "-rc",
        "constqp",
        "-preset",
        "p7",
        "-tune",
        "hq",
        video_file,
    };

    return try std.process.spawn(
        io,
        .{
            .argv = &args,
            .stdin = .pipe,
        },
    );
}

// FIXME: this function crashes at exit, because of a use after free (???)
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
