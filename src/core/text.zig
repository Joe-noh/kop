// The document's bytes as a piece table.
//
// The file is read once into `orig` and never written; everything typed is
// appended to `add`, which is only ever appended to, so a piece is just
// (which buffer, where, how long). The document is the pieces read in
// order. Deleted text stays in its buffer, so undo keeps the pieces it
// removed instead of copying their bytes.
//
// Each piece also counts its newlines, and `orig_lf` lists where every
// newline of `orig` is, so splitting a piece of a huge file costs a binary
// search, not a scan.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Src = enum(u8) { orig, add };

pub const Piece = struct { src: Src, start: usize, len: usize, lf: usize };

pub const not_dirty: usize = std.math.maxInt(usize);

// Appends the offset of every '\n' in `s` to `out`.
pub fn indexLf(gpa: Allocator, s: []const u8, out: *std.ArrayList(usize)) !void {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, pos, '\n')) |k| {
        try out.append(gpa, k);
        pos = k + 1;
    }
}

// The first index of `xs` (ascending) whose value is not below `v`.
fn lowerBound(xs: []const usize, v: usize) usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (xs[mid] < v) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub const Text = struct {
    gpa: Allocator,
    // Both belong to whoever made the Text and outlive it.
    orig: []const u8,
    orig_lf: []const usize,
    add: std.ArrayList(u8) = .empty,
    pieces: std.ArrayList(Piece) = .empty,
    len: usize = 0,
    lf: usize = 0,
    dirty_from: usize = not_dirty, // the first offset changed since the last takeDirty

    pub fn init(gpa: Allocator, orig: []const u8, orig_lf: []const usize) !Text {
        var t = Text{ .gpa = gpa, .orig = orig, .orig_lf = orig_lf, .len = orig.len, .lf = orig_lf.len };
        if (orig.len > 0) try t.pieces.append(gpa, .{ .src = .orig, .start = 0, .len = orig.len, .lf = orig_lf.len });
        return t;
    }

    pub fn deinit(t: *Text) void {
        t.add.deinit(t.gpa);
        t.pieces.deinit(t.gpa);
    }

    // Where the text first changed since the last call, or not_dirty.
    pub fn takeDirty(t: *Text) usize {
        const d = t.dirty_from;
        t.dirty_from = not_dirty;
        return d;
    }

    pub fn lineCount(t: *const Text) usize {
        return t.lf + 1;
    }

    pub fn bytesOf(t: *const Text, src: Src, start: usize, len: usize) []const u8 {
        return switch (src) {
            .orig => t.orig[start .. start + len],
            .add => t.add.items[start .. start + len],
        };
    }

    pub fn countLf(t: *const Text, src: Src, start: usize, len: usize) usize {
        if (len == 0) return 0;
        if (src == .orig) return lowerBound(t.orig_lf, start + len) - lowerBound(t.orig_lf, start);
        return std.mem.count(u8, t.add.items[start .. start + len], "\n");
    }

    // Splits the pieces so that one starts at `pos`, and returns its index:
    // pieces[0..k] are exactly the bytes before `pos`.
    fn splitAt(t: *Text, pos: usize) !usize {
        var at: usize = 0;
        for (t.pieces.items, 0..) |p, i| {
            if (pos == at) return i;
            if (pos < at + p.len) {
                const off = pos - at;
                const left_lf = t.countLf(p.src, p.start, off);
                t.pieces.items[i] = .{ .src = p.src, .start = p.start, .len = off, .lf = left_lf };
                try t.pieces.insert(t.gpa, i + 1, .{ .src = p.src, .start = p.start + off, .len = p.len - off, .lf = p.lf - left_lf });
                return i + 1;
            }
            at += p.len;
        }
        return t.pieces.items.len;
    }

    // Joins pieces k-1 and k when the second continues the first in the same buffer.
    fn mergeAt(t: *Text, k: usize) void {
        if (k == 0 or k >= t.pieces.items.len) return;
        const a = t.pieces.items[k - 1];
        const b = t.pieces.items[k];
        if (a.src == b.src and a.start + a.len == b.start) {
            t.pieces.items[k - 1] = .{ .src = a.src, .start = a.start, .len = a.len + b.len, .lf = a.lf + b.lf };
            _ = t.pieces.orderedRemove(k);
        }
    }

    // Inserts the given pieces at `pos`.
    pub fn insertPieces(t: *Text, pos: usize, ps: []const Piece) !void {
        if (ps.len == 0) return;
        t.dirty_from = @min(t.dirty_from, pos);
        const k = try t.splitAt(pos);
        try t.pieces.insertSlice(t.gpa, k, ps);
        for (ps) |p| {
            t.len += p.len;
            t.lf += p.lf;
        }
        t.mergeAt(k + ps.len);
        t.mergeAt(k);
    }

    // Appends `bytes` to the add buffer and inserts them at `pos`; returns
    // where they went in the add buffer.
    pub fn insert(t: *Text, pos: usize, bytes: []const u8) !usize {
        const start = t.add.items.len;
        if (bytes.len == 0) return start;
        try t.add.appendSlice(t.gpa, bytes);
        const p = Piece{ .src = .add, .start = start, .len = bytes.len, .lf = t.countLf(.add, start, bytes.len) };
        try t.insertPieces(pos, &.{p});
        return start;
    }

    // Removes [pos, pos + len) and appends the pieces that held it to `out`.
    pub fn cut(t: *Text, pos: usize, len: usize, out: *std.ArrayList(Piece)) !void {
        if (len == 0) return;
        t.dirty_from = @min(t.dirty_from, pos);
        const a = try t.splitAt(pos);
        const b = try t.splitAt(pos + len);
        for (t.pieces.items[a..b]) |p| {
            t.len -= p.len;
            t.lf -= p.lf;
        }
        try out.appendSlice(t.gpa, t.pieces.items[a..b]);
        t.pieces.replaceRangeAssumeCapacity(a, b - a, &.{});
        t.mergeAt(a);
    }

    // Appends the bytes of [a, b) to `out`.
    pub fn read(t: *const Text, a: usize, b: usize, out: *std.ArrayList(u8)) !void {
        if (b <= a) return;
        var at: usize = 0;
        for (t.pieces.items) |p| {
            const end = at + p.len;
            if (end > a and at < b) {
                const lo = @max(a, at) - at;
                const hi = @min(b, end) - at;
                try out.appendSlice(t.gpa, t.bytesOf(p.src, p.start + lo, hi - lo));
            }
            if (end >= b) break;
            at = end;
        }
    }

    pub fn byteAt(t: *const Text, pos: usize) u8 {
        var at: usize = 0;
        for (t.pieces.items) |p| {
            if (pos < at + p.len) return t.bytesOf(p.src, p.start, p.len)[pos - at];
            at += p.len;
        }
        return 0;
    }

    // The offset where line `n` (from 0) starts.
    pub fn lineStart(t: *const Text, n: usize) usize {
        if (n == 0) return 0;
        if (n > t.lf) return t.len;
        var at: usize = 0;
        var lf: usize = 0;
        for (t.pieces.items) |p| {
            if (lf + p.lf >= n) {
                const k = n - lf; // the k-th newline in this piece, from 1
                if (p.src == .orig) {
                    const first = lowerBound(t.orig_lf, p.start);
                    return at + t.orig_lf[first + k - 1] - p.start + 1;
                }
                var seen: usize = 0;
                for (t.add.items[p.start .. p.start + p.len], 0..) |c, i| {
                    if (c == '\n') {
                        seen += 1;
                        if (seen == k) return at + i + 1;
                    }
                }
            }
            at += p.len;
            lf += p.lf;
        }
        return t.len;
    }

    // The line `pos` is on.
    pub fn lineOf(t: *const Text, pos: usize) usize {
        var at: usize = 0;
        var lf: usize = 0;
        for (t.pieces.items) |p| {
            if (pos < at + p.len) return lf + t.countLf(p.src, p.start, pos - at);
            at += p.len;
            lf += p.lf;
        }
        return lf;
    }

    // Where line `n`'s text ends: before its "\n" or "\r\n".
    pub fn lineEnd(t: *const Text, n: usize) usize {
        if (n >= t.lf) return t.len;
        const nl = t.lineStart(n + 1) - 1;
        if (nl > t.lineStart(n) and t.byteAt(nl - 1) == '\r') return nl - 1;
        return nl;
    }

    // Appends line `n`'s text, without its line break, to `out`.
    pub fn readLine(t: *const Text, n: usize, out: *std.ArrayList(u8)) !void {
        try t.read(t.lineStart(n), t.lineEnd(n), out);
    }

    // The first match of `needle` at or after `from`.
    pub fn findForward(t: *const Text, from: usize, needle: []const u8) !?usize {
        const m = needle.len;
        if (m == 0 or from >= t.len) return null;
        // The last m - 1 bytes before the current piece, and where they start.
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(t.gpa);
        var window: std.ArrayList(u8) = .empty;
        defer window.deinit(t.gpa);
        var carry_at: usize = 0;
        var at: usize = 0;
        for (t.pieces.items) |p| {
            const end = at + p.len;
            if (end <= from) {
                at = end;
                continue;
            }
            const lo = @max(from, at);
            const seg = t.bytesOf(p.src, p.start + lo - at, end - lo);
            if (carry.items.len > 0) {
                window.clearRetainingCapacity();
                try window.appendSlice(t.gpa, carry.items);
                try window.appendSlice(t.gpa, seg[0..@min(m - 1, seg.len)]);
                if (std.mem.indexOf(u8, window.items, needle)) |k| {
                    if (k < carry.items.len) return carry_at + k;
                }
            }
            if (std.mem.indexOf(u8, seg, needle)) |k| return lo + k;
            try carry.appendSlice(t.gpa, seg);
            const keep = @min(m - 1, carry.items.len);
            std.mem.copyForwards(u8, carry.items[0..keep], carry.items[carry.items.len - keep ..]);
            carry.shrinkRetainingCapacity(keep);
            carry_at = end - keep;
            at = end;
        }
        return null;
    }

    // The last match of `needle` that ends at or before `before`.
    pub fn findBackward(t: *const Text, before: usize, needle: []const u8) !?usize {
        const m = needle.len;
        if (m == 0 or before == 0) return null;
        // The first m - 1 bytes after the current piece.
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(t.gpa);
        var window: std.ArrayList(u8) = .empty;
        defer window.deinit(t.gpa);
        var end_at = t.len;
        var i = t.pieces.items.len;
        while (i > 0) {
            i -= 1;
            const p = t.pieces.items[i];
            const at = end_at - p.len;
            if (at >= before) {
                end_at = at;
                continue;
            }
            const hi = @min(before, end_at);
            const seg = t.bytesOf(p.src, p.start, hi - at);
            if (carry.items.len > 0) {
                const head = seg[seg.len - @min(seg.len, m - 1) ..];
                window.clearRetainingCapacity();
                try window.appendSlice(t.gpa, head);
                try window.appendSlice(t.gpa, carry.items);
                if (std.mem.lastIndexOf(u8, window.items, needle)) |k| {
                    if (k + m > head.len) return hi - head.len + k;
                }
            }
            if (std.mem.lastIndexOf(u8, seg, needle)) |k| return at + k;
            window.clearRetainingCapacity();
            try window.appendSlice(t.gpa, seg);
            try window.appendSlice(t.gpa, carry.items);
            const keep = @min(m - 1, window.items.len);
            carry.clearRetainingCapacity();
            try carry.appendSlice(t.gpa, window.items[0..keep]);
            end_at = at;
        }
        return null;
    }

    // The whole text, for tests and saving.
    pub fn all(t: *const Text, out: *std.ArrayList(u8)) !void {
        try t.read(0, t.len, out);
    }
};

// Tests.

const testing = std.testing;

pub const TestText = struct {
    lf: std.ArrayList(usize) = .empty,
    t: Text,

    pub fn init(src: []const u8) !*TestText {
        const self = try testing.allocator.create(TestText);
        self.* = .{ .t = undefined };
        try indexLf(testing.allocator, src, &self.lf);
        self.t = try Text.init(testing.allocator, src, self.lf.items);
        return self;
    }

    pub fn deinit(self: *TestText) void {
        self.t.deinit();
        self.lf.deinit(testing.allocator);
        testing.allocator.destroy(self);
    }
};

pub fn wholeOf(t: *const Text) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try t.all(&out);
    return out.toOwnedSlice(t.gpa);
}

fn expectText(t: *const Text, want: []const u8) !void {
    const got = try wholeOf(t);
    defer t.gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

test "text basics" {
    const tt = try TestText.init("hello\nworld\n");
    defer tt.deinit();
    const t = &tt.t;
    try testing.expect(t.len == 12 and t.lineCount() == 3);
    _ = try t.insert(5, ", big");
    try expectText(t, "hello, big\nworld\n");
    _ = try t.insert(0, ">");
    _ = try t.insert(t.len, "end");
    try expectText(t, ">hello, big\nworld\nend");
    var gone: std.ArrayList(Piece) = .empty;
    defer gone.deinit(testing.allocator);
    try t.cut(6, 5, &gone);
    try expectText(t, ">hello\nworld\nend");
    try testing.expect(t.lineStart(1) == 7 and t.lineStart(2) == 13);
    try testing.expect(t.lineOf(6) == 0 and t.lineOf(7) == 1 and t.lineOf(20) == 2);
    try testing.expect(t.lineEnd(0) == 6 and t.lineEnd(2) == t.len);
    try t.insertPieces(6, gone.items);
    try expectText(t, ">hello, big\nworld\nend");
    try testing.expectEqual(@as(?usize, 12), try t.findForward(0, "world"));
    try testing.expectEqual(@as(?usize, 15), try t.findBackward(t.len, "l"));
}

// Random edits against a plain byte array, checking contents and line queries.
test "text fuzz" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(12345);
    const r = prng.random();
    const src = "alpha\nbeta\r\ngamma\n\ndelta";
    const tt = try TestText.init(src);
    defer tt.deinit();
    const t = &tt.t;
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, src);
    const alphabet = "ab\nあ\r";
    var gone: std.ArrayList(Piece) = .empty;
    defer gone.deinit(gpa);
    for (0..3000) |step| {
        const pos = r.uintAtMost(usize, model.items.len);
        if (r.uintLessThan(usize, 3) > 0 or model.items.len == 0) {
            var ins: [4]u8 = undefined;
            const n = r.uintLessThan(usize, 4) + 1;
            for (ins[0..n]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
            _ = try t.insert(pos, ins[0..n]);
            try model.insertSlice(gpa, pos, ins[0..n]);
        } else {
            const n = @min(r.uintLessThan(usize, 6) + 1, model.items.len - pos);
            gone.clearRetainingCapacity();
            try t.cut(pos, n, &gone);
            if (r.uintLessThan(usize, 4) == 0) {
                try t.insertPieces(pos, gone.items); // as undo would
            } else {
                model.replaceRangeAssumeCapacity(pos, n, &.{});
            }
        }
        if (step % 97 == 0 or step == 2999) {
            try expectText(t, model.items);
            try testing.expect(t.lf == std.mem.count(u8, model.items, "\n") and t.len == model.items.len);
            var line: usize = 0;
            for (model.items, 0..) |c, i| {
                if (c == '\n') {
                    line += 1;
                    try testing.expectEqual(i + 1, t.lineStart(line));
                }
            }
            const probe = r.uintAtMost(usize, model.items.len);
            try testing.expectEqual(std.mem.count(u8, model.items[0..probe], "\n"), t.lineOf(probe));
            const needle = model.items[probe..@min(probe + 3, model.items.len)];
            if (needle.len > 0) {
                try testing.expectEqual(std.mem.indexOf(u8, model.items, needle), try t.findForward(0, needle));
                try testing.expectEqual(std.mem.lastIndexOf(u8, model.items, needle), try t.findBackward(t.len, needle));
            }
        }
    }
}
