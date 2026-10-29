// How many cells of the monospace grid a character takes: 0, 1 or 2.
//
// The font knows best: once one is loaded, src/view/font.zig answers for
// the characters it has, by their advance, and the answer is kept, so a
// character the font draws wide gets two cells whatever Unicode says about
// it. Until then, and for characters it does not have, the East Asian
// Width ranges below decide.

const std = @import("std");
const utf8 = @import("utf8.zig");

pub const tab_size = 4;

// Indexed by codepoint below 0x10000: 0 not known yet, else cells + 1.
var learned: [0x10000]u8 = @splat(0);

// What the font says a character takes, or null when it does not have it.
pub var font_width: ?*const fn (cp: u32) ?u8 = null;

// Forgets what the font said, for when it changes.
pub fn forget() void {
    learned = @splat(0);
}

pub fn eawWidth(cp: u32) u8 {
    if (cp == 0) return 0;
    if ((cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x3099 and cp <= 0x309A) or cp == 0x200B or
        cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0x303E) or (cp >= 0x3041 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or (cp >= 0x20000 and cp <= 0x3FFFD)) return 2;
    return 1;
}

pub fn cellWidth(cp: u32) u8 {
    if (cp >= learned.len) return eawWidth(cp);
    const w = learned[cp];
    if (w != 0) return w - 1;
    const found = if (font_width) |f| f(cp) else null;
    const cells = found orelse eawWidth(cp);
    // Zero-width marks stay zero whatever their advance.
    const kept = if (eawWidth(cp) == 0) 0 else cells;
    if (font_width != null) learned[cp] = kept + 1;
    return kept;
}

// The cells a character takes at cell `col` (a tab depends on where it is).
pub fn widthAt(cp: u32, col: usize) usize {
    return if (cp == '\t') tab_size - col % tab_size else cellWidth(cp);
}

// The cells `s` takes when it starts at cell `col`.
pub fn advance(s: []const u8, col: usize) usize {
    var c = col;
    var i: usize = 0;
    while (i < s.len) {
        const d = utf8.decode(s, i);
        c += widthAt(d.cp, c);
        i += d.len;
    }
    return c;
}

// The byte offset in `line` of the character at cell `goal`: the first whose
// cells end past `goal`'s middle, or the line's end.
pub fn offsetAtCol(line: []const u8, goal: usize) usize {
    var c: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const d = utf8.decode(line, i);
        const w = widthAt(d.cp, c);
        if (w > 0 and c + (w + 1) / 2 > goal) return i;
        c += w;
        i += d.len;
    }
    return line.len;
}

// The byte offset in `line` of the character boundary nearest to `x`, a
// position in cells from the line's start (as a click gives).
pub fn offsetAtX(line: []const u8, x: f32) usize {
    var c: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const d = utf8.decode(line, i);
        const w = widthAt(d.cp, c);
        if (w > 0 and @as(f32, @floatFromInt(c)) + @as(f32, @floatFromInt(w)) * 0.5 > x) return i;
        c += w;
        i += d.len;
    }
    return line.len;
}

test "east asian width" {
    try std.testing.expect(eawWidth(0x3042) == 2 and eawWidth('a') == 1 and eawWidth(0x0301) == 0);
    try std.testing.expectEqual(@as(usize, 1), offsetAtCol("aあb", 1));
    try std.testing.expectEqual(@as(usize, 4), offsetAtCol("aあb", 3));
}
