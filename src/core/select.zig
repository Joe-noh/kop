// Selections. There is always at least one; each is an anchor and a head
// (the caret), equal when nothing is selected. `goal` is the cell column
// up and down aim for, kept across lines that are too short.

const std = @import("std");

pub const Sel = struct {
    anchor: usize,
    head: usize,
    goal: ?usize = null,

    pub fn caret(pos: usize) Sel {
        return .{ .anchor = pos, .head = pos };
    }
    pub fn lo(s: Sel) usize {
        return @min(s.anchor, s.head);
    }
    pub fn hi(s: Sel) usize {
        return @max(s.anchor, s.head);
    }
    pub fn isEmpty(s: Sel) bool {
        return s.anchor == s.head;
    }
};

fn before(_: void, a: Sel, b: Sel) bool {
    return a.lo() < b.lo() or (a.lo() == b.lo() and a.hi() < b.hi());
}

// Sorts by start and merges selections that overlap, or carets that coincide.
pub fn normalize(sels: *std.ArrayList(Sel)) void {
    const items = sels.items;
    std.mem.sort(Sel, items, {}, before);
    var w: usize = 0;
    for (items) |s| {
        if (w > 0) {
            const p = items[w - 1];
            if (s.lo() < p.hi() or (s.lo() == p.hi() and (s.isEmpty() or p.isEmpty()))) {
                const a = @min(p.lo(), s.lo());
                const b = @max(p.hi(), s.hi());
                // Keep the direction of the selection that was there first.
                items[w - 1] = if (p.head < p.anchor) .{ .anchor = b, .head = a } else .{ .anchor = a, .head = b };
                continue;
            }
        }
        items[w] = s;
        w += 1;
    }
    sels.shrinkRetainingCapacity(w);
}

pub fn clampSels(sels: []Sel, len: usize) void {
    for (sels) |*s| {
        s.anchor = @min(s.anchor, len);
        s.head = @min(s.head, len);
    }
}
