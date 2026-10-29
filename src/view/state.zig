// What the window shows and what it is in the middle of, apart from the
// document itself.

const std = @import("std");
const doc = @import("../core/doc.zig");
const utf8 = @import("../core/utf8.zig");

pub const Bar = enum {
    none,
    find, // the search field at the bottom
    save_as, // asking where to save an untitled document
};

pub const Drag = enum { none, chars, words, lines };

// Text of at most `n` bytes, cut at a character's boundary when longer.
pub fn Buf(comptime n: usize) type {
    return struct {
        bytes: [n]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn slice(b: *const Self) []const u8 {
            return b.bytes[0..b.len];
        }

        pub fn set(b: *Self, s: []const u8) void {
            b.len = 0;
            b.append(s);
        }

        pub fn append(b: *Self, s: []const u8) void {
            var end = @min(s.len, n - b.len);
            while (end < s.len and end > 0 and utf8.isCont(s[end])) end -= 1;
            @memcpy(b.bytes[b.len..][0..end], s[0..end]);
            b.len += end;
        }

        // Removes the last character.
        pub fn pop(b: *Self) void {
            b.len = utf8.prevStart(b.slice(), b.len);
        }

        pub fn eql(b: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, b.slice(), s);
        }
    };
}

// A file as it is on disk, to tell when something else has changed it.
pub const DiskStamp = struct {
    exists: bool = false,
    size: u64 = 0,
    mtime: i128 = 0,

    pub fn of(path: []const u8) DiskStamp {
        if (path.len == 0) return .{};
        const st = std.fs.cwd().statFile(path) catch return .{};
        if (st.kind != .file) return .{};
        return .{ .exists = true, .size = st.size, .mtime = st.mtime };
    }

    pub fn same(a: DiskStamp, b: DiskStamp) bool {
        return a.exists == b.exists and a.size == b.size and a.mtime == b.mtime;
    }
};

pub const View = struct {
    path: Buf(1024) = .{},
    info: doc.FileInfo = .{},
    readonly: bool = false,
    // The grid: the first line and cell column shown, how many fit, and
    // where the text starts, in pixels.
    top: usize = 0,
    left: usize = 0,
    rows: usize = 1,
    cols: usize = 1,
    panel_w: f32 = 0, // the file tree's width, left of the text
    right_cells: usize = 0, // the width of the changes on the right, in the ui's cells; 0 when hidden
    right_x: f32 = 0, // where they start
    text_x: f32 = 0,
    text_y: f32 = 0,
    text_bottom: f32 = 0,
    cell_w: f32 = 8, // the text's cells
    line_h: f32 = 16,
    ui_cell_w: f32 = 8, // the tree's and the bars'
    ui_line_h: f32 = 16,
    tree_y: f32 = 0, // where the tree's header row starts
    tree_bottom: f32 = 0,
    tree_rows: usize = 1, // entry rows that fit below the header
    follow: bool = true, // scroll to the primary caret at the next draw
    center: bool = false, // and put it a third of the way down
    scroll_y: f32 = 0, // how far the top line is scrolled up out of view, in pixels
    drag: Drag = .none,
    drag_a: usize = 0, // the word or line first clicked, for drags by words or lines
    drag_b: usize = 0,
    bar: Bar = .none,
    query: Buf(256) = .{},
    message: Buf(240) = .{},
    message_at: f64 = -100,
    blink_at: f64 = 0, // the caret shows steadily for a moment after it moves
    // What the input method is composing, shown at the caret until it is done.
    composing: Buf(256) = .{},
    quit: bool = false,
    // A file picked in the tree, to open once this document lets go of the
    // window; picking it again while this one has unsaved changes drops them.
    open_request: bool = false,
    open_path: Buf(1024) = .{},
    discard_path: Buf(1024) = .{},
    // The file on disk: as it was when read or saved, when it was last
    // looked at, and the change already told of. Reloading reads it again.
    disk: DiskStamp = .{},
    disk_checked: f64 = 0,
    disk_told: DiskStamp = .{},
    reload_request: bool = false,
    search_request: bool = false, // to search the whole project
    diff_request: bool = false, // to show what has changed since HEAD
    changes_click: ?f32 = null, // a click on the changes, at this height
    changes_wheel: f32 = 0, // the wheel turned over them, in rows
    saves: usize = 0, // how many times the document was saved
    changes_toggle: bool = false, // to show or hide the changes
    overwrite_ok: bool = false, // told that saving overwrites a change on disk; the next save does
};

// Seconds since the program started.
var started: ?std.time.Instant = null;

pub fn clock() f64 {
    const now = std.time.Instant.now() catch return 0;
    if (started == null) started = now;
    return @as(f64, @floatFromInt(now.since(started.?))) / 1e9;
}

pub fn say(v: *View, msg: []const u8) void {
    v.message.set(msg);
    v.message_at = clock();
}
