// The difference between two versions of a text, line by line: which runs
// of lines of the old one became which runs of the new one. Lines are
// compared by hash, the lines both versions start and end with are set
// aside first, and the rest goes through Myers's O(ND) algorithm, which
// finds the fewest lines to remove and add. Past a limit of differences,
// what is left is one run replaced by another.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Text = @import("text.zig").Text;

// Old lines [old_start, old_start + old_count) became new lines
// [new_start, new_start + new_count). A count of 0 is a run added or
// removed between lines.
pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,

    pub const Kind = enum { added, removed, changed };

    pub fn kind(h: Hunk) Kind {
        return if (h.old_count == 0) .added else if (h.new_count == 0) .removed else .changed;
    }
};

const max_edits = 4000;

// Appends a hash of each line of `text` to `out`; a line's "\r" before its
// "\n" is not part of it.
pub fn hashLines(gpa: Allocator, text: []const u8, out: *std.ArrayList(u64)) !void {
    var start: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        var end = nl orelse text.len;
        if (end > start and text[end - 1] == '\r') end -= 1;
        try out.append(gpa, std.hash.Wyhash.hash(0, text[start..end]));
        start = (nl orelse return) + 1;
    }
}

// The hunks that turn the lines hashed in `a` into those in `b`, in order.
pub fn diff(gpa: Allocator, a: []const u64, b: []const u64, out: *std.ArrayList(Hunk)) !void {
    // What both start and end with.
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and a[pre] == b[pre]) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and a[a.len - 1 - suf] == b[b.len - 1 - suf]) suf += 1;
    const x = a[pre .. a.len - suf];
    const y = b[pre .. b.len - suf];
    if (x.len == 0 and y.len == 0) return;
    if (x.len == 0 or y.len == 0) {
        try out.append(gpa, .{ .old_start = pre, .old_count = x.len, .new_start = pre, .new_count = y.len });
        return;
    }
    try myers(gpa, x, y, pre, out);
}

const Snake = struct { x: usize, y: usize, len: usize };

fn myers(gpa: Allocator, a: []const u64, b: []const u64, offset: usize, out: *std.ArrayList(Hunk)) !void {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const max: isize = @min(n + m, max_edits);
    // v[k + max] is how far along a the furthest path on diagonal k (x - y)
    // reaches; trace keeps v's live part, [-d, d], after each round d.
    const v = try gpa.alloc(isize, @intCast(2 * max + 2));
    defer gpa.free(v);
    @memset(v, 0);
    var trace: std.ArrayList(isize) = .empty;
    defer trace.deinit(gpa);
    var starts: std.ArrayList(usize) = .empty; // where each round's part of trace starts
    defer starts.deinit(gpa);
    const at = struct {
        fn f(k: isize, mx: isize) usize {
            return @intCast(k + mx);
        }
    }.f;
    var found: ?isize = null;
    var d: isize = 0;
    while (d <= max) : (d += 1) {
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            var px: isize = if (k == -d or (k != d and v[at(k - 1, max)] < v[at(k + 1, max)])) v[at(k + 1, max)] else v[at(k - 1, max)] + 1;
            var py = px - k;
            while (px < n and py < m and a[@intCast(px)] == b[@intCast(py)]) {
                px += 1;
                py += 1;
            }
            v[at(k, max)] = px;
            if (px >= n and py >= m) found = d;
            if (found != null) break;
        }
        try starts.append(gpa, trace.items.len);
        try trace.appendSlice(gpa, v[at(-d, max) .. at(d, max) + 1]);
        if (found != null) break;
    }
    const total = found orelse {
        // Too different: one run replaced by the other.
        try out.append(gpa, .{ .old_start = offset, .old_count = a.len, .new_start = offset, .new_count = b.len });
        return;
    };
    // Back from the end, the diagonal runs the path took, last first.
    var snakes: std.ArrayList(Snake) = .empty;
    defer snakes.deinit(gpa);
    var x: isize = n;
    var y: isize = m;
    d = total;
    while (d > 0) : (d -= 1) {
        const prev = trace.items[starts.items[@intCast(d - 1)]..];
        const vp = struct {
            fn f(p: []const isize, k: isize, dd: isize) isize {
                return p[@intCast(k + dd)];
            }
        }.f;
        const k = x - y;
        const down = k == -d or (k != d and vp(prev, k - 1, d - 1) < vp(prev, k + 1, d - 1));
        const pk = if (down) k + 1 else k - 1;
        const px = vp(prev, pk, d - 1);
        const py = px - pk;
        // The step from (px, py), then the diagonal to (x, y).
        const mx = if (down) px else px + 1;
        const my = if (down) py + 1 else py;
        if (x > mx) try snakes.append(gpa, .{ .x = @intCast(mx), .y = @intCast(my), .len = @intCast(x - mx) });
        x = px;
        y = py;
    }
    if (x > 0) try snakes.append(gpa, .{ .x = 0, .y = 0, .len = @intCast(x) });
    // The hunks are what lies between the diagonals.
    var ox: usize = 0;
    var oy: usize = 0;
    var i = snakes.items.len;
    while (i > 0) {
        i -= 1;
        const s = snakes.items[i];
        if (s.x > ox or s.y > oy) try out.append(gpa, .{ .old_start = offset + ox, .old_count = s.x - ox, .new_start = offset + oy, .new_count = s.y - oy });
        ox = s.x + s.len;
        oy = s.y + s.len;
    }
    if (ox < a.len or oy < b.len) try out.append(gpa, .{ .old_start = offset + ox, .old_count = a.len - ox, .new_start = offset + oy, .new_count = b.len - oy });
}

// A document's difference from what it was at HEAD, kept up to date as it
// is edited: the hunks, and what they come to.
pub const Live = struct {
    gpa: Allocator,
    base: std.ArrayList(u64) = .empty, // HEAD's lines, hashed
    has_base: bool = false,
    tracked: bool = true, // false for a file new since HEAD, all of it added
    hunks: std.ArrayList(Hunk) = .empty,
    lines: std.ArrayList(u64) = .empty,
    buf: std.ArrayList(u8) = .empty,
    stale: bool = false, // the text or the base changed since the hunks were found
    added: usize = 0,
    removed: usize = 0,

    // Past this, a document is not compared, so a huge file stays quick.
    pub const max_bytes = 16 << 20;

    pub fn deinit(l: *Live) void {
        l.base.deinit(l.gpa);
        l.hunks.deinit(l.gpa);
        l.lines.deinit(l.gpa);
        l.buf.deinit(l.gpa);
    }

    pub fn setBase(l: *Live, data: []const u8, tracked: bool) !void {
        l.base.clearRetainingCapacity();
        if (tracked) try hashLines(l.gpa, data, &l.base);
        l.has_base = true;
        l.tracked = tracked;
        l.stale = true;
    }

    pub fn clearBase(l: *Live) void {
        l.has_base = false;
        l.hunks.clearRetainingCapacity();
        l.added = 0;
        l.removed = 0;
    }

    pub fn update(l: *Live, t: *const Text) !void {
        if (!l.has_base or !l.stale) return;
        l.stale = false;
        l.hunks.clearRetainingCapacity();
        l.added = 0;
        l.removed = 0;
        if (t.len > max_bytes) return;
        l.buf.clearRetainingCapacity();
        try t.all(&l.buf);
        l.lines.clearRetainingCapacity();
        try hashLines(l.gpa, l.buf.items, &l.lines);
        // A new file's lines are all added; an empty one has none.
        if (!l.tracked and l.buf.items.len == 0) return;
        try diff(l.gpa, l.base.items, l.lines.items, &l.hunks);
        for (l.hunks.items) |h| {
            l.added += h.new_count;
            l.removed += h.old_count;
        }
    }

    pub const Mark = struct {
        kind: ?Hunk.Kind = null, // the line is added, or changed
        removed_above: bool = false, // lines were removed just before it
        removed_below: bool = false, // and after it, at the end of the text
    };

    // How line `n` of the document differs, of `count` lines.
    pub fn markAt(l: *const Live, n: usize, count: usize) Mark {
        const hs = l.hunks.items;
        // The first hunk that does not end before n.
        var lo: usize = 0;
        var hi: usize = hs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const h = hs[mid];
            if (h.new_start + h.new_count <= n and !(h.new_count == 0 and h.new_start == n)) lo = mid + 1 else hi = mid;
        }
        var m = Mark{};
        for (hs[lo..]) |h| {
            if (h.new_start > n + 1) break;
            if (h.new_count == 0) {
                if (h.new_start == n) m.removed_above = true;
                if (h.new_start == n + 1 and n + 1 == count) m.removed_below = true;
            } else if (h.new_start <= n and n < h.new_start + h.new_count) m.kind = h.kind();
        }
        return m;
    }
};

// Tests.

const testing = std.testing;

fn diffText(old: []const u8, new: []const u8, out: *std.ArrayList(Hunk)) !void {
    const gpa = testing.allocator;
    var a: std.ArrayList(u64) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u64) = .empty;
    defer b.deinit(gpa);
    try hashLines(gpa, old, &a);
    try hashLines(gpa, new, &b);
    try diff(gpa, a.items, b.items, out);
}

test "hunks" {
    const gpa = testing.allocator;
    var hs: std.ArrayList(Hunk) = .empty;
    defer hs.deinit(gpa);
    try diffText("a\nb\nc\n", "a\nb\nc\n", &hs);
    try testing.expectEqual(@as(usize, 0), hs.items.len);
    try diffText("a\nb\nc\nd\ne\n", "a\nB\nc\nd\nx\ny\ne\n", &hs);
    try testing.expectEqualSlices(Hunk, &.{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1 },
        .{ .old_start = 4, .old_count = 0, .new_start = 4, .new_count = 2 },
    }, hs.items);
    hs.clearRetainingCapacity();
    try diffText("a\nb\nc\nd\n", "a\nd\n", &hs);
    try testing.expectEqualSlices(Hunk, &.{.{ .old_start = 1, .old_count = 2, .new_start = 1, .new_count = 0 }}, hs.items);
    hs.clearRetainingCapacity();
    // CRLF and LF lines are the same lines.
    try diffText("a\r\nb\r\n", "a\nb\n", &hs);
    try testing.expectEqual(@as(usize, 0), hs.items.len);
}

// Random edits to random lines: applying the hunks to the old lines must
// give the new ones, and they must take no more lines than were edited.
test "diff fuzz" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(99);
    const r = prng.random();
    for (0..300) |_| {
        var a: std.ArrayList(u64) = .empty;
        defer a.deinit(gpa);
        for (0..r.uintLessThan(usize, 40)) |_| try a.append(gpa, r.uintLessThan(u64, 6));
        var b: std.ArrayList(u64) = .empty;
        defer b.deinit(gpa);
        try b.appendSlice(gpa, a.items);
        var edits: usize = 0;
        for (0..r.uintLessThan(usize, 6)) |_| {
            if (b.items.len > 0 and r.boolean()) {
                _ = b.orderedRemove(r.uintLessThan(usize, b.items.len));
            } else try b.insert(gpa, r.uintAtMost(usize, b.items.len), r.uintLessThan(u64, 6));
            edits += 1;
        }
        var hs: std.ArrayList(Hunk) = .empty;
        defer hs.deinit(gpa);
        try diff(gpa, a.items, b.items, &hs);
        var rebuilt: std.ArrayList(u64) = .empty;
        defer rebuilt.deinit(gpa);
        var ai: usize = 0;
        var changed: usize = 0;
        for (hs.items) |h| {
            try testing.expect(h.old_start >= ai);
            try rebuilt.appendSlice(gpa, a.items[ai..h.old_start]);
            try rebuilt.appendSlice(gpa, b.items[h.new_start .. h.new_start + h.new_count]);
            ai = h.old_start + h.old_count;
            changed += h.old_count + h.new_count;
        }
        try rebuilt.appendSlice(gpa, a.items[ai..]);
        try testing.expectEqualSlices(u64, b.items, rebuilt.items);
        try testing.expect(changed <= edits);
    }
}

test "live marks" {
    const gpa = testing.allocator;
    const tt = try @import("text.zig").TestText.init("a\nB\nc\nx\nd\n");
    defer tt.deinit();
    var l = Live{ .gpa = gpa };
    defer l.deinit();
    try l.setBase("a\nb\nc\nd\ne\n", true);
    try l.update(&tt.t);
    // a, B (changed), c, x (added), d, then e removed at the end.
    try testing.expect(l.markAt(0, 6).kind == null);
    try testing.expectEqual(Hunk.Kind.changed, l.markAt(1, 6).kind.?);
    try testing.expectEqual(Hunk.Kind.added, l.markAt(3, 6).kind.?);
    try testing.expect(l.markAt(5, 6).removed_above);
    try testing.expect(l.added == 2 and l.removed == 2);
    try l.setBase("", false);
    try l.update(&tt.t);
    try testing.expectEqual(Hunk.Kind.added, l.markAt(0, 6).kind.?);
    try testing.expectEqual(@as(usize, 6), l.added);
}
