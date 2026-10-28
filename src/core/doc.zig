// What a file looks like on disk: its byte-order mark, line breaks,
// indentation and encoding, found when it is opened and kept when it is saved.

const std = @import("std");
const Text = @import("text.zig").Text;
const utf8 = @import("utf8.zig");

pub const FileInfo = struct {
    bom: bool = false, // starts with the UTF-8 byte-order mark
    crlf: bool = false, // its first line break is "\r\n"
    utf8: bool = true, // its start reads as UTF-8; if not, it opens read-only
    tabs: bool = false, // more lines are indented with tabs than with spaces
};

const bom = "\xEF\xBB\xBF";

fn hasBom(data: []const u8) bool {
    return std.mem.startsWith(u8, data, bom);
}

// The bytes after the byte-order mark, if any.
pub fn body(data: []const u8) []const u8 {
    return if (hasBom(data)) data[3..] else data;
}

pub fn detect(data: []const u8) FileInfo {
    const b = body(data);
    var info = FileInfo{ .bom = hasBom(data), .utf8 = utf8.looksUtf8(b, 1 << 20) };
    if (std.mem.indexOfScalar(u8, b, '\n')) |nl| info.crlf = nl > 0 and b[nl - 1] == '\r';
    // Indentation: count the first thousand lines that start with each.
    var tab_lines: usize = 0;
    var space_lines: usize = 0;
    var lines: usize = 0;
    var at_start = true;
    for (b[0..@min(b.len, 1 << 20)]) |c| {
        if (at_start) {
            if (c == '\t') tab_lines += 1 else if (c == ' ') space_lines += 1;
            at_start = false;
        }
        if (c == '\n') {
            at_start = true;
            lines += 1;
            if (lines == 1000) break;
        }
    }
    info.tabs = tab_lines > space_lines;
    return info;
}

// Writes the text to `path` through a temporary file beside it, so a failed
// save leaves the file as it was.
pub fn save(t: *const Text, info: FileInfo, path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.gpa);
    if (info.bom) try out.appendSlice(t.gpa, bom);
    try t.all(&out);
    var buf: [4096]u8 = undefined;
    var file = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &buf });
    defer file.deinit();
    try file.file_writer.interface.writeAll(out.items);
    try file.finish();
}

test "detect" {
    const testing = std.testing;
    const info = detect("\xEF\xBB\xBFa\r\n\tb\r\n\tc\r\n d");
    try testing.expect(info.bom and info.crlf and info.utf8 and info.tabs);
    try testing.expectEqualStrings("ab", body("\xEF\xBB\xBFab"));
    try testing.expect(!detect("\x93\xFA\x96\x7B\x8C\xEA\n").utf8);
}
