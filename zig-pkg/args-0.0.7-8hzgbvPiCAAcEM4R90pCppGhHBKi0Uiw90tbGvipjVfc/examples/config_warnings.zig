//! Demonstration of configuration warnings, validation, and auto-resolving in args.zig.
//! Run with: zig build run-config_warnings

const std = @import("std");
const args = @import("args");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    // Create a configuration that contains multiple conflicting combinations:
    // 1. permissive mode + exit_on_error (useless exit_on_error)
    // 2. use_colors + silent_errors (wasted ANSI codes)
    // 3. suggest_closest + max_distance=0 (no suggestions will be shown)
    const cfg = args.Config{
        .parsing_mode = .permissive,
        .exit_on_error = true,
        .use_colors = true,
        .silent_errors = true,
        .suggest_closest = true,
        .suggestion_max_distance = 0,
    };

    _ = init;
    var ap = try args.ArgumentParser.init(allocator, .{ .name = "config-warnings-demo", .config = cfg });
    defer ap.deinit();

    // 1. Get and display configuration warnings
    var warn_buf: [16]args.config.ConfigWarning = undefined;
    const count = ap.getConfigWarnings(&warn_buf);

    std.debug.print("Detected {d} configuration conflicts:\n", .{count});
    for (warn_buf[0..count], 1..) |warn, idx| {
        std.debug.print("{d}. [{s}] {s}\n", .{ idx, warn.field, warn.message });
    }

    std.debug.print("\nAuto-resolving conflicts...\n", .{});

    // 2. Resolve the conflicts automatically
    ap.configureAutoResolve();

    // Show resolved configuration fields
    std.debug.print("Resolved Config:\n", .{});
    std.debug.print("  - exit_on_error:            {}\n", .{ap.cfg.exit_on_error});
    std.debug.print("  - use_colors:               {}\n", .{ap.cfg.use_colors});
    std.debug.print("  - suggestion_max_distance:  {d}\n", .{ap.cfg.suggestion_max_distance});
}
