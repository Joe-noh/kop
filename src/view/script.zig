// Input played back from a file, one line per frame, for tests that run
// without anyone at the window (--script, which also keeps it hidden):
//
//   text 日本語          typed text
//   compose にほん       what an input method would be composing
//   key mod+s            a key pressed and released, written as the keymap writes keys
//   click 120 40 [2]     the left button at a pixel, clicked once or more
//   wheel -0.25          the wheel turned, as a trackpad turns it
//   wait 10              ten frames of nothing
//   sleep 1.5            that many seconds of nothing
//   shot out.png         the screen, saved
//   quit

const std = @import("std");
const keymap = @import("../core/keymap.zig");
const Input = @import("input.zig").Input;
const state = @import("state.zig");

pub const Script = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    wait: usize = 0,
    until: f64 = 0,
    shot: ?[]const u8 = null, // a screenshot to take after this frame is drawn
    mac: bool,

    pub fn init(src: []const u8, mac: bool) Script {
        return .{ .lines = std.mem.splitScalar(u8, src, '\n'), .mac = mac };
    }

    fn float(s: []const u8) f32 {
        return std.fmt.parseFloat(f32, std.mem.trim(u8, s, " ")) catch 0;
    }

    // Runs the next line into `in`; false once the script says to quit.
    pub fn step(s: *Script, in: *Input) !bool {
        s.shot = null;
        if (s.wait > 0) {
            s.wait -= 1;
            return true;
        }
        if (state.clock() < s.until) return true;
        const line = s.lines.next() orelse return false;
        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const cmd = if (sp) |k| line[0..k] else line;
        const arg = if (sp) |k| line[k + 1 ..] else "";
        if (std.mem.eql(u8, cmd, "text")) {
            try in.pushText(arg);
        } else if (std.mem.eql(u8, cmd, "compose")) {
            try in.pushEditing(arg);
        } else if (std.mem.eql(u8, cmd, "key")) {
            const k = keymap.parseKey(arg, s.mac) orelse {
                std.debug.print("script: not a key: {s}\n", .{arg});
                return true;
            };
            try in.push(.{ .key = .{ .mods = k.mods, .key = k.key, .down = true } });
            try in.push(.{ .key = .{ .mods = .{}, .key = k.key, .down = false } });
        } else if (std.mem.eql(u8, cmd, "click")) {
            var parts = std.mem.tokenizeScalar(u8, arg, ' ');
            const x = float(parts.next() orelse "0");
            const y = float(parts.next() orelse "0");
            const n = std.fmt.parseInt(u8, parts.next() orelse "1", 10) catch 1;
            for (1..n + 1) |i| {
                try in.push(.{ .button = .{ .x = x, .y = y, .down = true, .clicks = @intCast(i), .left = true } });
                try in.push(.{ .button = .{ .x = x, .y = y, .down = false, .clicks = @intCast(i), .left = true } });
            }
        } else if (std.mem.eql(u8, cmd, "wheel")) {
            try in.push(.{ .wheel = .{ .x = 0, .y = float(arg) } });
        } else if (std.mem.eql(u8, cmd, "wait")) {
            s.wait = std.fmt.parseInt(usize, arg, 10) catch 0;
        } else if (std.mem.eql(u8, cmd, "sleep")) {
            s.until = state.clock() + float(arg);
        } else if (std.mem.eql(u8, cmd, "shot")) {
            s.shot = arg;
        } else if (std.mem.eql(u8, cmd, "quit")) {
            return false;
        } else if (cmd.len > 0 and cmd[0] != '#') {
            std.debug.print("script: unknown command: {s}\n", .{line});
        }
        return true;
    }
};
