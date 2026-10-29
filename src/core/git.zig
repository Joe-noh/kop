// What git says has changed in a project: the files that differ from
// HEAD, staged or not, and the new files it does not track yet, each with
// how many lines it adds and removes.
//
// Asking git takes a moment, so Background asks it on a thread of its
// own, one question at a time, and the window takes the answer when it
// comes.

const std = @import("std");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum { modified, added, deleted };

pub const Change = struct {
    path: []const u8, // as it opens: written from the directory asked about, as the tree writes it
    name: []const u8, // from the repository's top
    kind: Kind,
    added: ?usize = null, // lines; null for a binary file
    removed: ?usize = null,
};

pub const Changes = struct {
    arena: std.heap.ArenaAllocator,
    top: []const u8 = "", // the repository's top directory
    list: std.ArrayList(Change) = .empty, // by name

    pub fn deinit(c: *Changes) void {
        c.arena.deinit();
    }
};

// Runs git with `args` in `dir`; its output, or null if it failed.
fn run(gpa: Allocator, dir: []const u8, args: []const []const u8) !?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", dir });
    try argv.appendSlice(gpa, args);
    const r = sys.run(gpa, argv.items, 64 << 20) catch return null;
    gpa.free(r.stderr);
    if (r.ok) return r.stdout;
    gpa.free(r.stdout);
    return null;
}

pub const Entry = struct { kind: Kind, name: []const u8 };

// Reads `git status --porcelain=v1 -z --no-renames`: "XY name\0" each, X
// for the index and Y for the working tree.
pub fn parseStatus(gpa: Allocator, out: []const u8, entries: *std.ArrayList(Entry)) !void {
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |rec| {
        if (rec.len < 4) continue;
        const x = rec[0];
        const y = rec[1];
        const kind: Kind = if (x == '!') continue else if (x == '?' or x == 'A' or y == 'A')
            .added
        else if (x == 'D' or y == 'D')
            .deleted
        else
            .modified;
        try entries.append(gpa, .{ .kind = kind, .name = rec[3..] });
    }
}

pub const Count = struct { added: ?usize, removed: ?usize };

// Reads `git diff --numstat -z --no-renames`: "added\tremoved\tname\0"
// each, "-" for a binary file's counts.
pub fn parseNumstat(gpa: Allocator, out: []const u8, counts: *std.StringHashMapUnmanaged(Count)) !void {
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |rec| {
        var fields = std.mem.splitScalar(u8, rec, '\t');
        const a = fields.next() orelse continue;
        const r = fields.next() orelse continue;
        const name = fields.rest();
        if (name.len == 0) continue;
        try counts.put(gpa, name, .{
            .added = std.fmt.parseInt(usize, a, 10) catch null,
            .removed = std.fmt.parseInt(usize, r, 10) catch null,
        });
    }
}

// The lines of a file git does not know yet, all of them added; null for
// a binary one.
fn countLines(gpa: Allocator, path: []const u8) ?usize {
    const data = sys.readFile(gpa, path, 64 << 20) catch return null;
    defer gpa.free(data);
    if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) != null) return null;
    const n = std.mem.count(u8, data, "\n");
    return if (data.len > 0 and data[data.len - 1] != '\n') n + 1 else n;
}

fn byName(_: void, a: Change, b: Change) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// What has changed in the repository `dir` is in; null when it is in none.
pub fn collect(gpa: Allocator, dir: []const u8) !?Changes {
    const top_out = try run(gpa, dir, &.{ "rev-parse", "--show-toplevel", "--show-prefix" }) orelse return null;
    defer gpa.free(top_out);
    var c = Changes{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer c.deinit();
    const a = c.arena.allocator();
    var lines = std.mem.splitScalar(u8, top_out, '\n');
    c.top = try a.dupe(u8, lines.next() orelse "");
    // Where `dir` is in the repository: its files' paths are written from
    // `dir`, as the tree writes them, so the two say the same of a file.
    const prefix = lines.next() orelse "";
    const status = try run(gpa, c.top, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames" }) orelse return c;
    defer gpa.free(status);
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    try parseStatus(gpa, status, &entries);
    // Against HEAD, so what is staged counts too; a repository with no
    // commit yet has no HEAD, and then everything in it is new.
    const numstat = try run(gpa, c.top, &.{ "diff", "--numstat", "-z", "--no-renames", "HEAD" });
    defer if (numstat) |n| gpa.free(n);
    var counts: std.StringHashMapUnmanaged(Count) = .empty;
    defer counts.deinit(gpa);
    if (numstat) |n| try parseNumstat(gpa, n, &counts);
    for (entries.items) |e| {
        const path = if (std.mem.startsWith(u8, e.name, prefix))
            try std.fs.path.join(a, &.{ dir, e.name[prefix.len..] })
        else
            try std.fs.path.join(a, &.{ c.top, e.name });
        var ch = Change{ .path = path, .name = try a.dupe(u8, e.name), .kind = e.kind };
        if (counts.get(e.name)) |n| {
            ch.added = n.added;
            ch.removed = n.removed;
        } else if (e.kind == .added) {
            ch.added = countLines(gpa, path);
            ch.removed = if (ch.added != null) 0 else null;
        }
        try c.list.append(a, ch);
    }
    std.mem.sort(Change, c.list.items, {}, byName);
    return c;
}

// What a file was at HEAD, to tell how it has changed since.
pub const Head = struct {
    gpa: Allocator,
    data: []u8, // empty for a file git does not track yet
    tracked: bool,

    pub fn deinit(h: *Head) void {
        h.gpa.free(h.data);
    }
};

// The file at `path` as HEAD has it; null outside a repository, and for
// a file git ignores.
pub fn headVersion(gpa: Allocator, path: []const u8) !?Head {
    const dir = std.fs.path.dirname(path) orelse ".";
    const spec = try std.fmt.allocPrint(gpa, "HEAD:./{s}", .{std.fs.path.basename(path)});
    defer gpa.free(spec);
    if (try run(gpa, dir, &.{ "show", spec })) |data| return .{ .gpa = gpa, .data = data, .tracked = true };
    // Not at HEAD: a new file of a repository, or no repository's at all.
    const inside = try run(gpa, dir, &.{ "rev-parse", "--is-inside-work-tree" }) orelse return null;
    gpa.free(inside);
    if (try run(gpa, dir, &.{ "check-ignore", "-q", std.fs.path.basename(path) })) |o| {
        gpa.free(o);
        return null;
    }
    return .{ .gpa = gpa, .data = try gpa.alloc(u8, 0), .tracked = false };
}

// Runs `work` on a thread of its own, one question at a time: start()
// asks, or asks once the question in flight is answered; take() hands
// over an answer when there is one, with the question it answers. An
// answer that failed is null, as is one there is nothing to say for.
pub fn Background(comptime T: type, comptime work: fn (Allocator, []const u8) anyerror!?T) type {
    return struct {
        gpa: Allocator,
        input: std.ArrayList(u8) = .empty, // the question in flight
        next: std.ArrayList(u8) = .empty, // the one to ask after it
        has_next: bool = false,
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        answer: ?T = null, // written by the thread, read once `done`

        const Self = @This();

        pub const Answer = struct { question: []const u8, value: ?T };

        pub fn deinit(b: *Self) void {
            if (b.thread) |t| t.join();
            if (b.answer) |*a| a.deinit();
            b.input.deinit(b.gpa);
            b.next.deinit(b.gpa);
        }

        fn run_(b: *Self) void {
            b.answer = work(b.gpa, b.input.items) catch null;
            b.done.store(true, .release);
        }

        pub fn busy(b: *const Self) bool {
            return b.thread != null;
        }

        pub fn start(b: *Self, question: []const u8) !void {
            if (b.thread != null) {
                b.next.clearRetainingCapacity();
                try b.next.appendSlice(b.gpa, question);
                b.has_next = true;
                return;
            }
            b.input.clearRetainingCapacity();
            try b.input.appendSlice(b.gpa, question);
            b.done.store(false, .release);
            b.thread = try std.Thread.spawn(.{}, run_, .{b});
        }

        // The question in the answer stays good until the next take().
        pub fn take(b: *Self) !?Answer {
            const t = b.thread orelse return null;
            if (!b.done.load(.acquire)) return null;
            t.join();
            b.thread = null;
            const value = b.answer;
            b.answer = null;
            // The answered question moves to `next`'s buffer, so the next
            // one can go in flight.
            std.mem.swap(std.ArrayList(u8), &b.input, &b.next);
            if (b.has_next) {
                b.has_next = false;
                b.done.store(false, .release);
                b.thread = try std.Thread.spawn(.{}, run_, .{b});
            }
            return .{ .question = b.next.items, .value = value };
        }
    };
}

pub const Refresher = Background(Changes, collect);
pub const HeadLoader = Background(Head, headVersion);

test "status and numstat" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    try parseStatus(gpa, " M src/a.zig\x00?? new file.txt\x00A  staged.zig\x00 D gone.zig\x00MM both.zig\x00!! ignored\x00", &entries);
    try testing.expectEqual(@as(usize, 5), entries.items.len);
    try testing.expectEqual(Kind.modified, entries.items[0].kind);
    try testing.expectEqualStrings("src/a.zig", entries.items[0].name);
    try testing.expectEqual(Kind.added, entries.items[1].kind);
    try testing.expectEqualStrings("new file.txt", entries.items[1].name);
    try testing.expectEqual(Kind.added, entries.items[2].kind);
    try testing.expectEqual(Kind.deleted, entries.items[3].kind);
    try testing.expectEqual(Kind.modified, entries.items[4].kind);
    var counts: std.StringHashMapUnmanaged(Count) = .empty;
    defer counts.deinit(gpa);
    try parseNumstat(gpa, "3\t1\tsrc/a.zig\x00-\t-\timage.png\x00", &counts);
    try testing.expectEqual(Count{ .added = 3, .removed = 1 }, counts.get("src/a.zig").?);
    try testing.expectEqual(Count{ .added = null, .removed = null }, counts.get("image.png").?);
}

test "a repository's changes" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const dir_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_z);
    const dir: []const u8 = dir_z;
    const setup = [_][]const []const u8{
        &.{"init"},
        &.{ "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-m", "start" },
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one\ntwo\nthree\n" });
    for (setup) |args| {
        const o = try run(gpa, dir, args) orelse return error.SkipZigTest;
        gpa.free(o);
    }
    if (try run(gpa, dir, &.{ "add", "kept.txt" })) |o| gpa.free(o);
    if (try run(gpa, dir, &.{ "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "kept" })) |o| gpa.free(o);
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one\n2\nthree\nfour\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "a\nb" });
    var c = (try collect(gpa, dir)).?;
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.list.items.len);
    const kept = c.list.items[0];
    try testing.expectEqualStrings("kept.txt", kept.name);
    try testing.expect(kept.kind == .modified and kept.added == 2 and kept.removed == 1);
    const new = c.list.items[1];
    try testing.expect(new.kind == .added and new.added == 2 and new.removed == 0);
    try testing.expect(std.mem.startsWith(u8, new.path, dir));
    // Asked from inside a directory of it, its files are written from there.
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/x.txt", .data = "x\n" });
    const sub = try std.fs.path.join(gpa, &.{ dir, "sub" });
    defer gpa.free(sub);
    var c2 = (try collect(gpa, sub)).?;
    defer c2.deinit();
    for (c2.list.items) |e| if (std.mem.eql(u8, e.name, "sub/x.txt")) {
        const want = try std.fs.path.join(gpa, &.{ sub, "x.txt" });
        defer gpa.free(want);
        try testing.expectEqualStrings(want, e.path);
    };
}
