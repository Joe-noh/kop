// Which key does what: commands by name, keys written as "ctrl+shift+left",
// the defaults for macOS and for the others, and the settings' changes.
//
// A key is its modifiers and its name: the character a key types, as the
// keyboard's layout has it ("a", "/"), or the key's own name ("left",
// "return", "pageup", "f3"). "mod" stands for the command key: Cmd on
// macOS, Ctrl elsewhere. Moving with Shift held selects, so "shift+left"
// needs no binding of its own unless it should do something else.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _: u4 = 0,

    pub fn withoutShift(m: Mods) Mods {
        var n = m;
        n.shift = false;
        return n;
    }
};

// The commands, by the names the settings use.
pub const Command = enum {
    none,
    left,
    right,
    up,
    down,
    word_left,
    word_right,
    line_start,
    line_end,
    doc_start,
    doc_end,
    page_up,
    page_down,
    delete_left,
    delete_right,
    delete_word_left,
    delete_word_right,
    delete_to_line_start,
    delete_to_line_end,
    newline,
    indent,
    undo,
    redo,
    copy,
    cut,
    paste,
    select_all,
    find,
    find_next,
    find_previous,
    save,
    quit,
    toggle_tree,
    cancel,
    reload,
    search_project,
    toggle_changes,
    show_changes,

    // Commands that move the carets, which select when Shift is held.
    pub fn isMotion(c: Command) bool {
        return @intFromEnum(c) >= @intFromEnum(Command.left) and @intFromEnum(c) <= @intFromEnum(Command.page_down);
    }
};

// The bindings every platform has, "mod" being its command key.
const common_keys =
    \\left left
    \\right right
    \\up up
    \\down down
    \\home line_start
    \\end line_end
    \\pageup page_up
    \\pagedown page_down
    \\backspace delete_left
    \\delete delete_right
    \\return newline
    \\keypadenter newline
    \\tab indent
    \\escape cancel
    \\mod+z undo
    \\mod+shift+z redo
    \\mod+y redo
    \\mod+c copy
    \\mod+x cut
    \\mod+v paste
    \\mod+a select_all
    \\mod+f find
    \\mod+g find_next
    \\mod+shift+g find_previous
    \\mod+shift+f search_project
    \\mod+shift+d show_changes
    \\mod+s save
    \\mod+q quit
    \\mod+b toggle_tree
    \\mod+r reload
    \\mod+home doc_start
    \\mod+end doc_end
;

// macOS: Option moves by words, Cmd to the ends, and Ctrl as Emacs does.
const mac_keys =
    \\alt+left word_left
    \\alt+right word_right
    \\cmd+left line_start
    \\cmd+right line_end
    \\cmd+up doc_start
    \\cmd+down doc_end
    \\alt+backspace delete_word_left
    \\alt+delete delete_word_right
    \\cmd+backspace delete_to_line_start
    \\ctrl+a line_start
    \\ctrl+e line_end
    \\ctrl+n down
    \\ctrl+p up
    \\ctrl+k delete_to_line_end
    \\ctrl+shift+g toggle_changes
;

// Elsewhere Ctrl moves by words.
const other_keys =
    \\ctrl+left word_left
    \\ctrl+right word_right
    \\ctrl+backspace delete_word_left
    \\ctrl+delete delete_word_right
    \\ctrl+alt+g toggle_changes
;

pub const KeyName = struct {
    buf: [24]u8 = undefined,
    len: usize = 0,

    pub fn slice(k: *const KeyName) []const u8 {
        return k.buf[0..k.len];
    }

    // A key's name as bindings compare it: lower case, without spaces, and
    // the usual other names for a few keys made the one SDL gives.
    pub fn of(name: []const u8) KeyName {
        var k = KeyName{};
        for (name) |c| {
            if (c == ' ' or k.len == k.buf.len) continue;
            k.buf[k.len] = std.ascii.toLower(c);
            k.len += 1;
        }
        const aliases = [_][2][]const u8{
            .{ "enter", "return" },  .{ "esc", "escape" },   .{ "del", "delete" }, .{ "pgup", "pageup" },
            .{ "pgdn", "pagedown" }, .{ "bs", "backspace" }, .{ "space", " " },    .{ "plus", "+" },
        };
        for (aliases) |a| {
            if (std.mem.eql(u8, k.slice(), a[0])) {
                @memcpy(k.buf[0..a[1].len], a[1]);
                k.len = a[1].len;
            }
        }
        return k;
    }
};

pub const Binding = struct { mods: Mods, key: KeyName, cmd: Command };

pub const Key = struct { mods: Mods, key: KeyName };

// Reads a key written as "ctrl+shift+a"; null if it is not one.
pub fn parseKey(spec: []const u8, mac: bool) ?Key {
    var mods = Mods{};
    var parts = std.mem.splitScalar(u8, spec, '+');
    var last = parts.next() orelse return null;
    while (parts.next()) |p| {
        const m = KeyName.of(last);
        const name = m.slice();
        if (std.mem.eql(u8, name, "shift")) {
            mods.shift = true;
        } else if (std.mem.eql(u8, name, "ctrl") or std.mem.eql(u8, name, "control")) {
            mods.ctrl = true;
        } else if (std.mem.eql(u8, name, "alt") or std.mem.eql(u8, name, "option") or std.mem.eql(u8, name, "opt")) {
            mods.alt = true;
        } else if (std.mem.eql(u8, name, "cmd") or std.mem.eql(u8, name, "command") or std.mem.eql(u8, name, "super") or
            std.mem.eql(u8, name, "win") or std.mem.eql(u8, name, "meta"))
        {
            mods.cmd = true;
        } else if (std.mem.eql(u8, name, "mod")) {
            if (mac) mods.cmd = true else mods.ctrl = true;
        } else return null;
        last = p;
    }
    if (last.len == 0) return null;
    const key = KeyName.of(last);
    if (key.len == 0) return null;
    return .{ .mods = mods, .key = key };
}

pub const Keymap = struct {
    gpa: Allocator,
    bindings: std.ArrayList(Binding) = .empty,

    pub fn init(gpa: Allocator) Keymap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(km: *Keymap) void {
        km.bindings.deinit(km.gpa);
    }

    // Binds `key` to `cmd`, in place of what it did; .none unbinds it.
    pub fn bind(km: *Keymap, key: Key, cmd: Command) !void {
        var i: usize = 0;
        while (i < km.bindings.items.len) {
            const b = km.bindings.items[i];
            if (b.mods == key.mods and std.mem.eql(u8, b.key.slice(), key.key.slice())) {
                _ = km.bindings.orderedRemove(i);
            } else i += 1;
        }
        if (cmd != .none) try km.bindings.append(km.gpa, .{ .mods = key.mods, .key = key.key, .cmd = cmd });
    }

    // Applies "key command" lines; what cannot be read goes into `problems`.
    pub fn bindLines(km: *Keymap, lines: []const u8, sep: u8, mac: bool, problems: *std.ArrayList(u8)) !void {
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const at = std.mem.indexOfScalar(u8, line, sep);
            const spec = if (at) |k| line[0..k] else line;
            const name = if (at) |k| line[k + 1 ..] else "";
            const cmd = std.meta.stringToEnum(Command, name);
            if (parseKey(spec, mac)) |key| {
                if (cmd) |c| try km.bind(key, c) else try problems.print(km.gpa, "no such command: {s}; ", .{name});
            } else try problems.print(km.gpa, "not a key: {s}; ", .{spec});
        }
    }

    // The defaults for the platform, then the settings' bindings over them
    // ("key\tcommand" lines, in the order the files gave them).
    pub fn build(km: *Keymap, mac: bool, settings: []const u8, problems: *std.ArrayList(u8)) !void {
        km.bindings.clearRetainingCapacity();
        try km.bindLines(common_keys, ' ', mac, problems);
        try km.bindLines(if (mac) mac_keys else other_keys, ' ', mac, problems);
        try km.bindLines(settings, '\t', mac, problems);
    }

    pub const Found = struct { cmd: Command, select: bool };

    // What a key does: the command, and whether it moves selecting, which a
    // motion's key does with Shift added when Shift has no binding of its own.
    pub fn commandFor(km: *const Keymap, mods: Mods, key: []const u8) Found {
        for (km.bindings.items) |b| {
            if (b.mods == mods and std.mem.eql(u8, b.key.slice(), key)) return .{ .cmd = b.cmd, .select = false };
        }
        if (mods.shift) {
            const m = mods.withoutShift();
            for (km.bindings.items) |b| {
                if (b.mods == m and std.mem.eql(u8, b.key.slice(), key) and b.cmd.isMotion()) return .{ .cmd = b.cmd, .select = true };
            }
        }
        return .{ .cmd = .none, .select = false };
    }
};

test "keymap" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var km = Keymap.init(gpa);
    defer km.deinit();
    var problems: std.ArrayList(u8) = .empty;
    defer problems.deinit(gpa);
    try km.build(true, "", &problems);
    try testing.expectEqualStrings("", problems.items);
    const ctrl = Mods{ .ctrl = true };
    const cmd = Mods{ .cmd = true };
    try testing.expectEqual(Keymap.Found{ .cmd = .line_start, .select = false }, km.commandFor(ctrl, "a"));
    try testing.expectEqual(Keymap.Found{ .cmd = .line_end, .select = true }, km.commandFor(.{ .ctrl = true, .shift = true }, "e"));
    try testing.expectEqual(Command.save, km.commandFor(cmd, "s").cmd);
    try testing.expectEqual(Keymap.Found{ .cmd = .redo, .select = false }, km.commandFor(.{ .cmd = true, .shift = true }, "z"));
    try testing.expectEqual(Keymap.Found{ .cmd = .word_left, .select = true }, km.commandFor(.{ .alt = true, .shift = true }, "left"));
    try testing.expectEqual(Command.down, km.commandFor(ctrl, "n").cmd);
    try testing.expectEqual(Command.up, km.commandFor(ctrl, "p").cmd);
    try testing.expectEqual(Command.delete_to_line_end, km.commandFor(ctrl, "k").cmd);
    try testing.expectEqual(Command.reload, km.commandFor(cmd, "r").cmd);
    try testing.expectEqual(Command.search_project, km.commandFor(.{ .cmd = true, .shift = true }, "f").cmd);
    try km.build(false, "", &problems);
    try testing.expectEqual(Command.select_all, km.commandFor(ctrl, "a").cmd);
    try testing.expectEqual(Command.word_left, km.commandFor(ctrl, "left").cmd);

    // The settings' changes, read from JSON as the files give them.
    var st = @import("settings.zig").Settings.init(gpa);
    defer st.deinit();
    try testing.expect(try st.apply("{ \"keybindings\": { \"ctrl+a\": \"line_start\", \"Ctrl+K\": \"delete_to_line_end\", \"mod+b\": null } }", &problems));
    try testing.expect(try st.apply("{ \"keybindings\": { \"ctrl+k\": \"cut\", \"hyper+x\": \"save\", \"ctrl+j\": \"jump\" } }", &problems));
    problems.clearRetainingCapacity();
    try km.build(false, st.keybindings.items, &problems);
    try testing.expectEqual(Command.line_start, km.commandFor(ctrl, "a").cmd);
    try testing.expectEqual(Command.cut, km.commandFor(ctrl, "k").cmd);
    try testing.expectEqual(Command.none, km.commandFor(ctrl, "b").cmd);
    try testing.expect(std.mem.indexOf(u8, problems.items, "hyper+x") != null);
    try testing.expect(std.mem.indexOf(u8, problems.items, "jump") != null);
    try testing.expectEqualStrings("pageup", KeyName.of("Page Up").slice());
    try testing.expectEqualStrings("return", KeyName.of("Enter").slice());
}
