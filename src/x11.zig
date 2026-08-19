const std = @import("std");
const c   = @import("x11");

const Self = @This();

conn:   *c.xcb_connection_t,
screen: *c.xcb_screen_t,
window:  c.xcb_window_t,

atoms:     std.StringHashMapUnmanaged(c.xcb_atom_t) = .empty,
clipboard: []const u8 = &.{},

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Self {
    var pref_screen: c_int = undefined;

    const conn = c.xcb_connect(null, &pref_screen) orelse return error.NoDisplay;
    errdefer c.xcb_disconnect(conn);
    if (c.xcb_connection_has_error(conn) != 0) {
        return error.NoDisplay;
    }

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

    return .{
        .conn   = conn,
        .screen = screen,
        .window = window,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.atoms.deinit(self.allocator);
    self.allocator.free(self.clipboard);
    c.xcb_disconnect(self.conn);
    self.* = undefined;
}

