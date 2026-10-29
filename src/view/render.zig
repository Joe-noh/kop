// Drawing a frame: the gutter, the visible lines on a grid of cells, the
// selections and carets, and the status bar. Only the lines on screen are
// read, so a frame costs the same for any size of file. Everything is in
// pixels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const Editor = @import("../core/edit.zig").Editor;
const motion = @import("../core/motion.zig");
const utf8 = @import("../core/utf8.zig");
const width = @import("../core/width.zig");
const syntax = @import("../core/syntax.zig");
const Span = syntax.Span;
const state = @import("state.zig");
const View = state.View;
const font = @import("font.zig");
const Face = font.Face;
const Fonts = font.Fonts;
const Tree = @import("tree.zig").Tree;
const tree = @import("tree.zig");
const theme = @import("theme.zig");
const Color = theme.Color;

fn th() *const theme.Theme {
    return &theme.current;
}

pub fn fill(ren: *c.SDL_Renderer, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    if (w <= 0 or h <= 0) return;
    _ = c.SDL_SetRenderDrawColor(ren, color.r, color.g, color.b, color.a);
    _ = c.SDL_RenderFillRect(ren, &.{ .x = x, .y = y, .w = w, .h = h });
}

fn triangle(ren: *c.SDL_Renderer, pts: [3][2]f32, color: Color) void {
    const fc = c.SDL_FColor{ .r = @as(f32, @floatFromInt(color.r)) / 255, .g = @as(f32, @floatFromInt(color.g)) / 255, .b = @as(f32, @floatFromInt(color.b)) / 255, .a = 1 };
    var vs: [3]c.SDL_Vertex = undefined;
    for (pts, 0..) |p, i| vs[i] = .{ .position = .{ .x = p[0], .y = p[1] }, .color = fc, .tex_coord = .{ .x = 0, .y = 0 } };
    _ = c.SDL_RenderGeometry(ren, null, &vs, 3, null, 0);
}

pub fn digits(n: usize) usize {
    var d: usize = 1;
    var x = n;
    while (x >= 10) : (x /= 10) d += 1;
    return d;
}

fn float(n: usize) f32 {
    return @floatFromInt(n);
}

// Lays the window out for its size. The text is laid out in the text
// face's cells, the tree and the bars in the ui face's.
pub fn layout(ed: *const Editor, v: *View, tr: *Tree, f: *const Fonts, w: f32, h: f32) void {
    const tf = &f.text;
    const uf = &f.ui;
    v.cell_w = tf.cell_w;
    v.line_h = tf.line_h;
    v.ui_cell_w = uf.cell_w;
    v.ui_line_h = uf.line_h;
    const bars_h = @as(f32, if (v.bar != .none) 2 else 1) * uf.line_h;
    v.panel_w = if (tr.shown) float(tr.width) * uf.cell_w else 0;
    v.text_x = v.panel_w + float(@max(digits(ed.t.lineCount()), 3) + 2) * tf.cell_w;
    v.text_y = @round(tf.line_h * 0.3);
    v.text_bottom = h - bars_h - @round(tf.line_h * 0.3);
    v.rows = @max(@as(usize, @intFromFloat(@max(@floor((v.text_bottom - v.text_y) / tf.line_h), 0))), 1);
    v.right_x = w - float(v.right_cells) * uf.cell_w;
    v.cols = @max(@as(usize, @intFromFloat(@max(@floor((v.right_x - v.text_x - tf.cell_w) / tf.cell_w), 0))), 1);
    v.tree_y = @round(uf.line_h * 0.3);
    v.tree_bottom = h - bars_h;
    v.tree_rows = @max(@as(usize, @intFromFloat(@max(@floor((v.tree_bottom - v.tree_y) / uf.line_h), 1))) - 1, 1);
    tr.top = @min(tr.top, tr.rows.items.len -| v.tree_rows);
}

// Scrolls so the primary caret is on screen.
pub fn followCaret(ed: *const Editor, v: *View) !void {
    const head = ed.primary().head;
    const n = ed.t.lineOf(head);
    if (n < v.top or (n == v.top and v.scroll_y > 0)) {
        v.top = n;
        v.scroll_y = 0;
    }
    if (n >= v.top + v.rows) {
        v.top = n - v.rows + 1;
        v.scroll_y = 0;
    }
    const col = try motion.colOf(&ed.t, head);
    if (col < v.left) v.left = col -| 8;
    if (col >= v.left + v.cols) v.left = col - v.cols + 8;
}

// Takes whole lines of the pixel scroll into the top line.
pub fn clampScroll(ed: *const Editor, v: *View) void {
    const lines = @floor(v.scroll_y / v.line_h);
    v.scroll_y -= lines * v.line_h;
    const top = @as(i64, @intCast(v.top)) + @as(i64, @intFromFloat(lines));
    if (top < 0) {
        v.top = 0;
        v.scroll_y = 0;
    } else v.top = @intCast(top);
    if (v.top >= ed.t.lf) {
        v.top = ed.t.lf;
        v.scroll_y = 0;
    }
}

pub fn cellX(v: *const View, col: usize) f32 {
    return v.text_x + (float(col) - float(v.left)) * v.cell_w;
}

// The offset nearest to a point, clamped to the text.
pub fn hit(ed: *const Editor, v: *const View, x: f32, y: f32) !usize {
    const row = @floor((y - v.text_y + v.scroll_y) / v.line_h);
    const n: usize = @intCast(std.math.clamp(@as(i64, @intCast(v.top)) + @as(i64, @intFromFloat(row)), 0, @as(i64, @intCast(ed.t.lf))));
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ed.gpa);
    try ed.t.readLine(n, &line);
    const cells = (x - v.text_x) / v.cell_w + float(v.left);
    return ed.t.lineStart(n) + width.offsetAtX(line.items, @max(cells, 0));
}

// One line of text at row `y`, colored by `spans`, with its tabs, full-width
// spaces and trailing blanks shown as marks.
pub fn drawLine(ren: *c.SDL_Renderer, f: *Face, v: *const View, line: []const u8, y: f32, spans: []const Span) !void {
    // Where the trailing blanks start, which get marks.
    var blank_from = line.len;
    while (blank_from > 0 and (line[blank_from - 1] == ' ' or line[blank_from - 1] == '\t')) blank_from -= 1;
    const last_col = v.left + v.cols;
    var span: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len and col < last_col) {
        const d = utf8.decode(line, i);
        const cp = d.cp;
        while (span < spans.len and spans[span].start + spans[span].len <= i) span += 1;
        const color = if (span < spans.len and spans[span].start <= i) th().token(spans[span].kind) else th().fg;
        const w = width.widthAt(cp, col);
        if (col >= v.left) {
            const x = cellX(v, col);
            if (cp == '\t') {
                const mid = y + @round(f.line_h * 0.5);
                const t = @max(@round(f.cell_w * 0.1), 1);
                fill(ren, x + f.cell_w * 0.25, mid - @floor(t / 2), float(w) * f.cell_w - f.cell_w * 0.5, t, th().invisible);
            } else if (cp == ' ' and i >= blank_from) {
                const s = @max(@round(f.cell_w * 0.2), 2);
                fill(ren, x + @round((f.cell_w - s) * 0.5), y + @round((f.line_h - s) * 0.5), s, s, th().invisible);
            } else if (cp == 0x3000) {
                const inset = @round(f.cell_w * 0.2);
                const color2 = th().invisible;
                _ = c.SDL_SetRenderDrawColor(ren, color2.r, color2.g, color2.b, color2.a);
                _ = c.SDL_RenderRect(ren, &.{ .x = x + inset, .y = y + inset * 2, .w = float(w) * f.cell_w - inset * 2, .h = f.line_h - inset * 4 });
            } else if (cp < 0x20 or cp == 0x7F or cp == 0xFFFD) {
                f.box(x, y, @max(w, 1), th().notice);
            } else if (w > 0 and cp != ' ') {
                if (!try f.drawChar(x, y, cp, w, color)) f.box(x, y, w, th().invisible);
            }
        }
        col += w;
        i += d.len;
    }
}

pub const Cols = struct { a: usize, b: usize, past: bool };

// The part of [a, b) on a line starting at `ls` with text `line`, as cell
// columns; `past` when the range goes on beyond the line's break.
pub fn spanCols(line: []const u8, ls: usize, a: usize, b: usize) Cols {
    const lo = std.math.clamp(a -| ls, 0, line.len);
    const hi = std.math.clamp(b -| ls, 0, line.len);
    const ca = width.advance(line[0..lo], 0);
    return .{ .a = ca, .b = width.advance(line[lo..hi], ca), .past = b > ls + line.len };
}

pub fn fillCols(ren: *c.SDL_Renderer, v: *const View, y: f32, ca: usize, cb: usize, color: Color) void {
    const a = @max(ca, v.left);
    const b = @min(cb, v.left + v.cols + 1);
    if (b > a) fill(ren, cellX(v, a), y, float(b - a) * v.cell_w, v.line_h, color);
}

pub const Scratch = struct {
    gpa: Allocator,
    line: std.ArrayList(u8) = .empty,
    s: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,

    pub fn deinit(s: *Scratch) void {
        s.line.deinit(s.gpa);
        s.s.deinit(s.gpa);
        s.spans.deinit(s.gpa);
    }
};

fn drawTextArea(ren: *c.SDL_Renderer, f: *Face, ed: *const Editor, v: *const View, hl: *const syntax.Highlight, sc: *Scratch) !void {
    const t = &ed.t;
    const p = ed.primary();
    const current = t.lineOf(p.head);
    const now = state.clock();
    const blink_on = @mod(now - v.blink_at, 1.1) < 0.65 or now - v.blink_at < 0.6;
    var lex_state: u8 = syntax.state_normal;
    var num_buf: [24]u8 = undefined;
    _ = c.SDL_SetRenderClipRect(ren, &.{ .x = 0, .y = 0, .w = @intFromFloat(v.right_x), .h = @intFromFloat(v.text_bottom + @round(f.line_h * 0.3)) });
    defer _ = c.SDL_SetRenderClipRect(ren, null);
    // One more row than fits: when scrolled part of a line, it shows at the bottom.
    for (0..v.rows + 1) |row| {
        const n = v.top + row;
        if (n > t.lf) break;
        const y = v.text_y + float(row) * f.line_h - v.scroll_y;
        const ls = t.lineStart(n);
        sc.line.clearRetainingCapacity();
        try t.readLine(n, &sc.line);
        const line = sc.line.items;
        const le = ls + line.len;
        if (n == current and p.isEmpty()) fill(ren, v.panel_w, y, v.right_x - v.panel_w, f.line_h, th().current_line);
        // Matches of the search, on this line.
        if (v.bar == .find and v.query.len > 0) {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, line, at, v.query.slice())) |k| {
                const cols = spanCols(line, ls, ls + k, ls + k + v.query.len);
                fillCols(ren, v, y, cols.a, cols.b, th().match_bg);
                at = k + v.query.len;
            }
        }
        for (ed.sels.items) |s| {
            if (s.isEmpty() or s.hi() < ls or s.lo() > le) continue;
            const cols = spanCols(line, ls, s.lo(), s.hi());
            fillCols(ren, v, y, cols.a, if (cols.past) cols.b + 1 else cols.b, th().selection);
        }
        // The line number, right-aligned in the gutter.
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{n + 1}) catch unreachable;
        const nx = v.text_x - float(num.len + 1) * f.cell_w;
        _ = try f.drawStr(nx, y, num, if (n == current) th().gutter_fg_current else th().gutter_fg);
        // The state the line starts in: known, or carried on from the row above.
        if (hl.stateAt(n)) |known| lex_state = known;
        sc.spans.clearRetainingCapacity();
        if (hl.lang) |l| lex_state = try syntax.lexLine(sc.gpa, l, line, lex_state, &sc.spans);
        try drawLine(ren, f, v, line, y, sc.spans.items);
        for (ed.sels.items) |s| {
            if (s.head < ls or s.head > le) continue;
            const col = width.advance(line[0 .. s.head - ls], 0);
            if (col < v.left or col > v.left + v.cols) continue;
            const x = cellX(v, col);
            if (s.head == p.head and v.composing.len > 0) {
                // What the input method is composing, over the text at the caret.
                const cw = width.advance(v.composing.slice(), 0);
                fill(ren, x, y, float(cw) * f.cell_w, f.line_h, th().field_bg);
                _ = try f.drawStr(x, y, v.composing.slice(), th().fg);
                fill(ren, x, y + f.line_h - @max(@round(f.cell_w * 0.12), 1), float(cw) * f.cell_w, @max(@round(f.cell_w * 0.12), 1), th().caret);
                continue;
            }
            if (blink_on) fill(ren, x - 1, y, @max(@round(f.cell_w * 0.22), 2), f.line_h, th().caret);
        }
    }
}

fn drawBars(ren: *c.SDL_Renderer, f: *Face, ed: *const Editor, v: *const View, w: f32, h: f32, sc: *Scratch) !void {
    const gpa = sc.gpa;
    var y = h - f.line_h;
    const s = &sc.s;
    // The status bar: the file, the caret, and what the file is made of.
    fill(ren, 0, y, w, f.line_h, th().bar_bg);
    const p = ed.primary();
    s.clearRetainingCapacity();
    try s.appendSlice(gpa, if (v.path.len > 0) v.path.slice() else "(untitled)");
    if (ed.h.modified()) try s.appendSlice(gpa, " ●");
    if (v.readonly) try s.appendSlice(gpa, "  [read-only]");
    try s.print(gpa, "   Ln {d}, Col {d}", .{ ed.t.lineOf(p.head) + 1, try motion.colOf(&ed.t, p.head) + 1 });
    if (ed.sels.items.len > 1) {
        try s.print(gpa, "   ({d} cursors)", .{ed.sels.items.len});
    } else if (!p.isEmpty()) try s.print(gpa, "   ({d} bytes selected)", .{p.hi() - p.lo()});
    try s.appendSlice(gpa, if (v.info.utf8) "   UTF-8" else "   not UTF-8");
    if (v.info.bom) try s.appendSlice(gpa, " BOM");
    try s.appendSlice(gpa, if (ed.crlf) "   CRLF" else "   LF");
    try s.appendSlice(gpa, if (ed.tabs) "   Tabs" else "   Spaces");
    _ = try f.drawStr(f.cell_w, y, s.items, th().bar_fg);
    if (v.message.len > 0 and state.clock() - v.message_at < 4.0) {
        const mw = float(width.advance(v.message.slice(), 0) + 2);
        const x = @max(w - mw * f.cell_w, w * 0.5);
        fill(ren, x - f.cell_w, y, w - x + f.cell_w, f.line_h, th().bar_bg);
        _ = try f.drawStr(x, y, v.message.slice(), th().notice);
    }
    if (v.bar == .none) return;
    // The field above it: search, or where to save.
    y -= f.line_h;
    fill(ren, 0, y, w, f.line_h, th().field_bg);
    s.clearRetainingCapacity();
    try s.appendSlice(gpa, if (v.bar == .find) "Find: " else "Save as: ");
    try s.appendSlice(gpa, v.query.slice());
    const caret_col = try f.drawStr(f.cell_w, y, s.items, th().fg);
    fill(ren, float(caret_col + 1) * f.cell_w, y, @max(@round(f.cell_w * 0.22), 2), f.line_h, th().caret);
    if (v.bar == .find) {
        const hint = "Enter: next   Shift+Enter: previous   Esc: close";
        const hx = w - float(width.advance(hint, 0) + 2) * f.cell_w;
        if (hx > float(caret_col + 4) * f.cell_w) _ = try f.drawStr(hx, y, hint, th().hint_fg);
    }
}

pub const TreeHit = union(enum) { none, header, row: usize };

// The tree's row at a point.
pub fn treeRowAt(v: *const View, tr: *const Tree, x: f32, y: f32) TreeHit {
    if (x >= v.panel_w or y < v.tree_y or y >= v.tree_bottom) return .none;
    const row: usize = @intFromFloat((y - v.tree_y) / v.ui_line_h);
    if (row == 0) return .header;
    const i = tr.top + row - 1;
    return if (i < tr.rows.items.len) .{ .row = i } else .none;
}

// The tree: the directory's name, then a row per entry, indented by depth;
// the file being edited is marked.
pub fn drawTree(ren: *c.SDL_Renderer, f: *Face, v: *const View, tr: *const Tree, sc: *Scratch) !void {
    const gpa = sc.gpa;
    const pw = v.panel_w;
    fill(ren, 0, 0, pw, v.tree_bottom, th().panel_bg);
    fill(ren, pw - 1, 0, 1, v.tree_bottom, th().panel_edge);
    const s = &sc.s;
    s.clearRetainingCapacity();
    try tree.fit(gpa, tr.title, tr.width -| 2, s);
    _ = try f.drawStr(f.cell_w, v.tree_y, s.items, th().hint_fg);
    for (0..v.tree_rows) |row| {
        const i = tr.top + row;
        if (i >= tr.rows.items.len) break;
        const e = tr.rows.items[i];
        const y = v.tree_y + float(row + 1) * f.line_h;
        const current = !e.is_dir and v.path.eql(e.path);
        if (current) fill(ren, 0, y, pw - 1, f.line_h, th().panel_current);
        const indent = 1 + e.depth * 2;
        if (e.is_dir) {
            // A small triangle: right when closed, down when open.
            const cx = (float(indent) + 0.5) * f.cell_w;
            const cy = y + f.line_h * 0.5;
            const r = f.cell_w * 0.35;
            if (e.open) {
                triangle(ren, .{ .{ cx - r, cy - r * 0.6 }, .{ cx + r, cy - r * 0.6 }, .{ cx, cy + r * 0.8 } }, th().hint_fg);
            } else {
                triangle(ren, .{ .{ cx - r * 0.6, cy - r }, .{ cx - r * 0.6, cy + r }, .{ cx + r * 0.8, cy } }, th().hint_fg);
            }
        }
        s.clearRetainingCapacity();
        try tree.fit(gpa, e.name(), tr.width -| (indent + 3), s);
        const label = if (e.is_dir) th().tree_dir_fg else if (current) th().tree_current_fg else th().tree_fg;
        _ = try f.drawStr(float(indent + 2) * f.cell_w, y, s.items, label);
    }
}

pub fn draw(ren: *c.SDL_Renderer, f: *Fonts, ed: *const Editor, v: *View, tr: *Tree, hl: *const syntax.Highlight, sc: *Scratch) !void {
    var pw: c_int = 0;
    var ph: c_int = 0;
    _ = c.SDL_GetCurrentRenderOutputSize(ren, &pw, &ph);
    const w: f32 = @floatFromInt(pw);
    const h: f32 = @floatFromInt(ph);
    layout(ed, v, tr, f, w, h);
    clampScroll(ed, v);
    if (v.center) {
        v.center = false;
        v.top = ed.t.lineOf(ed.primary().head) -| v.rows / 3;
        v.scroll_y = 0;
    }
    if (v.follow) {
        try followCaret(ed, v);
        v.follow = false;
        clampScroll(ed, v);
    }
    const bg = th().bg;
    _ = c.SDL_SetRenderDrawColor(ren, bg.r, bg.g, bg.b, 255);
    _ = c.SDL_RenderClear(ren);
    try drawTextArea(ren, &f.text, ed, v, hl, sc);
    if (tr.shown) try drawTree(ren, &f.ui, v, tr, sc);
    try drawBars(ren, &f.ui, ed, v, w, h, sc);
}
