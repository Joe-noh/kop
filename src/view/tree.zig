// The file tree beside the text: a directory's entries as rows in the order
// they show, directories first. Opening a directory lists it then and puts
// its rows after its own; closing it takes them out again.

const std = @import("std");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const width = @import("../core/width.zig");

pub const Entry = struct {
    path: []const u8, // in the tree's arena
    name_at: usize, // where its last component starts
    depth: usize,
    is_dir: bool,
    open: bool = false,

    pub fn name(e: Entry) []const u8 {
        return e.path[e.name_at..];
    }
};

pub const Tree = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator, // every path listed so far
    root: []const u8 = "", // the directory opened, as it was given; empty for none
    title: []const u8 = "", // its own name, which "." does not say
    rows: std.ArrayList(Entry) = .empty,
    shown: bool = false,
    top: usize = 0, // the first row shown
    width: usize = 32, // in cells
    wheel: f32 = 0,

    pub fn init(gpa: Allocator) Tree {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(tr: *Tree) void {
        tr.rows.deinit(tr.gpa);
        tr.arena.deinit();
    }

    // Names not worth showing.
    fn hidden(name: []const u8) bool {
        return std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, ".DS_Store");
    }

    fn byName(_: void, a: Entry, b: Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.mem.order(u8, a.name(), b.name()) == .lt;
    }

    // The entries of directory `dir`, directories first, into `out`.
    fn listEntries(tr: *Tree, dir: []const u8, depth: usize, out: *std.ArrayList(Entry)) !void {
        const d = sys.openDir(dir) catch return;
        defer sys.closeDir(d);
        const a = tr.arena.allocator();
        const first = out.items.len;
        var it = sys.Entries.of(d);
        while (it.next()) |e| {
            if (hidden(e.name)) continue;
            const sep = if (dir.len > 0 and dir[dir.len - 1] != '/') "/" else "";
            const path = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ dir, sep, e.name });
            const is_dir = e.kind == .directory or (e.kind == .sym_link and isDir(path));
            try out.append(tr.gpa, .{ .path = path, .name_at = path.len - e.name.len, .depth = depth, .is_dir = is_dir });
        }
        std.mem.sort(Entry, out.items[first..], {}, byName);
    }

    pub fn open(tr: *Tree, dir: []const u8) !void {
        var end = dir.len;
        while (end > 1 and dir[end - 1] == '/') end -= 1;
        const a = tr.arena.allocator();
        tr.root = try a.dupe(u8, dir[0..end]);
        tr.title = try directoryName(a, tr.root);
        tr.rows.clearRetainingCapacity();
        try tr.listEntries(tr.root, 0, &tr.rows);
        tr.shown = true;
        tr.top = 0;
    }

    // Opens or closes directory row `i`.
    pub fn toggle(tr: *Tree, i: usize) !void {
        const e = tr.rows.items[i];
        if (!e.is_dir) return;
        if (e.open) {
            var j = i + 1;
            while (j < tr.rows.items.len and tr.rows.items[j].depth > e.depth) j += 1;
            tr.rows.replaceRangeAssumeCapacity(i + 1, j - i - 1, &.{});
            tr.rows.items[i].open = false;
            return;
        }
        var kids: std.ArrayList(Entry) = .empty;
        defer kids.deinit(tr.gpa);
        try tr.listEntries(e.path, e.depth + 1, &kids);
        try tr.rows.insertSlice(tr.gpa, i + 1, kids.items);
        tr.rows.items[i].open = true;
    }
};

fn isDir(path: []const u8) bool {
    return sys.isDir(path);
}

// The name of the directory `path` names, which "." and "dir/.." do not
// say: the last part of its absolute path.
pub fn directoryName(gpa: Allocator, path: []const u8) ![]const u8 {
    const full = sys.realPath(gpa, path) catch return gpa.dupe(u8, path);
    defer gpa.free(full);
    const name = std.fs.path.basename(full);
    return gpa.dupe(u8, if (name.len == 0) "/" else name);
}

// The longest start of `s` that fits in `cells`, with "…" when cut.
pub fn fit(gpa: Allocator, s: []const u8, cells: usize, out: *std.ArrayList(u8)) !void {
    if (width.advance(s, 0) <= cells) {
        try out.appendSlice(gpa, s);
        return;
    }
    try out.appendSlice(gpa, s[0..width.offsetAtCol(s, cells -| 2)]);
    try out.appendSlice(gpa, "…");
}

test "directory name" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const root = try directoryName(gpa, "/");
    defer gpa.free(root);
    try testing.expectEqualStrings("/", root);
    const cwd = try sys.realPath(gpa, ".");
    defer gpa.free(cwd);
    const dot = try directoryName(gpa, ".");
    defer gpa.free(dot);
    try testing.expectEqualStrings(std.fs.path.basename(cwd), dot);
    const up = try directoryName(gpa, "../");
    defer gpa.free(up);
    try testing.expectEqualStrings(std.fs.path.basename(std.fs.path.dirname(cwd).?), up);
    const src = try directoryName(gpa, "src/../src/./");
    defer gpa.free(src);
    try testing.expectEqualStrings("src", src);
}
