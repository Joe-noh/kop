// Commands on the document: each applies to every selection, and each
// edit is one undo group.

import std;
import core.text;
import core.select;
import core.undo;
import core.motion;
import core.width;

struct Editor {
    t: Text&,
    h: History&,
    sels: Sel[>..<]&,
    crlf: bool,             // line breaks are "\r\n"
    tabs: bool,             // indent with tabs rather than spaces
}

fn eol(ed: Editor&) -> const u8[:] { if ed.crlf { "\r\n" } else { "\n" } }

fn primary(ed: Editor&) -> Sel { ed.sels[ed.sels.len - 1] }

fn set_single(ed: Editor&, s: Sel) {
    ed.sels.resize(0, caret(0));
    ed.sels.push(s);
    seal(ed.h);
}

// Replaces each selection with what F(start, end, out) writes into `out`;
// positions are those of the text as it is when F is called.
fn replace_each<F>(ed: Editor&, kind: i64) {
    normalize(ed.sels);
    begin_group(ed.h, ed.sels, kind);
    var delta = 0;
    var out: u8[>..] = [];
    for i in ed.sels.len {
        let s = ed.sels[i];
        let a = lo(s) + delta;
        let b = hi(s) + delta;
        out.clear();
        F(a, b, &out);
        replace(ed.t, ed.h, a, b - a, out);
        ed.sels[i] = caret(a + out.len);
        delta += out.len - (b - a);
    }
    normalize(ed.sels);
    end_group(ed.h, ed.sels, kind);
}

fn insert_text(ed: Editor&, bytes: const u8[:], kind: i64) {
    replace_each(ed, kind) { a, b, out => out.append(bytes); };
}

// Deletes each selection, or for a caret, the text between it and F(caret).
fn delete_each<F>(ed: Editor&) {
    normalize(ed.sels);
    var ranges: i64[>..<] = [];
    var any = false;
    var prev_end = 0;
    for s in ed.sels {
        var a = lo(s);
        var b = hi(s);
        if is_empty(s) {
            let to = F(s.head);
            a = min(s.head, to);
            b = max(s.head, to);
        }
        a = max(a, prev_end);
        b = max(a, b);
        ranges.push(a);
        ranges.push(b);
        if b > a { any = true; }
        prev_end = b;
    }
    if !any { return; }
    begin_group(ed.h, ed.sels, KIND_EDIT);
    var delta = 0;
    for i in ed.sels.len {
        let a = ranges[2 * i] + delta;
        let n = ranges[2 * i + 1] - ranges[2 * i];
        replace(ed.t, ed.h, a, n, "");
        ed.sels[i] = caret(a);
        delta -= n;
    }
    normalize(ed.sels);
    end_group(ed.h, ed.sels, KIND_EDIT);
}

// Moves each caret to F's choice (F sets s.head, and s.goal for vertical
// motion); with `extend` the anchors stay, so the selections grow.
fn move_each<F>(ed: Editor&, extend: bool) {
    for &s in ed.sels {
        F(s);
        if !extend { s.anchor = s.head; }
    }
    normalize(ed.sels);
    seal(ed.h);
}

// The leading blanks of the line `pos` is on, up to `pos`.
fn indent_before(t: Text&, pos: i64, out: u8[>..]&) {
    let ls = line_start(t, line_of(t, pos));
    var line: u8[>..] = [];
    read(t, ls, pos, line);
    for c in line {
        if c != ' ' && c != '\t' { break; }
        out.push(c);
    }
}

fn newline(ed: Editor&) {
    replace_each(ed, KIND_EDIT) { a, b, out =>
        out.append(eol(ed));
        indent_before(ed.t, a, out);
    };
}

fn tab(ed: Editor&) {
    replace_each(ed, KIND_TYPE) { a, b, out =>
        if ed.tabs {
            out.push('\t');
        } else {
            let col = col_of(ed.t, a);
            for k in TAB_SIZE - col % TAB_SIZE { out.push(' '); }
        }
    };
}

// `text` with its line breaks made the document's.
fn with_eol(ed: Editor&, text: const u8[:], out: u8[>..]&) {
    var i = 0;
    while i < text.len {
        let c = text[i];
        if c == '\r' && i + 1 < text.len && text[i + 1] == '\n' { i++; continue; }
        if c == '\n' || c == '\r' { out.append(eol(ed)); } else { out.push(c); }
        i++;
    }
}

// Pastes `text`; when it has one line per selection, each gets its own line.
fn paste(ed: Editor&, text: const u8[:]) {
    var norm: u8[>..] = [];
    with_eol(ed, text, norm);
    let parts = split(norm, eol(ed));
    var count = parts.len;
    if count > 1 && parts[count - 1].len == 0 { count--; }
    if ed.sels.len > 1 && count == ed.sels.len {
        normalize(ed.sels);
        var i = 0;
        replace_each(ed, KIND_EDIT) { a, b, out =>
            out.append(parts[i]);
            i++;
        };
        return;
    }
    insert_text(ed, norm, KIND_EDIT);
}

// The selected text, selections joined by line breaks. An empty selection
// stands for its whole line, line break included, as copy and cut take it.
fn copy_text(ed: Editor&, out: u8[>..]&) {
    normalize(ed.sels);
    let whole_lines = ed.sels.all() { is_empty(it) };
    for s, i in ed.sels {
        if whole_lines {
            let n = line_of(ed.t, s.head);
            read(ed.t, line_start(ed.t, n), line_start(ed.t, n + 1), out);
            if n == ed.t.lf { out.append(eol(ed)); }
        } else {
            if i > 0 { out.append(eol(ed)); }
            read(ed.t, lo(s), hi(s), out);
        }
    }
}

fn cut_selection(ed: Editor&) {
    normalize(ed.sels);
    let whole_lines = ed.sels.all() { is_empty(it) };
    if whole_lines {
        // Whole lines: select each caret's line, break included.
        for &s in ed.sels {
            let n = line_of(ed.t, s.head);
            s.anchor = line_start(ed.t, n);
            s.head = if n == ed.t.lf { ed.t.len } else { line_start(ed.t, n + 1) };
        }
        normalize(ed.sels);
    }
    delete_each(ed) { it };
}

fn select_all(ed: Editor&) { set_single(ed, Sel { anchor: 0, head: ed.t.len }); }

// The next (or previous) match of `needle` after the primary selection,
// wrapping around; selects it and returns whether there was one.
fn find_next(ed: Editor&, needle: const u8[:], forward: bool) -> bool {
    if needle.len == 0 { return false; }
    let s = primary(ed);
    var at = -1;
    if forward {
        at = find_forward(ed.t, hi(s), needle);
        if at < 0 { at = find_forward(ed.t, 0, needle); }
    } else {
        at = find_backward(ed.t, lo(s), needle);
        if at < 0 { at = find_backward(ed.t, ed.t.len, needle); }
    }
    if at < 0 { return false; }
    set_single(ed, Sel { anchor: at, head: at + needle.len });
    return true;
}
