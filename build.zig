const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.path("./vulkan-zig/vk.xml"),
    }).module("vulkan-zig");

    const args = b.dependency("args", .{
        .target = target,
        .optimize = optimize,
    }).module("args");

    const exe = b.addExecutable(
        .{
            .name = "amr-view",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .link_libc = true,
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{
                        .name = "vulkan",
                        .module = vulkan,
                    },
                    .{
                        .name = "args",
                        .module = args,
                    },
                },
            }),
        },
    );

    b.installArtifact(exe);

    const exe_run_cmd = b.addRunArtifact(exe);
    exe_run_cmd.step.dependOn(b.getInstallStep());

    const exe_run_step = b.step("run", "Run the executable");
    exe_run_step.dependOn(&exe_run_cmd.step);
}
