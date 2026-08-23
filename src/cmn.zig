const std   = @import("std");
const linux = std.os.linux;

pub const SOCK_NAME = "/copied.sock";
pub const BUF_SIZE  = 32 * 1024;

pub const CopyMode = enum { read, write };
pub const Header = struct {
    mode: CopyMode,
    mime_len: usize = 0,
    data_len: usize = 0,

    pub fn serialize(self: Header) [7]u8 {
        var res: [7]u8 = undefined;
        res[0] = @intFromEnum(self.mode);
        std.mem.writeInt(u16, res[1..3], @intCast(self.mime_len), .little);
        std.mem.writeInt(u32, res[3..7], @intCast(self.data_len), .little);
        return res;
    }

    pub fn deserialize(data: [7]u8) Header {
        return .{
            .mode = @enumFromInt(data[0]),
            .mime_len = std.mem.readInt(u16, data[1..3], .little),
            .data_len = std.mem.readInt(u32, data[3..7], .little),
        };
    }
};

pub const SockPath = struct {
    buf: [108]u8 = undefined,
    len: usize,
};

pub fn getSockPath(run_dir: []const u8) SockPath {
    var path: SockPath = .{ .len = run_dir.len + SOCK_NAME.len };

    @memcpy(path.buf[0           .. run_dir.len],   run_dir);
    @memcpy(path.buf[run_dir.len ..    path.len], SOCK_NAME);
    path.buf[path.len] = 0;

    return path;
}

pub const Reader = struct {
    eof:     bool = false,
    seek_i: usize = 0,
    read_i: usize = 0,

    read_buf: []u8,
    fd: linux.fd_t,

    pub fn readInto(self: *Reader, result: []u8) !void {
        var i: usize = 0;
        while (i < result.len) {
            const data = try self.read(result.len - i);
            const from = i;
            i += data.len;
            @memcpy(result[from..i], data);
        }
    }

    pub fn readRemainingAlloc(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        var res: std.ArrayList(u8) = .empty;
        errdefer res.deinit(allocator);

        while (true) {
            const add = self.read(self.read_buf.len) catch |err| switch (err) {
                error.NoMore => break,
                else         => return err,
            };
            try res.appendSlice(allocator, add);
        }

        return res.toOwnedSlice(allocator);
    }

    pub fn read(self: *Reader, count: usize) ![]u8 {
        if (self.seek_i >= self.read_i) try self.readFd();

        const from = self.seek_i;
        self.seek_i = @min(self.seek_i + count, self.read_i);
        return self.read_buf[from..self.seek_i];
    }

    fn readFd(self: *Reader) !void {
        if (self.eof) return error.NoMore;

        self.seek_i = 0;
        self.read_i = 0;
        while (self.read_i < self.read_buf.len) {
            const buf = self.read_buf[self.read_i..self.read_buf.len];

            const read_res = linux.read(self.fd, buf.ptr, buf.len);
            switch (linux.errno(read_res)) {
                .SUCCESS => {
                    if (read_res == 0) {
                        self.eof = true;
                        if (self.seek_i == self.read_i) {
                            return error.NoMore;
                        }
                        return;
                    }
                    self.read_i += read_res;
                },
                .AGAIN => return error.Timeout,
                .INTR  => continue,
                else   => |err| {
                    std.log.err("Failed to read fd: errno={}", .{err});
                    return error.UnexpectedErrno;
                },
            }
        }
    }
};

pub fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const buf = bytes[i..];
        const write_res = linux.write(fd, buf.ptr, buf.len);
        switch (linux.errno(write_res)) {
            .SUCCESS => i += write_res,
            .INTR    => continue,
            else     => return error.NoWrite,
        }
    }
}

pub fn call(res: usize) ?usize {
    if (linux.errno(res) != .SUCCESS) return null;
    return res;
}
