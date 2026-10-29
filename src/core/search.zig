// Searching a whole project: which files it has, where a query is in each,
// and the excerpts around the matches that the results show.
//
// The files are git's, tracked and untracked but not ignored, when the
// project is a repository; otherwise every file below it that is not
// hidden. Binary files and huge ones are skipped. A query in lower case
// matches either case; one with a capital letter only its own (as Vim's
// smartcase).

const std = @import("std");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;

pub const context_lines = 2; // shown before and after each match
pub const max_matches = 10000;
const max_file_size = 16 << 20;

// A match: on which line, and where in it, in bytes.
pub const Match = struct { line: usize, start: usize, len: usize };

// Lines first to last, both shown.
pub const Excerpt = struct { first: usize, last: usize };

pub const FileResult = struct {
    path: []const u8, // as it opens: the project's directory joined with the file's
    name: []const u8, // as it shows: from the project's directory
    data: []const u8,
    line_starts: []const usize, // where each line starts; one more than the file has newlines
    matches: []const Match,
    excerpts: []const Excerpt,

    pub fn lineCount(f: *const FileResult) usize {
        return f.line_starts.len;
    }

    // Line `n`'s text, without its line break.
    pub fn line(f: *const FileResult, n: usize) []const u8 {
        const a = f.line_starts[n];
        var b = if (n + 1 < f.line_starts.len) f.line_starts[n + 1] - 1 else f.data.len;
        if (b > a and f.data[b - 1] == '\r') b -= 1;
        return f.data[a..b];
    }
};

pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    files: std.ArrayList(FileResult) = .empty,
    total: usize = 0, // matches found
    searched: usize = 0, // files looked in
    truncated: bool = false, // stopped at max_matches

    pub fn deinit(r: *Results) void {
        r.arena.deinit();
    }
};

// Whether the query matches only its own case: when it has a capital letter.
pub fn caseSensitive(query: []const u8) bool {
    for (query) |c| if (std.ascii.isUpper(c)) return true;
    return false;
}

fn indexOf(hay: []const u8, from: usize, needle: []const u8, sensitive: bool) ?usize {
    return if (sensitive) std.mem.indexOfPos(u8, hay, from, needle) else std.ascii.findIgnoreCasePos(hay, from, needle);
}

// The matches of `query` in `data`, with `line_starts` saying where its
// lines start; at most `limit` of them.
pub fn findAll(gpa: Allocator, data: []const u8, line_starts: []const usize, query: []const u8, limit: usize, out: *std.ArrayList(Match)) !void {
    if (query.len == 0) return;
    const sensitive = caseSensitive(query);
    var line: usize = 0;
    var at: usize = 0;
    while (out.items.len < limit) {
        const k = indexOf(data, at, query, sensitive) orelse break;
        while (line + 1 < line_starts.len and line_starts[line + 1] <= k) line += 1;
        try out.append(gpa, .{ .line = line, .start = k - line_starts[line], .len = query.len });
        at = k + query.len;
    }
}

// The excerpts around the lines of `matches` (in order), `context` lines
// either side, those that touch or overlap made one.
pub fn excerptsFor(gpa: Allocator, matches: []const Match, context: usize, line_count: usize, out: *std.ArrayList(Excerpt)) !void {
    for (matches) |m| {
        const first = m.line -| context;
        const last = @min(m.line + context, line_count - 1);
        if (out.items.len > 0) {
            const prev = &out.items[out.items.len - 1];
            if (first <= prev.last + 1) {
                prev.last = @max(prev.last, last);
                continue;
            }
        }
        try out.append(gpa, .{ .first = first, .last = last });
    }
}

pub fn lineStarts(gpa: Allocator, data: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    try out.append(gpa, 0);
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, pos, '\n')) |k| {
        try out.append(gpa, k + 1);
        pos = k + 1;
    }
    return out.toOwnedSlice(gpa);
}

fn isBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) != null;
}

// Directories never worth looking in when git does not say which files count.
fn skipped(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, "zig-out");
}

// The project's files, relative to `root`, one after another in `out`.
pub fn listFiles(gpa: Allocator, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    if (sys.run(gpa, &.{ "git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard" }, 256 << 20)) |r| {
        defer gpa.free(r.stderr);
        if (r.ok) {
            defer gpa.free(r.stdout);
            var it = std.mem.splitScalar(u8, r.stdout, 0);
            while (it.next()) |p| if (p.len > 0) try out.append(gpa, try gpa.dupe(u8, p));
            if (out.items.len > 0) return;
        } else gpa.free(r.stdout);
    } else |_| {}
    // Not a repository, or no git, or a directory git ignores: every file
    // that is not hidden.
    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    try dirs.append(gpa, try gpa.dupe(u8, ""));
    while (dirs.pop()) |rel| {
        defer gpa.free(rel);
        const full = try std.fs.path.join(gpa, &.{ root, rel });
        defer gpa.free(full);
        const dir = sys.openDir(full) catch continue;
        defer sys.closeDir(dir);
        var it = sys.Entries.of(dir);
        while (it.next()) |e| {
            if (skipped(e.name)) continue;
            const p = try std.fs.path.join(gpa, &.{ rel, e.name });
            switch (e.kind) {
                .directory => try dirs.append(gpa, p),
                .file, .sym_link => try out.append(gpa, p),
                else => gpa.free(p),
            }
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

// Searches the files of the project at `root` for `query`.
pub fn search(gpa: Allocator, root: []const u8, query: []const u8) !Results {
    var r = Results{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer r.deinit();
    if (query.len == 0) return r;
    const a = r.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    try listFiles(gpa, root, &names);
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(gpa);
    var excerpts: std.ArrayList(Excerpt) = .empty;
    defer excerpts.deinit(gpa);
    for (names.items) |name| {
        if (r.total >= max_matches) {
            r.truncated = true;
            break;
        }
        const path = try std.fs.path.join(a, &.{ root, name });
        const data = sys.readFile(gpa, path, max_file_size) catch continue;
        r.searched += 1;
        if (isBinary(data) or (if (caseSensitive(query)) std.mem.indexOf(u8, data, query) else std.ascii.findIgnoreCase(data, query)) == null) {
            gpa.free(data);
            continue;
        }
        defer gpa.free(data);
        const kept = try a.dupe(u8, data);
        const starts = try lineStarts(a, kept);
        matches.clearRetainingCapacity();
        try findAll(gpa, kept, starts, query, max_matches - r.total, &matches);
        excerpts.clearRetainingCapacity();
        try excerptsFor(gpa, matches.items, context_lines, starts.len, &excerpts);
        r.total += matches.items.len;
        try r.files.append(a, .{
            .path = path,
            .name = path[path.len - name.len ..],
            .data = kept,
            .line_starts = starts,
            .matches = try a.dupe(Match, matches.items),
            .excerpts = try a.dupe(Excerpt, excerpts.items),
        });
    }
    return r;
}

test "matches and excerpts" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const data = "a\nfoo\nb\nc\nd\ne\nf\ng\nFoo foo\nh";
    const starts = try lineStarts(gpa, data);
    defer gpa.free(starts);
    try testing.expectEqual(@as(usize, 10), starts.len);
    var ms: std.ArrayList(Match) = .empty;
    defer ms.deinit(gpa);
    try findAll(gpa, data, starts, "foo", 100, &ms);
    try testing.expectEqualSlices(Match, &.{
        .{ .line = 1, .start = 0, .len = 3 },
        .{ .line = 8, .start = 0, .len = 3 },
        .{ .line = 8, .start = 4, .len = 3 },
    }, ms.items);
    ms.clearRetainingCapacity();
    try findAll(gpa, data, starts, "Foo", 100, &ms);
    try testing.expectEqual(@as(usize, 1), ms.items.len);
    var ex: std.ArrayList(Excerpt) = .empty;
    defer ex.deinit(gpa);
    try excerptsFor(gpa, &.{ .{ .line = 1, .start = 0, .len = 1 }, .{ .line = 8, .start = 0, .len = 1 }, .{ .line = 8, .start = 4, .len = 1 } }, 2, 10, &ex);
    try testing.expectEqualSlices(Excerpt, &.{ .{ .first = 0, .last = 3 }, .{ .first = 6, .last = 9 } }, ex.items);
    ex.clearRetainingCapacity();
    // Matches five lines apart: their context touches, so one excerpt.
    try excerptsFor(gpa, &.{ .{ .line = 2, .start = 0, .len = 1 }, .{ .line = 7, .start = 0, .len = 1 } }, 2, 10, &ex);
    try testing.expectEqualSlices(Excerpt, &.{.{ .first = 0, .last = 9 }}, ex.items);
}

test "a project's files" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.createDirPath(io, ".hidden");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/a.txt", .data = "one needle\ntwo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "Needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden/c.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "needle\x00" });
    const root_z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_z);
    const root: []const u8 = root_z;
    var r = try search(gpa, root, "needle");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.files.items.len);
    try testing.expectEqual(@as(usize, 2), r.total);
    try testing.expectEqualStrings("b.txt", r.files.items[0].name);
    try testing.expectEqualStrings("sub/a.txt", r.files.items[1].name);
    try testing.expectEqualStrings("one needle", r.files.items[1].line(0));
}
