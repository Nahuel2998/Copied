const std = @import("std");

const BuildContext = struct {
    b:       *std.Build,
    target:   std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const ctx: BuildContext = .{
        .b        = b,
        .target   = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const xcb = buildXcb(ctx);
    const lib = buildLib(ctx, &.{
        .{ .name = "xcb", .module = xcb },
    });

    buildCli(ctx, &.{
        .{ .name = "lib", .module = lib },
    });
    buildDaemon(ctx, &.{
        .{ .name = "lib", .module = lib },
    });
}

fn buildXcb(ctx: BuildContext) *std.Build.Module {
    const b = ctx.b;

    const xcb = b.addTranslateC(.{
        .root_source_file = b.path("src/xcb.h"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
    });
    xcb.linkSystemLibrary("xcb", .{});

    return xcb.createModule();
}

fn buildLib(ctx: BuildContext, imports: []const std.Build.Module.Import) *std.Build.Module {
    const b = ctx.b;

    const lib = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
        .imports          = imports,
    });

    const tests = b.addTest(.{
        .root_module = lib,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test_lib", "Run lib tests");
    test_step.dependOn(&run_tests.step);

    return lib;
}

fn buildCli(ctx: BuildContext, imports: []const std.Build.Module.Import) void {
    const b = ctx.b;

    const exe = b.addExecutable(.{
        .name = "copied",
        .root_module = ctx.b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target           = ctx.target,
            .optimize         = ctx.optimize,
            .imports          = imports,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run_cli", "Run CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test_cli", "Run CLI tests");
    test_step.dependOn(&run_tests.step);
}

fn buildDaemon(ctx: BuildContext, imports: []const std.Build.Module.Import) void {
    const b = ctx.b;

    const exe = b.addExecutable(.{
        .name = "copiedd",
        .root_module = ctx.b.createModule(.{
            .root_source_file = b.path("src/dmn.zig"),
            .target           = ctx.target,
            .optimize         = ctx.optimize,
            .imports          = imports,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run_daemon", "Run daemon");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test_daemon", "Run daemon tests");
    test_step.dependOn(&run_tests.step);
}
