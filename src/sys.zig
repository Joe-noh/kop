// What the program asks of the system: files, directories, the
// environment, the clock and child processes. Zig's standard library does
// all of these through an Io, which main is handed; this keeps it, so the
// modules below can ask without passing it about.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

var main_io: ?Io = null;

pub fn setIo(io_: Io) void {
    main_io = io_;
}

pub fn io() Io {
    if (builtin.is_test) return std.testing.io;
    return main_io.?;
}

pub fn cwd() Io.Dir {
    return Io.Dir.cwd();
}

pub fn readFile(gpa: Allocator, path: []const u8, limit: usize) ![]u8 {
    return cwd().readFileAlloc(io(), path, gpa, .limited(limit));
}

pub fn stat(path: []const u8) !Io.File.Stat {
    return cwd().statFile(io(), path, .{});
}

pub fn isDir(path: []const u8) bool {
    const st = stat(path) catch return false;
    return st.kind == .directory;
}

pub fn exists(path: []const u8) bool {
    cwd().access(io(), path, .{}) catch return false;
    return true;
}

pub fn realPath(gpa: Allocator, path: []const u8) ![]u8 {
    const z = try cwd().realPathFileAlloc(io(), path, gpa);
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}

pub fn makePath(path: []const u8) !void {
    try cwd().createDirPath(io(), path);
}

// Writes `data` to `path` through a temporary file beside it, so a failed
// write leaves the file as it was.
pub fn writeAtomic(path: []const u8, data: []const u8) !void {
    var af = try cwd().createFileAtomic(io(), path, .{ .replace = true });
    defer af.deinit(io());
    try af.file.writeStreamingAll(io(), data);
    try af.replace(io());
}

pub fn openDir(path: []const u8) !Io.Dir {
    return cwd().openDir(io(), path, .{ .iterate = true });
}

pub fn closeDir(d: Io.Dir) void {
    d.close(io());
}

// The entries of an open directory, one after another.
pub const Entries = struct {
    it: Io.Dir.Iterator,

    pub fn of(d: Io.Dir) Entries {
        return .{ .it = d.iterate() };
    }

    pub fn next(e: *Entries) ?Io.Dir.Entry {
        return e.it.next(io()) catch null;
    }
};

pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}

// Seconds on a clock that only goes forward.
pub fn monotonic() f64 {
    const t = Io.Timestamp.now(io(), .awake);
    return @as(f64, @floatFromInt(t.toNanoseconds())) / 1e9;
}

// Seconds since 1970.
pub fn unixTime() i64 {
    return Io.Timestamp.now(io(), .real).toSeconds();
}

pub const RunResult = struct { ok: bool, stdout: []u8, stderr: []u8 };

// Runs `argv`, waiting for it; what it wrote, and whether it exited with 0.
pub fn run(gpa: Allocator, argv: []const []const u8, max_output: usize) !RunResult {
    const r = try std.process.run(gpa, io(), .{ .argv = argv, .stdout_limit = .limited(max_output), .stderr_limit = .limited(1 << 20) });
    return .{ .ok = r.term == .exited and r.term.exited == 0, .stdout = r.stdout, .stderr = r.stderr };
}
