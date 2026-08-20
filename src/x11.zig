const std = @import("std");
const c   = @import("xcb");

const Self = @This();

conn:   *c.xcb_connection_t,
screen: *c.xcb_screen_t,
window:  c.xcb_window_t,

atoms:     AtomStash,
clipboard: []const u8 = &.{},

allocator: std.mem.Allocator,

fn xcbConnect(pref_screen: ?*c_int) ?*c.xcb_connection_t {
    const conn = c.xcb_connect(null, pref_screen) orelse return null;
    errdefer c.xcb_disconnect(conn);
    if (c.xcb_connection_has_error(conn) != 0) {
        return null;
    }
    return conn;
}

pub fn init(allocator: std.mem.Allocator) !Self {
    var pref_screen: c_int = undefined;
    const conn = xcbConnect(&pref_screen) orelse return error.NoDisplay;

    const screen: *c.xcb_screen_t = blk: {
        const setup = c.xcb_get_setup(conn);
        var   iter  = c.xcb_setup_roots_iterator(setup);
        for (0..@intCast(pref_screen)) |_| {
            if (iter.rem == 0) return error.NoScreen;
            c.xcb_screen_next(&iter);
        }
        break :blk iter.data;
    };

    const evmask = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    const window = c.xcb_generate_id(conn);
    const cookie = c.xcb_create_window_checked(
        conn,
        c.XCB_COPY_FROM_PARENT,
        window,
        screen.root,
        0, 0, 1, 1, 0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        c.XCB_CW_EVENT_MASK, &evmask,
    );
    const err = c.xcb_request_check(conn, cookie);
    if (err != null) {
        std.c.free(err);
        return error.NoWindow;
    }

    var atoms: AtomStash = .init(conn, allocator);
    _ = try atoms.intern(3, .{"TARGETS", "INCR", "UTF8_STRING"});

    return .{
        .conn   = conn,
        .screen = screen,
        .window = window,
        .atoms  = atoms,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.atoms.deinit();
    self.allocator.free(self.clipboard);
    c.xcb_disconnect(self.conn);
    self.* = undefined;
}

const AtomStash = struct {
    conn:      *c.xcb_connection_t,
    cache:     std.StringHashMapUnmanaged(c.xcb_atom_t) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(conn: *c.xcb_connection_t, allocator: std.mem.Allocator) AtomStash {
        return .{
            .conn      = conn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AtomStash) void {
        self.cache.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *AtomStash, name: []const u8) !c.xcb_atom_t {
        const entry = try self.cache.getOrPut(self.allocator, name);
        if (entry.found_existing) {
            return entry.value_ptr.*;
        }

        const res = try self.intern(1, .{ name });
        return res[0];
    }

    pub fn intern(self: *AtomStash, comptime count: usize, names: [count][]const u8) ![count]c.xcb_atom_t {
        var results: [count]c.xcb_atom_t               = undefined;
        var cookies: [count]c.xcb_intern_atom_cookie_t = undefined;
        for (names, &cookies) |name, *cookie| {
            cookie.* = c.xcb_intern_atom(self.conn, 0, @intCast(name.len), name.ptr);
        }
        for (names, cookies, &results) |name, cookie, *res| {
            const reply = c.xcb_intern_atom_reply(self.conn, cookie, null) orelse return error.NoAtom;
            defer std.c.free(reply);

            const atom = reply.*.atom;
            try self.cache.put(self.allocator, name, atom);
            res.* = atom;
        }
        return results;
    }
};

test "atom caching" {
    const conn = xcbConnect(null).?;

    var atoms = AtomStash.init(conn, std.testing.allocator);
    defer atoms.deinit();

    const name = "image/png";
    _ = try atoms.get(name);
    try std.testing.expect(atoms.cache.get(name) != null);
}
