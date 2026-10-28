// Settings, from JSON files read one over another: the defaults, then
// ~/.kop/settings.json, then the project's .kop/settings.json. A file
// sets only what it names.
//
//   {
//     "theme": "spacegray",
//     "editor": { "fontSize": 14, "fontFamily": ["Menlo", "ヒラギノ角ゴシック W3"] },
//     "ui": { "fontSize": 13 },
//     "keybindings": { "ctrl+k": "delete_to_line_end", "mod+b": "none" }
//   }
//
// A font is a file name among the system's fonts, with or without its
// extension, or a path; each character is drawn with the first font that
// has it. Without a fontFamily the text uses the system's usual fonts and
// the ui the text's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const min_font_size: f32 = 6;
pub const max_font_size: f32 = 24;

pub const Settings = struct {
    gpa: Allocator,
    editor_font_size: f32 = 13, // in points
    ui_font_size: f32 = 12,
    editor_fonts: std.ArrayList(u8) = .empty, // font names, one per line; empty for the defaults
    ui_fonts: std.ArrayList(u8) = .empty,
    theme: std.ArrayList(u8) = .empty, // a theme's name; empty for the default
    keybindings: std.ArrayList(u8) = .empty, // "key\tcommand" lines, the later files' last

    pub fn init(gpa: Allocator) Settings {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Settings) void {
        s.editor_fonts.deinit(s.gpa);
        s.ui_fonts.deinit(s.gpa);
        s.theme.deinit(s.gpa);
        s.keybindings.deinit(s.gpa);
    }

    // Reads what `src` sets over `s`. Problems, such as a key it does not
    // know or a value out of range, go into `problems`; false if the text is
    // not JSON, which leaves `s` as it was and says only that.
    pub fn apply(s: *Settings, src: []const u8, problems: *std.ArrayList(u8)) !bool {
        var scanner = json.Scanner.initCompleteInput(s.gpa, src);
        defer scanner.deinit();
        var diag = json.Diagnostics{};
        scanner.enableDiagnostics(&diag);
        const parsed = json.parseFromTokenSource(json.Value, s.gpa, &scanner, .{}) catch |e| {
            if (e == error.OutOfMemory) return e;
            try problems.print(s.gpa, "not JSON at line {d}, column {d}; ", .{ diag.getLine(), diag.getColumn() });
            return false;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            try problems.appendSlice(s.gpa, "not a JSON object; ");
            return true;
        }
        var it = parsed.value.object.iterator();
        while (it.next()) |section| {
            const name = section.key_ptr.*;
            const v = section.value_ptr.*;
            if (std.mem.eql(u8, name, "editor") or std.mem.eql(u8, name, "ui")) {
                const editor = name[0] == 'e';
                if (v != .object) {
                    try problems.print(s.gpa, "{s} must be an object; ", .{name});
                    continue;
                }
                var keys = v.object.iterator();
                while (keys.next()) |kv| {
                    const key = kv.key_ptr.*;
                    if (std.mem.eql(u8, key, "fontSize")) {
                        try s.readFontSize(kv.value_ptr.*, name, if (editor) &s.editor_font_size else &s.ui_font_size, problems);
                    } else if (std.mem.eql(u8, key, "fontFamily")) {
                        try s.readFontFamily(kv.value_ptr.*, name, if (editor) &s.editor_fonts else &s.ui_fonts, problems);
                    } else {
                        try problems.print(s.gpa, "unknown setting: {s}.{s}; ", .{ name, key });
                    }
                }
            } else if (std.mem.eql(u8, name, "keybindings")) {
                try s.readKeybindings(v, problems);
            } else if (std.mem.eql(u8, name, "theme")) {
                if (v != .string) {
                    try problems.appendSlice(s.gpa, "theme must be a name; ");
                    continue;
                }
                s.theme.clearRetainingCapacity();
                try s.theme.appendSlice(s.gpa, v.string);
            } else {
                try problems.print(s.gpa, "unknown setting: {s}; ", .{name});
            }
        }
        return true;
    }

    fn readFontSize(s: *Settings, v: json.Value, section: []const u8, at: *f32, problems: *std.ArrayList(u8)) !void {
        const n: f32 = switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => {
                try problems.print(s.gpa, "{s}.fontSize must be a number; ", .{section});
                return;
            },
        };
        if (n < min_font_size or n > max_font_size) {
            try problems.print(s.gpa, "{s}.fontSize must be from {d} to {d}; ", .{ section, min_font_size, max_font_size });
        }
        at.* = std.math.clamp(n, min_font_size, max_font_size);
    }

    // "fontFamily": one name, or a list of them.
    fn readFontFamily(s: *Settings, v: json.Value, section: []const u8, at: *std.ArrayList(u8), problems: *std.ArrayList(u8)) !void {
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(s.gpa);
        switch (v) {
            .string => |name| try names.print(s.gpa, "{s}\n", .{name}),
            .array => |list| for (list.items) |item| {
                if (item != .string) {
                    try problems.print(s.gpa, "{s}.fontFamily must list names; ", .{section});
                    return;
                }
                try names.print(s.gpa, "{s}\n", .{item.string});
            },
            else => {
                try problems.print(s.gpa, "{s}.fontFamily must be a name or a list of them; ", .{section});
                return;
            },
        }
        at.clearRetainingCapacity();
        try at.appendSlice(s.gpa, names.items);
    }

    // "keybindings": { "key": "command", ... }, a null command unbinding the key.
    fn readKeybindings(s: *Settings, v: json.Value, problems: *std.ArrayList(u8)) !void {
        if (v != .object) {
            try problems.appendSlice(s.gpa, "keybindings must be an object; ");
            return;
        }
        var it = v.object.iterator();
        while (it.next()) |kv| {
            const cmd = switch (kv.value_ptr.*) {
                .null => "none",
                .string => |c| c,
                else => {
                    try problems.print(s.gpa, "the binding of {s} must be a command's name; ", .{kv.key_ptr.*});
                    continue;
                },
            };
            try s.keybindings.print(s.gpa, "{s}\t{s}\n", .{ kv.key_ptr.*, cmd });
        }
    }

    // Reads the file at `path` over `s`, if there is one; what went wrong goes
    // into `problems`, after the file's name.
    pub fn loadFile(s: *Settings, path: []const u8, problems: *std.ArrayList(u8)) !void {
        const src = std.fs.cwd().readFileAlloc(s.gpa, path, 1 << 20) catch |e| switch (e) {
            error.FileNotFound => return,
            error.OutOfMemory => return e,
            else => {
                try problems.print(s.gpa, "{s}: cannot read; ", .{path});
                return;
            },
        };
        defer s.gpa.free(src);
        var found: std.ArrayList(u8) = .empty;
        defer found.deinit(s.gpa);
        _ = try s.apply(src, &found);
        if (found.items.len > 0) try problems.print(s.gpa, "{s}: {s} ", .{ path, found.items });
    }
};

// The directory a path's project settings belong to: the path itself for a
// directory, else the directory the file is in.
pub fn projectDir(path: []const u8, is_dir: bool) []const u8 {
    if (path.len == 0) return "";
    if (is_dir) return path;
    return std.fs.path.dirname(path) orelse ".";
}

// The defaults, the user's settings, then the project's.
pub fn load(gpa: Allocator, path: []const u8, problems: *std.ArrayList(u8)) !Settings {
    var s = Settings.init(gpa);
    errdefer s.deinit();
    if (std.posix.getenv("HOME")) |home| {
        const p = try std.fs.path.join(gpa, &.{ home, ".kop/settings.json" });
        defer gpa.free(p);
        try s.loadFile(p, problems);
    }
    const is_dir = if (std.fs.cwd().statFile(path)) |st| st.kind == .directory else |_| false;
    const dir = projectDir(path, is_dir);
    if (dir.len > 0) {
        const p = try std.fs.path.join(gpa, &.{ dir, ".kop/settings.json" });
        defer gpa.free(p);
        try s.loadFile(p, problems);
    }
    return s;
}

test "settings" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var s = Settings.init(gpa);
    defer s.deinit();
    var problems: std.ArrayList(u8) = .empty;
    defer problems.deinit(gpa);
    try testing.expect(try s.apply("{ \"editor\": { \"fontSize\": 18 } }", &problems) and problems.items.len == 0);
    try testing.expect(s.editor_font_size == 18 and s.ui_font_size == 12);
    try testing.expect(try s.apply("{ \"ui\": { \"fontSize\": 11.5 } }", &problems));
    try testing.expect(s.editor_font_size == 18 and s.ui_font_size == 11.5);
    try testing.expect(try s.apply("{ \"ui\": { \"fontSize\": 100, \"theme\": \"x\" }, \"other\": 1 }", &problems));
    try testing.expectEqual(max_font_size, s.ui_font_size);
    try testing.expect(std.mem.indexOf(u8, problems.items, "ui.fontSize") != null);
    try testing.expect(std.mem.indexOf(u8, problems.items, "ui.theme") != null);
    try testing.expect(std.mem.indexOf(u8, problems.items, "other") != null);
    problems.clearRetainingCapacity();
    try testing.expect(!try s.apply("{ \"editor\": { \"fontSize\": 9 ", &problems) and problems.items.len > 0);
    try testing.expectEqual(@as(f32, 18), s.editor_font_size);

    var t = Settings.init(gpa);
    defer t.deinit();
    try testing.expect(try t.apply("{ \"editor\": { \"fontFamily\": [\"Menlo\", \"/x/y.ttf\"] }, \"ui\": { \"fontFamily\": \"Osaka\" } }", &problems));
    try testing.expectEqualStrings("Menlo\n/x/y.ttf\n", t.editor_fonts.items);
    try testing.expectEqualStrings("Osaka\n", t.ui_fonts.items);
    try testing.expect(try t.apply("{ \"theme\": \"spacegray\" }", &problems));
    try testing.expectEqualStrings("spacegray", t.theme.items);
    try testing.expectEqualStrings("a/b", projectDir("a/b/c.txt", false));
}
