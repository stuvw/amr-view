const std = @import("std");
const args = @import("args");

pub fn parseArgs(parser: *args.ArgumentParser, init: std.process.Init) !args.ParseResult {
    try parser.addFileOption("colormap-file", .{
        .help = "Input colormap file",
        .required = true,
        .must_exist = true,
    });

    try parser.addFileOption("path-file", .{
        .help = "Input camera path file",
        .required = true,
        .must_exist = true,
    });

    try parser.addFileOption("data-file", .{
        .help = "Input simulation data file",
        .required = true,
        .must_exist = true,
    });

    try parser.addFileOption("video-file", .{
        .help = "Output video file",
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

    try parser.addOption("fov", .{
        .help = "Output video FOV",
        .value_type = .float,
        .default = "60",
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

    try parser.addListOption("over-color", .{
        .help = "RGBA color used when value the oveflows --max-val",
        .default = "1.0,1.0,1.0,1.0",
    });

    try parser.addListOption("under-color", .{
        .help = "RGBA color used when the value underflows --min-val",
        .default = "0.0,0.0,0.0,1.0",
    });

    try parser.addListOption("bad-color", .{
        .help = "RGBA color used when a rendering error occurs",
        .default = "0.0,0.0,0.0,0.0",
    });

    try parser.addOption("root-size", .{
        .help = "Size of the root node of the SVO",
        .value_type = .float,
        .default = "1.0",
    });

    try parser.addListOption("root-pos", .{
        .help = "Center position of the root node of the SVO",
        .default = "0.0,0.0,0.0",
    });

    try parser.addOption("encoder", .{
        .help = "Select video encoder. See README for more details",
        .choices = &.{ "x264", "x265", "av1" },
        .default = "x264",
        .value_type = .choice,
    });

    try parser.addOption("hwaccel", .{
        .help = "Select hardware acceleration. See README for more details",
        .choices = &.{ "none", "nvenc", "amf", "qsv" },
        .default = "none",
        .value_type = .choice,
    });

    return try parser.parseProcess(init);
}

pub fn parseArray(arr: ?[]const []const u8, comptime size: comptime_int, comptime default: [size]f32) ![size]f32 {
    if (arr) |a| {
        if (a.len != size) {
            return error.InvalidSize;
        }
        var ret: [size]f32 = undefined;

        for (0..size) |i| {
            ret[i] = try std.fmt.parseFloat(f32, a[i]);
        }

        return ret;
    } else {
        return default;
    }
}
