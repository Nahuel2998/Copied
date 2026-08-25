const std = @import("std");
const c   = @import("xcb");

const Self = @This();

// We're copying Emacs on this one
// Chromium seems to be more conservative (0x100000) and other clipboard managers even more so (xsel using 4000)
// From my tests, Emacs seems to follow the protocol very closely
// It was also last modified in 1994 so it can't be that incompatible with old clients/servers...
const MAX_TRANSFER_CAP = 0xFFFFFF;

const RECV_PROPERTY = "_COPIED_RECV";
const SELECTION     = "CLIPBOARD";

conn:   *c.xcb_connection_t,
screen: *c.xcb_screen_t,
window:  c.xcb_window_t,

atoms:     AtomStash,
clipboard: ClipboardData,

allocator: std.mem.Allocator,

xfixes_base:  u8,
max_transfer: u32,

last_event_time: c.xcb_timestamp_t = c.XCB_CURRENT_TIME,
selection_is_mine: bool = false,

incr_send: TransfersRing = .{},

fn xcbConnect(pref_screen: ?*c_int) ?*c.xcb_connection_t {
    const conn = c.xcb_connect(null, pref_screen) orelse return null;
    errdefer c.xcb_disconnect(conn);
    if (c.xcb_connection_has_error(conn) != 0) {
        return null;
    }
    return conn;
}

fn getScreen(conn: *c.xcb_connection_t, num: c_int) !*c.xcb_screen_t {
    const setup = c.xcb_get_setup(conn);
    var   iter  = c.xcb_setup_roots_iterator(setup);
    for (0..@intCast(num)) |_| {
        if (iter.rem == 0) return error.NoScreen;
        c.xcb_screen_next(&iter);
    }
    return iter.data;
}

fn initWindow(conn: *c.xcb_connection_t, screen: *c.xcb_screen_t) !u32 {
    const window = c.xcb_generate_id(conn);
    const evmask = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
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
    return window;
}

fn initAtoms(conn: *c.xcb_connection_t, allocator: std.mem.Allocator) !AtomStash {
    var atoms: AtomStash = .init(conn, allocator);
    const common_atoms = [_][]const u8{RECV_PROPERTY, SELECTION, "TIMESTAMP", "TARGETS", "INCR", "UTF8_STRING", "STRING", "text/uri-list", "text/html", "image/png"};
    _ = try atoms.intern(common_atoms.len, common_atoms);
    return atoms;
}

extern var xcb_xfixes_id: c.xcb_extension_t; // Why doesn't translate-c do this?

fn initXFixes(conn: *c.xcb_connection_t, window: u32, atoms: AtomStash) !u8 {
    const xfixes = c.xcb_get_extension_data(conn, &xcb_xfixes_id) orelse return error.NoXFixes;
    if (xfixes.*.present == 0) return error.NoXFixes;

    const cookie = c.xcb_xfixes_query_version(conn, c.XCB_XFIXES_MAJOR_VERSION, c.XCB_XFIXES_MINOR_VERSION);

    const evmask = c.XCB_XFIXES_SELECTION_EVENT_MASK_SET_SELECTION_OWNER
                 | c.XCB_XFIXES_SELECTION_EVENT_MASK_SELECTION_WINDOW_DESTROY
                 | c.XCB_XFIXES_SELECTION_EVENT_MASK_SELECTION_CLIENT_CLOSE;
    const selection = atoms.getNoIntern(SELECTION).?;
    _ = c.xcb_xfixes_select_selection_input(conn, window, selection, evmask);

    const reply = c.xcb_xfixes_query_version_reply(conn, cookie, null) orelse return error.NoXFixes;
    std.c.free(reply);

    return xfixes.*.first_event;
}

pub fn init(allocator: std.mem.Allocator) !Self {
    var pref_screen: c_int = undefined;
    const conn = xcbConnect(&pref_screen) orelse return error.NoDisplay;

    const screen = try getScreen(conn, pref_screen);
    const window = try initWindow(conn, screen);
    const atoms  = try initAtoms(conn, allocator);

    const xfixes_base     = try initXFixes(conn, window, atoms);
    const max_request_len = c.xcb_get_maximum_request_length(conn);
    const max_transfer    = @min(MAX_TRANSFER_CAP, max_request_len * 4 - 100);
    _ = c.xcb_flush(conn);

    return .{
        .conn   = conn,
        .screen = screen,
        .window = window,
        .atoms  = atoms,
        .clipboard = .init(allocator),
        .allocator = allocator,
        .xfixes_base = xfixes_base,
        .max_transfer = max_transfer,
    };
}

pub fn deinit(self: *Self) void {
    self.atoms.deinit();
    self.clipboard.deinit();
    c.xcb_disconnect(self.conn);
    self.* = undefined;
}

pub fn copy(self: *Self, mime: c.xcb_atom_t, data: []const u8) !void {
    self.claimOwnership();
    _ = c.xcb_flush(self.conn);

    self.clipboard.reset();
    _ = try self.clipboard.saveCopy(mime, data);
}

pub fn paste(self: *Self, mime: ?c.xcb_atom_t) ?[]const u8 {
    if (self.clipboard.get(mime)) |res| return res;
    if (self.selection_is_mine)         return null;
    // FIXME: Temporary UTF8_STRING default
    return self.retrieveSelection(mime orelse self.atoms.getNoIntern("UTF8_STRING").?) catch |err| {
        std.log.err("Failed to retrieve selection from selection owner: {}", .{err});
        return null;
    };
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

fn waitForEvent(self: *Self, target_evtype: u8) !*c.xcb_generic_event_t {
    // FIXME: Well I don't know what to do if you're just slow, ~5s seems plenty
    const POLL_TIMEOUT = 500;
    const POLL_TIMES   = 10;

    var fds = [_]std.posix.pollfd{
        .{ .fd = self.getXFileDescriptor(), .events = std.posix.POLL.IN, .revents = 0 },
    };

    for (0..POLL_TIMES) |_| {
        while (c.xcb_poll_for_event(self.conn)) |event| {
            const evtype = event.*.response_type & 0x7f;
            if (evtype == target_evtype) {
                return event;
            }
            defer std.c.free(event);
            self.handleXEvent(event);
        }
        _ = try std.posix.poll(&fds, POLL_TIMEOUT);
    }
    return error.PollTimeout;
}

fn handleXEvent(self: *Self, event: *c.xcb_generic_event_t) void {
    const evtype = event.response_type & 0x7f;

    if (evtype >= self.xfixes_base) switch (evtype - self.xfixes_base) {
        c.XCB_XFIXES_SELECTION_NOTIFY => {
            self.handleXFixesSelectionNotify(@ptrCast(event)) catch |err| {
                std.log.err("Unexpected error handling XFixesSelectionNotify: {}", .{err});
            };
        },
        else => {},
    }
    else switch (evtype) {
        c.XCB_SELECTION_REQUEST => {
            self.handleSelectionRequest(@ptrCast(event));
        },
        c.XCB_SELECTION_NOTIFY => {
            std.log.warn("Received dangling SelectionNotify, handling anyways", .{});
            _ = self.handleSelectionNotify(@ptrCast(event)) catch |err| {
                std.log.err("Unexpected error handling SelectionNotify: {}\n", .{err});
            };
        },
        c.XCB_PROPERTY_NOTIFY => {
            self.handlePropertyNotify(@ptrCast(event));
        },
        else => {},
    }
}

fn handleXFixesSelectionNotify(self: *Self, ev: *c.xcb_xfixes_selection_notify_event_t) !void {
    self.last_event_time = ev.timestamp;

    if (ev.owner == c.XCB_NONE) {
        self.claimOwnership();
        _ = c.xcb_flush(self.conn);
        return;
    }

    if (ev.owner == self.window) {
        self.selection_is_mine = true;
        return;
    }

    self.clipboard.reset();
    self.selection_is_mine = false;
}

inline fn claimOwnership(self: *Self) void {
    _ = c.xcb_set_selection_owner(self.conn, self.window, self.atoms.getNoIntern(SELECTION).?, self.last_event_time);
}

fn handleSelectionNotify(self: *Self, ev: *c.xcb_selection_notify_event_t) !?[]const u8 {
    self.last_event_time = ev.time;

    if (ev.property == c.XCB_ATOM_NONE) {
        std.log.debug("Selection owner rejected the request :(", .{});
        return null;
    }

    const reply = try self.getProperty(ev.property);
    defer std.c.free(reply);

    const value: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
    const length:      usize = @intCast(c.xcb_get_property_value_length(reply));

    var mime = reply.*.type;
    var data = value[0..length];
    const is_incr = reply.*.type == self.atoms.getNoIntern("INCR").?;
    if (is_incr) {
        var init_capacity: usize = 0;
        if (length == 4) {
            init_capacity = std.mem.readInt(u32, value[0..4], .native);
        }

        const res = try self.receiveIncr(ev.property, init_capacity);
        mime = res.mime;
        data = res.data;
    }
    defer if (is_incr) self.allocator.free(data);

    return try self.clipboard.saveCopy(mime, data);
}


fn handlePropertyNotify(self: *Self, ev: *c.xcb_property_notify_event_t) void {
    self.last_event_time = ev.time;

    if (ev.state != c.XCB_PROPERTY_DELETE or ev.window == self.window) return;
    if (self.incr_send.find(ev.window, ev.atom)) |transfer| {
        const sent = transfer.sendChunk(self.conn, self.max_transfer) catch |err| blk: {
            std.log.err("Failed to send chunk: {}", .{err});
            transfer.in_progress = false;
            break :blk 0;
        };
        if (sent != 0) return;

        self.allocator.free(transfer.data);
        if (!self.incr_send.haveAnyOf(transfer.requestor)) {
            const evmask: u32 = c.XCB_EVENT_MASK_NO_EVENT;
            _ = c.xcb_change_window_attributes(self.conn, transfer.requestor, c.XCB_CW_EVENT_MASK, &evmask);
            _ = c.xcb_flush(self.conn);
        }
    }
}

fn getProperty(self: *Self, property: c.xcb_atom_t) !*c.xcb_get_property_reply_t {
    const cookie = c.xcb_get_property(self.conn, 1, self.window, property, c.XCB_GET_PROPERTY_TYPE_ANY, 0, std.math.maxInt(u32) / 4);
    const reply  = c.xcb_get_property_reply(self.conn, cookie, null) orelse return error.NoProperty;
    if (reply.*.bytes_after > 0) {
        // FIXME: Probably keep reading rather than just failing?
        return error.NotTheEntireOwl;
    }
    return reply;
}

fn receiveIncr(self: *Self, property: c.xcb_atom_t, init_capacity: usize) !struct{ mime: c.xcb_atom_t, data: []const u8 } {
    var buf: std.ArrayList(u8) = try .initCapacity(self.allocator, init_capacity);
    errdefer buf.deinit(self.allocator);

    while (true) {
        const event = try self.waitForEvent(c.XCB_PROPERTY_NOTIFY);
        defer std.c.free(event);
        self.handleXEvent(event);

        const ev: *c.xcb_property_notify_event_t = @ptrCast(event);
        if (ev.atom != property or ev.state != c.XCB_PROPERTY_NEW_VALUE) {
            continue;
        }

        const reply = try self.getProperty(property);
        defer std.c.free(reply);

        const value: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
        const length:      usize = @intCast(c.xcb_get_property_value_length(reply));

        if (length == 0) return .{
            .mime = reply.*.type,
            .data = try buf.toOwnedSlice(self.allocator),
        };
        try buf.appendSlice(self.allocator, value[0..length]);
    }
}

fn handleSelectionRequest(self: *Self, ev: *c.xcb_selection_request_event_t) void {
    self.last_event_time = ev.time;

    const property = if (ev.property != c.XCB_ATOM_NONE) ev.property else ev.target;
    var notify: c.xcb_selection_notify_event_t = .{
        .response_type = c.XCB_SELECTION_NOTIFY,
        .time          = ev.time,
        .requestor     = ev.requestor,
        .selection     = ev.selection,
        .target        = ev.target,
        .property      = property,
    };

    const handled = blk: {
        // Rather than comparing timestamp:
        // If we're no longer the owners, then we already cleared our data so we have nothing valid to send
        if (!self.selection_is_mine) break :blk false;

        if (ev.selection != self.atoms.getNoIntern(SELECTION).?) break :blk false;

        var data: []const u8 = undefined;
        if (ev.target == self.atoms.getNoIntern("TARGETS").?) {
            data = self.getTargetsList() catch |err| {
                std.log.err("Couldn't respond to TARGETS due to: {}", .{err});
                break :blk false;
            };
        }
        else {
            data = self.clipboard.get(ev.target) orelse break :blk false;
        }

        if (data.len > self.max_transfer) {
            self.startIncrSend(ev.time, ev.requestor, property, ev.target, data) catch |err| {
                std.log.err("Failed to start INCR send: {}", .{err});
                break :blk false;
            };
            break :blk true;
        }
        _ = c.xcb_change_property(self.conn, c.XCB_PROP_MODE_REPLACE, ev.requestor, property, ev.target, 8, @intCast(data.len), data.ptr);
        break :blk true;
    };
    if (!handled) {
        notify.property = c.XCB_ATOM_NONE;
    }
    _ = c.xcb_send_event(self.conn, 0, ev.requestor, c.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&notify));
    _ = c.xcb_flush(self.conn);
}

fn startIncrSend(self: *Self, timestamp: c.xcb_timestamp_t, requestor: c.xcb_window_t, property: c.xcb_atom_t, mime: c.xcb_atom_t, data: []const u8) !void {
    const data_len: u32 = @min(data.len, std.math.maxInt(u32));
    const cookie = c.xcb_change_property_checked(self.conn, c.XCB_PROP_MODE_REPLACE, requestor, property, self.atoms.getNoIntern("INCR").?, 32, 1, &data_len);
    const err    = c.xcb_request_check(self.conn, cookie);
    if (err != null) {
        std.c.free(err);
        return error.NoChange;
    }

    const evmask: u32   = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    const listen_cookie = c.xcb_change_window_attributes_checked(self.conn, requestor, c.XCB_CW_EVENT_MASK, &evmask);
    const listen_err    = c.xcb_request_check(self.conn, listen_cookie);
    if (listen_err != null) {
        std.c.free(listen_err);
        return error.NoListen;
    }

    if (self.incr_send.occupied()) |stale_transfer| {
        self.allocator.free(stale_transfer.data);
        stale_transfer.notifyFailure(self.conn, self.atoms.getNoIntern(SELECTION).?);
    }
    self.incr_send.insert(
        .{
            .requestor = requestor,
            .property  = property,
            .mime      = mime,
            .data      = try self.allocator.dupe(u8, data),
            .timestamp = timestamp,
        },
    ) catch unreachable;
}

fn retrieveSelection(self: *Self, mime: c.xcb_atom_t) !?[]const u8 {
    const selection = self.atoms.getNoIntern(SELECTION).?;
    const property  = self.atoms.getNoIntern(RECV_PROPERTY).?;
    _ = c.xcb_convert_selection(self.conn, self.window, selection, mime, property, self.last_event_time);
    _ = c.xcb_flush(self.conn);

    const ev = try self.waitForEvent(c.XCB_SELECTION_NOTIFY);
    defer std.c.free(ev);

    return self.handleSelectionNotify(@ptrCast(ev));
}

pub fn translateTargetsList(self: *Self, data: []const u8, buf: []u8) ![]const u8 {
    var i: usize = 0;
    var targets_atoms: [ClipboardData.MAX_OFFERS]c.xcb_atom_t = undefined;
    while (i + 4 <= data.len) : (i += 4) {
        const atom = std.mem.readInt(c.xcb_atom_t, data[i..][0..4], .native);
        targets_atoms[i / 4] = atom;
    }

    const targets_len = data.len / 4;
    var targets_names: [ClipboardData.MAX_OFFERS][]const u8 = undefined;
    try self.atoms.getNames(targets_atoms[0..targets_len], targets_names[0..targets_len]);

    var targets: std.ArrayList(u8) = .initBuffer(buf);
    for (targets_names[0..targets_len]) |name| {
        try targets.appendSliceBounded(name);
        try targets.appendBounded('\n');
    }
    return targets.items;
}

fn getTargetsList(self: *Self) ![]const u8 {
    const len = self.clipboard.offers_len;
    if (len >= ClipboardData.MAX_OFFERS) return error.NoMemory;

    self.clipboard.mime[len] = self.atoms.getNoIntern("TARGETS").?;
    return std.mem.sliceAsBytes(self.clipboard.mime[0..(len + 1)]);
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
    const MAX_OFFERS = 64;

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

const TransfersRing = struct {
    const MAX_SENDS = 64;

    next: usize = 0,
    transfers: [MAX_SENDS]Transfer = std.mem.zeroes([MAX_SENDS]Transfer),

    pub fn occupied(self: *@This()) ?*Transfer {
        const transfer = &self.transfers[self.next];
        if (transfer.in_progress) {
            return transfer;
        }
        return null;
    }

    pub fn insert(self: *@This(), transfer: Transfer) !void {
        if (self.occupied() != null) return error.SlotOccupied;

        self.transfers[self.next] = transfer;

        self.next = (self.next + 1) % MAX_SENDS;
    }

    pub fn find(self: *@This(), requestor: c.xcb_window_t, property: c.xcb_atom_t) ?*Transfer {
        for (&self.transfers) |*transfer| {
            if (!transfer.in_progress) continue;
            if (transfer.requestor == requestor and transfer.property == property) {
                return transfer;
            }
        }
        return null;
    }

    pub fn haveAnyOf(self: @This(), requestor: c.xcb_window_t) bool {
        for (self.transfers) |transfer| {
            if (!transfer.in_progress) continue;
            if (transfer.requestor == requestor) {
                return true;
            }
        }
        return false;
    }
};

const Transfer = struct {
    in_progress: bool = true,
    requestor:   c.xcb_window_t,
    property:    c.xcb_atom_t,
    timestamp:   c.xcb_timestamp_t,
    mime:        c.xcb_atom_t,
    data:        []const u8,
    offset:      usize = 0,

    pub fn notifyFailure(self: *Transfer, conn: *c.xcb_connection_t, selection: c.xcb_atom_t) void {
        var notify: c.xcb_selection_notify_event_t = .{
            .response_type = c.XCB_SELECTION_NOTIFY,
            .time          = self.timestamp,
            .requestor     = self.requestor,
            .selection     = selection,
            .target        = self.mime,
            .property      = c.XCB_ATOM_NONE,
        };
        _ = c.xcb_send_event(conn, 0, self.requestor, c.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&notify));
        self.in_progress = false;
    }

    pub fn sendChunk(self: *Transfer, conn: *c.xcb_connection_t, max_chunk_len: u32) !usize {
        const chunk_len: u32 = @min(max_chunk_len, self.data.len - self.offset);
        const mode:      u8  = if (self.offset == 0) c.XCB_PROP_MODE_REPLACE else c.XCB_PROP_MODE_APPEND; // ICCCM says this although it changes nothing..?

        const cookie = c.xcb_change_property_checked(conn, mode, self.requestor, self.property, self.mime, 8, chunk_len, self.data[self.offset..].ptr);
        const err    = c.xcb_request_check(conn, cookie);
        if (err != null) {
            std.c.free(err);
            return error.NoChange;
        }

        self.offset += chunk_len;
        if (chunk_len == 0) {
            self.in_progress = false;
        }
        return chunk_len;
    }
};

test {
    _ = AtomStash;
}
