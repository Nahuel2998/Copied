const std   = @import("std");
const linux = std.os.linux;

const cmn = @import("cmn.zig");

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
    std.debug.print("{s}\n", .{mime});

    const run_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse {
        try log(io, "error: XDG_RUNTIME_DIR isn't set");
        return error.Expected;
    };
    const path = cmn.getSockPath(run_dir);

    const sock = createSock(path.buf, path.len) catch |err| {
        switch (err) {
            error.NoSock    => try log(io, "error: Failed to create sock"),
            error.NoConnect => try log(io, "error: Failed to connect to sock"),
        }
        return error.Expected;
    };
    defer _ = linux.close(sock);
}

fn log(io: std.Io, comptime message: []const u8) !void {
    try stderr.writeStreamingAll(io, message ++ "\n");
}

fn createSock(path: [108]u8, path_len: usize) !linux.fd_t {
    const sock: linux.fd_t = @intCast(cmn.call( linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) ) orelse return error.NoSock);
    errdefer _ = linux.close(sock);

    const addr: std.posix.sockaddr.un = .{ .path = path };
    const addr_len: u32 = @intCast( @offsetOf(std.posix.sockaddr.un, "path") + path_len + 1 );

    _ = cmn.call( linux.connect(sock, @ptrCast(&addr), addr_len) ) orelse return error.NoConnect;
    return sock;
}
