// Commands on the document: each applies to every selection, and each
// edit is one undo group.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const Text = text.Text;
const select = @import("select.zig");
const Sel = select.Sel;
const undo = @import("undo.zig");
const History = undo.History;
const Kind = undo.Kind;
const motion = @import("motion.zig");
const width = @import("width.zig");

pub const Editor = struct {
    gpa: Allocator,
    t: Text,
    h: History,
    sels: std.ArrayList(Sel) = .empty,
    crlf: bool = false, // line breaks are "\r\n"
    tabs: bool = false, // indent with tabs rather than spaces

    // An editor over `orig`, which, with `orig_lf`, must outlive it.
    pub fn init(gpa: Allocator, orig: []const u8, orig_lf: []const usize) !Editor {
        var ed = Editor{ .gpa = gpa, .t = try Text.init(gpa, orig, orig_lf), .h = History.init(gpa) };
        try ed.sels.append(gpa, Sel.caret(0));
        return ed;
    }

    pub fn deinit(ed: *Editor) void {
        ed.t.deinit();
        ed.h.deinit();
        ed.sels.deinit(ed.gpa);
    }

    pub fn eol(ed: *const Editor) []const u8 {
        return if (ed.crlf) "\r\n" else "\n";
    }

    pub fn primary(ed: *const Editor) Sel {
        return ed.sels.items[ed.sels.items.len - 1];
    }

    pub fn setSingle(ed: *Editor, s: Sel) void {
        ed.sels.clearRetainingCapacity();
        ed.sels.appendAssumeCapacity(s);
        ed.h.seal();
    }

    // Replaces each selection with what ctx.write(ed, start, end, out) writes
    // into `out`; positions are those of the text as it is when it is called.
    pub fn replaceEach(ed: *Editor, kind: Kind, ctx: anytype) !void {
        select.normalize(&ed.sels);
        try ed.h.beginGroup(ed.sels.items, kind);
        var delta: isize = 0;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ed.gpa);
        for (0..ed.sels.items.len) |i| {
            const s = ed.sels.items[i];
            const a: usize = @intCast(@as(isize, @intCast(s.lo())) + delta);
            const b: usize = @intCast(@as(isize, @intCast(s.hi())) + delta);
            out.clearRetainingCapacity();
            try ctx.write(ed, a, b, &out);
            try ed.h.replace(&ed.t, a, b - a, out.items);
            ed.sels.items[i] = Sel.caret(a + out.items.len);
            delta += @as(isize, @intCast(out.items.len)) - @as(isize, @intCast(b - a));
        }
        select.normalize(&ed.sels);
        try ed.h.endGroup(ed.sels.items, kind);
    }

    pub fn insertText(ed: *Editor, bytes: []const u8, kind: Kind) !void {
        try ed.replaceEach(kind, struct {
            bytes: []const u8,
            fn write(self: @This(), e: *Editor, _: usize, _: usize, out: *std.ArrayList(u8)) !void {
                try out.appendSlice(e.gpa, self.bytes);
            }
        }{ .bytes = bytes });
    }

    // Deletes each selection, or for a caret, the text between it and
    // ctx.to(ed, caret).
    pub fn deleteEach(ed: *Editor, ctx: anytype) !void {
        select.normalize(&ed.sels);
        var ranges: std.ArrayList(motion.Range) = .empty;
        defer ranges.deinit(ed.gpa);
        var any = false;
        var prev_end: usize = 0;
        for (ed.sels.items) |s| {
            var a = s.lo();
            var b = s.hi();
            if (s.isEmpty()) {
                const to = try ctx.to(ed, s.head);
                a = @min(s.head, to);
                b = @max(s.head, to);
            }
            a = @max(a, prev_end);
            b = @max(a, b);
            try ranges.append(ed.gpa, .{ .a = a, .b = b });
            if (b > a) any = true;
            prev_end = b;
        }
        if (!any) return;
        try ed.h.beginGroup(ed.sels.items, .edit);
        var removed: usize = 0;
        for (ranges.items, 0..) |r, i| {
            const a = r.a - removed;
            try ed.h.replace(&ed.t, a, r.b - r.a, "");
            ed.sels.items[i] = Sel.caret(a);
            removed += r.b - r.a;
        }
        select.normalize(&ed.sels);
        try ed.h.endGroup(ed.sels.items, .edit);
    }

    // Moves each caret where ctx.move(ed, &sel) puts its head (and goal, for
    // vertical motion); with `extend` the anchors stay, so the selections grow.
    pub fn moveEach(ed: *Editor, extend: bool, ctx: anytype) !void {
        for (ed.sels.items) |*s| {
            try ctx.move(ed, s);
            if (!extend) s.anchor = s.head;
        }
        select.normalize(&ed.sels);
        ed.h.seal();
    }

    // The leading blanks of the line `pos` is on, up to `pos`.
    fn indentBefore(ed: *Editor, pos: usize, out: *std.ArrayList(u8)) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(ed.gpa);
        try ed.t.read(motion.lineStartAt(&ed.t, pos), pos, &line);
        for (line.items) |c| {
            if (c != ' ' and c != '\t') break;
            try out.append(ed.gpa, c);
        }
    }

    pub fn newline(ed: *Editor) !void {
        try ed.replaceEach(.edit, struct {
            fn write(_: @This(), e: *Editor, a: usize, _: usize, out: *std.ArrayList(u8)) !void {
                try out.appendSlice(e.gpa, e.eol());
                try e.indentBefore(a, out);
            }
        }{});
    }

    pub fn tab(ed: *Editor) !void {
        try ed.replaceEach(.type, struct {
            fn write(_: @This(), e: *Editor, a: usize, _: usize, out: *std.ArrayList(u8)) !void {
                if (e.tabs) {
                    try out.append(e.gpa, '\t');
                } else {
                    const col = try motion.colOf(&e.t, a);
                    try out.appendNTimes(e.gpa, ' ', width.tab_size - col % width.tab_size);
                }
            }
        }{});
    }

    // `src` with its line breaks made the document's.
    fn withEol(ed: *Editor, src: []const u8, out: *std.ArrayList(u8)) !void {
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            if (c == '\r' and i + 1 < src.len and src[i + 1] == '\n') continue;
            if (c == '\n' or c == '\r') try out.appendSlice(ed.gpa, ed.eol()) else try out.append(ed.gpa, c);
        }
    }

    // Pastes `src`; when it has one line per selection, each gets its own line.
    pub fn paste(ed: *Editor, src: []const u8) !void {
        var norm: std.ArrayList(u8) = .empty;
        defer norm.deinit(ed.gpa);
        try ed.withEol(src, &norm);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(ed.gpa);
        var it = std.mem.splitSequence(u8, norm.items, ed.eol());
        while (it.next()) |p| try parts.append(ed.gpa, p);
        var count = parts.items.len;
        if (count > 1 and parts.items[count - 1].len == 0) count -= 1;
        if (ed.sels.items.len > 1 and count == ed.sels.items.len) {
            select.normalize(&ed.sels);
            if (count == ed.sels.items.len) {
                var ctx = struct {
                    parts: [][]const u8,
                    i: usize = 0,
                    fn write(self: *@This(), e: *Editor, _: usize, _: usize, out: *std.ArrayList(u8)) !void {
                        try out.appendSlice(e.gpa, self.parts[self.i]);
                        self.i += 1;
                    }
                }{ .parts = parts.items };
                try ed.replaceEach(.edit, &ctx);
                return;
            }
        }
        try ed.insertText(norm.items, .edit);
    }

    fn allEmpty(ed: *const Editor) bool {
        for (ed.sels.items) |s| if (!s.isEmpty()) return false;
        return true;
    }

    // The selected text, selections joined by line breaks. An empty selection
    // stands for its whole line, line break included, as copy and cut take it.
    pub fn copyText(ed: *Editor, out: *std.ArrayList(u8)) !void {
        select.normalize(&ed.sels);
        const whole_lines = ed.allEmpty();
        for (ed.sels.items, 0..) |s, i| {
            if (whole_lines) {
                const n = ed.t.lineOf(s.head);
                try ed.t.read(ed.t.lineStart(n), ed.t.lineStart(n + 1), out);
                if (n == ed.t.lf) try out.appendSlice(ed.gpa, ed.eol());
            } else {
                if (i > 0) try out.appendSlice(ed.gpa, ed.eol());
                try ed.t.read(s.lo(), s.hi(), out);
            }
        }
    }

    pub fn cutSelection(ed: *Editor) !void {
        select.normalize(&ed.sels);
        if (ed.allEmpty()) {
            // Whole lines: select each caret's line, break included.
            for (ed.sels.items) |*s| {
                const r = motion.lineRange(&ed.t, s.head);
                s.anchor = r.a;
                s.head = r.b;
            }
            select.normalize(&ed.sels);
        }
        try ed.deleteEach(struct {
            fn to(_: @This(), _: *Editor, pos: usize) !usize {
                return pos;
            }
        }{});
    }

    pub fn selectAll(ed: *Editor) void {
        ed.setSingle(.{ .anchor = 0, .head = ed.t.len });
    }

    // The next (or previous) match of `needle` after the primary selection,
    // wrapping around; selects it and returns whether there was one.
    pub fn findNext(ed: *Editor, needle: []const u8, forward: bool) !bool {
        if (needle.len == 0) return false;
        const s = ed.primary();
        const found = if (forward)
            try ed.t.findForward(s.hi(), needle) orelse try ed.t.findForward(0, needle)
        else
            try ed.t.findBackward(s.lo(), needle) orelse try ed.t.findBackward(ed.t.len, needle);
        const at = found orelse return false;
        ed.setSingle(.{ .anchor = at, .head = at + needle.len });
        return true;
    }

    pub fn undo(ed: *Editor) !bool {
        return ed.h.undo(&ed.t, &ed.sels);
    }

    pub fn redo(ed: *Editor) !bool {
        return ed.h.redo(&ed.t, &ed.sels);
    }
};

// Deletions by motion, for deleteEach.
pub const ToCharLeft = struct {
    pub fn to(_: ToCharLeft, ed: *Editor, pos: usize) !usize {
        return motion.charLeft(&ed.t, pos);
    }
};
pub const ToCharRight = struct {
    pub fn to(_: ToCharRight, ed: *Editor, pos: usize) !usize {
        return motion.charRight(&ed.t, pos);
    }
};
pub const ToWordLeft = struct {
    pub fn to(_: ToWordLeft, ed: *Editor, pos: usize) !usize {
        return motion.wordLeft(&ed.t, pos);
    }
};
pub const ToWordRight = struct {
    pub fn to(_: ToWordRight, ed: *Editor, pos: usize) !usize {
        return motion.wordRight(&ed.t, pos);
    }
};
pub const ToLineStart = struct {
    pub fn to(_: ToLineStart, ed: *Editor, pos: usize) !usize {
        return motion.lineStartAt(&ed.t, pos);
    }
};
// At a line's end, the line break, as Emacs's Ctrl+K takes it.
pub const ToLineEnd = struct {
    pub fn to(_: ToLineEnd, ed: *Editor, pos: usize) !usize {
        const le = motion.lineEndAt(&ed.t, pos);
        return if (le == pos) motion.charRight(&ed.t, pos) else le;
    }
};

// Tests.

const testing = std.testing;

const TestEditor = struct {
    lf: std.ArrayList(usize) = .empty,
    ed: Editor,

    fn init(src: []const u8, crlf: bool) !*TestEditor {
        const self = try testing.allocator.create(TestEditor);
        self.* = .{ .ed = undefined };
        try text.indexLf(testing.allocator, src, &self.lf);
        self.ed = try Editor.init(testing.allocator, src, self.lf.items);
        self.ed.crlf = crlf;
        return self;
    }

    fn deinit(self: *TestEditor) void {
        self.ed.deinit();
        self.lf.deinit(testing.allocator);
        testing.allocator.destroy(self);
    }
};

fn expectText(ed: *Editor, want: []const u8) !void {
    const got = try text.wholeOf(&ed.t);
    defer ed.gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

fn typeStr(ed: *Editor, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const n = @import("utf8.zig").decode(s, i).len;
        try ed.insertText(s[i .. i + n], .type);
        i += n;
    }
}

test "editing" {
    {
        const te = try TestEditor.init("", false);
        defer te.deinit();
        const ed = &te.ed;
        try typeStr(ed, "  日本語");
        try ed.newline();
        try typeStr(ed, "abc");
        try expectText(ed, "  日本語\n  abc");
        try testing.expectEqual(@as(usize, 3), ed.h.groups.items.len);
        try ed.deleteEach(ToCharLeft{});
        try ed.deleteEach(ToCharLeft{});
        try expectText(ed, "  日本語\n  a");
        try testing.expect(try ed.undo());
        try expectText(ed, "  日本語\n  ab");
        try testing.expect(try ed.undo());
        try expectText(ed, "  日本語\n  abc");
        try testing.expect(try ed.undo());
        try expectText(ed, "  日本語\n  ");
        try testing.expect(try ed.undo());
        try expectText(ed, "  日本語");
        try testing.expect(try ed.redo() and try ed.redo());
        try expectText(ed, "  日本語\n  abc");
        try testing.expectEqual(ed.t.len, ed.primary().head);
        try typeStr(ed, "!");
        try testing.expect(!try ed.redo());
    }
    {
        const te = try TestEditor.init("one\r\ntwo", true);
        defer te.deinit();
        const ed = &te.ed;
        ed.setSingle(Sel.caret(5));
        try ed.deleteEach(ToCharLeft{});
        try expectText(ed, "onetwo");
        try ed.newline();
        try expectText(ed, "one\r\ntwo");
        try ed.paste("x\ny\n");
        try expectText(ed, "one\r\nx\r\ny\r\ntwo");
    }
}

test "multiple cursors" {
    const te = try TestEditor.init("aa\nbb\ncc", false);
    defer te.deinit();
    const ed = &te.ed;
    ed.sels.clearRetainingCapacity();
    try ed.sels.appendSlice(ed.gpa, &.{ Sel.caret(6), Sel.caret(0), Sel.caret(3) });
    try ed.insertText("> ", .type);
    try expectText(ed, "> aa\n> bb\n> cc");
    try ed.deleteEach(ToCharLeft{});
    try expectText(ed, ">aa\n>bb\n>cc");
    try testing.expect(try ed.undo());
    try expectText(ed, "> aa\n> bb\n> cc");
    try testing.expectEqual(@as(usize, 3), ed.sels.items.len);
    var copied: std.ArrayList(u8) = .empty;
    defer copied.deinit(ed.gpa);
    try ed.copyText(&copied);
    try testing.expectEqualStrings("> aa\n> bb\n> cc\n", copied.items);
    ed.setSingle(Sel.caret(0));
    try ed.sels.appendSlice(ed.gpa, &.{ Sel.caret(5), Sel.caret(10) });
    try ed.paste("1\n2\n3");
    try expectText(ed, "1> aa\n2> bb\n3> cc");
}

// Random commands, then undo all of them and redo all of them.
test "undo fuzz" {
    const te = try TestEditor.init("first line\nsecond\n\tthird 日本\n", false);
    defer te.deinit();
    const ed = &te.ed;
    var prng = std.Random.DefaultPrng.init(777);
    const r = prng.random();
    var states: std.ArrayList(u64) = .empty; // a hash of the text after each edit
    defer states.deinit(ed.gpa);
    const hashOf = struct {
        fn f(e: *Editor) !u64 {
            const got = try text.wholeOf(&e.t);
            defer e.gpa.free(got);
            return std.hash.Wyhash.hash(0, got);
        }
    }.f;
    try states.append(ed.gpa, try hashOf(ed));
    for (0..400) |_| {
        const n = ed.t.len;
        ed.sels.clearRetainingCapacity();
        for (0..r.uintLessThan(usize, 3) + 1) |_| {
            const a = r.uintAtMost(usize, n);
            const b = if (r.boolean()) a else r.uintAtMost(usize, n);
            try ed.sels.append(ed.gpa, .{ .anchor = a, .head = b });
        }
        // Keep the carets on character boundaries.
        for (ed.sels.items) |*s| {
            while (s.anchor > 0 and s.anchor < n and @import("utf8.zig").isCont(ed.t.byteAt(s.anchor))) s.anchor -= 1;
            while (s.head > 0 and s.head < n and @import("utf8.zig").isCont(ed.t.byteAt(s.head))) s.head -= 1;
        }
        ed.h.seal();
        const before = ed.h.applied;
        switch (r.uintLessThan(usize, 5)) {
            0 => try ed.insertText("xy", .edit),
            1 => try ed.insertText("語\n", .edit),
            2 => try ed.deleteEach(ToCharLeft{}),
            3 => try ed.newline(),
            else => try ed.paste("p\nq"),
        }
        if (ed.h.applied != before) try states.append(ed.gpa, try hashOf(ed));
    }
    var i = states.items.len - 1;
    while (i > 0) {
        i -= 1;
        try testing.expect(try ed.undo());
        try testing.expectEqual(states.items[i], try hashOf(ed));
    }
    try testing.expect(!try ed.undo());
    for (states.items[1..]) |s| {
        try testing.expect(try ed.redo());
        try testing.expectEqual(s, try hashOf(ed));
    }
    try testing.expect(!try ed.redo());
}
