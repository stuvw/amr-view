const std = @import("std");

pub fn roundEven(n: usize) usize {
    return (std.math.maxInt(usize) - 1) & n;
}

pub fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}
