const std   = @import("std");
const linux = std.os.linux;

const opt = @import("opt");
const cmn = @import("cmn.zig");
const Clipboard = @import("lib");

const ipc_log = std.log.scoped(.ipc);
const IpcSock = struct {
    fd:   std.posix.fd_t,
    path: cmn.SockPath,
};

var sig_pipe: [2]std.posix.fd_t = undefined;
fn handleSigterm(_: linux.SIG) callconv(.c) void {
    _ = linux.write(sig_pipe[1], "please die", 1);
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.Expected => std.process.exit(1),
        else           => return err,
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;

    var cb = Clipboard.init(allocator) catch |err| {
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

    const ipc_sock: ?IpcSock = if (opt.ipc_sock) blk: {
        const run_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse {
            ipc_log.err("XDG_RUNTIME_DIR isn't set", .{});
            return error.Expected;
        };
        const path = cmn.getSockPath(run_dir);

        const fd = createSock(path.buf, path.len) catch |err| {
            switch (err) {
                error.NoSock   => ipc_log.err("Failed to create sock", .{}),
                error.NoBind   => ipc_log.err("Failed to bind sock", .{}),
                error.NoListen => ipc_log.err("Failed to start listening to sock", .{}),
            }
            return error.Expected;
        };

        break :blk .{ .fd = fd, .path = path };
    } else null;
    defer if (ipc_sock) |ipc| {
        _ = linux.close(ipc.fd);
        _ = linux.unlink(ipc.path.buf[0..ipc.path.len:0]);
    };
    const x_fd = cb.getXFileDescriptor();

    _ = cmn.call( linux.pipe(&sig_pipe) ) orelse {
        std.log.err("Failed to create signal pipe", .{});
        return error.Expected;
    };
    defer {
        _ = linux.close(sig_pipe[0]);
        _ = linux.close(sig_pipe[1]);
    }

    const sigact = linux.Sigaction{
        .handler = .{ .handler = handleSigterm },
        .mask    = linux.sigemptyset(),
        .flags   = 0,
    };
    _ = cmn.call( linux.sigaction(.INT, &sigact, null) ) orelse {
        std.log.err("Failed to setup signal handler", .{});
        return error.Expected;
    };

    // FIXME: I'd want to use the shiny new Io interface, but I can't .poll() otherwise
    var fds_buf = [_]std.posix.pollfd{
        .{ .fd = sig_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd =        x_fd, .events = std.posix.POLL.IN, .revents = 0 },
        undefined,
    };
    var fds: []std.posix.pollfd = fds_buf[0..2];
    if (ipc_sock) |ipc| {
        fds = fds_buf[0..3];
        fds[2] = .{ .fd = ipc.fd, .events = std.posix.POLL.IN, .revents = 0 };
    }

    while (true) {
        _ = try std.posix.poll(fds, -1);

        if (fds[0].revents & std.posix.POLL.IN != 0) break;
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            _ = cb.drainXEvents();
        }
        if (ipc_sock) |ipc| {
            if (fds[2].revents & std.posix.POLL.IN != 0) {
                handleIpcConnect(allocator, ipc.fd, &cb);
            }
        }
    }
}

fn handleIpcConnect(allocator: std.mem.Allocator, sock: linux.fd_t, cb: *Clipboard) void {
    // TODO: recv timeout?
    const client: linux.fd_t = @intCast(cmn.call( linux.accept(sock, null, null) ) orelse return);
    defer _ = linux.close(client);

    var buf: [cmn.BUF_SIZE]u8 = undefined;
    var reader:    cmn.Reader = .{ .fd = client, .read_buf = &buf };

    // |mode (0 => read; 1 => write)
    // |x|mime_len
    // |x|xx|data_len? (optional; if zero, reading will still be attempted)
    // |x|xx|xxxx|<mime>|<data>|
    var header_buf: [7]u8 = undefined;
    reader.readInto(&header_buf) catch |err| {
        ipc_log.err("Failed to read header from request: {}", .{err});
        return;
    };
    const header = cmn.Header.deserialize(header_buf);

    const res_buf = allocator.alloc(u8, header.mime_len + header.data_len) catch {
        ipc_log.err("Failed to alloc memory for request", .{});
        return;
    };
    defer allocator.free(res_buf);

    const mime = res_buf[0..header.mime_len];
    reader.readInto(mime) catch |err| {
        ipc_log.err("Failed to read mimetype from request: {}", .{err});
        return;
    };

    switch (header.mode) {
        .read => {
            const mime_atom = if (mime.len == 0) null else cb.atoms.getIntern(mime) catch return;
            var   data      = cb.paste(sock, mime_atom) orelse return;
            if (mime_atom == cb.atoms.get("TARGETS").?) {
                var targets_buf: [1024]u8 = undefined;
                data = cb.translateTargetsList(data, &targets_buf) catch |err| {
                    ipc_log.err("Failed to get atom names building TARGETS response: {}", .{err});
                    return;
                };
            }
            else if (mime_atom == cb.atoms.get("TIMESTAMP").?) {
                var timestamp_buf: [16]u8 = undefined;
                const timestamp = std.mem.readInt(u32, data[0..4], .native);
                data = std.fmt.bufPrint(&timestamp_buf, "{}\n", .{timestamp}) catch unreachable;
            }
            cmn.writeAll(client, data) catch |err| {
                ipc_log.err("Failed to send data: {}", .{err});
                return;
            };
        },
        .write => {
            var data: []u8 = undefined;
            if (header.data_len > 0) {
                data = res_buf[header.mime_len..];
                reader.readInto(data) catch |err| {
                    ipc_log.err("Failed to read data from request: {}", .{err});
                    return;
                };
            }
            else {
                data = reader.readRemainingAlloc(allocator) catch |err| {
                    ipc_log.err("Failed to read data from request: {}", .{err});
                    return;
                };
            }
            defer if (header.data_len == 0) allocator.free(data);

            const mime_str  = if (mime.len != 0) mime else "UTF8_STRING";
            const mime_atom = cb.atoms.getIntern(mime_str) catch |err| {
                ipc_log.err("Failed to save data (mime): {}", .{err});
                return;
            };
            cb.copy(mime_atom, data) catch |err| switch (err) {
                error.NotSavingMeta => ipc_log.warn("Refusing to save meta target: {s}", .{mime_str}),
                else                => ipc_log.err("Failed to save data: {}", .{err}),
            };
        },
    }
}

fn createSock(path: [108]u8, path_len: usize) !linux.fd_t {
    const sock: linux.fd_t = @intCast(cmn.call( linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) ) orelse return error.NoSock);
    errdefer _ = linux.close(sock);

    const addr: std.posix.sockaddr.un = .{ .path = path };
    const addr_len: u32 = @intCast( @offsetOf(std.posix.sockaddr.un, "path") + path_len + 1 );

    _ = linux.unlink(path[0..path_len:0]);
    _ = cmn.call( linux.bind(sock, @ptrCast(&addr), addr_len) ) orelse return error.NoBind;
    _ = cmn.call( linux.listen(sock, 1) )                       orelse return error.NoListen;
    return sock;
}
