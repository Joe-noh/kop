// The frame's keys, typing and mouse, turned into commands. Which key runs
// which command is core/keymap.zig's.
//
// SDL's events become the events below first, so a script can play input
// back through the same path (view/script.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const edit = @import("../core/edit.zig");
const Editor = edit.Editor;
const Sel = @import("../core/select.zig").Sel;
const motion = @import("../core/motion.zig");
const doc = @import("../core/doc.zig");
const keymap = @import("../core/keymap.zig");
const Command = keymap.Command;
const Mods = keymap.Mods;
const KeyName = keymap.KeyName;
const state = @import("state.zig");
const View = state.View;
const say = state.say;
const render = @import("render.zig");
const Tree = @import("tree.zig").Tree;
const platform = @import("platform.zig");

const Bytes = struct { at: usize, len: usize };

pub const Event = union(enum) {
    text: Bytes, // typed text, in Input.bytes
    editing: Bytes, // what the input method is composing; empty when it is done
    key: struct { mods: Mods, key: KeyName, down: bool },
    button: struct { x: f32, y: f32, down: bool, clicks: u8, left: bool },
    motion: struct { x: f32, y: f32 },
    wheel: struct { x: f32, y: f32 },
    focus, // the window came to the front
    quit,
};

// The frame's events, and what the mouse and the modifiers are doing.
pub const Input = struct {
    gpa: Allocator,
    events: std.ArrayList(Event) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    density: f32 = 1,
    mouse_x: f32 = -1, // in pixels
    mouse_y: f32 = -1,
    left_down: bool = false,
    mods: Mods = .{},

    pub fn deinit(in: *Input) void {
        in.events.deinit(in.gpa);
        in.bytes.deinit(in.gpa);
    }

    pub fn str(in: *const Input, b: Bytes) []const u8 {
        return in.bytes.items[b.at .. b.at + b.len];
    }

    fn keep(in: *Input, s: []const u8) !Bytes {
        const at = in.bytes.items.len;
        try in.bytes.appendSlice(in.gpa, s);
        return .{ .at = at, .len = s.len };
    }

    pub fn clear(in: *Input) void {
        in.events.clearRetainingCapacity();
        in.bytes.clearRetainingCapacity();
    }

    pub fn push(in: *Input, e: Event) !void {
        switch (e) {
            .key => |k| in.mods = k.mods,
            .button => |b| {
                if (b.left) in.left_down = b.down;
                in.mouse_x = b.x;
                in.mouse_y = b.y;
            },
            .motion => |m| {
                in.mouse_x = m.x;
                in.mouse_y = m.y;
            },
            else => {},
        }
        try in.events.append(in.gpa, e);
    }

    pub fn pushText(in: *Input, s: []const u8) !void {
        try in.push(.{ .text = try in.keep(s) });
    }

    pub fn pushEditing(in: *Input, s: []const u8) !void {
        try in.push(.{ .editing = try in.keep(s) });
    }

    fn modsOf(m: c.SDL_Keymod) Mods {
        return .{
            .shift = (m & c.SDL_KMOD_SHIFT) != 0,
            .ctrl = (m & c.SDL_KMOD_CTRL) != 0,
            .alt = (m & c.SDL_KMOD_ALT) != 0,
            .cmd = (m & c.SDL_KMOD_GUI) != 0,
        };
    }

    // The key's name as the keymap has it: the character it types, else its own.
    fn keyName(key: c.SDL_Keycode) KeyName {
        if (key > 32 and key < 127) {
            var k = KeyName{ .len = 1 };
            k.buf[0] = std.ascii.toLower(@intCast(key));
            return k;
        }
        if (key == 32) return KeyName.of("space");
        return KeyName.of(std.mem.span(c.SDL_GetKeyName(key)));
    }

    // Takes in what SDL has; false once the window is closed.
    pub fn poll(in: *Input) !void {
        var e: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&e)) try in.take(&e);
    }

    pub fn take(in: *Input, e: *const c.SDL_Event) !void {
        const d = in.density;
        switch (e.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => try in.push(.quit),
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => try in.push(.focus),
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => try in.push(.{ .key = .{ .mods = modsOf(e.key.mod), .key = keyName(e.key.key), .down = e.key.down } }),
            c.SDL_EVENT_TEXT_INPUT => try in.pushText(std.mem.span(e.text.text)),
            c.SDL_EVENT_TEXT_EDITING => try in.pushEditing(if (e.edit.text) |t| std.mem.span(t) else ""),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => try in.push(.{ .button = .{
                .x = e.button.x * d,
                .y = e.button.y * d,
                .down = e.button.down,
                .clicks = e.button.clicks,
                .left = e.button.button == c.SDL_BUTTON_LEFT,
            } }),
            c.SDL_EVENT_MOUSE_MOTION => try in.push(.{ .motion = .{ .x = e.motion.x * d, .y = e.motion.y * d } }),
            // As the system's setting has it: with natural scrolling, the
            // text follows the fingers. SDL's values already say so.
            c.SDL_EVENT_MOUSE_WHEEL => try in.push(.{ .wheel = .{ .x = e.wheel.x, .y = e.wheel.y } }),
            else => {},
        }
    }
};

// What a frame of input needs: the document, its view, the tree, and how
// keys map to commands.
pub const Context = struct {
    gpa: Allocator,
    ed: *Editor,
    v: *View,
    tr: *Tree,
    km: *const keymap.Keymap,
    mac: bool,
};

// The caret moved or the text changed: show it, and show the caret steadily.
fn touched(v: *View) void {
    v.follow = true;
    v.blink_at = state.clock();
}

fn writable(v: *View) bool {
    if (v.readonly) say(v, "Opened read-only: not UTF-8");
    return !v.readonly;
}

pub fn saveDoc(cx: Context) !void {
    const v = cx.v;
    if (v.path.len == 0) {
        v.bar = .save_as;
        v.query.set("");
        return;
    }
    if (v.readonly) return say(v, "Read-only");
    // Something else changed the file since it was read: say so once, and
    // overwrite it at the next save.
    const now = state.DiskStamp.of(v.path.slice());
    if (now.exists and !now.same(v.disk) and !v.overwrite_ok) {
        v.overwrite_ok = true;
        say(v, if (v.disk.exists) "Changed on disk since opened: save again to overwrite it" else "The file exists: save again to overwrite it");
        return;
    }
    doc.save(&cx.ed.t, v.info, v.path.slice()) catch {
        var buf: [240]u8 = undefined;
        say(v, std.fmt.bufPrint(&buf, "Could not save: {s}", .{v.path.slice()}) catch "Could not save");
        return;
    };
    cx.ed.h.markSaved();
    v.saves += 1;
    v.overwrite_ok = false;
    v.disk = state.DiskStamp.of(v.path.slice());
    v.disk_told = v.disk;
    say(v, "Saved");
}

fn openFind(cx: Context) !void {
    const v = cx.v;
    v.bar = .find;
    const p = cx.ed.primary();
    if (!p.isEmpty() and p.hi() - p.lo() <= 200) {
        var sel: std.ArrayList(u8) = .empty;
        defer sel.deinit(cx.gpa);
        try cx.ed.t.read(p.lo(), p.hi(), &sel);
        if (std.mem.indexOfScalar(u8, sel.items, '\n') == null) v.query.set(sel.items);
    }
}

fn findInDoc(cx: Context, forward: bool) !void {
    if (cx.v.query.len == 0) return;
    if (try cx.ed.findNext(cx.v.query.slice(), forward)) touched(cx.v) else say(cx.v, "Not found");
}

fn appendField(v: *View, s: []const u8) void {
    const end = std.mem.indexOfAny(u8, s, "\r\n") orelse s.len;
    v.query.append(s[0..end]);
}

// A command for the field at the bottom; false for those it leaves to the
// document. Enter finds the next match, or with Shift the previous one.
fn barCommand(cx: Context, cmd: Command, shift: bool) !bool {
    const v = cx.v;
    switch (cmd) {
        .cancel => v.bar = .none,
        .delete_left => v.query.pop(),
        .paste => {
            var clip: std.ArrayList(u8) = .empty;
            defer clip.deinit(cx.gpa);
            try platform.clipboard(cx.gpa, &clip);
            appendField(v, clip.items);
        },
        .newline => {
            if (v.bar == .find) {
                try findInDoc(cx, !shift);
            } else if (v.query.len > 0) {
                v.path.set(v.query.slice());
                v.bar = .none;
                try saveDoc(cx);
            }
        },
        else => return false,
    }
    return true;
}

// Motions, for Editor.moveEach.
pub const Move = struct {
    cmd: Command,
    select: bool,
    step: usize = 1,

    pub fn move(m: Move, ed: *Editor, s: *Sel) !void {
        const t = &ed.t;
        switch (m.cmd) {
            .up, .down, .page_up, .page_down => {
                const dir: i64 = if (m.cmd == .up or m.cmd == .page_up) -1 else 1;
                const r = try motion.vertical(t, s.head, s.goal, dir * @as(i64, @intCast(m.step)));
                s.head = r.pos;
                s.goal = r.goal;
                return;
            },
            else => {},
        }
        // Left and right without Shift first collapse a selection to its side.
        s.head = switch (m.cmd) {
            .left => if (!m.select and !s.isEmpty()) s.lo() else try motion.charLeft(t, s.head),
            .right => if (!m.select and !s.isEmpty()) s.hi() else try motion.charRight(t, s.head),
            .word_left => try motion.wordLeft(t, s.head),
            .word_right => try motion.wordRight(t, s.head),
            .line_start => try motion.smartHome(t, s.head),
            .line_end => motion.lineEndAt(t, s.head),
            .doc_start => 0,
            else => t.len,
        };
        s.goal = null;
    }
};

// Runs `cmd`; a motion with `select` moves the carets' heads only, so the
// selections grow.
pub fn runCommand(cx: Context, cmd: Command, select: bool) !void {
    const ed = cx.ed;
    const v = cx.v;
    if (cmd.isMotion()) {
        const paging = cmd == .page_up or cmd == .page_down;
        const step = if (paging) @max(v.rows -| 1, 1) else 1;
        try ed.moveEach(select, Move{ .cmd = cmd, .select = select, .step = step });
        if (paging) {
            if (cmd == .page_up) v.top -|= step else v.top += step;
        }
        touched(v);
        return;
    }
    switch (cmd) {
        .none => return,
        .save => return saveDoc(cx),
        .quit => v.quit = true,
        .find => return openFind(cx),
        .find_next, .find_previous => return findInDoc(cx, cmd == .find_next),
        .toggle_tree => {
            if (cx.tr.root.len > 0) cx.tr.shown = !cx.tr.shown;
        },
        .reload => {
            if (v.path.len > 0) v.reload_request = true;
        },
        .search_project => v.search_request = true,
        .show_changes => v.diff_request = true,
        .toggle_changes => v.changes_toggle = true,
        .select_all => {
            ed.selectAll();
            touched(v);
        },
        .copy, .cut => {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(cx.gpa);
            try ed.copyText(&out);
            try platform.setClipboard(cx.gpa, out.items);
            if (cmd == .cut and writable(v)) {
                try ed.cutSelection();
                touched(v);
            }
        },
        .cancel => {
            ed.setSingle(if (ed.sels.items.len > 1) ed.primary() else Sel.caret(ed.primary().head));
            touched(v);
        },
        else => {
            // The rest change the text.
            if (!writable(v)) return;
            switch (cmd) {
                .undo => if (!try ed.undo()) return,
                .redo => if (!try ed.redo()) return,
                .paste => {
                    var clip: std.ArrayList(u8) = .empty;
                    defer clip.deinit(cx.gpa);
                    try platform.clipboard(cx.gpa, &clip);
                    try ed.paste(clip.items);
                },
                .newline => try ed.newline(),
                .indent => try ed.tab(),
                .delete_left => try ed.deleteEach(edit.ToCharLeft{}),
                .delete_right => try ed.deleteEach(edit.ToCharRight{}),
                .delete_word_left => try ed.deleteEach(edit.ToWordLeft{}),
                .delete_word_right => try ed.deleteEach(edit.ToWordRight{}),
                .delete_to_line_start => try ed.deleteEach(edit.ToLineStart{}),
                .delete_to_line_end => try ed.deleteEach(edit.ToLineEnd{}),
                else => return,
            }
            touched(v);
        },
    }
}

// Runs the key's command, if it has one; true if it did.
fn onKey(cx: Context, mods: Mods, key: KeyName) !bool {
    const found = cx.km.commandFor(mods, key.slice());
    if (found.cmd == .none) return false;
    if (cx.v.bar != .none and try barCommand(cx, found.cmd, mods.shift)) return true;
    try runCommand(cx, found.cmd, found.select);
    return true;
}

// Extends the primary selection to `pos` the way the drag started: by
// characters, words or lines.
fn dragTo(cx: Context, pos: usize) !void {
    const ed = cx.ed;
    const v = cx.v;
    var s = ed.primary();
    if (v.drag == .chars) {
        s.head = pos;
    } else {
        const r = if (v.drag == .words) try motion.wordRange(&ed.t, pos) else motion.lineRange(&ed.t, pos);
        if (r.a < v.drag_a) {
            s.anchor = v.drag_b;
            s.head = r.a;
        } else {
            s.anchor = v.drag_a;
            s.head = @max(r.b, v.drag_b);
        }
    }
    s.goal = null;
    ed.sels.items[ed.sels.items.len - 1] = s;
}

// A click in the tree opens or closes a directory, or asks for a file.
fn onTreeClick(cx: Context, x: f32, y: f32) !void {
    switch (render.treeRowAt(cx.v, cx.tr, x, y)) {
        .row => |i| {
            const e = cx.tr.rows.items[i];
            if (e.is_dir) return cx.tr.toggle(i);
            cx.v.open_path.set(e.path);
            cx.v.open_request = true;
        },
        else => {},
    }
}

fn onButton(cx: Context, x: f32, y: f32, clicks: u8, shift: bool) !void {
    const ed = cx.ed;
    const v = cx.v;
    if (x < v.panel_w) return onTreeClick(cx, x, y);
    if (v.right_cells > 0 and x >= v.right_x) {
        if (y < v.tree_bottom) v.changes_click = y;
        return;
    }
    if (y >= v.text_bottom) return;
    const pos = try render.hit(ed, v, x, y);
    if (clicks >= 3) {
        const r = motion.lineRange(&ed.t, pos);
        ed.setSingle(.{ .anchor = r.a, .head = r.b });
        v.drag = .lines;
        v.drag_a = r.a;
        v.drag_b = r.b;
    } else if (clicks == 2) {
        const r = try motion.wordRange(&ed.t, pos);
        ed.setSingle(.{ .anchor = r.a, .head = r.b });
        v.drag = .words;
        v.drag_a = r.a;
        v.drag_b = r.b;
    } else if (shift) {
        ed.setSingle(.{ .anchor = ed.primary().anchor, .head = pos });
        v.drag = .chars;
    } else {
        ed.setSingle(Sel.caret(pos));
        v.drag = .chars;
    }
    v.blink_at = state.clock();
}

// Typing goes to the field at the bottom when it is open, else to every caret.
fn flushTyped(cx: Context, typed: *std.ArrayList(u8)) !void {
    if (typed.items.len == 0) return;
    if (cx.v.bar != .none) {
        appendField(cx.v, typed.items);
    } else if (writable(cx.v)) {
        try cx.ed.insertText(typed.items, .type);
        touched(cx.v);
    }
    typed.clearRetainingCapacity();
}

pub fn handle(cx: Context, in: *Input) !void {
    const v = cx.v;
    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(cx.gpa);
    var swallow = false; // the last key ran a command: what it types is not text
    for (in.events.items) |e| {
        switch (e) {
            .text => |b| {
                const cmd_held = if (cx.mac) in.mods.cmd else in.mods.ctrl;
                if (swallow or cmd_held) continue;
                for (in.str(b)) |ch| {
                    if (ch >= 0x20 and ch != 0x7F) try typed.append(cx.gpa, ch);
                }
                v.composing.set("");
                continue;
            },
            else => {},
        }
        try flushTyped(cx, &typed);
        switch (e) {
            // While the input method composes, its keys are its own: Return
            // takes what it made, and the text follows.
            .key => |k| if (k.down) {
                swallow = v.composing.len > 0 or try onKey(cx, k.mods, k.key);
            },
            .editing => |b| {
                v.composing.set(in.str(b));
                v.blink_at = state.clock();
            },
            .button => |b| if (b.left and b.down) try onButton(cx, b.x, b.y, b.clicks, in.mods.shift),
            .wheel => |w| {
                if (v.right_cells > 0 and in.mouse_x >= v.right_x) {
                    v.changes_wheel += w.y * 3;
                } else if (in.mouse_x < v.panel_w) {
                    cx.tr.wheel += w.y * 3;
                    const rows = @trunc(cx.tr.wheel);
                    cx.tr.wheel -= rows;
                    const top = @as(i64, @intCast(cx.tr.top)) - @as(i64, @intFromFloat(rows));
                    cx.tr.top = @intCast(@max(top, 0));
                } else {
                    // Three lines a notch of a wheel; a trackpad's fractions scroll by pixels.
                    v.scroll_y -= w.y * 3 * v.line_h;
                    const left = @as(i64, @intCast(v.left)) + @as(i64, @intFromFloat(@round(w.x * 3)));
                    v.left = @intCast(@max(left, 0));
                }
            },
            .quit => v.quit = true,
            else => {},
        }
    }
    try flushTyped(cx, &typed);
    if (v.drag != .none) {
        if (in.left_down) {
            if (in.mouse_y < v.text_y) v.top -|= 1;
            if (in.mouse_y > v.text_bottom) v.top += 1;
            try dragTo(cx, try render.hit(cx.ed, v, in.mouse_x, in.mouse_y));
            v.blink_at = state.clock();
        } else v.drag = .none;
    }
}

// The cursor for where the mouse is: an I-beam over the text, and while
// dragging a selection; a pointing hand over the tree's entries.
pub fn cursorAt(v: *const View, tr: *const Tree, in: *const Input) platform.Cursor {
    if (v.drag != .none) return .text;
    const x = in.mouse_x;
    const y = in.mouse_y;
    if (x < v.panel_w) return if (render.treeRowAt(v, tr, x, y) == .row) .pointer else .arrow;
    if (v.right_cells > 0 and x >= v.right_x) return .arrow;
    if (x >= v.text_x and y >= 0 and y < v.text_bottom) return .text;
    return .arrow;
}
