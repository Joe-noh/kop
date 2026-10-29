// What has changed since HEAD, every changed file in one view: under each
// file's heading, the lines around its changes, the lines removed on red
// and those added on green. The lines as they are now can be edited where
// they stand, and Cmd+S saves every file edited. The document the window
// had open is edited through its own editor, so its history goes on.

const std = @import("std");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const text = @import("../core/text.zig");
const edit = @import("../core/edit.zig");
const Editor = edit.Editor;
const Sel = @import("../core/select.zig").Sel;
const motion = @import("../core/motion.zig");
const doc = @import("../core/doc.zig");
const git = @import("../core/git.zig");
const diff = @import("../core/diff.zig");
const search = @import("../core/search.zig");
const width = @import("../core/width.zig");
const syntax = @import("../core/syntax.zig");
const keymap = @import("../core/keymap.zig");
const Command = keymap.Command;
const state = @import("state.zig");
const View = state.View;
const font = @import("font.zig");
const render = @import("render.zig");
const fill = render.fill;
const theme = @import("theme.zig");
const Tree = @import("tree.zig").Tree;
const input = @import("input.zig");
const platform = @import("platform.zig");
const changes_view = @import("changes.zig");

const context_lines = 3;

fn th() *const theme.Theme {
    return &theme.current;
}

fn float(n: usize) f32 {
    return @floatFromInt(n);
}

// A file opened for the view: its bytes and their newlines, which its
// editor's text is made over and which must stay where they are.
const Loaded = struct {
    data: []u8,
    lf: std.ArrayList(usize) = .empty,
    ed: Editor,
};

const File = struct {
    name: []const u8,
    path: []const u8,
    kind: git.Kind,
    loaded: ?*Loaded = null, // opened here; null for the window's own document, or none
    ed: ?*Editor = null, // the lines as they are now; null for a deleted file, or one that cannot be edited
    info: doc.FileInfo = .{},
    head: []u8 = &.{}, // as HEAD has it
    old_starts: []usize = &.{}, // where its lines start
    old_states: []u8 = &.{}, // the lexer's state as each starts
    live: diff.Live,
    hl: ?syntax.Highlight = null,
    note: ?[]const u8 = null, // why its lines are not shown

    // HEAD's lines, as git counts them: none after a last line break.
    fn oldCount(f: *const File) usize {
        return diff.lineCount(f.head);
    }

    fn oldLine(f: *const File, n: usize) []const u8 {
        const a = f.old_starts[n];
        var b = if (n + 1 < f.old_starts.len) f.old_starts[n + 1] - 1 else f.head.len;
        if (b > a and f.head[b - 1] == '\r') b -= 1;
        return f.head[a..b];
    }
};

pub const Row = struct {
    kind: enum { header, note, gap, old, new },
    file: usize,
    line: usize = 0, // an old line's number in HEAD's version; a new one's in the text now
    added: bool = false, // a new line the change added
};

pub const Action = union(enum) {
    none,
    back,
    quit,
    open: struct { path: []const u8, line: usize, col: usize },
};

pub const Screen = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    files: std.ArrayList(File) = .empty,
    rows: std.ArrayList(Row) = .empty,
    active: ?usize = null, // the file the caret is in
    v: View = .{},
    sticky: ?usize = null,
    sticky_bottom: f32 = 0,
    discard_asked: bool = false, // told that leaving drops unsaved changes
    // The changes on the right, as the window has them, shown or not.
    panel: ?*changes_view.Panel = null,
    panel_shown: ?*bool = null,
    line: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(syntax.Span) = .empty,

    pub fn init(gpa: Allocator) Screen {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(s: *Screen) void {
        for (s.files.items) |*f| {
            f.live.deinit();
            if (f.hl) |*h| h.deinit();
            if (f.loaded) |l| {
                l.ed.deinit();
                l.lf.deinit(s.gpa);
                s.gpa.free(l.data);
                s.gpa.destroy(l);
            }
        }
        s.files.deinit(s.gpa);
        s.rows.deinit(s.gpa);
        s.line.deinit(s.gpa);
        s.spans.deinit(s.gpa);
        s.arena.deinit();
    }

    // Opens the changed files: `own` is the window's document, at `own_path`,
    // used as it is rather than read again.
    pub fn load(s: *Screen, changes: []const git.Change, own: *Editor, own_path: []const u8, own_info: doc.FileInfo) !void {
        const a = s.arena.allocator();
        for (changes) |ch| {
            var f = File{ .name = try a.dupe(u8, ch.name), .path = try a.dupe(u8, ch.path), .kind = ch.kind, .live = .{ .gpa = s.gpa } };
            // HEAD's version, and its lines' states for their colors.
            if (try git.headVersion(s.gpa, ch.path)) |hv| {
                var h = hv;
                defer h.deinit();
                f.head = try a.dupe(u8, h.data);
                try f.live.setBase(h.data, h.tracked);
            } else try f.live.setBase("", false);
            f.old_starts = try search.lineStarts(a, f.head);
            f.old_states = try a.alloc(u8, f.old_starts.len);
            const lang = syntax.languages.languageFor(ch.path);
            var st: u8 = syntax.state_normal;
            for (0..f.old_starts.len) |n| {
                f.old_states[n] = st;
                if (lang) |l| {
                    s.spans.clearRetainingCapacity();
                    st = try syntax.lexLine(s.gpa, l, f.oldLine(n), st, &s.spans);
                }
            }
            if (ch.kind != .deleted) {
                if (std.mem.eql(u8, ch.path, own_path)) {
                    f.ed = own;
                    f.info = own_info;
                } else if (sys.readFile(s.gpa, ch.path, diff.Live.max_bytes)) |data| {
                    const info = doc.detect(data);
                    if (!info.utf8 or std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) != null) {
                        s.gpa.free(data);
                        f.note = "Binary, or not UTF-8";
                    } else {
                        const l = try s.gpa.create(Loaded);
                        l.* = .{ .data = data, .ed = undefined };
                        const body = doc.body(data);
                        try text.indexLf(s.gpa, body, &l.lf);
                        l.ed = try Editor.init(s.gpa, body, l.lf.items);
                        l.ed.crlf = info.crlf;
                        l.ed.tabs = info.tabs;
                        f.loaded = l;
                        f.ed = &l.ed;
                        f.info = info;
                    }
                } else |e| {
                    if (e == error.OutOfMemory) return e;
                    f.note = if (e == error.StreamTooLong) "Too large to show" else "Cannot be read";
                }
                if (f.ed) |ed| {
                    f.hl = try syntax.Highlight.init(s.gpa, ch.path);
                    try f.live.update(&ed.t);
                }
            } else if (f.head.len == 0) f.note = "Deleted";
            if (ch.added == null and ch.removed == null and f.note == null) f.note = "Binary";
            try s.files.append(s.gpa, f);
        }
        try s.build();
        // The caret starts at the first change.
        for (s.rows.items) |r| if ((r.kind == .new and r.added) or r.kind == .old) {
            if (s.files.items[r.file].ed) |ed| {
                s.active = r.file;
                const n = if (r.kind == .new) r.line else s.newLineNear(r);
                ed.setSingle(Sel.caret(ed.t.lineStart(n)));
                break;
            }
        };
        if (s.active == null) for (s.rows.items) |r| if (r.kind == .new) {
            s.active = r.file;
            break;
        };
        s.v.follow = true;
    }

    // The line as it is now where an old line's change is.
    fn newLineNear(s: *const Screen, r: Row) usize {
        const f = s.file(r.file);
        const ed = f.ed orelse return 0;
        for (f.live.hunks.items) |h| {
            if (r.line >= h.old_start and r.line < h.old_start + h.old_count) return @min(h.new_start, ed.t.lf);
        }
        return 0;
    }

    // Scrolls to the file at `path`, its heading at the top, and puts the
    // caret at its first change.
    fn jumpTo(s: *Screen, path: []const u8) void {
        for (s.rows.items, 0..) |r, i| {
            if (r.kind != .header or !std.mem.eql(u8, s.files.items[r.file].path, path)) continue;
            s.v.top = i;
            s.v.scroll_y = 0;
            s.v.blink_at = state.clock();
            for (s.rows.items[i + 1 ..]) |q| {
                if (q.file != r.file) break;
                if (!((q.kind == .new and q.added) or q.kind == .old)) continue;
                const ed = s.files.items[r.file].ed orelse break;
                s.active = r.file;
                const n = if (q.kind == .new) q.line else s.newLineNear(q);
                ed.setSingle(Sel.caret(ed.t.lineStart(n)));
                break;
            }
            return;
        }
    }

    // The mouse's cursor at a point.
    pub fn cursorAt(s: *const Screen, x: f32, y: f32) platform.Cursor {
        if (s.v.right_cells > 0 and x >= s.v.right_x) return if (s.panel.?.changeAt(&s.v, y) != null) .pointer else .arrow;
        if (x < s.v.panel_w) return .arrow;
        return .text;
    }

    fn file(s: *const Screen, i: usize) *const File {
        return &s.files.items[i];
    }

    // Lays out the rows: each file's heading, then its excerpts.
    fn build(s: *Screen) !void {
        s.rows.clearRetainingCapacity();
        for (s.files.items, 0..) |*f, fi| {
            try s.rows.append(s.gpa, .{ .kind = .header, .file = fi });
            if (f.note) |_| {
                try s.rows.append(s.gpa, .{ .kind = .note, .file = fi });
                continue;
            }
            const ed = f.ed orelse {
                // Deleted: what it had, all removed.
                for (0..f.oldCount()) |n| try s.rows.append(s.gpa, .{ .kind = .old, .file = fi, .line = n });
                continue;
            };
            const count = ed.t.lineCount();
            const hunks = f.live.hunks.items;
            if (hunks.len == 0) {
                try s.rows.append(s.gpa, .{ .kind = .note, .file = fi });
                continue;
            }
            // The excerpts: each hunk with lines of context either side, those
            // that touch made one.
            var i: usize = 0;
            var first_excerpt = true;
            while (i < hunks.len) {
                const lo = hunks[i].new_start -| context_lines;
                var hi = @min(hunks[i].new_start + @max(hunks[i].new_count, 1) - 1 + context_lines, count - 1);
                var j = i + 1;
                while (j < hunks.len and hunks[j].new_start -| context_lines <= hi + 1) : (j += 1) {
                    hi = @min(@max(hi, hunks[j].new_start + @max(hunks[j].new_count, 1) - 1 + context_lines), count - 1);
                }
                if (!first_excerpt) try s.rows.append(s.gpa, .{ .kind = .gap, .file = fi });
                first_excerpt = false;
                // Lines up to each hunk, its removed lines, then its added ones.
                var n = lo;
                for (hunks[i..j]) |h| {
                    while (n < h.new_start and n <= hi) : (n += 1) try s.rows.append(s.gpa, .{ .kind = .new, .file = fi, .line = n });
                    for (h.old_start..h.old_start + h.old_count) |o| try s.rows.append(s.gpa, .{ .kind = .old, .file = fi, .line = o });
                    for (h.new_start..h.new_start + h.new_count) |k| try s.rows.append(s.gpa, .{ .kind = .new, .file = fi, .line = k, .added = true });
                    n = @max(n, h.new_start + h.new_count);
                }
                while (n <= hi) : (n += 1) try s.rows.append(s.gpa, .{ .kind = .new, .file = fi, .line = n });
                i = j;
            }
        }
    }

    // The row the caret is on.
    fn caretRow(s: *const Screen) ?usize {
        const fi = s.active orelse return null;
        const ed = s.files.items[fi].ed orelse return null;
        const n = ed.t.lineOf(ed.primary().head);
        var near: ?usize = null;
        for (s.rows.items, 0..) |r, i| {
            if (r.file != fi or r.kind != .new) continue;
            if (r.line == n) return i;
            if (near == null or r.line < n) near = i;
        }
        return near;
    }

    fn activeEd(s: *Screen) ?*Editor {
        const fi = s.active orelse return null;
        return s.files.items[fi].ed;
    }

    fn touched(s: *Screen) void {
        s.v.follow = true;
        s.v.blink_at = state.clock();
    }

    // After an edit to the active file: its difference again, and the rows.
    fn edited(s: *Screen) !void {
        const fi = s.active orelse return;
        const f = &s.files.items[fi];
        const ed = f.ed orelse return;
        f.live.stale = true;
        try f.live.update(&ed.t);
        const d = ed.t.takeDirty();
        if (d != text.not_dirty) if (f.hl) |*h| h.edited(&ed.t, d);
        try s.build();
        s.discard_asked = false;
        s.touched();
    }

    // Up or down by rows, onto lines as they are now, keeping the column.
    fn moveRows(s: *Screen, delta: i64, select: bool) !void {
        const from = s.caretRow() orelse return;
        const ed0 = s.activeEd() orelse return;
        const p = ed0.primary();
        const goal = p.goal orelse try motion.colOf(&ed0.t, p.head);
        var i: i64 = @intCast(from);
        const n: i64 = @intCast(s.rows.items.len);
        var left = @abs(delta);
        const step: i64 = if (delta < 0) -1 else 1;
        var target = from;
        while (left > 0) {
            i += step;
            if (i < 0 or i >= n) break;
            const r = s.rows.items[@intCast(i)];
            if (r.kind != .new or s.files.items[r.file].ed == null) continue;
            if (select and r.file != s.active.?) break; // a selection stays in its file
            target = @intCast(i);
            left -= 1;
        }
        const r = s.rows.items[target];
        const ed = s.files.items[r.file].ed.?;
        const pos = try motion.posAtCol(&ed.t, r.line, goal);
        if (r.file != s.active.?) {
            s.active = r.file;
            ed.setSingle(Sel.caret(pos));
        } else {
            var sel = ed.primary();
            sel.head = pos;
            if (!select) sel.anchor = pos;
            ed.setSingle(sel);
        }
        ed.sels.items[ed.sels.items.len - 1].goal = goal;
        s.touched();
    }

    fn modifiedCount(s: *const Screen) usize {
        var n: usize = 0;
        for (s.files.items) |f| if (f.loaded) |l| {
            if (l.ed.h.modified()) n += 1;
        };
        return n;
    }

    fn saveAll(s: *Screen) !void {
        var saved: usize = 0;
        for (s.files.items) |*f| {
            const ed = f.ed orelse continue;
            if (!ed.h.modified()) continue;
            doc.save(&ed.t, f.info, f.path) catch {
                var buf: [240]u8 = undefined;
                state.say(&s.v, std.fmt.bufPrint(&buf, "Could not save: {s}", .{f.name}) catch "Could not save");
                return;
            };
            ed.h.markSaved();
            saved += 1;
        }
        var buf: [64]u8 = undefined;
        state.say(&s.v, if (saved == 0) "Nothing to save" else std.fmt.bufPrint(&buf, "Saved {d} file{s}", .{ saved, if (saved == 1) "" else "s" }) catch "Saved");
    }

    // Leaving: fine unless files opened here have unsaved changes, which the
    // first try says and the second drops.
    fn leave(s: *Screen, then: Action) Action {
        const n = s.modifiedCount();
        if (n == 0 or s.discard_asked) return then;
        s.discard_asked = true;
        var buf: [120]u8 = undefined;
        state.say(&s.v, std.fmt.bufPrint(&buf, "Unsaved changes in {d} file{s}: Cmd+S saves, again to discard", .{ n, if (n == 1) "" else "s" }) catch "Unsaved changes");
        return .none;
    }

    fn openAt(s: *Screen, i: usize) Action {
        const r = s.rows.items[i];
        const f = s.file(r.file);
        if (f.kind == .deleted) return .none;
        var line: usize = 0;
        var col: usize = 0;
        if (r.kind == .new) {
            line = r.line;
            if (s.active == r.file) if (f.ed) |ed| {
                line = ed.t.lineOf(ed.primary().head);
                col = ed.primary().head - ed.t.lineStart(line);
            };
        } else if (f.live.hunks.items.len > 0) line = f.live.hunks.items[0].new_start;
        return s.leave(.{ .open = .{ .path = f.path, .line = line, .col = col } });
    }

    fn command(s: *Screen, gpa: Allocator, cmd: Command, select: bool, tr: *Tree) !Action {
        switch (cmd) {
            .none => return .none,
            .cancel => {
                if (s.activeEd()) |ed| if (!ed.primary().isEmpty()) {
                    ed.setSingle(Sel.caret(ed.primary().head));
                    return .none;
                };
                return s.leave(.back);
            },
            .show_changes => return s.leave(.back),
            .toggle_changes => {
                if (s.panel_shown) |shown| shown.* = !shown.*;
                return .none;
            },
            .quit => return s.leave(.quit),
            .save => {
                try s.saveAll();
                return .none;
            },
            .toggle_tree => {
                if (tr.root.len > 0) tr.shown = !tr.shown;
                return .none;
            },
            .up, .down => try s.moveRows(if (cmd == .up) -1 else 1, select),
            .page_up, .page_down => try s.moveRows(@as(i64, @intCast(@max(s.v.rows -| 1, 1))) * @as(i64, if (cmd == .page_up) -1 else 1), select),
            .doc_start, .doc_end => try s.moveRows(if (cmd == .doc_start) -@as(i64, @intCast(s.rows.items.len)) else @intCast(s.rows.items.len), select),
            else => {},
        }
        const ed = s.activeEd() orelse return .none;
        if (cmd.isMotion()) {
            if (cmd != .up and cmd != .down and cmd != .page_up and cmd != .page_down and cmd != .doc_start and cmd != .doc_end) {
                try ed.moveEach(select, input.Move{ .cmd = cmd, .select = select });
                s.touched();
            }
            return .none;
        }
        switch (cmd) {
            .copy, .cut => {
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(gpa);
                try ed.copyText(&out);
                try platform.setClipboard(gpa, out.items);
                if (cmd == .cut) {
                    try ed.cutSelection();
                    try s.edited();
                }
                return .none;
            },
            .select_all => {
                ed.selectAll();
                s.touched();
                return .none;
            },
            else => {},
        }
        switch (cmd) {
            .undo => if (!try ed.undo()) return .none,
            .redo => if (!try ed.redo()) return .none,
            .paste => {
                var clip: std.ArrayList(u8) = .empty;
                defer clip.deinit(gpa);
                try platform.clipboard(gpa, &clip);
                try ed.paste(clip.items);
            },
            .newline => try ed.newline(),
            .indent => try ed.tab(),
            .delete_left => try ed.deleteEach(edit.ToCharLeft{}),
            .delete_right => try ed.deleteEach(edit.ToCharRight{}),
            .delete_word_left => try ed.deleteEach(edit.ToWordLeft{}),
            .delete_word_right => try ed.deleteEach(edit.ToWordRight{}),
            .delete_to_line_start => try ed.deleteEach(edit.ToLineStart{}),
            .delete_to_line_end => try ed.deleteEach(edit.ToLineEnd{}),
            else => return .none,
        }
        try s.edited();
        return .none;
    }

    // The row at a point; over the heading kept at the top, its file's heading.
    fn rowAt(s: *const Screen, y: f32) ?usize {
        if (y < 0 or y >= s.v.text_bottom) return null;
        if (s.sticky) |fi| if (y < s.sticky_bottom) {
            for (s.rows.items, 0..) |r, i| if (r.kind == .header and r.file == fi) return i;
        };
        if (y < s.v.text_y) return null;
        const i = s.v.top + @as(usize, @intFromFloat((y - s.v.text_y + s.v.scroll_y) / s.v.line_h));
        return if (i < s.rows.items.len) i else null;
    }

    pub fn handle(s: *Screen, gpa: Allocator, in: *input.Input, km: *const keymap.Keymap, mac: bool, tr: *Tree) !Action {
        var swallow = false;
        var typed: std.ArrayList(u8) = .empty;
        defer typed.deinit(gpa);
        for (in.events.items) |e| {
            if (e == .text) {
                const cmd_held = if (mac) in.mods.cmd else in.mods.ctrl;
                if (swallow or cmd_held) continue;
                for (in.str(e.text)) |ch| if (ch >= 0x20 and ch != 0x7F) try typed.append(gpa, ch);
                continue;
            }
            if (typed.items.len > 0) {
                if (s.activeEd()) |ed| {
                    try ed.insertText(typed.items, .type);
                    try s.edited();
                }
                typed.clearRetainingCapacity();
            }
            switch (e) {
                .key => |k| if (k.down) {
                    const found = km.commandFor(k.mods, k.key.slice());
                    swallow = found.cmd != .none;
                    const a = try s.command(gpa, found.cmd, found.select, tr);
                    if (a != .none) return a;
                },
                .button => |b| if (b.left and b.down) {
                    if (s.v.right_cells > 0 and b.x >= s.v.right_x) {
                        if (s.panel.?.changeAt(&s.v, b.y)) |picked| s.jumpTo(picked.path);
                        continue;
                    }
                    if (b.x < s.v.panel_w) {
                        switch (render.treeRowAt(&s.v, tr, b.x, b.y)) {
                            .row => |i| {
                                const entry = tr.rows.items[i];
                                if (entry.is_dir) try tr.toggle(i) else {
                                    const a = s.leave(.{ .open = .{ .path = entry.path, .line = 0, .col = 0 } });
                                    if (a != .none) return a;
                                }
                            },
                            else => {},
                        }
                        continue;
                    }
                    const i = s.rowAt(b.y) orelse continue;
                    const r = s.rows.items[i];
                    if (r.kind == .header) {
                        if (b.clicks >= 2) {
                            const a = s.openAt(i);
                            if (a != .none) return a;
                        }
                        continue;
                    }
                    if (r.kind != .new) continue;
                    const ed = s.files.items[r.file].ed orelse continue;
                    s.line.clearRetainingCapacity();
                    try ed.t.readLine(r.line, &s.line);
                    const cells = (b.x - s.v.text_x) / s.v.cell_w + float(s.v.left);
                    const pos = ed.t.lineStart(r.line) + width.offsetAtX(s.line.items, @max(cells, 0));
                    if (in.mods.shift and s.active == r.file) {
                        ed.setSingle(.{ .anchor = ed.primary().anchor, .head = pos });
                    } else ed.setSingle(Sel.caret(pos));
                    s.active = r.file;
                    s.v.blink_at = state.clock();
                    if (b.clicks >= 2) {
                        const a = s.openAt(i);
                        if (a != .none) return a;
                    }
                },
                .wheel => |w| {
                    if (s.v.right_cells > 0 and in.mouse_x >= s.v.right_x) {
                        s.v.changes_wheel += w.y * 3;
                    } else if (in.mouse_x < s.v.panel_w) {
                        tr.wheel += w.y * 3;
                        const rows = @trunc(tr.wheel);
                        tr.wheel -= rows;
                        tr.top = @intCast(@max(@as(i64, @intCast(tr.top)) - @as(i64, @intFromFloat(rows)), 0));
                    } else s.v.scroll_y -= w.y * 3 * s.v.line_h;
                },
                .quit => {
                    const a = s.leave(.quit);
                    if (a != .none) return a;
                },
                else => {},
            }
        }
        if (typed.items.len > 0) if (s.activeEd()) |ed| {
            try ed.insertText(typed.items, .type);
            try s.edited();
        };
        return .none;
    }

    fn layout(s: *Screen, f: *const font.Fonts, tr: *Tree, w: f32, h: f32) !void {
        const v = &s.v;
        const tf = &f.text;
        const uf = &f.ui;
        v.cell_w = tf.cell_w;
        v.line_h = tf.line_h;
        v.ui_cell_w = uf.cell_w;
        v.ui_line_h = uf.line_h;
        v.panel_w = if (tr.shown) float(tr.width) * uf.cell_w else 0;
        var widest: usize = 1;
        for (s.files.items) |fl| {
            widest = @max(widest, fl.old_starts.len);
            if (fl.ed) |ed| widest = @max(widest, ed.t.lineCount());
        }
        v.text_x = v.panel_w + float(@max(render.digits(widest), 3) + 2) * tf.cell_w + 2 * render.gutterPad(tf.cell_w);
        v.text_y = @round(tf.line_h * 0.3);
        v.text_bottom = h - uf.line_h;
        v.rows = @max(@as(usize, @intFromFloat(@max(@floor((v.text_bottom - v.text_y) / tf.line_h), 1))), 1);
        v.right_cells = if (s.panel != null and s.panel_shown.?.*) changes_view.cells else 0;
        v.right_x = w - float(v.right_cells) * uf.cell_w;
        v.cols = @max(@as(usize, @intFromFloat(@max(@floor((v.right_x - v.text_x - tf.cell_w) / tf.cell_w), 1))), 1);
        v.tree_y = @round(uf.line_h * 0.3);
        v.tree_bottom = h - uf.line_h;
        v.tree_rows = render.listRows(v);
        tr.top = @min(tr.top, tr.rows.items.len -| v.tree_rows);
        const lines = @floor(v.scroll_y / v.line_h);
        v.scroll_y -= lines * v.line_h;
        const top = @as(i64, @intCast(v.top)) + @as(i64, @intFromFloat(lines));
        const last = s.rows.items.len -| 1;
        if (top < 0) {
            v.top = 0;
            v.scroll_y = 0;
        } else v.top = @min(@as(usize, @intCast(top)), last);
        if (v.top == last) v.scroll_y = 0;
        if (v.follow) {
            v.follow = false;
            if (s.caretRow()) |cr| {
                // The row above the caret comes into view with it, for the
                // heading kept at the top to cover.
                const want_top = cr -| 1;
                if (want_top < v.top or (want_top == v.top and v.scroll_y > 0)) {
                    v.top = want_top;
                    v.scroll_y = 0;
                }
                if (cr >= v.top + v.rows) {
                    v.top = cr + 1 - v.rows;
                    v.scroll_y = 0;
                }
                if (s.activeEd()) |ed| {
                    const col = try motion.colOf(&ed.t, ed.primary().head);
                    if (col < v.left) v.left = col -| 8;
                    if (col >= v.left + v.cols) v.left = col - v.cols + 8;
                }
            }
        }
    }

    fn drawHeader(s: *Screen, ren: *c.SDL_Renderer, f: *font.Fonts, fr: *const File, y: f32, w: f32, sc: *render.Scratch) !void {
        const tf = &f.text;
        const uf = &f.ui;
        fill(ren, s.v.panel_w, y, w - s.v.panel_w, tf.line_h, th().bar_bg);
        const ty = y + @round((tf.line_h - uf.line_h) * 0.5);
        var x = s.v.panel_w + uf.cell_w;
        const mark = switch (fr.kind) {
            .modified => th().changed,
            .added => th().added,
            .deleted => th().removed,
        };
        const d = @round(uf.cell_w * 0.6);
        fill(ren, x + @round((uf.cell_w - d) * 0.5), y + @round((tf.line_h - d) * 0.5), d, d, mark);
        x += uf.cell_w * 2;
        var cols = try uf.drawStr(x, ty, fr.name, th().fg);
        if (fr.ed) |ed| if (ed.h.modified()) {
            cols += try uf.drawStr(x + float(cols) * uf.cell_w, ty, " ●", th().fg);
        };
        x += float(cols + 2) * uf.cell_w;
        sc.s.clearRetainingCapacity();
        if (fr.live.added > 0) try sc.s.print(s.gpa, "+{d}", .{fr.live.added});
        const plus = try uf.drawStr(x, ty, sc.s.items, th().added);
        sc.s.clearRetainingCapacity();
        const removed = if (fr.ed == null) fr.oldCount() else fr.live.removed;
        if (removed > 0) try sc.s.print(s.gpa, "−{d}", .{removed});
        _ = try uf.drawStr(x + float(plus + @as(usize, if (plus > 0) 1 else 0)) * uf.cell_w, ty, sc.s.items, th().removed);
    }

    pub fn draw(s: *Screen, ren: *c.SDL_Renderer, f: *font.Fonts, tr: *Tree, sc: *render.Scratch) !void {
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetCurrentRenderOutputSize(ren, &pw, &ph);
        const w: f32 = @floatFromInt(pw);
        const h: f32 = @floatFromInt(ph);
        try s.layout(f, tr, w, h);
        const v = &s.v;
        const tf = &f.text;
        const uf = &f.ui;
        const bg = th().bg;
        _ = c.SDL_SetRenderDrawColor(ren, bg.r, bg.g, bg.b, 255);
        _ = c.SDL_RenderClear(ren);
        const now = state.clock();
        const blink_on = @mod(now - v.blink_at, 1.1) < 0.65 or now - v.blink_at < 0.6;
        const caret_row = s.caretRow();
        var num_buf: [24]u8 = undefined;
        const pad = render.gutterPad(tf.cell_w);
        // The rows stop where the changes on the right start.
        const rw = v.right_x;
        _ = c.SDL_SetRenderClipRect(ren, &.{ .x = 0, .y = 0, .w = @intFromFloat(rw), .h = @intFromFloat(v.text_bottom) });
        for (0..v.rows + 1) |k| {
            const i = v.top + k;
            if (i >= s.rows.items.len) break;
            const r = s.rows.items[i];
            const fr = &s.files.items[r.file];
            const y = v.text_y + float(k) * tf.line_h - v.scroll_y;
            const bar_x = v.text_x - pad - @round(tf.cell_w * 0.75);
            const bar_w = @max(@round(tf.cell_w * 0.3), 2);
            switch (r.kind) {
                .header => try s.drawHeader(ren, f, fr, y, rw, sc),
                .note => {
                    const why = fr.note orelse "No changes left";
                    _ = try uf.drawStr(v.text_x, y + @round((tf.line_h - uf.line_h) * 0.5), why, th().hint_fg);
                },
                .gap => {
                    const mid = y + @round(tf.line_h * 0.5);
                    fill(ren, v.text_x, mid, rw - v.text_x - tf.cell_w, 1, th().panel_edge);
                    _ = try tf.drawStr(v.text_x - pad - float(3) * tf.cell_w, y, "⋯", th().gutter_fg);
                },
                .old => {
                    fill(ren, v.panel_w, y, rw - v.panel_w, tf.line_h, th().removed_bg);
                    fill(ren, bar_x, y, bar_w, tf.line_h, th().removed);
                    const line = fr.oldLine(r.line);
                    s.spans.clearRetainingCapacity();
                    if (syntax.languages.languageFor(fr.path)) |l| _ = try syntax.lexLine(s.gpa, l, line, fr.old_states[r.line], &s.spans);
                    try render.drawLine(ren, tf, v, line, y, s.spans.items);
                },
                .new => {
                    const ed = fr.ed.?;
                    const t = &ed.t;
                    s.line.clearRetainingCapacity();
                    try t.readLine(r.line, &s.line);
                    const line = s.line.items;
                    const ls = t.lineStart(r.line);
                    const mine = s.active == r.file;
                    if (r.added) {
                        fill(ren, v.panel_w, y, rw - v.panel_w, tf.line_h, th().added_bg);
                        fill(ren, bar_x, y, bar_w, tf.line_h, th().added);
                    } else if (caret_row == i and ed.primary().isEmpty()) fill(ren, v.panel_w, y, rw - v.panel_w, tf.line_h, th().current_line);
                    if (mine) for (ed.sels.items) |sel| {
                        if (sel.isEmpty() or sel.hi() < ls or sel.lo() > ls + line.len) continue;
                        const cols = render.spanCols(line, ls, sel.lo(), sel.hi());
                        render.fillCols(ren, v, y, cols.a, if (cols.past) cols.b + 1 else cols.b, th().selection);
                    };
                    const num = std.fmt.bufPrint(&num_buf, "{d}", .{r.line + 1}) catch unreachable;
                    _ = try tf.drawStr(v.text_x - pad - float(num.len + 1) * tf.cell_w, y, num, if (caret_row == i) th().gutter_fg_current else th().gutter_fg);
                    s.spans.clearRetainingCapacity();
                    if (fr.hl) |*hl| if (hl.lang) |l| {
                        _ = try hl.extend(t, r.line, 0.01);
                        _ = try syntax.lexLine(s.gpa, l, line, hl.stateAt(r.line) orelse syntax.state_normal, &s.spans);
                    };
                    try render.drawLine(ren, tf, v, line, y, s.spans.items);
                    if (mine and blink_on) for (ed.sels.items) |sel| {
                        if (sel.head < ls or sel.head > ls + line.len) continue;
                        const col = width.advance(line[0 .. sel.head - ls], 0);
                        if (col >= v.left and col <= v.left + v.cols) fill(ren, render.cellX(v, col) - 1, y, @max(@round(tf.cell_w * 0.22), 2), tf.line_h, th().caret);
                    };
                },
            }
        }
        // The heading of the file at the top stays there, until the next
        // file's pushes it up and out.
        s.sticky = null;
        if (s.rows.items.len > 0) {
            fill(ren, v.panel_w, 0, rw - v.panel_w, v.text_y, th().bg);
            var y = v.text_y;
            for (1..v.rows + 1) |k| {
                const i = v.top + k;
                if (i >= s.rows.items.len) break;
                if (s.rows.items[i].kind == .header) {
                    y = @min(y, v.text_y + float(k) * tf.line_h - v.scroll_y - tf.line_h);
                    break;
                }
            }
            const fi = s.rows.items[v.top].file;
            try s.drawHeader(ren, f, &s.files.items[fi], y, rw, sc);
            s.sticky = fi;
            s.sticky_bottom = y + tf.line_h;
        }
        _ = c.SDL_SetRenderClipRect(ren, null);
        if (tr.shown) try render.drawTree(ren, uf, v, tr, sc);
        // The changes on the right, the files of this view as they are now,
        // the one at the top marked.
        if (v.right_cells > 0) {
            const p = s.panel.?;
            p.rows.clearRetainingCapacity();
            for (s.files.items) |fl| try p.rows.append(s.gpa, .{
                .path = fl.path,
                .name = fl.name,
                .kind = fl.kind,
                .added = if (fl.note != null and fl.ed == null and fl.kind != .deleted) null else fl.live.added,
                .removed = if (fl.ed == null) fl.oldCount() else fl.live.removed,
            });
            v.path.set(if (s.sticky) |fi| s.files.items[fi].path else "");
            p.scroll(v, p.rows.items.len);
            try p.draw(ren, uf, v, sc);
        }

        // What is shown, and where the caret is, at the bottom.
        const by = h - uf.line_h;
        fill(ren, 0, by, w, uf.line_h, th().bar_bg);
        sc.s.clearRetainingCapacity();
        var added: usize = 0;
        var removed: usize = 0;
        for (s.files.items) |fl| {
            added += fl.live.added;
            removed += if (fl.ed == null) fl.oldCount() else fl.live.removed;
        }
        try sc.s.print(s.gpa, "Changes since HEAD: {d} file{s}, +{d} −{d}", .{ s.files.items.len, if (s.files.items.len == 1) "" else "s", added, removed });
        if (s.active) |fi| if (s.files.items[fi].ed) |ed| {
            try sc.s.print(s.gpa, "   {s}:{d}", .{ s.files.items[fi].name, ed.t.lineOf(ed.primary().head) + 1 });
        };
        try sc.s.appendSlice(s.gpa, "   Cmd+S: save all   Esc: back");
        _ = try uf.drawStr(uf.cell_w, by, sc.s.items, th().bar_fg);
        if (v.message.len > 0 and now - v.message_at < 4.0) {
            const mw = float(width.advance(v.message.slice(), 0) + 2);
            const x = @max(w - mw * uf.cell_w, w * 0.5);
            fill(ren, x - uf.cell_w, by, w - x + uf.cell_w, uf.line_h, th().bar_bg);
            _ = try uf.drawStr(x, by, v.message.slice(), th().notice);
        }
    }
};
