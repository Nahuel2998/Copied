const std   = @import("std");
const linux = std.os.linux;

const cmn = @import("cmn.zig");
const Clipboard = @import("lib");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.Expected => std.process.exit(1),
        else           => return err,
    };
}

fn run(init: std.process.Init) !void {
    var cb = Clipboard.init(init.gpa) catch |err| {
        switch (err) {
            error.NoDisplay => std.log.err("Failed to open display", .{}),
            error.NoScreen  => std.log.err("Failed to get screen", .{}),
            error.NoWindow  => std.log.err("Failed to create window", .{}),
            error.NoAtom    => std.log.err("Failed to intern initial atoms", .{}),
            else            => return err,
        }
        return error.Expected;
    };
    defer cb.deinit();

    const run_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse {
        std.log.err("XDG_RUNTIME_DIR isn't set", .{});
        return error.Expected;
    };
    const path = cmn.getSockPath(run_dir);

    const cli_fd = createSock(path.buf, path.len) catch |err| {
        switch (err) {
            error.NoSock   => std.log.err("Failed to create sock", .{}),
            error.NoBind   => std.log.err("Failed to bind sock", .{}),
            error.NoListen => std.log.err("Failed to start listening to sock", .{}),
        }
        return error.Expected;
    };
    defer {
        _ = linux.close(cli_fd);
        _ = linux.unlink(path.buf[0..path.len:0]);
    }
    const x_fd = cb.getXFileDescriptor();

    // Look I'd want to use the shiny new Io interface, but I can't .poll() otherwise
    var fds = [_]std.posix.pollfd{
        .{ .fd =   x_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = cli_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        _ = try std.posix.poll(&fds, -1);

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            cb.drainXEvents();
        }
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            handleCliConnect(init.gpa, cli_fd, &cb);
        }
    }
}

fn handleCliConnect(allocator: std.mem.Allocator, sock: linux.fd_t, cb: *Clipboard) void {
    _ = cb;
    // TODO: recv timeout?
    const client: linux.fd_t = @intCast(call( linux.accept(sock, null, null) ) orelse return);
    defer _ = linux.close(client);

    //      |data_len
    //   |mime_len
    // |mode (0 => read; 1 => write)
    // |x|xx|xxxx|<mime>|<data>|
    var header: [7]u8 = undefined;

    var buf:      [4096]u8 = undefined;
    var reader: cmn.Reader = .{ .fd = client, .read_buf = &buf };

    reader.readInto(&header) catch {
        std.log.err("Failed to read header from client request", .{});
        return;
    };
    const mime_len = std.mem.readInt(u16, header[1..3], .little);
    const data_len = std.mem.readInt(u32, header[3..7], .little);
    const  res_buf = allocator.alloc(u8, mime_len + data_len) catch {
        std.log.err("Failed to alloc memory for client request", .{});
        return;
    };
    defer allocator.free(res_buf);

    const mime = res_buf[0..mime_len];
    reader.readInto(mime) catch {
        std.log.err("Failed to read mimetype from client request", .{});
        return;
    };

    switch (header[0]) {
        0 => {
            // TODO: ...
        },
        1 => {
            const data = res_buf[mime_len..];
            reader.readInto(data) catch {
                std.log.err("Failed to read data from client request", .{});
                return;
            };
            // TODO: ...
        },
        else => |mode| {
            std.log.err("Received bogus data: mode={} is not valid", .{mode});
            return;
        },
    }
}

fn call(res: usize) ?usize {
    if (std.posix.errno(res) != .SUCCESS) return null;
    return res;
}

fn createSock(path: [108]u8, path_len: usize) !linux.fd_t {
    const sock: linux.fd_t = @intCast(call( linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) ) orelse return error.NoSock);
    errdefer _ = linux.close(sock);

    const addr: std.posix.sockaddr.un = .{ .path = path };
    const addr_len: u32 = @intCast( @offsetOf(std.posix.sockaddr.un, "path") + path_len + 1 );

    _ = call( linux.bind(sock, @ptrCast(&addr), addr_len) ) orelse return error.NoBind;
    _ = call( linux.listen(sock, 1) )                       orelse return error.NoListen;
    return sock;
}
