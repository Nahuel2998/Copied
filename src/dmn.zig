const std   = @import("std");
const linux = std.os.linux;

const Clipboard = @import("lib");
const SOCK_NAME = "/copied.sock";

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

    var   path: [108]u8 = undefined;
    const run_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse {
        std.log.err("XDG_RUNTIME_DIR isn't set", .{});
        return error.Expected;
    };
    const path_len = run_dir.len + SOCK_NAME.len;
    @memcpy(path[0           .. run_dir.len],   run_dir);
    @memcpy(path[run_dir.len ..    path_len], SOCK_NAME);
    path[path_len] = 0;

    const cli_fd = createSock(path, path_len) catch |err| {
        switch (err) {
            error.NoSock   => std.log.err("Failed to create sock", .{}),
            error.NoBind   => std.log.err("Failed to bind sock", .{}),
            error.NoListen => std.log.err("Failed to start listening to sock", .{}),
        }
        return error.Expected;
    };
    defer {
        _ = linux.close(cli_fd);
        _ = linux.unlink(path[0..path_len:0]);
    }
    const x_fd = cb.getXFileDescriptor();

    if (true) return;

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
            // TODO: Handle cli connection
        }
    }
}

fn createSock(path: [108]u8, path_len: usize) !linux.fd_t {
    const sock_res = linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(sock_res) != .SUCCESS) {
        return error.NoSock;
    }
    const sock: linux.fd_t = @intCast(sock_res);
    errdefer _ = linux.close(sock);

    const addr: std.posix.sockaddr.un = .{ .path = path };
    const addr_len: u32 = @intCast( @offsetOf(std.posix.sockaddr.un, "path") + path_len + 1 );

    const bind_res = linux.bind(sock, @ptrCast(&addr), addr_len);
    if (std.posix.errno(bind_res) != .SUCCESS) {
        return error.NoBind;
    }

    const listen_res = linux.listen(sock, 1);
    if (std.posix.errno(listen_res) != .SUCCESS) {
        return error.NoListen;
    }

    return sock;
}
