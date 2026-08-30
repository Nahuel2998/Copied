const std = @import("std");
const c   = @import("xcb");

const Self = @This();

// We're copying Emacs on this one
// Chromium seems to be more conservative (0x100000) and other clipboard managers even more so (xsel using 4000)
// From my tests, Emacs seems to follow the protocol very closely
// It was also last modified in 1994 so it can't be that incompatible with old clients/servers...
const MAX_TRANSFER_CAP = 0xFFFFFF;

const RECV_PROPERTIES = blk: {
    var res: [16][]const u8 = undefined;
    for (0..res.len) |i| {
        res[i] = "_COPIED_RECV_" ++ .{('0' + i)};
    }
    break :blk res;
};
const SELECTION    = "CLIPBOARD";
const META_TARGETS = [_][]const u8{"TARGETS", "MULTIPLE", "TIMESTAMP", "SAVE_TARGETS"};
const OTHER_META_TARGETS = .{"DELETE", "INSERT_PROPERTY", "INSERT_SELECTION"}; // We don't support these yet

conn:   *c.xcb_connection_t,
screen: *c.xcb_screen_t,
window:  c.xcb_window_t,

atoms:     AtomStash,
clipboard: ClipboardData,
timestamp: c.xcb_timestamp_t = c.XCB_CURRENT_TIME,

allocator: std.mem.Allocator,

xfixes_base:  u8,
max_transfer: u32,

last_event_time: c.xcb_timestamp_t = c.XCB_CURRENT_TIME, // FIXME: This is somewhat non-compliant
selection_is_mine: bool = false,

incr_send: SendRing = .{},
recv_pool: RecvPool,

// Used when returning a meta-target while not being the owners
meta_buf: [ClipboardData.MIME_CAP * 4]u8 align(@alignOf(c.xcb_atom_t)) = undefined,

pub fn init(allocator: std.mem.Allocator) !Self {
    var pref_screen: c_int = undefined;
    const conn = xcbConnect(&pref_screen) orelse return error.NoDisplay;

    const screen = try getScreen(conn, pref_screen);
    const window = try initWindow(conn, screen);
    const atoms  = try initAtoms(conn, allocator);

    const xfixes_base     = try initXFixes(conn, window, atoms);
    const max_request_len = c.xcb_get_maximum_request_length(conn);
    const max_transfer    = @min(MAX_TRANSFER_CAP, max_request_len * 4 - 100);

    _ = c.xcb_set_selection_owner(conn, window, atoms.get("CLIPBOARD_MANAGER").?, c.XCB_CURRENT_TIME);
    _ = c.xcb_flush(conn);

    std.log.debug("My window is: {}", .{window});
    var self: Self = .{
        .conn   = conn,
        .screen = screen,
        .window = window,
        .atoms  = atoms,
        .recv_pool = .init(atoms),
        .clipboard = .init(allocator),
        .allocator = allocator,
        .xfixes_base = xfixes_base,
        .max_transfer = max_transfer,
    };
    self.getSomeTargets(self.last_event_time);
    return self;
}

pub fn deinit(self: *Self) void {
    self.incr_send.cancelAll(self.allocator, self.conn, self.atoms.get(SELECTION).?);
    self.recv_pool.failAll(self.allocator);
    _ = c.xcb_flush(self.conn);

    self.clipboard.deinit();
    self.atoms.deinit();

    c.xcb_disconnect(self.conn);
    self.* = undefined;
}

pub fn copy(self: *Self, mime: c.xcb_atom_t, data: []const u8) !void {
    self.claimOwnership();
    _ = c.xcb_flush(self.conn);

    self.reset();
    _ = try self.clipboard.saveCopy(mime, data);
}

pub fn paste(self: *Self, sock: std.posix.fd_t, maybe_mime: ?c.xcb_atom_t) ?[]const u8 {
    // FIXME: Temporary UTF8_STRING default
    const mime = maybe_mime orelse self.atoms.get("UTF8_STRING").?;

    if (self.convertSelection(mime)) |res| return res.data;
    if (self.selection_is_mine)            return null;

    return self.retrieveSelection(self.last_event_time, mime, sock);
}

pub fn reset(self: *Self) void {
    self.incr_send.ownAll(self.allocator);
    self.recv_pool.failAll(self.allocator);
    self.clipboard.reset();
}

pub fn getXFileDescriptor(self: Self) std.posix.fd_t {
    return c.xcb_get_file_descriptor(self.conn);
}

pub fn drainXEvents(self: *Self) bool {
    var drained = false;
    while (c.xcb_poll_for_event(self.conn)) |event| {
        defer std.c.free(event);
        self.handleXEvent(event);
        drained = true;
    }
    return drained;
}

pub fn waitDrainXEvents(self: *Self, sock: ?std.posix.fd_t) bool {
    if (self.drainXEvents()) return true;

    if (!self.waitForEvent(sock)) return false;
    return self.drainXEvents();
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
    const common_atoms = [_][]const u8{
        SELECTION,
        "CLIPBOARD_MANAGER",
        "INCR",
        "UTF8_STRING",
        "STRING",
        "INTEGER",
        "ATOM",
        "ATOM_PAIR",
        "text/uri-list",
        "image/png",
    } ++ META_TARGETS ++ OTHER_META_TARGETS ++ RECV_PROPERTIES;
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
    const selection = atoms.get(SELECTION).?;
    _ = c.xcb_xfixes_select_selection_input(conn, window, selection, evmask);

    const reply = c.xcb_xfixes_query_version_reply(conn, cookie, null) orelse return error.NoXFixes;
    std.c.free(reply);

    return xfixes.*.first_event;
}

fn waitForEvent(self: *Self, sock: ?std.posix.fd_t) bool {
    // std.log.debug("Waiting for events...", .{});
    // for (self.recv_pool.transfers) |transfer| {
    //     if (!transfer.active) continue;
    //     std.log.debug("Transfer pending of mime={s}", .{self.atoms.getName(transfer.mime) catch "idk"});
    // }

    var fds_buf: [2]std.posix.pollfd = .{
        .{ .fd = self.getXFileDescriptor(), .events = std.posix.POLL.IN, .revents = 0 },
        undefined,
    };

    var fds: []std.posix.pollfd = fds_buf[0..1];
    if (sock) |fd| {
        fds = fds_buf[0..2];
        fds[1] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
    }

    _ = std.posix.poll(fds, -1) catch return false;
    if (sock == null) return true;

    const sock_died = fds[1].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0;
    return !sock_died;
}

fn handleXEvent(self: *Self, event: *c.xcb_generic_event_t) void {
    const evtype = event.response_type & 0x7f;

    if (evtype >= self.xfixes_base) switch (evtype - self.xfixes_base) {
        c.XCB_XFIXES_SELECTION_NOTIFY => {
            self.handleXFixesSelectionNotify(@ptrCast(event));
        },
        else => {},
    }
    else switch (evtype) {
        c.XCB_SELECTION_REQUEST => self.handleSelectionRequest(@ptrCast(event)),
        c.XCB_SELECTION_NOTIFY  => self.handleSelectionNotify(@ptrCast(event)),
        c.XCB_PROPERTY_NOTIFY   => self.handlePropertyNotify(@ptrCast(event)),
        else => {},
    }
}

fn handleXFixesSelectionNotify(self: *Self, ev: *c.xcb_xfixes_selection_notify_event_t) void {
    self.last_event_time = ev.timestamp;

    std.log.debug("Ownership changed to: {}", .{ev.owner});
    if (ev.owner == c.XCB_NONE) {
        self.recv_pool.failAll(self.allocator);
        self.claimOwnership();
        _ = c.xcb_flush(self.conn);
        return;
    }

    if (ev.owner == self.window) {
        self.selection_is_mine = true;
        return;
    }

    self.reset();
    self.selection_is_mine = false;
    self.getSomeTargets(ev.timestamp);
}

inline fn claimOwnership(self: *Self) void {
    self.timestamp = self.last_event_time;
    _ = c.xcb_set_selection_owner(self.conn, self.window, self.atoms.get(SELECTION).?, self.timestamp);
}

fn getSomeTargets(self: *Self, timestamp: c.xcb_timestamp_t) void {
    const targets_bytes = self.retrieveSelection(timestamp, self.atoms.get("TARGETS").?, null) orelse return;
    const targets: []const c.xcb_atom_t = @ptrCast(@alignCast(targets_bytes));
    for (targets) |mime| {
        if (mime == self.atoms.get("UTF8_STRING").? or mime == self.atoms.get("image/png") or mime == self.atoms.get("text/uri-list")) {
            _ = self.retrieveSelection(timestamp, mime, null);
        }
    }
}

// FIXME: I think if there's a pending selection and the owner changes and we use the same mime,
//        we may still pass it as appropriate and save stale data, possibly double-writing or ignoring the actual good data
//        Checking the timestamp may fix this
fn handleSelectionNotify(self: *Self, ev: *c.xcb_selection_notify_event_t) void {
    self.last_event_time = ev.time;

    if (ev.property == c.XCB_ATOM_NONE) {
        var transfer = self.recv_pool.findByMime(ev.target) orelse {
            std.log.debug("Received notification for a transfer we don't care about anymore, ignoring", .{});
            return;
        };
        std.log.debug("Selection owner rejected the request :(", .{});
        transfer.fail(self.allocator);
        return;
    }

    const transfer = self.recv_pool.findByProperty(ev.property) orelse {
        std.log.debug("Received notification for a transfer we don't care about anymore, ignoring", .{});
        return;
    };

    const cookie = self.getPropertyCookie(self.window, ev.property, true);
    self.readSelectionResponse(transfer, cookie);
}

fn readSelectionResponse(self: *Self, transfer: *RecvTransfer, cookie: c.xcb_get_property_cookie_t) void {
    const reply = c.xcb_get_property_reply(self.conn, cookie, null) orelse {
        std.log.err("Failed to read selection property", .{});
        transfer.fail(self.allocator);
        return;
    };
    defer std.c.free(reply);

    // std.log.debug("Read property {s}", .{self.atoms.getName(transfer.property) catch "idk"});

    // What do you mean there's more than 4GB?
    std.debug.assert(reply.*.bytes_after == 0);

    const value: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
    const length:      usize = @intCast(c.xcb_get_property_value_length(reply));
    // TODO: Check whether length == 0?

    if (reply.*.type == self.atoms.get("INCR").?) {
        var init_capacity: usize = 0;
        if (length == 4) {
            init_capacity = std.mem.readInt(u32, value[0..4], .native);
        }
        transfer.incr_buf = std.ArrayList(u8).initCapacity(self.allocator, init_capacity) catch .empty;
        return;
    }

    self.endReceive(transfer, value[0..length]) catch |err| {
        std.log.err("Failed to save received selection: {}", .{err});
        transfer.fail(self.allocator);
    };
}

fn endReceive(self: *Self, transfer: *RecvTransfer, data: []const u8) !void {
    var res: []const u8 = undefined;
    if (self.isMetaTarget(transfer.mime)) {
        if (data.len > self.meta_buf.len) return error.NoMemory;

        const mut_res = self.meta_buf[0..data.len];
        @memcpy(mut_res, data);
        res = mut_res;
    }
    else {
        res = try self.clipboard.saveCopy(transfer.mime, data);
    }
    transfer.data   = res;
    transfer.active = false;
}

fn isMetaTarget(self: *Self, mime: c.xcb_atom_t) bool {
    for (META_TARGETS ++ OTHER_META_TARGETS) |target| {
        if (mime == self.atoms.get(target).?) {
            return true;
        }
    }
    return false;
}

fn handlePropertyNotify(self: *Self, ev: *c.xcb_property_notify_event_t) void {
    self.last_event_time = ev.time;

    // std.log.debug("Received PropertyNotify for window {} for property {s} with state {}", .{ev.window, self.atoms.getName(ev.atom) catch "idk", ev.state});
    if (ev.window == self.window) {
        if (ev.state != c.XCB_PROPERTY_NEW_VALUE) return;
        if (self.recv_pool.findByProperty(ev.atom)) |transfer| {
            // std.log.debug("It belongs to a recv", .{});
            if (transfer.incr_buf) |*incr_buf| {
                // std.log.debug("an INCR to be specific", .{});
                self.receiveIncr(transfer, incr_buf);
            }
        }
        return;
    }

    if (ev.state != c.XCB_PROPERTY_DELETE) return;
    if (self.incr_send.find(ev.window, ev.atom)) |transfer| {
        const sent = transfer.sendChunk(self.conn, self.max_transfer) catch |err| blk: {
            std.log.err("Failed to send chunk: {}", .{err});
            transfer.active = false;
            break :blk 0;
        };
        if (sent != 0) return;

        transfer.disown(self.allocator);
        if (!self.incr_send.haveAnyOf(transfer.requestor)) {
            const evmask: u32 = c.XCB_EVENT_MASK_NO_EVENT;
            _ = c.xcb_change_window_attributes(self.conn, transfer.requestor, c.XCB_CW_EVENT_MASK, &evmask);
            _ = c.xcb_flush(self.conn);
        }
    }
}

fn receiveIncr(self: *Self, transfer: *RecvTransfer, incr_buf: *std.ArrayList(u8)) void {
    const reply = self.getProperty(self.window, transfer.property, true) catch |err| {
        std.log.err("Failed to read INCR chunk: {}", .{err});
        transfer.fail(self.allocator);
        return;
    };
    defer std.c.free(reply);

    const value: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
    const length:      usize = @intCast(c.xcb_get_property_value_length(reply));

    if (length != 0) {
        incr_buf.appendSlice(self.allocator, value[0..length]) catch |err| {
            std.log.err("Failed to save INCR chunk: {}", .{err});
            transfer.fail(self.allocator);
        };
        return;
    }

    self.endReceive(transfer, incr_buf.items) catch |err| {
        std.log.err("Failed to finalize INCR receive: {}", .{err});
        transfer.fail(self.allocator);
        return;
    };
    transfer.endIncr(self.allocator);
}

fn getProperty(self: Self, window: c.xcb_window_t, property: c.xcb_atom_t, delete: bool) !*c.xcb_get_property_reply_t {
    const cookie = self.getPropertyCookie(window, property, delete);
    const reply  = c.xcb_get_property_reply(self.conn, cookie, null) orelse return error.NoProperty;
    // I mean we asked for 4GB what do you mean there's more?
    std.debug.assert(reply.*.bytes_after == 0);
    return reply;
}

inline fn getPropertyCookie(self: Self, window: c.xcb_window_t, property: c.xcb_atom_t, delete: bool) c.xcb_get_property_cookie_t {
    // std.log.debug("Reading property {s} of window {}; delete={}", .{self.atoms.ehcac.get(property) orelse "idk", window, delete});
    return c.xcb_get_property(self.conn, @intFromBool(delete), window, property, c.XCB_GET_PROPERTY_TYPE_ANY, 0, std.math.maxInt(u32) / 4);
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

    // std.log.debug("Window {} wants to convert {s} to {}", .{ev.requestor, self.atoms.getName(ev.selection) catch "idk", ev.target});
    const handled = blk: {
        if (ev.selection != self.atoms.get(SELECTION).?) {
            if (ev.target == self.atoms.get("SAVE_TARGETS").?) {
                self.saveTargets(ev.time, ev.requestor, property) catch |err| {
                    std.log.err("Couldn't SAVE_TARGETS: {}", .{err});
                    break :blk false;
                };
                break :blk true;
            }
            break :blk false;
        }

        // Rather than comparing timestamp:
        // If we're no longer the owners, then we already cleared our data so we have nothing valid to send
        if (!self.selection_is_mine) break :blk false;

        if (ev.target == self.atoms.get("MULTIPLE").?) {
            self.startMultipleSend(ev.time, ev.requestor, property) catch |err| {
                std.log.err("Couldn't start MULTIPLE send due to: {}", .{err});
                break :blk false;
            };
            break :blk true;
        }

        const data = self.convertSelection(ev.target) orelse break :blk false;
        const ok   = self.sendData(ev.time, ev.requestor, property, data);
        break :blk ok;
    };
    if (!handled) {
        notify.property = c.XCB_ATOM_NONE;
    }
    _ = c.xcb_send_event(self.conn, 0, ev.requestor, c.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&notify));
    _ = c.xcb_flush(self.conn);
}

fn saveTargets(self: *Self, timestamp: c.xcb_timestamp_t, window: c.xcb_window_t, property: c.xcb_atom_t) !void {
    var targets_buf: [ClipboardData.MAX_OFFERS]c.xcb_atom_t = undefined;
    var targets:                             []c.xcb_atom_t = undefined;
    if (self.getProperty(window, property, false)) |reply| {
        defer std.c.free(reply);

        const value:  [*]u8 = @ptrCast(c.xcb_get_property_value(reply));
        const length: usize = @intCast(c.xcb_get_property_value_length(reply));

        const want_saved: []c.xcb_atom_t = @ptrCast(@alignCast(value[0..length]));
        targets = targets_buf[0..@min(targets_buf.len, want_saved.len)];
        @memcpy(targets, want_saved[0..targets.len]);
    }
    else |_| {
        const all_targets_bytes = self.retrieveSelection(timestamp, self.atoms.get("TARGETS").?, null) orelse return error.NoTargets;
        const all_targets: []const c.xcb_atom_t = @ptrCast(@alignCast(all_targets_bytes));

        targets = targets_buf[0..@min(targets_buf.len, all_targets.len)];
        @memcpy(targets, all_targets[0..targets.len]);
    }

    var i: usize = 0;
    while (i < targets.len) {
        if (self.isMetaTarget(targets[i]) or (self.clipboard.get(targets[i]) != null)) {
            targets[i] = targets[targets.len - 1];
            targets.len -= 1;
            continue;
        }
        i += 1;
    }

    std.log.debug("Saving {} targets from window {}", .{targets.len, window});
    self.retrieveMultiple(timestamp, targets);
    self.claimOwnership();
}

fn convertSelection(self: *Self, mime: c.xcb_atom_t) ?SendData {
    if (self.selection_is_mine) {
        if (mime == self.atoms.get("TARGETS").?) return .{
            .format = 32,
            .mime   = self.atoms.get("ATOM").?,
            .data   = self.getTargetsList(),
        };
        if (mime == self.atoms.get("TIMESTAMP").?) return .{
            .format = 32,
            .mime   = self.atoms.get("INTEGER").?,
            .data   = std.mem.asBytes(&self.timestamp),
        };
    }
    return .{
        .mime = mime,
        .data = self.clipboard.get(mime) orelse return null,
    };
}

fn sendData(self: *Self, timestamp: c.xcb_atom_t, requestor: c.xcb_window_t, property: c.xcb_atom_t, sel: SendData) bool {
    if (sel.data.len > self.max_transfer) {
        self.startIncrSend(timestamp, requestor, property, sel.mime, sel.data) catch |err| {
            std.log.err("Failed to start INCR send: {}", .{err});
            return false;
        };
        return true;
    }
    const count = sel.data.len / (sel.format / 8);
    _ = c.xcb_change_property(self.conn, c.XCB_PROP_MODE_REPLACE, requestor, property, sel.mime, sel.format, @intCast(count), sel.data.ptr);
    return true;
}

fn startMultipleSend(self: *Self, timestamp: c.xcb_atom_t, requestor: c.xcb_window_t, property: c.xcb_atom_t) !void {
    const reply = try self.getProperty(requestor, property, false);
    defer std.c.free(reply);

    const value:  [*]u8 = @ptrCast(c.xcb_get_property_value(reply));
    const length: usize = @intCast(c.xcb_get_property_value_length(reply));
    if (length % (2 * 4) != 0) return error.TheseAreNotPairs;

    var rejected_some: bool = false;
    const atom_pairs: []AtomPair = @ptrCast(@alignCast(value[0..length]));
    for (atom_pairs) |*pair| {
        if (self.convertSelection(pair.mime)) |data| {
            const ok = self.sendData(timestamp, requestor, pair.prop, data);
            if (ok) continue;
        }
        pair.prop = c.XCB_ATOM_NONE;
        rejected_some = true;
    }

    if (rejected_some) {
        const ok = self.sendData(timestamp, requestor, property, .{ .format = 32, .mime = self.atoms.get("ATOM_PAIR").?, .data = @ptrCast(atom_pairs) });
        if (!ok) return error.NoChange;
    }
}

fn startIncrSend(self: *Self, timestamp: c.xcb_timestamp_t, requestor: c.xcb_window_t, property: c.xcb_atom_t, mime: c.xcb_atom_t, data: []const u8) !void {
    const data_len: u32 = @min(data.len, std.math.maxInt(u32));
    const cookie = c.xcb_change_property_checked(self.conn, c.XCB_PROP_MODE_REPLACE, requestor, property, self.atoms.get("INCR").?, 32, 1, &data_len);
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
        stale_transfer.cancel(self.allocator, self.conn, self.atoms.get(SELECTION).?);
    }
    self.incr_send.insert(
        .{
            .requestor = requestor,
            .property  = property,
            .mime      = mime,
            .data      = data,
            .timestamp = timestamp,
        },
    ) catch unreachable;
}

fn retrieveSelection(self: *Self, timestamp: c.xcb_timestamp_t, mime: c.xcb_atom_t, sock: ?std.posix.fd_t) ?[]const u8 {
    if (self.selection_is_mine) {
        std.log.debug("Refusing to retrieveSelection myself", .{});
        return null;
    }

    var transfer = self.recv_pool.acquire() catch |err| {
        std.log.err("Couldn't acquire a slot for RecvTransfer: {}", .{err});
        return null;
    };

    const selection = self.atoms.get(SELECTION).?;
    _ = c.xcb_convert_selection(self.conn, self.window, selection, mime, transfer.property, timestamp);
    _ = c.xcb_flush(self.conn);

    transfer.mime   = mime;
    transfer.active = true;
    while (transfer.active) {
        if (!self.waitDrainXEvents(sock)) {
            return null;
        }
    }
    return transfer.data;
}

fn retrieveMultiple(self: *Self, timestamp: c.xcb_timestamp_t, mimes: []const c.xcb_atom_t) void {
    var i: usize = 0;
    while (i < mimes.len) {
        var batch_size = @min(self.recv_pool.slotsAvailable(), mimes.len - i);
        if (batch_size == 0) {
            // Wait for something to free-up
            // Given _when_ we call this function, this should be unreachable
            _ = self.waitDrainXEvents(null);
            continue;
        }

        if (batch_size > 2) {
            batch_size -= 1;
            if (self.retrieveMultipleBatch(timestamp, mimes[i..(i + batch_size)])) {
                i += batch_size;
                continue;
            } else |err| if (err == error.NoMultiple) {
                batch_size = mimes.len - i;
            }
        }
        for (0..batch_size) |j| {
            _ = self.retrieveSelection(timestamp, mimes[i + j], null);
        }
        i += batch_size;
    }
}

fn retrieveMultipleBatch(self: *Self, timestamp: c.xcb_timestamp_t, mimes: []const c.xcb_atom_t) !void {
    std.debug.assert(0         <  mimes.len);
    std.debug.assert(mimes.len <= RecvPool.MAX_RECVS);

    if (self.selection_is_mine) {
        std.log.debug("Refusing to retrieveMultipleBatch myself", .{});
        return;
    }

    var transfers_buf: [RecvPool.MAX_RECVS]*RecvTransfer = undefined;
    try self.recv_pool.acquireMultiple(transfers_buf[0..(mimes.len + 1)]);
    const transfers = transfers_buf[0..mimes.len];

    var ask_pairs: [RecvPool.MAX_RECVS]AtomPair = undefined;
    for (transfers, mimes, 0..) |transfer, mime, i| {
        transfer.mime   = mime;
        transfer.active = true;
        ask_pairs[i] = .{
            .mime = mime,
            .prop = transfer.property,
        };
    }

    const multiple_transfer = transfers_buf[mimes.len];
    multiple_transfer.mime  = self.atoms.get("MULTIPLE").?;
    const err = c.xcb_request_check(
        self.conn,
        c.xcb_change_property_checked(
            self.conn,
            c.XCB_PROP_MODE_REPLACE,
            self.window, multiple_transfer.property,
            self.atoms.get("ATOM_PAIR").?,
            32, @intCast(mimes.len * 2), &ask_pairs,
        ),
    );
    if (err != null) {
        std.c.free(err);
        return error.NoChange;
    }
    multiple_transfer.active = true;

    const selection = self.atoms.get(SELECTION).?;
    _ = c.xcb_convert_selection(self.conn, self.window, selection, multiple_transfer.mime, multiple_transfer.property, timestamp);
    _ = c.xcb_flush(self.conn);

    while (multiple_transfer.active) {
        _ = self.waitDrainXEvents(null);
    }
    const data = multiple_transfer.data orelse {
        for (transfers) |transfer| {
            transfer.fail(self.allocator);
        }
        return error.NoMultiple;
    };

    var   cookies: [RecvPool.MAX_RECVS]c.xcb_get_property_cookie_t = undefined;
    const res_pairs: []const AtomPair = @ptrCast(@alignCast(data));
    for (transfers, res_pairs, 0..) |transfer, pair, i| {
        if (pair.prop == c.XCB_ATOM_NONE) {
            std.log.debug("[Multiple] Selection owner rejected the request :(", .{});
            transfer.fail(self.allocator);
            continue;
        }
        cookies[i] = self.getPropertyCookie(self.window, pair.prop, true);
    }
    for (transfers, cookies[0..transfers.len]) |transfer, cookie| {
        if (!transfer.active) continue;
        self.readSelectionResponse(transfer, cookie);
    }

    for (transfers) |transfer| {
        while (transfer.active) {
            // FIXME: Possibly, some new event might acquire a slot we previously set as active=false
            //        It doesn't change anything here, but not intended
            _ = self.waitDrainXEvents(null);
        }
    }
}

fn getTargetsList(self: *Self) []const u8 {
    const len = self.clipboard.offers_len + META_TARGETS.len;
    for (META_TARGETS, 0..) |atom_name, i| {
        const atom = self.atoms.get(atom_name).?;
        self.clipboard.mime[self.clipboard.offers_len + i] = atom;
    }
    return std.mem.sliceAsBytes(self.clipboard.mime[0..len]);
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

    pub fn get(self: AtomStash, name: []const u8) ?c.xcb_atom_t {
        return self.cache.get(name);
    }

    pub fn getIntern(self: *AtomStash, name: []const u8) !c.xcb_atom_t {
        if (self.get(name)) |atom| return atom;

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
        const atom = try atoms.getIntern(name);
        try std.testing.expect(atoms.cache.get(name) != null);
        try std.testing.expect(atoms.ehcac.get(atom) != null);

        const primary_name = try atoms.getName(c.XCB_ATOM_PRIMARY);
        const primary_atom = try atoms.getIntern(primary_name);
        try std.testing.expect(primary_atom == c.XCB_ATOM_PRIMARY);
    }
};

const ClipboardData = struct {
    const MIME_CAP   = 64;
    const MAX_OFFERS = MIME_CAP - META_TARGETS.len;

    mime: [MIME_CAP]c.xcb_atom_t = undefined, // NOTE: We reuse this when building TARGETS
    data: [MAX_OFFERS][]const u8 = undefined,

    offers_len: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) ClipboardData {
        return .{
            .arena = .init(allocator),
        };
    }

    pub fn get(self: ClipboardData, mime: c.xcb_atom_t) ?[]const u8 {
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

// The idea here is inserting to the current position and increasing pos by one
// By the time we've gone full circle, if that same spot is still `active`, we may assume it's stale
fn SlotRing(comptime T: type, comptime cap: usize) type {
    comptime if (!@hasField(T, "active")) {
        @compileError(@typeName(T) ++ " must have an `active: bool` field");
    };

    return struct {
        next:  usize = 0,
        slots: [cap]T = std.mem.zeroes([cap]T),

        pub fn occupied(self: *@This()) ?*T {
            const slot = &self.slots[self.next];
            if (slot.active) return slot;
            return null;
        }

        pub fn insert(self: *@This(), slot: T) !void {
            if (self.occupied() != null) return error.SlotOccupied;
            self.slots[self.next] = slot;
            self.next = (self.next + 1) % cap;
        }

        pub fn find(self: *@This(), ctx: anytype, match: fn(@TypeOf(ctx), *T)bool) ?*T {
            for (&self.slots) |*slot| {
                if (!slot.active or !match(ctx, slot)) continue;
                return slot;
            }
            return null;
        }
    };
}

const SendRing = struct {
    const MAX_SENDS = ClipboardData.MIME_CAP;

    ring: SlotRing(SendTransfer, MAX_SENDS) = .{},

    pub fn occupied(self: *SendRing) ?*SendTransfer {
        return self.ring.occupied();
    }

    pub fn insert(self: *SendRing, transfer: SendTransfer) !void {
        return self.ring.insert(transfer);
    }

    pub fn find(self: *SendRing, requestor: c.xcb_window_t, property: c.xcb_atom_t) ?*SendTransfer {
        const Context = struct {
            requestor: c.xcb_window_t,
            property:  c.xcb_atom_t,
        };
        return self.ring.find(
            Context{ .requestor = requestor, .property = property },
            struct {
                fn match(ctx: Context, transfer: *SendTransfer) bool {
                    return (transfer.requestor == ctx.requestor and transfer.property == ctx.property);
                }
            }.match
        );
    }

    pub fn haveAnyOf(self: @This(), requestor: c.xcb_window_t) bool {
        for (self.ring.slots) |transfer| {
            if (!transfer.active) continue;
            if (transfer.requestor == requestor) {
                return true;
            }
        }
        return false;
    }

    pub fn ownAll(self: *@This(), allocator: std.mem.Allocator) void {
        for (&self.ring.slots) |*transfer| {
            transfer.own(allocator) catch |err| {
                std.log.err("Failed to own transfer, continuing anyways: {}", .{err});
            };
        }
    }

    pub fn cancelAll(self: *@This(), allocator: std.mem.Allocator, conn: *c.xcb_connection_t, selection: c.xcb_atom_t) void {
        for (&self.ring.slots) |*transfer| {
            transfer.cancel(allocator, conn, selection);
        }
        self.ring.next = 0;
    }
};

const SendTransfer = struct {
    active: bool = true,

    requestor: c.xcb_window_t,
    property:  c.xcb_atom_t,
    timestamp: c.xcb_timestamp_t,
    mime:      c.xcb_atom_t,
    data:      []const u8,
    owned:     bool = false,
    offset:    usize = 0,

    pub fn cancel(self: *SendTransfer, allocator: std.mem.Allocator, conn: *c.xcb_connection_t, selection: c.xcb_atom_t) void {
        if (!self.active) return;

        self.disown(allocator);
        self.notifyFailure(conn, selection);
    }

    pub fn own(self: *SendTransfer, allocator: std.mem.Allocator) !void {
        if (!self.active or self.owned) return;

        self.data  = try allocator.dupe(u8, self.data);
        self.owned = true;
    }

    pub fn disown(self: *SendTransfer, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.data);
        }
        self.owned = false;
    }

    pub fn sendChunk(self: *SendTransfer, conn: *c.xcb_connection_t, max_chunk_len: u32) !usize {
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
            self.active = false;
        }
        return chunk_len;
    }

    fn notifyFailure(self: *SendTransfer, conn: *c.xcb_connection_t, selection: c.xcb_atom_t) void {
        var notify: c.xcb_selection_notify_event_t = .{
            .response_type = c.XCB_SELECTION_NOTIFY,
            .time          = self.timestamp,
            .requestor     = self.requestor,
            .selection     = selection,
            .target        = self.mime,
            .property      = c.XCB_ATOM_NONE,
        };
        _ = c.xcb_send_event(conn, 0, self.requestor, c.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&notify));
        self.active = false;
    }
};

const RecvPool = struct {
    const MAX_RECVS = RECV_PROPERTIES.len;

    transfers: [MAX_RECVS]RecvTransfer,

    pub fn init(atoms: AtomStash) RecvPool {
        var self: RecvPool = undefined;
        for (&self.transfers, RECV_PROPERTIES) |*transfer, prop_name| {
            transfer.* = .{
                .mime     = undefined,
                .property = atoms.get(prop_name).?,
            };
        }
        return self;
    }

    pub fn acquire(self: *RecvPool) !*RecvTransfer {
        for (&self.transfers) |*transfer| {
            if (!transfer.active) return transfer;
        }
        return error.NoMemory;
    }

    pub fn acquireMultiple(self: *RecvPool, out: []*RecvTransfer) !void {
        std.debug.assert(out.len > 0);
        var i: usize = 0;
        for (&self.transfers) |*transfer| {
            if (transfer.active) continue;

            out[i] = transfer;
            i += 1;
            if (i == out.len) return;
        }
        return error.NoMemory;
    }

    pub fn slotsAvailable(self: RecvPool) usize {
        var res: usize = 0;
        for (self.transfers) |transfer| {
            if (!transfer.active) {
                res += 1;
            }
        }
        return res;
    }

    pub fn findByMime(self: *RecvPool, mime: c.xcb_atom_t) ?*RecvTransfer {
        for (&self.transfers) |*transfer| {
            if (transfer.mime == mime) return transfer;
        }
        return null;
    }

    pub fn findByProperty(self: *RecvPool, property: c.xcb_atom_t) ?*RecvTransfer {
        for (&self.transfers) |*transfer| {
            if (transfer.property == property) return transfer;
        }
        return null;
    }

    pub fn failAll(self: *RecvPool, allocator: std.mem.Allocator) void {
        for (&self.transfers) |*transfer| {
            transfer.fail(allocator);
        }
    }
};

const RecvTransfer = struct {
    active: bool = false,

    property: c.xcb_atom_t,
    mime:     c.xcb_atom_t,
    data:     ?[]const u8        = null,
    incr_buf: ?std.ArrayList(u8) = null,

    pub fn fail(self: *RecvTransfer, allocator: std.mem.Allocator) void {
        if (!self.active) return;
        self.active = false;
        self.data   = null;
        self.endIncr(allocator);
    }

    pub fn endIncr(self: *RecvTransfer, allocator: std.mem.Allocator) void {
        if (self.incr_buf) |*incr_buf| {
            incr_buf.deinit(allocator);
            self.incr_buf = null;
        }
    }
};

const SendData = struct {
    mime: c.xcb_atom_t,
    data: []const u8,
    format: u8 = 8,
};

const AtomPair = extern struct {
    mime: c.xcb_atom_t,
    prop: c.xcb_atom_t,
};

test {
    _ = AtomStash;
}
