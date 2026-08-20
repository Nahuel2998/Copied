const std = @import("std");
const X11 = @import("x11");

const stdin  = std.Io.File.stdin();
const stdout = std.Io.File.stdout();
const stderr = std.Io.File.stderr();

const Source = union(enum) {
    filename: []const u8,
    stdin,
    none,
};

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.Expected        => std.process.exit(1),
        error.InvalidArgument => std.process.exit(2),
        else                  => return err,
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next(); // program name

    var source: Source = .none;
    if (!try stdin.isTty(io)) {
        source = .stdin;
    }

    var mime: []const u8 = &.{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try log(io, "--help");
            return;
        }

        if (std.mem.eql(u8, arg, "-t")) {
            mime = args.next() orelse {
                try log(io, "usage(arg): -t <mime_type>");
                return error.InvalidArgument;
            };
        }

        if (source != .none) {
            try log(io, "error: Too many things to copy");
            return error.InvalidArgument;
        }
        source = .{ .filename = arg };
    }

    var x = X11.init(init.gpa) catch |err| {
        switch (err) {
            error.NoDisplay => try log(io, "error: Failed to open display"),
            error.NoScreen  => try log(io, "error: Failed to get screen"),
            error.NoWindow  => try log(io, "error: Failed to create window"),
            error.NoAtom    => try log(io, "error: Failed to intern initial atoms"),
            else            => {},
        }
        return error.Expected;
    };
    defer x.deinit();

    std.debug.print("{s}\n", .{mime});
}

fn log(io: std.Io, comptime message: []const u8) !void {
    try stderr.writeStreamingAll(io, message ++ "\n");
}
