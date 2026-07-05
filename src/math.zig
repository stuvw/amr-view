const std = @import("std");

pub fn norm(vec: [3]f32) f32 {
    return std.math.sqrt(
        vec[0] * vec[0] + vec[1] * vec[1] + vec[2] * vec[2],
    );
}

pub fn normalize(vec: [3]f32) [3]f32 {
    const n = norm(vec);

    if (n > 0.0) {
        return .{
            vec[0] / n,
            vec[1] / n,
            vec[2] / n,
        };
    } else {
        return vec;
    }
}

pub fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}
