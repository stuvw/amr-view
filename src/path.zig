const std = @import("std");
const Io = std.Io;

fn parseLine(line: []const u8) ![9]f32 {
    var ret: [9]f32 = undefined;

    var num_vals: usize = 0;
    var vals = std.mem.splitScalar(u8, line, ' ');

    while (vals.next()) |val| : (num_vals += 1) {
        ret[num_vals] = try std.fmt.parseFloat(f32, val);
    }

    if (num_vals != 9) {
        return error.InvalidData;
    }

    return ret;
}

pub fn load(cam_file: []const u8, io: Io, allocator: std.mem.Allocator) ![][9]f32 {
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(
        io,
        cam_file,
        .{},
    );
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const stat = try reader.file.stat(io);
    const size = stat.size;

    const raw = try allocator.alloc(u8, size);
    defer allocator.free(raw);

    try reader.interface.readSliceAll(raw);

    const line_count = std.mem.count(u8, raw, "\n");

    const path = try allocator.alloc([9]f32, line_count);

    var idx: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');

    while (lines.next()) |line| : (idx += 1) {
        path[idx] = try parseLine(line);
    }

    return path;
}
