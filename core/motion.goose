// Where the caret goes. Each function reads only the line it is on.
//
// A character is a codepoint together with the zero-width ones after it
// (combining marks, variation selectors), so "か゛" moves as one. "\r\n" is
// one step.

import std;
import core.text;
import core.utf8;
import core.width;

fn char_left(t: Text&, pos: i64) -> i64 {
    if pos <= 0 { return 0; }
    let n = line_of(t, pos);
    let ls = line_start(t, n);
    if pos == ls { return line_end(t, n - 1); }
    var buf: u8[>..] = [];
    read(t, max(ls, pos - 32), pos, buf);
    var j = prev_start(buf, buf.len);
    loop {
        let cp, k = decode(buf, j);
        if j == 0 || cell_width(cp) != 0 { break; }
        j = prev_start(buf, j);
    }
    return pos - (buf.len - j);
}

fn char_right(t: Text&, pos: i64) -> i64 {
    if pos >= t.len { return t.len; }
    let n = line_of(t, pos);
    let le = line_end(t, n);
    if pos >= le { return line_start(t, n + 1); }
    var buf: u8[>..] = [];
    read(t, pos, min(le, pos + 32), buf);
    let cp, k = decode(buf, 0);
    var i = k;
    while i < buf.len {
        let c2, k2 = decode(buf, i);
        if cell_width(c2) != 0 { break; }
        i += k2;
    }
    return pos + i;
}

fn class_at(s: const u8[:], i: i64) -> i64 {
    let cp, k = decode(s, i);
    char_class(cp)
}

// Past the spaces, then past the run of one character class.
fn word_right(t: Text&, pos: i64) -> i64 {
    let n = line_of(t, pos);
    let le = line_end(t, n);
    if pos >= le { return char_right(t, pos); }
    var line: u8[>..] = [];
    read(t, pos, le, line);
    var i = 0;
    while i < line.len && class_at(line, i) == CLASS_SPACE {
        let cp, k = decode(line, i);
        i += k;
    }
    if i < line.len {
        let c = class_at(line, i);
        while i < line.len && class_at(line, i) == c {
            let cp, k = decode(line, i);
            i += k;
        }
    }
    return pos + i;
}

fn word_left(t: Text&, pos: i64) -> i64 {
    let n = line_of(t, pos);
    let ls = line_start(t, n);
    if pos <= ls { return char_left(t, pos); }
    var line: u8[>..] = [];
    read(t, ls, pos, line);
    var i = line.len;
    while i > 0 && class_at(line, prev_start(line, i)) == CLASS_SPACE { i = prev_start(line, i); }
    if i > 0 {
        let c = class_at(line, prev_start(line, i));
        while i > 0 && class_at(line, prev_start(line, i)) == c { i = prev_start(line, i); }
    }
    return ls + i;
}

// The word (or run of spaces, or of one punctuation class) around `pos`.
fn word_range(t: Text&, pos: i64) -> i64, i64 {
    let n = line_of(t, pos);
    let ls = line_start(t, n);
    var line: u8[>..] = [];
    read_line(t, n, line);
    if line.len == 0 { return pos, pos; }
    var at = min(pos - ls, line.len);
    if at == line.len { at = prev_start(line, at); }
    let c = class_at(line, at);
    var a = at;
    while a > 0 && class_at(line, prev_start(line, a)) == c { a = prev_start(line, a); }
    var b = at;
    while b < line.len && class_at(line, b) == c {
        let cp, k = decode(line, b);
        b += k;
    }
    return ls + a, ls + b;
}

// Home: the first non-blank of the line, or its start if already there.
fn smart_home(t: Text&, pos: i64) -> i64 {
    let n = line_of(t, pos);
    let ls = line_start(t, n);
    var line: u8[>..] = [];
    read_line(t, n, line);
    var i = 0;
    while i < line.len && class_at(line, i) == CLASS_SPACE {
        let cp, k = decode(line, i);
        i += k;
    }
    if pos == ls + i { return ls; }
    return ls + i;
}

fn line_end_at(t: Text&, pos: i64) -> i64 { line_end(t, line_of(t, pos)) }

// The cell column of `pos` on its line.
fn col_of(t: Text&, pos: i64) -> i64 {
    let ls = line_start(t, line_of(t, pos));
    var buf: u8[>..] = [];
    read(t, ls, pos, buf);
    advance(buf, 0)
}

// The offset on line `n` nearest to cell column `col`.
fn pos_at_col(t: Text&, n: i64, col: i64) -> i64 {
    let line_n = clamp(n, 0, t.lf);
    var line: u8[>..] = [];
    read_line(t, line_n, line);
    return line_start(t, line_n) + offset_at_col(line, col);
}

// `lines` up (negative) or down, aiming at `goal` (or the caret's own
// column); returns the new offset and the goal kept.
fn vertical(t: Text&, pos: i64, goal: i64, lines: i64) -> i64, i64 {
    let col = if goal >= 0 { goal } else { col_of(t, pos) };
    let n = line_of(t, pos) + lines;
    if n < 0 { return 0, col; }
    if n > t.lf { return t.len, col; }
    return pos_at_col(t, n, col), col;
}
