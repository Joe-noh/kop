// The results of a search of the whole project, as one buffer of many:
// each file that has a match, under a heading with its name, shows the
// lines around its matches, with their own line numbers, and the matches
// marked. Moving through them works as in a document; Enter or a double
// click opens the file there.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const search = @import("../core/search.zig");
const utf8 = @import("../core/utf8.zig");
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

fn th() *const theme.Theme {
    return &theme.current;
}

fn float(n: usize) f32 {
    return @floatFromInt(n);
}

pub const Row = struct {
    kind: enum { header, line, gap },
    file: usize,
    line: usize = 0,
    state: u8 = 0, // the lexer's state as the line starts
};

pub const Action = union(enum) {
    none,
    back, // to the document
    quit,
    open: struct { path: []const u8, line: usize, col: usize }, // col in bytes
};

pub const Screen = struct {
    gpa: Allocator,
    root: []const u8,
    results: ?search.Results = null,
    rows: std.ArrayList(Row) = .empty,
    query: state.Buf(256) = .{},
    searched: state.Buf(256) = .{}, // the query the results are for
    took: f64 = 0,
    cursor: usize = 0, // the row the caret is on
    col: usize = 0, // and where in its line, in bytes
    v: View = .{}, // the grid: where rows go, the first one shown, the scroll
    field_h: f32 = 0,
    // The heading kept at the top while its file's lines scroll under it:
    // which file's, and where it ends, for clicks.
    sticky: ?usize = null,
    sticky_bottom: f32 = 0,

    pub fn deinit(s: *Screen) void {
        if (s.results) |*r| r.deinit();
        s.rows.deinit(s.gpa);
    }

    fn file(s: *const Screen, i: usize) *const search.FileResult {
        return &s.results.?.files.items[i];
    }

    fn lineOf(s: *const Screen, r: Row) []const u8 {
        return s.file(r.file).line(r.line);
    }

    // Searches for the query, and lays out the rows of what it found.
    pub fn run(s: *Screen) !void {
        if (s.results) |*r| r.deinit();
        s.results = null;
        s.rows.clearRetainingCapacity();
        s.searched = s.query;
        s.cursor = 0;
        s.col = 0;
        s.v.top = 0;
        s.v.scroll_y = 0;
        s.v.follow = true;
        if (s.query.len == 0) return;
        const started = state.clock();
        s.results = try search.search(s.gpa, s.root, s.query.slice());
        s.took = state.clock() - started;
        var spans: std.ArrayList(syntax.Span) = .empty;
        defer spans.deinit(s.gpa);
        for (s.results.?.files.items, 0..) |*f, fi| {
            try s.rows.append(s.gpa, .{ .kind = .header, .file = fi });
            // The states the excerpts' lines start in, lexing the file up to them.
            const lang = syntax.languages.languageFor(f.path);
            var st: u8 = syntax.state_normal;
            var lexed: usize = 0;
            for (f.excerpts, 0..) |e, ei| {
                if (ei > 0) try s.rows.append(s.gpa, .{ .kind = .gap, .file = fi });
                for (e.first..e.last + 1) |n| {
                    if (lang) |l| while (lexed < n) : (lexed += 1) {
                        spans.clearRetainingCapacity();
                        st = try syntax.lexLine(s.gpa, l, f.line(lexed), st, &spans);
                    };
                    try s.rows.append(s.gpa, .{ .kind = .line, .file = fi, .line = n, .state = st });
                }
            }
        }
        // The caret starts at the first match.
        if (s.firstMatch(0)) |m| {
            s.cursor = m.row;
            s.col = m.col;
        }
    }

    const Spot = struct { row: usize, col: usize };

    // The first match at or after row `from` (and after `after_col` on it).
    fn firstMatch(s: *const Screen, from: usize) ?Spot {
        return s.nextMatch(from, null);
    }

    fn nextMatch(s: *const Screen, from: usize, after_col: ?usize) ?Spot {
        var i = from;
        while (i < s.rows.items.len) : (i += 1) {
            const r = s.rows.items[i];
            if (r.kind != .line) continue;
            for (s.file(r.file).matches) |m| {
                if (m.line != r.line) continue;
                if (i == from and after_col != null and m.start <= after_col.?) continue;
                return .{ .row = i, .col = m.start };
            }
        }
        return null;
    }

    fn prevMatch(s: *const Screen, from: usize, before_col: usize) ?Spot {
        var i = from + 1;
        while (i > 0) {
            i -= 1;
            const r = s.rows.items[i];
            if (r.kind != .line) continue;
            const ms = s.file(r.file).matches;
            var k = ms.len;
            while (k > 0) {
                k -= 1;
                const m = ms[k];
                if (m.line != r.line) continue;
                if (i == from and m.start >= before_col) continue;
                return .{ .row = i, .col = m.start };
            }
        }
        return null;
    }

    // The line row nearest to `i` in the direction `dir`, or `i` itself.
    fn lineRow(s: *const Screen, i: usize, dir: i64) usize {
        var j: i64 = @intCast(i);
        const n: i64 = @intCast(s.rows.items.len);
        while (j >= 0 and j < n) : (j += dir) {
            if (s.rows.items[@intCast(j)].kind == .line) return @intCast(j);
        }
        return s.cursor;
    }

    fn moveRows(s: *Screen, delta: i64) void {
        if (s.rows.items.len == 0) return;
        const cells = width.advance(s.lineOf(s.rows.items[s.cursor])[0..s.col], 0);
        const n: i64 = @intCast(s.rows.items.len);
        const target: usize = @intCast(std.math.clamp(@as(i64, @intCast(s.cursor)) + delta, 0, n - 1));
        s.cursor = s.lineRow(target, if (delta < 0) -1 else 1);
        if (s.rows.items[s.cursor].kind != .line) s.cursor = s.lineRow(target, if (delta < 0) 1 else -1);
        const line = s.lineOf(s.rows.items[s.cursor]);
        s.col = width.offsetAtCol(line, cells);
        s.v.follow = true;
        s.v.blink_at = state.clock();
    }

    fn moveCol(s: *Screen, cmd: Command) void {
        if (s.rows.items.len == 0) return;
        const line = s.lineOf(s.rows.items[s.cursor]);
        s.col = switch (cmd) {
            .left => utf8.prevStart(line, s.col),
            .right => if (s.col < line.len) s.col + utf8.decode(line, s.col).len else s.col,
            .word_left => blk: {
                var i = s.col;
                while (i > 0 and utf8.charClass(utf8.decode(line, utf8.prevStart(line, i)).cp) == .space) i = utf8.prevStart(line, i);
                if (i > 0) {
                    const k = utf8.charClass(utf8.decode(line, utf8.prevStart(line, i)).cp);
                    while (i > 0 and utf8.charClass(utf8.decode(line, utf8.prevStart(line, i)).cp) == k) i = utf8.prevStart(line, i);
                }
                break :blk i;
            },
            .word_right => blk: {
                var i = s.col;
                while (i < line.len and utf8.charClass(utf8.decode(line, i).cp) == .space) i += utf8.decode(line, i).len;
                if (i < line.len) {
                    const k = utf8.charClass(utf8.decode(line, i).cp);
                    while (i < line.len and utf8.charClass(utf8.decode(line, i).cp) == k) i += utf8.decode(line, i).len;
                }
                break :blk i;
            },
            .line_start => 0,
            .line_end => line.len,
            else => s.col,
        };
        s.v.follow = true;
        s.v.blink_at = state.clock();
    }

    fn openAt(s: *const Screen, row: usize, col: usize) Action {
        if (s.rows.items.len == 0) return .none;
        const r = s.rows.items[row];
        const f = s.file(r.file);
        if (r.kind == .header) {
            const m = f.matches[0];
            return .{ .open = .{ .path = f.path, .line = m.line, .col = m.start } };
        }
        return .{ .open = .{ .path = f.path, .line = r.line, .col = col } };
    }

    // Runs `cmd`, returning what the window should do next.
    fn command(s: *Screen, gpa: Allocator, cmd: Command, tr: *Tree) !Action {
        switch (cmd) {
            .up, .down => s.moveRows(if (cmd == .up) -1 else 1),
            .page_up, .page_down => s.moveRows(@as(i64, @intCast(@max(s.v.rows -| 1, 1))) * @as(i64, if (cmd == .page_up) -1 else 1)),
            .doc_start => s.moveRows(-@as(i64, @intCast(s.rows.items.len))),
            .doc_end => s.moveRows(@intCast(s.rows.items.len)),
            .left, .right, .word_left, .word_right, .line_start, .line_end => s.moveCol(cmd),
            .find_next, .find_previous => {
                const spot = if (cmd == .find_next)
                    s.nextMatch(s.cursor, s.col) orelse s.firstMatch(0)
                else
                    s.prevMatch(s.cursor, s.col) orelse if (s.rows.items.len > 0) s.prevMatch(s.rows.items.len - 1, std.math.maxInt(usize)) else null;
                if (spot) |m| {
                    s.cursor = m.row;
                    s.col = m.col;
                    s.v.follow = true;
                    s.v.blink_at = state.clock();
                }
            },
            .newline, .search_project => {
                if (cmd == .search_project or !s.query.eql(s.searched.slice()) or s.rows.items.len == 0) {
                    try s.run();
                } else return s.openAt(s.cursor, s.col);
            },
            .cancel => return .back,
            .quit => return .quit,
            .delete_left => s.query.pop(),
            .paste => {
                var clip: std.ArrayList(u8) = .empty;
                defer clip.deinit(gpa);
                try platform.clipboard(gpa, &clip);
                const end = std.mem.indexOfAny(u8, clip.items, "\r\n") orelse clip.items.len;
                s.query.append(clip.items[0..end]);
            },
            .toggle_tree => if (tr.root.len > 0) {
                tr.shown = !tr.shown;
            },
            else => {},
        }
        return .none;
    }

    // The row at a point in the text area; over the heading kept at the
    // top, its file's heading.
    fn rowAt(s: *const Screen, y: f32) ?usize {
        if (y < s.field_h or y >= s.v.text_bottom) return null;
        if (s.sticky) |fi| if (y < s.sticky_bottom) {
            for (s.rows.items, 0..) |r, i| if (r.kind == .header and r.file == fi) return i;
        };
        if (y < s.v.text_y) return null;
        const i = s.v.top + @as(usize, @intFromFloat((y - s.v.text_y + s.v.scroll_y) / s.v.line_h));
        return if (i < s.rows.items.len) i else null;
    }

    pub fn handle(s: *Screen, gpa: Allocator, in: *input.Input, km: *const keymap.Keymap, mac: bool, tr: *Tree) !Action {
        var swallow = false;
        for (in.events.items) |e| switch (e) {
            .text => |b| {
                const cmd_held = if (mac) in.mods.cmd else in.mods.ctrl;
                if (swallow or cmd_held) continue;
                const t = in.str(b);
                const end = std.mem.indexOfAny(u8, t, "\r\n") orelse t.len;
                s.query.append(t[0..end]);
                s.v.blink_at = state.clock();
            },
            .key => |k| if (k.down) {
                const found = km.commandFor(k.mods, k.key.slice());
                swallow = found.cmd != .none;
                const a = try s.command(gpa, found.cmd, tr);
                if (a != .none) return a;
            },
            .button => |b| if (b.left and b.down) {
                if (b.x < s.v.panel_w) {
                    switch (render.treeRowAt(&s.v, tr, b.x, b.y)) {
                        .row => |i| {
                            const entry = tr.rows.items[i];
                            if (entry.is_dir) try tr.toggle(i) else return .{ .open = .{ .path = entry.path, .line = 0, .col = 0 } };
                        },
                        else => {},
                    }
                    continue;
                }
                const i = s.rowAt(b.y) orelse continue;
                const r = s.rows.items[i];
                if (r.kind == .header) {
                    if (b.clicks >= 2) return s.openAt(i, 0);
                    continue;
                }
                if (r.kind != .line) continue;
                const cells = (b.x - s.v.text_x) / s.v.cell_w + float(s.v.left);
                s.cursor = i;
                s.col = width.offsetAtX(s.lineOf(r), @max(cells, 0));
                s.v.blink_at = state.clock();
                if (b.clicks >= 2) return s.openAt(i, s.col);
            },
            .wheel => |w| {
                if (in.mouse_x < s.v.panel_w) {
                    tr.wheel += w.y * 3;
                    const rows = @trunc(tr.wheel);
                    tr.wheel -= rows;
                    tr.top = @intCast(@max(@as(i64, @intCast(tr.top)) - @as(i64, @intFromFloat(rows)), 0));
                } else s.v.scroll_y -= w.y * 3 * s.v.line_h;
            },
            .quit => return .quit,
            else => {},
        };
        return .none;
    }

    fn layout(s: *Screen, f: *const font.Fonts, tr: *Tree, w: f32, h: f32) void {
        const v = &s.v;
        const tf = &f.text;
        const uf = &f.ui;
        v.cell_w = tf.cell_w;
        v.line_h = tf.line_h;
        v.ui_cell_w = uf.cell_w;
        v.ui_line_h = uf.line_h;
        s.field_h = @round(uf.line_h * 1.6);
        v.panel_w = if (tr.shown) float(tr.width) * uf.cell_w else 0;
        var widest: usize = 1;
        if (s.results) |r| for (r.files.items) |fr| {
            widest = @max(widest, fr.excerpts[fr.excerpts.len - 1].last + 1);
        };
        v.text_x = v.panel_w + float(@max(render.digits(widest), 3) + 2) * tf.cell_w;
        v.text_y = s.field_h + @round(tf.line_h * 0.3);
        v.text_bottom = h - uf.line_h;
        v.rows = @max(@as(usize, @intFromFloat(@max(@floor((v.text_bottom - v.text_y) / tf.line_h), 1))), 1);
        v.cols = @max(@as(usize, @intFromFloat(@max(@floor((w - v.text_x - tf.cell_w) / tf.cell_w), 1))), 1);
        v.tree_y = s.field_h + @round(uf.line_h * 0.3);
        v.tree_bottom = h - uf.line_h;
        v.tree_rows = @max(@as(usize, @intFromFloat(@max(@floor((v.tree_bottom - v.tree_y) / uf.line_h), 1))) - 1, 1);
        tr.top = @min(tr.top, tr.rows.items.len -| v.tree_rows);
        // The scroll, in rows and pixels, then the caret kept in view.
        const lines = @floor(v.scroll_y / v.line_h);
        v.scroll_y -= lines * v.line_h;
        const top = @as(i64, @intCast(v.top)) + @as(i64, @intFromFloat(lines));
        const last = s.rows.items.len -| 1;
        if (top < 0) {
            v.top = 0;
            v.scroll_y = 0;
        } else v.top = @min(@as(usize, @intCast(top)), last);
        if (v.top == last) v.scroll_y = 0;
        if (v.follow and s.rows.items.len > 0) {
            v.follow = false;
            // The row above the caret comes into view with it: the heading
            // kept at the top covers that one, not the caret's.
            const want_top = s.cursor -| 1;
            if (want_top < v.top or (want_top == v.top and v.scroll_y > 0)) {
                v.top = want_top;
                v.scroll_y = 0;
            }
            if (s.cursor >= v.top + v.rows) {
                v.top = s.cursor + 1 - v.rows;
                v.scroll_y = 0;
            }
            const col = width.advance(s.lineOf(s.rows.items[s.cursor])[0..s.col], 0);
            if (col < v.left) v.left = col -| 8;
            if (col >= v.left + v.cols) v.left = col - v.cols + 8;
        }
    }

    // A file's heading: its name, then how many matches it has.
    fn drawHeader(s: *Screen, ren: *c.SDL_Renderer, f: *font.Fonts, fr: *const search.FileResult, y: f32, w: f32, sc: *render.Scratch) !void {
        const tf = &f.text;
        const uf = &f.ui;
        fill(ren, s.v.panel_w, y, w - s.v.panel_w, tf.line_h, th().bar_bg);
        const ty = y + @round((tf.line_h - uf.line_h) * 0.5);
        const x = s.v.panel_w + uf.cell_w;
        const cols = try uf.drawStr(x, ty, fr.name, th().fg);
        sc.s.clearRetainingCapacity();
        try sc.s.print(s.gpa, "{d}", .{fr.matches.len});
        _ = try uf.drawStr(x + float(cols + 2) * uf.cell_w, ty, sc.s.items, th().hint_fg);
    }

    pub fn draw(s: *Screen, ren: *c.SDL_Renderer, f: *font.Fonts, tr: *Tree, sc: *render.Scratch) !void {
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetCurrentRenderOutputSize(ren, &pw, &ph);
        const w: f32 = @floatFromInt(pw);
        const h: f32 = @floatFromInt(ph);
        s.layout(f, tr, w, h);
        const v = &s.v;
        const tf = &f.text;
        const uf = &f.ui;
        const bg = th().bg;
        _ = c.SDL_SetRenderDrawColor(ren, bg.r, bg.g, bg.b, 255);
        _ = c.SDL_RenderClear(ren);

        const now = state.clock();
        const blink_on = @mod(now - v.blink_at, 1.1) < 0.65 or now - v.blink_at < 0.6;
        var num_buf: [24]u8 = undefined;
        _ = c.SDL_SetRenderClipRect(ren, &.{ .x = 0, .y = @intFromFloat(s.field_h), .w = @intFromFloat(w), .h = @intFromFloat(v.text_bottom - s.field_h) });
        for (0..v.rows + 1) |k| {
            const i = v.top + k;
            if (i >= s.rows.items.len) break;
            const r = s.rows.items[i];
            const fr = s.file(r.file);
            const y = v.text_y + float(k) * tf.line_h - v.scroll_y;
            switch (r.kind) {
                .header => try s.drawHeader(ren, f, fr, y, w, sc),
                .gap => {
                    const mid = y + @round(tf.line_h * 0.5);
                    fill(ren, v.text_x, mid, w - v.text_x - tf.cell_w, 1, th().panel_edge);
                    _ = try tf.drawStr(v.text_x - float(3) * tf.cell_w, y, "⋯", th().gutter_fg);
                },
                .line => {
                    const line = fr.line(r.line);
                    if (i == s.cursor) fill(ren, v.panel_w, y, w - v.panel_w, tf.line_h, th().current_line);
                    for (fr.matches) |m| {
                        if (m.line != r.line) continue;
                        const cols = render.spanCols(line, 0, m.start, m.start + m.len);
                        render.fillCols(ren, v, y, cols.a, cols.b, th().match_bg);
                    }
                    const num = std.fmt.bufPrint(&num_buf, "{d}", .{r.line + 1}) catch unreachable;
                    _ = try tf.drawStr(v.text_x - float(num.len + 1) * tf.cell_w, y, num, if (i == s.cursor) th().gutter_fg_current else th().gutter_fg);
                    sc.spans.clearRetainingCapacity();
                    if (syntax.languages.languageFor(fr.path)) |l| _ = try syntax.lexLine(s.gpa, l, line, r.state, &sc.spans);
                    try render.drawLine(ren, tf, v, line, y, sc.spans.items);
                    if (i == s.cursor and blink_on) {
                        const col = width.advance(line[0..s.col], 0);
                        if (col >= v.left and col <= v.left + v.cols) fill(ren, render.cellX(v, col) - 1, y, @max(@round(tf.cell_w * 0.22), 2), tf.line_h, th().caret);
                    }
                },
            }
        }
        // The heading of the file at the top stays there, until the next
        // file's pushes it up and out.
        s.sticky = null;
        if (s.rows.items.len > 0) {
            fill(ren, v.panel_w, s.field_h, w - v.panel_w, v.text_y - s.field_h, th().bg);
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
            try s.drawHeader(ren, f, s.file(fi), y, w, sc);
            s.sticky = fi;
            s.sticky_bottom = y + tf.line_h;
        }
        _ = c.SDL_SetRenderClipRect(ren, null);
        if (tr.shown) try render.drawTree(ren, uf, v, tr, sc);

        // The query, at the top.
        fill(ren, 0, 0, w, s.field_h, th().field_bg);
        const fy = @round((s.field_h - uf.line_h) * 0.5);
        sc.s.clearRetainingCapacity();
        try sc.s.print(s.gpa, "Search project: {s}", .{s.query.slice()});
        const caret_col = try uf.drawStr(uf.cell_w, fy, sc.s.items, th().fg);
        fill(ren, float(caret_col + 1) * uf.cell_w, fy, @max(@round(uf.cell_w * 0.22), 2), uf.line_h, th().caret);
        const hint = if (!s.query.eql(s.searched.slice()) or s.rows.items.len == 0) "Enter: search   Esc: back" else "Enter: open   Cmd+G: next match   Esc: back";
        const hx = w - float(width.advance(hint, 0) + 2) * uf.cell_w;
        if (hx > float(caret_col + 4) * uf.cell_w) _ = try uf.drawStr(hx, fy, hint, th().hint_fg);

        // What was found, at the bottom.
        const by = h - uf.line_h;
        fill(ren, 0, by, w, uf.line_h, th().bar_bg);
        sc.s.clearRetainingCapacity();
        if (s.results) |r| {
            try sc.s.print(s.gpa, "{d} match{s} in {d} file{s} of {d}, {d:.2} s", .{
                r.total, if (r.total == 1) "" else "es", r.files.items.len, if (r.files.items.len == 1) "" else "s", r.searched, s.took,
            });
            if (r.truncated) try sc.s.print(s.gpa, " (stopped at {d})", .{search.max_matches});
            if (s.rows.items.len > 0) {
                const row = s.rows.items[s.cursor];
                try sc.s.print(s.gpa, "   {s}:{d}", .{ s.file(row.file).name, row.line + 1 });
            }
        } else try sc.s.print(s.gpa, "in {s}", .{s.root});
        _ = try uf.drawStr(uf.cell_w, by, sc.s.items, th().bar_fg);
    }
};
