const std = @import("std");
const c   = @import("xcb");

const Self = @This();

conn:   *c.xcb_connection_t,
screen: *c.xcb_screen_t,
window:  c.xcb_window_t,

atoms:     AtomStash,
clipboard: ClipboardData,

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
    const common_atoms = [_][]const u8{"TIMESTAMP", "TARGETS", "INCR", "UTF8_STRING", "STRING", "text/uri-list"};
    _ = try atoms.intern(common_atoms.len, common_atoms);

    return .{
        .conn   = conn,
        .screen = screen,
        .window = window,
        .atoms  = atoms,
        .clipboard = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.atoms.deinit();
    self.clipboard.deinit();
    c.xcb_disconnect(self.conn);
    self.* = undefined;
}

pub fn copy(self: *Self, mime: c.xcb_atom_t, data: []const u8) !void {
    self.clipboard.reset();
    _ = try self.clipboard.saveCopy(mime, data);
}

pub fn paste(self: Self, mime: ?c.xcb_atom_t) ?[]const u8 {
    return self.clipboard.get(mime);
}

pub fn getXFileDescriptor(self: Self) std.posix.fd_t {
    return c.xcb_get_file_descriptor(self.conn);
}

pub fn drainXEvents(self: *Self) void {
    while (c.xcb_poll_for_event(self.conn)) |event| {
        defer std.c.free(event);
        self.handleXEvent(event);
    }
}

fn handleXEvent(self: *Self, event: *c.xcb_generic_event_t) void {
    _ = self;
    _ = event;
}

const AtomStash = struct {
    conn:        *c.xcb_connection_t,
    allocator:   std.mem.Allocator,
    names_arena: std.heap.ArenaAllocator,

    cache: std.StringHashMapUnmanaged(c.xcb_atom_t)           = .empty,
    ehcac: std.AutoHashMapUnmanaged(c.xcb_atom_t, []const u8) = .empty,

    pub fn init(conn: *c.xcb_connection_t, allocator: std.mem.Allocator) AtomStash {
        return .{
            .conn        = conn,
            .allocator   = allocator,
            .names_arena = .init(allocator),
        };
    }

    pub fn deinit(self: *AtomStash) void {
        self.cache.deinit(self.allocator);
        self.ehcac.deinit(self.allocator);
        self.names_arena.deinit();
        self.* = undefined;
    }

    pub fn getNoIntern(self: AtomStash, name: []const u8) ?c.xcb_atom_t {
        return self.cache.get(name);
    }

    pub fn get(self: *AtomStash, name: []const u8) !c.xcb_atom_t {
        if (self.getNoIntern(name)) |atom| return atom;

        const res = try self.intern(1, .{ name });
        return res[0];
    }

    pub fn getName(self: *AtomStash, atom: c.xcb_atom_t) ![]const u8 {
        if (self.ehcac.get(atom)) |name| return name;

        var res: [1][]const u8 = undefined;
        try self.getNames(&.{atom}, &res);
        return res[0];
    }

    pub fn intern(self: *AtomStash, comptime count: usize, names: [count][]const u8) ![count]c.xcb_atom_t {
        var results: [count]c.xcb_atom_t               = undefined;
        var cookies: [count]c.xcb_intern_atom_cookie_t = undefined;
        for (names, &cookies) |name, *cookie| {
            cookie.* = c.xcb_intern_atom(self.conn, 0, @intCast(name.len), name.ptr);
        }

        var i: usize = 0;
        errdefer for (cookies[i..]) |cookie| {
            const reply = c.xcb_intern_atom_reply(self.conn, cookie, null) orelse continue;
            defer std.c.free(reply);
        };
        while (i < cookies.len) : (i += 1) {
            const name   = names[i];
            const cookie = cookies[i];

            const reply = c.xcb_intern_atom_reply(self.conn, cookie, null) orelse return error.NoAtom;
            defer std.c.free(reply);

            const name_owned = try self.names_arena.allocator().dupe(u8, name);
            const atom       = reply.*.atom;
            try self.cache.put(self.allocator, name_owned, atom);
            try self.ehcac.put(self.allocator, atom, name_owned);
            results[i] = atom;
        }
        return results;
    }

    pub fn getNames(self: *AtomStash, atoms: []const c.xcb_atom_t, results: [][]const u8) !void {
        std.debug.assert(atoms.len == results.len);

        const Missing = struct {
            index:    usize,
            cookie:   c.xcb_get_atom_name_cookie_t,

            fn resolveBatch(stash: *AtomStash, missing: []@This(), m_atoms: []const c.xcb_atom_t, m_results: [][]const u8) !void {
                var i: usize = 0;
                errdefer for (missing[i..]) |entry| {
                    const reply = c.xcb_get_atom_name_reply(stash.conn, entry.cookie, null) orelse continue;
                    std.c.free(reply);
                };
                while (i < missing.len) : (i += 1) {
                    const entry = missing[i];

                    const reply = c.xcb_get_atom_name_reply(stash.conn, entry.cookie, null) orelse return error.NoAtom;
                    defer std.c.free(reply);

                    const name = c.xcb_get_atom_name_name(reply);
                    const len  = c.xcb_get_atom_name_name_length(reply);
                    const atom = m_atoms[entry.index];

                    const name_owned = try stash.names_arena.allocator().dupe(u8, name[0..@intCast(len)]);
                    try stash.cache.put(stash.allocator, name_owned, atom);
                    try stash.ehcac.put(stash.allocator, atom, name_owned);
                    m_results[entry.index] = name_owned;
                }
            }
        };

        const BATCH_SIZE = 32;
        var batch_buf:     [BATCH_SIZE]Missing    = undefined;
        var missing_batch: std.ArrayList(Missing) = .initBuffer(&batch_buf);

        for (atoms, 0..) |atom, i| {
            if (self.ehcac.get(atom)) |name| {
                results[i] = name;
                continue;
            }

            if (missing_batch.items.len == BATCH_SIZE) {
                try Missing.resolveBatch(self, missing_batch.items, atoms, results);
                missing_batch.clearRetainingCapacity();
            }

            missing_batch.appendAssumeCapacity(.{
                .index  = i,
                .cookie = c.xcb_get_atom_name(self.conn, atom),
            });
        }
        if (missing_batch.items.len > 0) {
            try Missing.resolveBatch(self, missing_batch.items, atoms, results);
        }
    }

    test "AtomStash" {
        const conn = xcbConnect(null).?;

        var atoms = AtomStash.init(conn, std.testing.allocator);
        defer atoms.deinit();

        const name = "image/png";
        const atom = try atoms.get(name);
        try std.testing.expect(atoms.cache.get(name) != null);
        try std.testing.expect(atoms.ehcac.get(atom) != null);

        const primary_name = try atoms.getName(c.XCB_ATOM_PRIMARY);
        const primary_atom = try atoms.get(primary_name);
        try std.testing.expect(primary_atom == c.XCB_ATOM_PRIMARY);
    }
};

const ClipboardData = struct {
    const MAX_OFFERS = 32;

    mime: [MAX_OFFERS]c.xcb_atom_t = undefined,
    data: [MAX_OFFERS][]const u8   = undefined,

    offers_len: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) ClipboardData {
        return .{
            .arena = .init(allocator),
        };
    }

    pub fn get(self: ClipboardData, mime: ?c.xcb_atom_t) ?[]const u8 {
        if (self.offers_len == 0) return null;

        if (mime == null) {
            return self.data[0];
        }

        for (0..self.offers_len) |i| {
            if (self.mime[i] == mime) {
                return self.data[i];
            }
        }
        return null;
    }

    pub fn saveCopy(self: *ClipboardData, mime: c.xcb_atom_t, data: []const u8) ![]const u8 {
        const data_owned = try self.arena.allocator().dupe(u8, data);
        self.saveAlias(mime, data_owned) catch {
            self.arena.allocator().free(data_owned);
        };
        return data_owned;
    }

    pub fn saveAlias(self: *ClipboardData, mime: c.xcb_atom_t, data: []const u8) !void {
        var idx = self.offers_len;
        for (self.mime[0..self.offers_len], 0..) |existing, i| {
            if (existing == mime) {
                idx = i;
            }
        }

        if (idx == self.offers_len) {
            if (self.offers_len >= MAX_OFFERS) return error.NoMemory;
            self.offers_len += 1;
        }

        self.mime[idx] = mime;
        self.data[idx] = data;
    }

    pub fn reset(self: *ClipboardData) void {
        _ = self.arena.reset(.retain_capacity);
        self.offers_len = 0;
    }

    pub fn deinit(self: *ClipboardData) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test {
    _ = AtomStash;
}
