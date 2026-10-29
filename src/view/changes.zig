// The changes beside the text, on the right: the files git says differ
// from HEAD and the new ones, each marked by what happened to it (yellow
// changed, green new, red deleted) with the lines it adds and removes.
// A click opens one.

const std = @import("std");
const c = @import("c.zig").c;
const git = @import("../core/git.zig");
const width = @import("../core/width.zig");
const state = @import("state.zig");
const View = state.View;
const font = @import("font.zig");
const render = @import("render.zig");
const fill = render.fill;
const tree = @import("tree.zig");
const theme = @import("theme.zig");

pub const cells = 36; // the panel's width, in the ui's cells

fn th() *const theme.Theme {
    return &theme.current;
}

fn float(n: usize) f32 {
    return @floatFromInt(n);
}

// The document being edited, as it differs from HEAD now, saved or not.
pub const Live = struct { path: []const u8, added: usize, removed: usize, tracked: bool };

pub const Panel = struct {
    top: usize = 0, // the first change shown
    wheel: f32 = 0,
    rows: std.ArrayList(git.Change) = .empty, // git's changes, with the document's own as it is now

    pub fn deinit(p: *Panel, gpa: std.mem.Allocator) void {
        p.rows.deinit(gpa);
    }

    // The rows: git's changes, the document's counted as it is now, and
    // the document itself first if git does not have it yet.
    pub fn build(p: *Panel, gpa: std.mem.Allocator, ch: *const git.Changes, live: ?Live) !void {
        p.rows.clearRetainingCapacity();
        var found = false;
        for (ch.list.items) |e| {
            var row = e;
            if (live) |l| if (std.mem.eql(u8, e.path, l.path)) {
                found = true;
                row.added = l.added;
                row.removed = l.removed;
            };
            try p.rows.append(gpa, row);
        }
        if (live) |l| if (!found and l.added + l.removed > 0) {
            try p.rows.insert(gpa, 0, .{
                .path = l.path,
                .name = std.fs.path.basename(l.path),
                .kind = if (l.tracked) .modified else .added,
                .added = l.added,
                .removed = l.removed,
            });
        };
    }

    // How many rows of changes fit below the heading.
    fn fits(v: *const View) usize {
        return render.listRows(v);
    }

    pub fn scroll(p: *Panel, v: *View, count: usize) void {
        p.wheel += v.changes_wheel;
        v.changes_wheel = 0;
        const rows = @trunc(p.wheel);
        p.wheel -= rows;
        const top = @as(i64, @intCast(p.top)) - @as(i64, @intFromFloat(rows));
        p.top = @min(@as(usize, @intCast(@max(top, 0))), count -| fits(v));
    }

    // The change at height `y`.
    pub fn changeAt(p: *const Panel, v: *const View, y: f32) ?*const git.Change {
        const i = p.top + (render.listRowAt(v, y) orelse return null);
        return if (i < p.rows.items.len) &p.rows.items[i] else null;
    }

    pub fn draw(p: *Panel, ren: *c.SDL_Renderer, f: *font.Face, v: *const View, sc: *render.Scratch) !void {
        const gpa = sc.gpa;
        const x0 = v.right_x;
        const w = float(cells) * f.cell_w;
        fill(ren, x0, 0, w, v.tree_bottom, th().panel_bg);
        fill(ren, x0, 0, 1, v.tree_bottom, th().panel_edge);
        const s = &sc.s;
        s.clearRetainingCapacity();
        const list = p.rows.items;
        if (list.len == 0) try s.appendSlice(gpa, "No changes") else try s.print(gpa, "Changes  {d}", .{list.len});
        _ = try f.drawStr(x0 + f.cell_w, v.tree_y, s.items, th().hint_fg);
        p.top = @min(p.top, list.len -| fits(v));
        for (0..fits(v)) |row| {
            const i = p.top + row;
            if (i >= list.len) break;
            const e = list[i];
            const y = render.listTop(v) + float(row) * f.line_h;
            if (v.path.eql(e.path)) fill(ren, x0 + 1, y, w - 1, f.line_h, th().panel_current);
            // What happened to it, as a colored mark.
            const mark = switch (e.kind) {
                .modified => th().changed,
                .added => th().added,
                .deleted => th().removed,
            };
            const d = @round(f.cell_w * 0.6);
            fill(ren, x0 + f.cell_w + @round((f.cell_w - d) * 0.5), y + @round((f.line_h - d) * 0.5), d, d, mark);
            // Its lines, at the right: "+12 −3".
            var counts: [48]u8 = undefined;
            var plus: []const u8 = "";
            var minus: []const u8 = "";
            // A side with nothing to count is left out: "+4" for a new file.
            if (e.added) |n| if (n > 0) {
                plus = std.fmt.bufPrint(counts[0..24], "+{d}", .{n}) catch "";
            };
            if (e.removed) |n| if (n > 0) {
                minus = std.fmt.bufPrint(counts[24..], "−{d}", .{n}) catch "";
            };
            if (e.added == null and e.removed == null) plus = "binary";
            const counts_w = width.advance(plus, 0) + width.advance(minus, 0) + @as(usize, if (plus.len > 0 and minus.len > 0) 1 else 0);
            const right = x0 + w - f.cell_w;
            const cx = right - float(counts_w) * f.cell_w;
            const plus_cols = try f.drawStr(cx, y, plus, if (e.added == null) th().hint_fg else th().added);
            if (minus.len > 0) _ = try f.drawStr(cx + float(plus_cols + @as(usize, if (plus.len > 0) 1 else 0)) * f.cell_w, y, minus, th().removed);
            // Its name, then where it is, dim, in what room is left.
            const room = cells -| (4 + counts_w + 2);
            const base = std.fs.path.basename(e.name);
            const dir = e.name[0 .. e.name.len - base.len];
            s.clearRetainingCapacity();
            try tree.fit(gpa, base, room, s);
            const nx = x0 + f.cell_w * 3;
            const name_cols = try f.drawStr(nx, y, s.items, if (e.kind == .deleted) th().hint_fg else th().tree_fg);
            if (dir.len > 0 and name_cols + 2 < room) {
                s.clearRetainingCapacity();
                try tree.fit(gpa, std.mem.trimEnd(u8, dir, "/"), room - name_cols - 1, s);
                _ = try f.drawStr(nx + float(name_cols + 1) * f.cell_w, y, s.items, th().hint_fg);
            }
        }
    }
};
