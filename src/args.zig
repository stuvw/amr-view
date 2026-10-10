const std = @import("std");
const args = @import("args");

const Video = @import("./video.zig");
const Pipeline = @import("./pipeline.zig");
const Math = @import("./math.zig");

pub fn getParser(allocator: std.mem.Allocator) !args.ArgumentParser {
    return try args.ArgumentParser.init(allocator, .{
        .name = "amr-view",
        .version = "0.4.0",
        .description = "A Zig and Vulkan based AMR dataset visualizer.",
    });
}

pub fn setupArgs(parser: *args.ArgumentParser) !void {
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
        .choices = &.{ "none", "vulkan", "nvenc", "amf", "qsv", "vtb" },
        .default = "none",
        .value_type = .choice,
    });

    try parser.addOption("mode", .{
        .help = "Rendering mode",
        .choices = &.{ "normal", "vr180", "vr360" },
        .default = "normal",
        .value_type = .choice,
    });
}

pub fn parseArgs(parser: *args.ArgumentParser, init: std.process.Init) !args.ParseResult {
    return try parser.parseProcess(init);
}

pub fn getArgs(result: args.ParseResult) !struct {
    data_file: []const u8,
    path_file: []const u8,
    cmap_file: []const u8,
    video_file: []const u8,

    frame_width: usize,
    frame_height: usize,

    fov: f32,
    framerate: usize,

    min_val: f32,
    max_val: f32,

    under_color: [4]f32,
    over_color: [4]f32,
    bad_color: [4]f32,

    root_pos: [3]f32,
    root_size: f32,

    encoder: Video.Encoder,
    hwaccel: Video.HWAccel,

    mode: Pipeline.Mode,
} {
    return .{
        .data_file = result.getString("data-file").?,
        .path_file = result.getString("path-file").?,
        .cmap_file = result.getString("colormap-file").?,
        .video_file = result.getOrString("video-file", "video.mp4"),

        .frame_width = Math.roundEven(result.getOrUint("width", 1920)),
        .frame_height = Math.roundEven(result.getOrUint("height", 1080)),
        .fov = @floatCast(result.getOrFloat("fov", 60)),
        .framerate = result.getOrUint("framerate", 30),

        .min_val = @floatCast(result.getOrFloat("min-val", -3.0)),
        .max_val = @floatCast(result.getOrFloat("max-val", 3.0)),

        .under_color = try parseArray(result.getArray("under-color"), 4, .{ 0.0, 0.0, 0.0, 1.0 }),
        .over_color = try parseArray(result.getArray("over-color"), 4, .{ 1.0, 1.0, 1.0, 1.0 }),
        .bad_color = try parseArray(result.getArray("bad-color"), 4, .{ 0.0, 0.0, 0.0, 0.0 }),

        .root_pos = try parseArray(result.getArray("root-pos"), 3, .{ 0.0, 0.0, 0.0 }),
        .root_size = @floatCast(result.getOrFloat("root-size", 1.0)),

        .encoder = result.getEnum(Video.Encoder, "encoder") orelse .x264,
        .hwaccel = result.getEnum(Video.HWAccel, "hwaccel") orelse .none,

        .mode = result.getEnum(Pipeline.Mode, "mode") orelse .normal,
    };
}

fn parseArray(arr: ?[]const []const u8, comptime size: comptime_int, comptime default: [size]f32) ![size]f32 {
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
