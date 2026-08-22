const std   = @import("std");
const linux = std.os.linux;

const SOCK_NAME = "/copied.sock";

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

    fn read(self: *Reader, count: usize) ![]u8 {
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
            switch (std.posix.errno(read_res)) {
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
