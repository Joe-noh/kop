// What the window system gives through SDL: the clipboard, the mouse's
// cursors, and where the input method shows its candidates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

// The clipboard's text, empty if it has none, in the caller's buffer.
pub fn clipboard(gpa: Allocator, out: *std.ArrayList(u8)) !void {
    const p = c.SDL_GetClipboardText() orelse return;
    defer c.SDL_free(p);
    try out.appendSlice(gpa, std.mem.span(p));
}

pub fn setClipboard(gpa: Allocator, s: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, s, 0);
    defer gpa.free(z);
    _ = c.SDL_SetClipboardText(z.ptr);
}

pub const Cursor = enum { arrow, text, pointer };

pub const Cursors = struct {
    arrow: ?*c.SDL_Cursor,
    text: ?*c.SDL_Cursor,
    pointer: ?*c.SDL_Cursor,
    shown: Cursor = .arrow,

    pub fn init() Cursors {
        return .{
            .arrow = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
            .text = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT),
            .pointer = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
        };
    }

    pub fn deinit(cs: *Cursors) void {
        for ([_]?*c.SDL_Cursor{ cs.arrow, cs.text, cs.pointer }) |p| if (p) |q| c.SDL_DestroyCursor(q);
    }

    pub fn show(cs: *Cursors, which: Cursor) void {
        if (which == cs.shown) return;
        const handle = switch (which) {
            .arrow => cs.arrow,
            .text => cs.text,
            .pointer => cs.pointer,
        };
        if (handle) |h| _ = c.SDL_SetCursor(h);
        cs.shown = which;
    }
};

// Tells the input method where the caret is, in pixels, so its candidate
// window opens beside it.
pub fn setImeCaret(win: *c.SDL_Window, density: f32, x: f32, y: f32, h: f32) void {
    const r = c.SDL_Rect{ .x = @intFromFloat(x / density), .y = @intFromFloat(y / density), .w = 1, .h = @max(@as(c_int, @intFromFloat(h / density)), 1) };
    _ = c.SDL_SetTextInputArea(win, &r, 0);
}
