// How many cells of the monospace grid a character takes: 0, 1 or 2.
//
// The font knows best: once it is loaded, view/font.goose records each
// glyph's advance in `cell_widths`, so a character the font draws wide gets
// two cells, whatever Unicode says about it. Until then, and for characters
// beyond the table, the East Asian Width ranges below decide.

import std;
import core.utf8;

let TAB_SIZE = 4;

// Indexed by codepoint below 0x10000: 0 not known yet, else cells + 1.
var cell_widths: u8[>..<] = [];

fn eaw_width(cp: u32) -> i64 {
    if cp == 0 { return 0; }
    if (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x3099 && cp <= 0x309A) || cp == 0x200B ||
       cp == 0x200D || (cp >= 0xFE00 && cp <= 0xFE0F) {
        return 0;
    }
    if (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0x303E) || (cp >= 0x3041 && cp <= 0x33FF) ||
       (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xA000 && cp <= 0xA4CF) ||
       (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE30 && cp <= 0xFE4F) ||
       (cp >= 0xFF00 && cp <= 0xFF60) || (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1F64F) ||
       (cp >= 0x1F900 && cp <= 0x1F9FF) || (cp >= 0x20000 && cp <= 0x3FFFD) {
        return 2;
    }
    return 1;
}

fn cell_width(cp: u32) -> i64 {
    if cp < cell_widths.len {
        let w = cell_widths[cp];
        if w != 0 { return w - 1; }
    }
    return eaw_width(cp);
}

// The cells `s` takes when it starts at cell `col` (tabs depend on where they are).
fn advance(s: const u8[:], col: i64) -> i64 {
    var c = col;
    var i = 0;
    while i < s.len {
        let cp, n = decode(s, i);
        if cp == '\t' { c += TAB_SIZE - c % TAB_SIZE; } else { c += cell_width(cp); }
        i += n;
    }
    return c;
}

// The byte offset in `line` of the character at cell `goal`: the first whose
// cells end past `goal`'s middle, or the line's end.
fn offset_at_col(line: const u8[:], goal: i64) -> i64 {
    var c = 0;
    var i = 0;
    while i < line.len {
        let cp, n = decode(line, i);
        let w = if cp == '\t' { TAB_SIZE - c % TAB_SIZE } else { cell_width(cp) };
        if w > 0 && c + (w + 1) / 2 > goal { return i; }
        c += w;
        i += n;
    }
    return line.len;
}

// The byte offset in `line` of the character boundary nearest to `x`, a
// position in cells from the line's start (as a click gives).
fn offset_at_x(line: const u8[:], x: f64) -> i64 {
    var c = 0;
    var i = 0;
    while i < line.len {
        let cp, n = decode(line, i);
        let w = if cp == '\t' { TAB_SIZE - c % TAB_SIZE } else { cell_width(cp) };
        if w > 0 && c + w * 0.5 > x { return i; }
        c += w;
        i += n;
    }
    return line.len;
}
