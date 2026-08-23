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
            continue;
        }

        if (source != .none) {
            try log(io, "error: Too many things to copy");
            return error.InvalidArgument;
        }
        source = .{ .filename = arg };
    }

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

    if (source == .none) {
        try modeRead(io, sock, mime);
    }
    else {
        try modeWrite(io, sock, mime, source);
    }
}

fn modeRead(io: std.Io, sock: linux.fd_t, mime: []const u8) !void {
    const header: cmn.Header = .{
        .mode     = .read,
        .mime_len = mime.len,
    };
    const header_data = header.serialize();
    try cmn.writeAll(sock, &header_data);

    if (mime.len > 0) {
        try cmn.writeAll(sock, mime);
    }
    _ = cmn.call( linux.shutdown(sock, linux.SHUT.WR) ) orelse return error.NoShutdown;

    var buf: [cmn.BUF_SIZE]u8 = undefined;
    var reader: cmn.Reader = .{ .fd = sock, .read_buf = &buf };
    while (true) {
        const recv = reader.read(buf.len) catch |err| switch (err) {
            error.NoMore => break,
            else         => return err,
        };
        try stdout.writeStreamingAll(io, recv);
    }
}

fn modeWrite(io: std.Io, sock: linux.fd_t, mime: []const u8, source: Source) !void {
    var data_len: usize = 0;
    var file = stdin;
    switch (source) {
        .filename => |filepath| {
            file = try std.Io.Dir.cwd().openFile(io, filepath, .{});

            const stat = try file.stat(io);
            data_len = stat.size;
        },
        .stdin => {},
        .none  => unreachable,
    }
    defer file.close(io);

    const header: cmn.Header = .{
        .mode     = .write,
        .mime_len = mime.len,
        .data_len = data_len,
    };
    const header_data = header.serialize();
    try cmn.writeAll(sock, &header_data);

    if (mime.len > 0) {
        try cmn.writeAll(sock, mime);
    }

    var buf: [cmn.BUF_SIZE]u8 = undefined;
    while (true) {
        const send = try readFileChunk(io, file, &buf);
        try cmn.writeAll(sock, send);
        if (send.len < buf.len) break;
    }
}

fn readFileChunk(io: std.Io, file: std.Io.File, buf: []u8) ![]u8 {
    var i: usize = 0;
    while (true) {
        i += file.readStreaming(io, &.{buf[i..]}) catch |err| switch (err) {
            error.EndOfStream => return buf[0..i],
            else              => return err,
        };
        if (i == buf.len) return buf;
    }
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
