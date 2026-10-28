// Undo and redo.
//
// An edit is recorded as where it happened, the add-buffer span it
// inserted, and the pieces it removed, kept in `dels`: the removed bytes
// are still in their buffers, so nothing is copied. A group is what one
// command did, for every selection at once, with the selections before and
// after it. Typing extends the last group until something else happens.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const Text = text.Text;
const Piece = text.Piece;
const Sel = @import("select.zig").Sel;

pub const EditOp = struct { pos: usize, ins_start: usize, ins_len: usize, del_first: usize, del_count: usize, del_len: usize };

pub const Group = struct {
    op_first: usize,
    op_count: usize,
    before_first: usize,
    before_count: usize,
    after_first: usize,
    after_count: usize,
    kind: Kind,
};

pub const Kind = enum {
    none,
    type, // typed characters: merged with the previous typing
    edit, // anything else that changes the text
};

pub const History = struct {
    gpa: Allocator,
    ops: std.ArrayList(EditOp) = .empty,
    dels: std.ArrayList(Piece) = .empty,
    groups: std.ArrayList(Group) = .empty,
    snaps: std.ArrayList(Sel) = .empty, // selections before and after each group
    applied: usize = 0, // groups[0..applied] are in effect; the rest can be redone
    last_kind: Kind = .none, // what the last command was, for merging typing
    saved_at: ?usize = 0, // `applied` when the file was saved; null if that state is gone
    scratch: std.ArrayList(Piece) = .empty,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(h: *History) void {
        h.ops.deinit(h.gpa);
        h.dels.deinit(h.gpa);
        h.groups.deinit(h.gpa);
        h.snaps.deinit(h.gpa);
        h.scratch.deinit(h.gpa);
    }

    pub fn modified(h: *const History) bool {
        return h.saved_at != h.applied;
    }

    pub fn markSaved(h: *History) void {
        h.saved_at = h.applied;
        h.last_kind = .none;
    }

    // Ends merging: the next typing starts a group of its own.
    pub fn seal(h: *History) void {
        h.last_kind = .none;
    }

    // Forgets what could be redone.
    fn dropRedo(h: *History) void {
        if (h.applied == h.groups.items.len) return;
        const g = h.groups.items[h.applied];
        if (g.op_first < h.ops.items.len) h.dels.shrinkRetainingCapacity(h.ops.items[g.op_first].del_first);
        h.ops.shrinkRetainingCapacity(g.op_first);
        h.snaps.shrinkRetainingCapacity(g.before_first);
        h.groups.shrinkRetainingCapacity(h.applied);
        if (h.saved_at) |s| {
            if (s > h.applied) h.saved_at = null;
        }
    }

    // Starts recording a command of `kind` done to `sels`.
    pub fn beginGroup(h: *History, sels: []const Sel, kind: Kind) !void {
        const merge = kind == .type and h.last_kind == .type and h.applied == h.groups.items.len and
            h.applied > 0 and h.saved_at != h.applied;
        if (merge) {
            // Reopen the last group: its "after" selections are the last snapshot.
            h.snaps.shrinkRetainingCapacity(h.groups.items[h.applied - 1].after_first);
            return;
        }
        h.dropRedo();
        const first = h.snaps.items.len;
        try h.snaps.appendSlice(h.gpa, sels);
        try h.groups.append(h.gpa, .{
            .op_first = h.ops.items.len,
            .op_count = 0,
            .before_first = first,
            .before_count = sels.len,
            .after_first = h.snaps.items.len,
            .after_count = 0,
            .kind = kind,
        });
        h.applied = h.groups.items.len;
    }

    pub fn endGroup(h: *History, sels: []const Sel, kind: Kind) !void {
        const g = &h.groups.items[h.applied - 1];
        g.op_count = h.ops.items.len - g.op_first;
        g.after_first = h.snaps.items.len;
        g.after_count = sels.len;
        try h.snaps.appendSlice(h.gpa, sels);
        h.last_kind = kind;
    }

    // Replaces [pos, pos + len) with `bytes`, recording it in the open group.
    pub fn replace(h: *History, t: *Text, pos: usize, len: usize, bytes: []const u8) !void {
        const del_first = h.dels.items.len;
        try t.cut(pos, len, &h.dels);
        const start = try t.insert(pos, bytes);
        const del_count = h.dels.items.len - del_first;
        if (h.ops.items.len > h.groups.items[h.applied - 1].op_first and del_count == 0) {
            // Typing straight after the last insertion: one op, not one per key.
            const op = &h.ops.items[h.ops.items.len - 1];
            if (op.del_count == 0 and op.pos + op.ins_len == pos and op.ins_start + op.ins_len == start) {
                op.ins_len += bytes.len;
                return;
            }
        }
        try h.ops.append(h.gpa, .{ .pos = pos, .ins_start = start, .ins_len = bytes.len, .del_first = del_first, .del_count = del_count, .del_len = len });
    }

    fn restoreSels(h: *History, sels: *std.ArrayList(Sel), first: usize, count: usize) !void {
        sels.clearRetainingCapacity();
        try sels.appendSlice(h.gpa, h.snaps.items[first .. first + count]);
    }

    pub fn undo(h: *History, t: *Text, sels: *std.ArrayList(Sel)) !bool {
        if (h.applied == 0) return false;
        const g = h.groups.items[h.applied - 1];
        var i = g.op_first + g.op_count;
        while (i > g.op_first) {
            i -= 1;
            const op = h.ops.items[i];
            h.scratch.clearRetainingCapacity();
            try t.cut(op.pos, op.ins_len, &h.scratch);
            try t.insertPieces(op.pos, h.dels.items[op.del_first .. op.del_first + op.del_count]);
        }
        try h.restoreSels(sels, g.before_first, g.before_count);
        h.applied -= 1;
        h.last_kind = .none;
        return true;
    }

    pub fn redo(h: *History, t: *Text, sels: *std.ArrayList(Sel)) !bool {
        if (h.applied == h.groups.items.len) return false;
        const g = h.groups.items[h.applied];
        for (h.ops.items[g.op_first .. g.op_first + g.op_count]) |op| {
            h.scratch.clearRetainingCapacity();
            try t.cut(op.pos, op.del_len, &h.scratch);
            if (op.ins_len > 0) {
                try t.insertPieces(op.pos, &.{.{ .src = .add, .start = op.ins_start, .len = op.ins_len, .lf = t.countLf(.add, op.ins_start, op.ins_len) }});
            }
        }
        try h.restoreSels(sels, g.after_first, g.after_count);
        h.applied += 1;
        h.last_kind = .none;
        return true;
    }
};
