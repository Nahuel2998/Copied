const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xcb = b.addTranslateC(.{
        .root_source_file = b.path("src/xcb.h"),
        .target           = target,
        .optimize         = optimize,
    });
    xcb.linkSystemLibrary("xcb", .{});

    const x11 = b.createModule(.{
        .root_source_file = b.path("src/x11.zig"),
        .target           = target,
        .optimize         = optimize,
        .imports          = &.{
            .{ .name = "xcb", .module = xcb.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "Copied",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target           = target,
            .optimize         = optimize,
            .imports          = &.{
                .{ .name = "x11", .module = x11 },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const x11_tests = b.addTest(.{
        .root_module = x11,
    });
    const run_x11_tests = b.addRunArtifact(x11_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_x11_tests.step);
}
