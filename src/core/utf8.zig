// UTF-8 over byte slices, and the character classes word motion uses.

const std = @import("std");

pub fn isCont(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

pub const Decoded = struct { cp: u32, len: usize };

// The codepoint at s[i] and how many bytes it takes. A malformed sequence
// is one byte of U+FFFD, so every byte belongs to some character.
pub fn decode(s: []const u8, i: usize) Decoded {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    var n: usize = 0;
    var cp: u32 = 0;
    if (b0 >= 0xF0 and b0 < 0xF8) {
        n = 4;
        cp = b0 & 0x07;
    } else if (b0 >= 0xE0 and b0 < 0xF0) {
        n = 3;
        cp = b0 & 0x0F;
    } else if (b0 >= 0xC2 and b0 < 0xE0) {
        n = 2;
        cp = b0 & 0x1F;
    } else return .{ .cp = 0xFFFD, .len = 1 };
    if (i + n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    for (1..n) |k| {
        const b = s[i + k];
        if (!isCont(b)) return .{ .cp = 0xFFFD, .len = 1 };
        cp = (cp << 6) | (b & 0x3F);
    }
    return .{ .cp = cp, .len = n };
}

// Where the character before s[i] starts.
pub fn prevStart(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and i - j < 4 and isCont(s[j])) j -= 1;
    if (j + decode(s, j).len != i) return i - 1; // malformed: one byte back
    return j;
}

// Appends the UTF-8 of `cp`.
pub fn encode(cp: u32, out: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(@intCast(cp), out) catch {
        out[0..3].* = .{ 0xEF, 0xBF, 0xBD };
        return out[0..3];
    };
    return out[0..n];
}

// Whether the first `limit` bytes look like UTF-8. A sequence cut off by the
// limit is allowed.
pub fn looksUtf8(s: []const u8, limit: usize) bool {
    const n = @min(s.len, limit);
    var i: usize = 0;
    while (i < n) {
        if (s[i] < 0x80) {
            i += 1;
            continue;
        }
        const d = decode(s, i);
        if (d.cp == 0xFFFD and d.len == 1) {
            return i + 4 > n and s[i] >= 0xC2;
        }
        i += d.len;
    }
    return true;
}

// Character classes for word motion: a word is a run of one class, so
// "日本語テキストです" stops between the kanji, the katakana and the hiragana.
pub const Class = enum { space, punct, word, hiragana, katakana, kanji, other };

pub fn charClass(cp: u32) Class {
    if (cp == ' ' or cp == '\t' or cp == 0x3000) return .space;
    if (cp < 0x80) {
        if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9') or cp == '_') return .word;
        return .punct;
    }
    if (cp >= 0x3041 and cp <= 0x309F) return .hiragana;
    if ((cp >= 0x30A0 and cp <= 0x30FF) or (cp >= 0xFF66 and cp <= 0xFF9F)) return .katakana;
    if ((cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or cp == 0x3005) return .kanji;
    if ((cp >= 0xFF10 and cp <= 0xFF19) or (cp >= 0xFF21 and cp <= 0xFF3A) or (cp >= 0xFF41 and cp <= 0xFF5A)) return .word;
    if ((cp >= 0x3000 and cp <= 0x303F) or (cp >= 0xFF00 and cp <= 0xFF65) or (cp >= 0x2000 and cp <= 0x206F)) return .punct;
    if (cp >= 0xC0 and cp < 0x2000) return .word; // accented Latin, Greek, Cyrillic
    return .other;
}

test "utf-8 check" {
    try std.testing.expect(looksUtf8("日本語", 100));
    try std.testing.expect(!looksUtf8("\x82\xA0", 100));
}
