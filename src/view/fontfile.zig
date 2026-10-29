// Font files: finding them by name among the system's fonts. FreeType
// reads them, collections (.ttc) included.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const utf8 = @import("../core/utf8.zig");

// The fonts used when the settings name none, first choice first; the
// ones a system does not have are skipped.
const mac_fonts = "Menlo\nヒラギノ角ゴシック W3";
const linux_fonts = "DejaVuSansMono\nNotoSansMonoCJKjp-Regular\nNotoSansCJK-Regular\nNotoSansCJKjp-Regular\nipag";
const windows_fonts = "consola\nBIZ-UDGothicR\nmsgothic\nYuGothR";

pub fn defaultFonts() []const u8 {
    return switch (builtin.os.tag) {
        .macos => mac_fonts,
        .windows => windows_fonts,
        else => linux_fonts,
    };
}

// Where the system keeps fonts, as lines.
fn fontDirs(gpa: Allocator, out: *std.ArrayList(u8)) !void {
    const home = std.process.getEnvVarOwned(gpa, "HOME") catch null;
    defer if (home) |h| gpa.free(h);
    switch (builtin.os.tag) {
        .macos => {
            try out.appendSlice(gpa, "/System/Library/Fonts\n/System/Library/Fonts/Supplemental\n/Library/Fonts\n");
            if (home) |h| try out.print(gpa, "{s}/Library/Fonts\n", .{h});
        },
        .windows => {
            if (std.process.getEnvVarOwned(gpa, "WINDIR") catch null) |w| {
                defer gpa.free(w);
                try out.print(gpa, "{s}/Fonts\n", .{w});
            }
            if (std.process.getEnvVarOwned(gpa, "LOCALAPPDATA") catch null) |l| {
                defer gpa.free(l);
                try out.print(gpa, "{s}/Microsoft/Windows/Fonts\n", .{l});
            }
        },
        else => {
            try out.appendSlice(gpa, "/usr/share/fonts\n/usr/local/share/fonts\n");
            if (home) |h| try out.print(gpa, "{s}/.local/share/fonts\n{s}/.fonts\n", .{ h, h });
        },
    }
}

fn hasFontExt(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".ttf") or std.ascii.eqlIgnoreCase(ext, ".otf") or std.ascii.eqlIgnoreCase(ext, ".ttc");
}

// Kana that take a voiced mark (゛) as the next codepoint, and those that
// also take the semi-voiced one (゜); katakana are these plus 0x60.
const voiced = [_]u32{ 0x304B, 0x304D, 0x304F, 0x3051, 0x3053, 0x3055, 0x3057, 0x3059, 0x305B, 0x305D, 0x305F, 0x3061, 0x3064, 0x3066, 0x3068, 0x306F, 0x3072, 0x3075, 0x3078, 0x307B };

// `s` with each kana and a combining voiced or semi-voiced mark after it
// made one character, as macOS file names have them apart (NFD) and
// settings, typed, have them together (NFC).
pub fn composeKana(gpa: Allocator, s: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < s.len) {
        const d = utf8.decode(s, i);
        var cp = d.cp;
        var n = d.len;
        if (i + n < s.len) {
            const mark = utf8.decode(s, i + n);
            if (mark.cp == 0x3099 or mark.cp == 0x309A) {
                const base = if (cp >= 0x30A0) cp - 0x60 else cp;
                if (std.mem.indexOfScalar(u32, &voiced, base)) |k| {
                    if (mark.cp == 0x3099 or k >= 15) {
                        cp += if (mark.cp == 0x3099) 1 else 2;
                        n += mark.len;
                    }
                } else if (mark.cp == 0x3099 and base == 0x3046) {
                    cp = if (cp >= 0x30A0) 0x30F4 else 0x3094;
                    n += mark.len;
                }
            }
        }
        var buf: [4]u8 = undefined;
        try out.appendSlice(gpa, utf8.encode(cp, &buf));
        i += n;
    }
}

// Looks in the directories `dirs` (one per line) and those below them, up
// to `depth` levels down, for the file `name` with a font extension (or
// `name` itself, when it has one). The path found goes into `out`.
fn findInDirs(gpa: Allocator, dirs: []const u8, name: []const u8, depth: usize, out: *std.ArrayList(u8)) !bool {
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    try composeKana(gpa, name, &want);
    const with_ext = hasFontExt(want.items);
    var entry: std.ArrayList(u8) = .empty;
    defer entry.deinit(gpa);
    var level: std.ArrayList(u8) = .empty;
    defer level.deinit(gpa);
    try level.appendSlice(gpa, dirs);
    var below: std.ArrayList(u8) = .empty;
    defer below.deinit(gpa);
    for (0..depth + 1) |d| {
        below.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, level.items, '\n');
        while (lines.next()) |dir_path| {
            if (dir_path.len == 0) continue;
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |e| {
                entry.clearRetainingCapacity();
                try composeKana(gpa, e.name, &entry);
                const matched = if (with_ext)
                    std.mem.eql(u8, entry.items, want.items)
                else
                    entry.items.len == want.items.len + 4 and std.mem.startsWith(u8, entry.items, want.items) and hasFontExt(entry.items);
                if (matched) {
                    try out.print(gpa, "{s}/{s}", .{ dir_path, e.name });
                    return true;
                }
                if (e.kind == .directory and e.name[0] != '.' and d < depth) try below.print(gpa, "{s}/{s}\n", .{ dir_path, e.name });
            }
        }
        std.mem.swap(std.ArrayList(u8), &level, &below);
    }
    return false;
}

// The file for a font named in the settings: a path (with "~/" for the
// home directory), or a file name, with or without its extension, among
// the system's fonts.
pub fn resolve(gpa: Allocator, name: []const u8, out: *std.ArrayList(u8)) !bool {
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        if (std.mem.startsWith(u8, name, "~/")) {
            const home = std.process.getEnvVarOwned(gpa, "HOME") catch return false;
            defer gpa.free(home);
            try out.print(gpa, "{s}{s}", .{ home, name[1..] });
        } else try out.appendSlice(gpa, name);
        std.fs.cwd().access(out.items, .{}) catch return false;
        return true;
    }
    var dirs: std.ArrayList(u8) = .empty;
    defer dirs.deinit(gpa);
    try fontDirs(gpa, &dirs);
    return findInDirs(gpa, dirs.items, name, 3, out);
}

test "font files" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var nfc: std.ArrayList(u8) = .empty;
    defer nfc.deinit(gpa);
    try composeKana(gpa, "\xE3\x82\xAD\xE3\x82\x99\xE3\x83\x8F\xE3\x82\x9A\xE3\x81\xAF", &nfc); // キ゛ハ゜は, decomposed
    try testing.expectEqualStrings("ギパは", nfc.items);
    if (builtin.os.tag != .macos) return;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    try testing.expect(try resolve(gpa, "Menlo", &path));
    try testing.expectEqualStrings("/System/Library/Fonts/Menlo.ttc", path.items);
    path.clearRetainingCapacity();
    try testing.expect(try resolve(gpa, "ヒラギノ角ゴシック W3", &path));
    path.clearRetainingCapacity();
    try testing.expect(!try resolve(gpa, "NoSuchFont-Regular", &path));
}
