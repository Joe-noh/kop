// Where the caret goes. Each function reads only the line it is on.
//
// A character is a codepoint together with the zero-width ones after it
// (combining marks, variation selectors), so "か゛" moves as one. "\r\n" is
// one step.

const std = @import("std");
const Text = @import("text.zig").Text;
const utf8 = @import("utf8.zig");
const width = @import("width.zig");

// Reads [a, b) of `t` into a buffer of the caller's.
fn slice(t: *const Text, a: usize, b: usize, buf: *std.ArrayList(u8)) ![]const u8 {
    buf.clearRetainingCapacity();
    try t.read(a, b, buf);
    return buf.items;
}

fn lineText(t: *const Text, n: usize, buf: *std.ArrayList(u8)) ![]const u8 {
    buf.clearRetainingCapacity();
    try t.readLine(n, buf);
    return buf.items;
}

pub fn charLeft(t: *const Text, pos: usize) !usize {
    if (pos == 0) return 0;
    const n = t.lineOf(pos);
    const ls = t.lineStart(n);
    if (pos == ls) return t.lineEnd(n - 1);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    const s = try slice(t, @max(ls, pos -| 32), pos, &buf);
    var j = utf8.prevStart(s, s.len);
    while (j > 0 and width.cellWidth(utf8.decode(s, j).cp) == 0) j = utf8.prevStart(s, j);
    return pos - (s.len - j);
}

pub fn charRight(t: *const Text, pos: usize) !usize {
    if (pos >= t.len) return t.len;
    const n = t.lineOf(pos);
    const le = t.lineEnd(n);
    if (pos >= le) return t.lineStart(n + 1);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    const s = try slice(t, pos, @min(le, pos + 32), &buf);
    var i = utf8.decode(s, 0).len;
    while (i < s.len) {
        const d = utf8.decode(s, i);
        if (width.cellWidth(d.cp) != 0) break;
        i += d.len;
    }
    return pos + i;
}

fn classAt(s: []const u8, i: usize) utf8.Class {
    return utf8.charClass(utf8.decode(s, i).cp);
}

fn next(s: []const u8, i: usize) usize {
    return i + utf8.decode(s, i).len;
}

// Past the spaces, then past the run of one character class.
pub fn wordRight(t: *const Text, pos: usize) !usize {
    const le = t.lineEnd(t.lineOf(pos));
    if (pos >= le) return charRight(t, pos);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    const line = try slice(t, pos, le, &buf);
    var i: usize = 0;
    while (i < line.len and classAt(line, i) == .space) i = next(line, i);
    if (i < line.len) {
        const c = classAt(line, i);
        while (i < line.len and classAt(line, i) == c) i = next(line, i);
    }
    return pos + i;
}

pub fn wordLeft(t: *const Text, pos: usize) !usize {
    const ls = t.lineStart(t.lineOf(pos));
    if (pos <= ls) return charLeft(t, pos);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    const line = try slice(t, ls, pos, &buf);
    var i = line.len;
    while (i > 0 and classAt(line, utf8.prevStart(line, i)) == .space) i = utf8.prevStart(line, i);
    if (i > 0) {
        const c = classAt(line, utf8.prevStart(line, i));
        while (i > 0 and classAt(line, utf8.prevStart(line, i)) == c) i = utf8.prevStart(line, i);
    }
    return ls + i;
}

pub const Range = struct { a: usize, b: usize };

// The word (or run of spaces, or of one punctuation class) around `pos`.
pub fn wordRange(t: *const Text, pos: usize) !Range {
    const n = t.lineOf(pos);
    const ls = t.lineStart(n);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    const line = try lineText(t, n, &buf);
    if (line.len == 0) return .{ .a = pos, .b = pos };
    var at = @min(pos - ls, line.len);
    if (at == line.len) at = utf8.prevStart(line, at);
    const c = classAt(line, at);
    var a = at;
    while (a > 0 and classAt(line, utf8.prevStart(line, a)) == c) a = utf8.prevStart(line, a);
    var b = at;
    while (b < line.len and classAt(line, b) == c) b = next(line, b);
    return .{ .a = ls + a, .b = ls + b };
}

// The whole line `pos` is on, its break included.
pub fn lineRange(t: *const Text, pos: usize) Range {
    const n = t.lineOf(pos);
    return .{ .a = t.lineStart(n), .b = if (n == t.lf) t.len else t.lineStart(n + 1) };
}

// Home: the first non-blank of the line, or its start if already there.
pub fn smartHome(t: *const Text, pos: usize) !usize {
    const n = t.lineOf(pos);
    const ls = t.lineStart(n);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    const line = try lineText(t, n, &buf);
    var i: usize = 0;
    while (i < line.len and classAt(line, i) == .space) i = next(line, i);
    if (pos == ls + i) return ls;
    return ls + i;
}

pub fn lineEndAt(t: *const Text, pos: usize) usize {
    return t.lineEnd(t.lineOf(pos));
}

pub fn lineStartAt(t: *const Text, pos: usize) usize {
    return t.lineStart(t.lineOf(pos));
}

// The cell column of `pos` on its line.
pub fn colOf(t: *const Text, pos: usize) !usize {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    return width.advance(try slice(t, lineStartAt(t, pos), pos, &buf), 0);
}

// The offset on line `n` nearest to cell column `col`.
pub fn posAtCol(t: *const Text, n: usize, col: usize) !usize {
    const line_n = @min(n, t.lf);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    return t.lineStart(line_n) + width.offsetAtCol(try lineText(t, line_n, &buf), col);
}

pub const Vertical = struct { pos: usize, goal: usize };

// `lines` up (negative) or down, aiming at `goal` (or the caret's own
// column); returns the new offset and the goal kept.
pub fn vertical(t: *const Text, pos: usize, goal: ?usize, lines: i64) !Vertical {
    const col = goal orelse try colOf(t, pos);
    const n = @as(i64, @intCast(t.lineOf(pos))) + lines;
    if (n < 0) return .{ .pos = 0, .goal = col };
    if (n > t.lf) return .{ .pos = t.len, .goal = col };
    return .{ .pos = try posAtCol(t, @intCast(n), col), .goal = col };
}

test "motion" {
    const testing = std.testing;
    const tt = try @import("text.zig").TestText.init("日本語テキストです abc_1 ok\n  x");
    defer tt.deinit();
    const t = &tt.t;
    try testing.expectEqual(@as(usize, 9), try wordRight(t, 0));
    try testing.expectEqual(@as(usize, 21), try wordRight(t, 9));
    try testing.expectEqual(@as(usize, 27), try wordRight(t, 21));
    try testing.expectEqual(@as(usize, 33), try wordRight(t, 27));
    try testing.expectEqual(@as(usize, 28), try wordLeft(t, 33));
    const r = try wordRange(t, 12);
    try testing.expect(r.a == 9 and r.b == 21);
    try testing.expect(try charRight(t, 0) == 3 and try charLeft(t, 3) == 0);
    try testing.expectEqual(@as(usize, 6), try colOf(t, 9));
    const v = try vertical(t, 9, null, 1);
    try testing.expect(v.pos == t.lineStart(1) + 3 and v.goal == 6);
    const v2 = try vertical(t, v.pos, v.goal, -1);
    try testing.expectEqual(@as(usize, 9), v2.pos);
    try testing.expectEqual(t.lineStart(1) + 2, try smartHome(t, t.lineStart(1) + 3));
}
