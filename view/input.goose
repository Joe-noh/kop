// The frame's keys, typing and mouse, turned into commands. Which key runs
// which command is core/keymap.goose's.

import std;
import os;
import math;
import gfx;
import core.text;
import core.select;
import core.undo;
import core.edit;
import core.motion;
import core.doc;
import core.utf8;
import core.keymap;
import view.state;
import view.render;
import view.tree;
import view.platform;

// The caret moved or the text changed: show it, and show the caret steadily.
fn touched(v: View&) {
    v.follow = true;
    v.blink_at = clock();
}

fn writable(v: View&) -> bool {
    if v.readonly { say(v, "UTF-8 ではないので読み取り専用で開いています"); }
    !v.readonly
}

fn save_doc(ed: Editor&, v: View&) {
    if v.path.len == 0 {
        v.bar = BAR_SAVE_AS;
        v.query.resize(0, 0);
        return;
    }
    if v.readonly { say(v, "読み取り専用です"); return; }
    if save(ed.t, v.info, v.path) {
        mark_saved(ed.h);
        say(v, "保存しました");
    } else {
        say(v, str("保存できませんでした: ", v.path));
    }
}

fn open_find(ed: Editor&, v: View&) {
    v.bar = BAR_FIND;
    let p = primary(ed);
    if !is_empty(p) && hi(p) - lo(p) <= 200 {
        var sel: u8[>..] = [];
        read(ed.t, lo(p), hi(p), sel);
        if find(sel, "\n") < 0 {
            v.query.resize(0, 0);
            v.query.append(sel);
        }
    }
}

fn find_in_doc(ed: Editor&, v: View&, forward: bool) {
    if v.query.len == 0 { return; }
    if find_next(ed, v.query, forward) { touched(v); } else { say(v, "見つかりません"); }
}

// Removes the last character of a field.
fn pop_char(s: u8[..256]&) {
    if s.len == 0 { return; }
    let k = prev_start(s, s.len);
    s.resize(k, 0);
}

fn append_field(s: u8[..256]&, text: const u8[:]) {
    for c in text {
        if c == '\n' || c == '\r' || s.len == 256 { break; }
        s.push(c);
    }
}

// A command for the field at the bottom; false for those it leaves to the
// document. Enter finds the next match, or with Shift the previous one.
fn bar_command(ed: Editor&, v: View&, cmd: i64, shift: bool) -> bool {
    if cmd == CMD_CANCEL { v.bar = BAR_NONE; return true; }
    if cmd == CMD_DELETE_LEFT { pop_char(v.query); return true; }
    if cmd == CMD_PASTE { append_field(v.query, gfx::clipboard()); return true; }
    if cmd == CMD_NEWLINE {
        if v.bar == BAR_FIND {
            find_in_doc(ed, v, !shift);
        } else if v.query.len > 0 {
            v.path.resize(0, 0);
            v.path.append(v.query);
            v.bar = BAR_NONE;
            save_doc(ed, v);
        }
        return true;
    }
    return false;
}

// Runs `cmd`; a motion with `select` moves the carets' heads only, so the
// selections grow.
fn run_command(ed: Editor&, v: View&, tr: Tree&, cmd: i64, select: bool) {
    let t = ed.t;
    if is_motion(cmd) {
        if cmd == CMD_UP || cmd == CMD_DOWN || cmd == CMD_PAGE_UP || cmd == CMD_PAGE_DOWN {
            let dir = if cmd == CMD_UP || cmd == CMD_PAGE_UP { -1 } else { 1 };
            let step = if cmd == CMD_PAGE_UP || cmd == CMD_PAGE_DOWN { max(v.rows - 1, 1) } else { 1 };
            move_each(ed, select) { s =>
                let p, g = vertical(t, s.head, s.goal, dir * step);
                s.head = p;
                s.goal = g;
            };
            if step > 1 { v.top += dir * step; }
        } else {
            move_each(ed, select) { s =>
                // Left and right without Shift first collapse a selection to its side.
                s.head = if cmd == CMD_LEFT && !select && !is_empty(s) { lo(s) }
                         else if cmd == CMD_RIGHT && !select && !is_empty(s) { hi(s) }
                         else if cmd == CMD_LEFT { char_left(t, s.head) }
                         else if cmd == CMD_RIGHT { char_right(t, s.head) }
                         else if cmd == CMD_WORD_LEFT { word_left(t, s.head) }
                         else if cmd == CMD_WORD_RIGHT { word_right(t, s.head) }
                         else if cmd == CMD_LINE_START { smart_home(t, s.head) }
                         else if cmd == CMD_LINE_END { line_end_at(t, s.head) }
                         else if cmd == CMD_DOC_START { 0 }
                         else { t.len };
                s.goal = -1;
            };
        }
        touched(v);
        return;
    }
    if cmd == CMD_SAVE { save_doc(ed, v); return; }
    if cmd == CMD_QUIT { v.quit = true; return; }
    if cmd == CMD_FIND { open_find(ed, v); return; }
    if cmd == CMD_FIND_NEXT || cmd == CMD_FIND_PREVIOUS { find_in_doc(ed, v, cmd == CMD_FIND_NEXT); return; }
    if cmd == CMD_TOGGLE_TREE { if tr.root.len > 0 { tr.shown = !tr.shown; } return; }
    if cmd == CMD_SELECT_ALL { select_all(ed); touched(v); return; }
    if cmd == CMD_COPY || cmd == CMD_CUT {
        var out: u8[>..] = [];
        copy_text(ed, out);
        gfx::set_clipboard(out);
        if cmd == CMD_CUT && writable(v) { cut_selection(ed); touched(v); }
        return;
    }
    if cmd == CMD_CANCEL {
        if ed.sels.len > 1 { set_single(ed, primary(ed)); } else { set_single(ed, caret(primary(ed).head)); }
        touched(v);
        return;
    }
    // The rest change the text.
    if !writable(v) { return; }
    if cmd == CMD_UNDO { if undo(ed.t, ed.h, ed.sels) { touched(v); } return; }
    if cmd == CMD_REDO { if redo(ed.t, ed.h, ed.sels) { touched(v); } return; }
    if cmd == CMD_PASTE { paste(ed, gfx::clipboard()); }
    else if cmd == CMD_NEWLINE { newline(ed); }
    else if cmd == CMD_INDENT { tab(ed); }
    else if cmd == CMD_DELETE_LEFT { delete_each(ed) { char_left(t, it) }; }
    else if cmd == CMD_DELETE_RIGHT { delete_each(ed) { char_right(t, it) }; }
    else if cmd == CMD_DELETE_WORD_LEFT { delete_each(ed) { word_left(t, it) }; }
    else if cmd == CMD_DELETE_WORD_RIGHT { delete_each(ed) { word_right(t, it) }; }
    else if cmd == CMD_DELETE_TO_LINE_START { delete_each(ed) { line_start(t, line_of(t, it)) }; }
    else if cmd == CMD_DELETE_TO_LINE_END {
        // At a line's end, the line break, as Emacs's Ctrl+K does.
        delete_each(ed) { if line_end_at(t, it) == it { char_right(t, it) } else { line_end_at(t, it) } };
    }
    touched(v);
}

// The key's name as the keymap has it: the character it types, else its own.
fn event_key(e: gfx::Event, out: u8[..24]&) {
    out.resize(0, 0);
    if e.keycode > 32 && e.keycode < 127 {
        let c = e.keycode as! u8;
        out.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c });
        return;
    }
    if e.keycode == 32 { out.push(' '); return; }
    key_name_of(gfx::key_name(e.scancode), out);
}

// Runs the key's command, if it has one; true if it did.
fn on_key(ed: Editor&, v: View&, tr: Tree&, e: gfx::Event) -> bool {
    var key: u8[..24] = [];
    event_key(e, key);
    let cmd, select = command_for(e.mods, key);
    if cmd == CMD_NONE { return false; }
    if v.bar != BAR_NONE && bar_command(ed, v, cmd, (e.mods & gfx::MOD_SHIFT) != 0) { return true; }
    run_command(ed, v, tr, cmd, select);
    return true;
}

fn line_range(t: Text&, pos: i64) -> i64, i64 {
    let n = line_of(t, pos);
    return line_start(t, n), if n == t.lf { t.len } else { line_start(t, n + 1) };
}

// Extends the primary selection to `pos` the way the drag started: by
// characters, words or lines.
fn drag_to(ed: Editor&, v: View&, pos: i64) {
    var s = primary(ed);
    if v.drag == DRAG_CHARS {
        s.head = pos;
    } else {
        var a = 0;
        var b = 0;
        if v.drag == DRAG_WORDS { a, b = word_range(ed.t, pos); } else { a, b = line_range(ed.t, pos); }
        if a < v.drag_a { s.anchor = v.drag_b; s.head = a; } else { s.anchor = v.drag_a; s.head = max(b, v.drag_b); }
    }
    s.goal = -1;
    ed.sels[ed.sels.len - 1] = s;
}

// A click in the tree opens or closes a directory, or asks for a file.
fn on_tree_click(v: View&, tr: Tree&, p: float2) {
    let i = tree_row_at(v, tr, p);
    if i < 0 { return; }
    let e = tr.rows[i];
    if e.is_dir {
        toggle(tr, i);
        return;
    }
    v.open_path.resize(0, 0);
    v.open_path.append(path_of(tr, e)[..min(e.path_len, 1024)]);
    v.open_request = true;
}

fn on_button(ed: Editor&, v: View&, tr: Tree&, e: gfx::Event) {
    if e.button != gfx::MOUSE_LEFT || !e.down { return; }
    if e.x < v.panel_w {
        on_tree_click(v, tr, float2 { e.x, e.y });
        return;
    }
    if e.y >= v.text_bottom { return; }
    let p = float2 { e.x, e.y };
    let pos = hit(ed, v, p);
    let shift = gfx::key_down("Left Shift") || gfx::key_down("Right Shift");
    if e.clicks >= 3 {
        let a, b = line_range(ed.t, pos);
        set_single(ed, Sel { anchor: a, head: b });
        v.drag = DRAG_LINES;
        v.drag_a = a;
        v.drag_b = b;
    } else if e.clicks == 2 {
        let a, b = word_range(ed.t, pos);
        set_single(ed, Sel { anchor: a, head: b });
        v.drag = DRAG_WORDS;
        v.drag_a = a;
        v.drag_b = b;
    } else if shift {
        var s = primary(ed);
        set_single(ed, Sel { anchor: s.anchor, head: pos });
        v.drag = DRAG_CHARS;
    } else {
        set_single(ed, caret(pos));
        v.drag = DRAG_CHARS;
    }
    v.blink_at = clock();
}

fn handle_input(ed: Editor&, v: View&, tr: Tree&, mac: bool) {
    var typed: u8[>..] = [];
    let cmd_key = if mac { gfx::MOD_GUI } else { gfx::MOD_CTRL };
    var mods: i32 = 0;
    var swallow = false;            // the last key ran a command: what it types is not text
    for e in gfx::events() {
        if e.kind == gfx::EVENT_TEXT {
            if !swallow && (mods & cmd_key) == 0 && e.codepoint >= 0x20 && e.codepoint != 0x7F {
                push_utf8(typed, e.codepoint);
            }
            continue;
        }
        flush_typed(ed, v, typed);
        if e.kind == gfx::EVENT_KEY {
            mods = e.mods;
            if e.down { swallow = on_key(ed, v, tr, e); }
        } else if e.kind == gfx::EVENT_MOUSE_BUTTON {
            on_button(ed, v, tr, e);
        } else if e.kind == gfx::EVENT_MOUSE_WHEEL && gfx::mouse_pos().x < v.panel_w {
            tr.wheel += e.y * 3.0;
            let rows = trunc(tr.wheel);
            tr.top -= rows as i64;
            tr.wheel -= rows;
        } else if e.kind == gfx::EVENT_MOUSE_WHEEL {
            // Three lines a notch of a wheel; a trackpad's fractions scroll by pixels.
            v.scroll_y -= e.y * 3.0 * v.line_h;
            v.left = max(v.left + round(e.x * 3.0) as i64, 0);
        }
    }
    flush_typed(ed, v, typed);
    if v.drag != DRAG_NONE {
        if gfx::mouse_down(gfx::MOUSE_LEFT) {
            let p = gfx::mouse_pos();
            if p.y < v.text_y { v.top -= 1; }
            if p.y > v.text_bottom { v.top += 1; }
            drag_to(ed, v, hit(ed, v, p));
            v.blink_at = clock();
        } else {
            v.drag = DRAG_NONE;
        }
    }
}

// The cursor for where the mouse is: an I-beam over the text, and while
// dragging a selection; a pointing hand over the tree's entries.
fn cursor_at(v: View&, tr: Tree&) -> i32 {
    if v.drag != DRAG_NONE { return CURSOR_TEXT; }
    let p = gfx::mouse_pos();
    if p.x < v.panel_w {
        return if tree_row_at(v, tr, p) >= 0 { CURSOR_POINTER } else { CURSOR_ARROW };
    }
    if p.x >= v.text_x && p.y < v.text_bottom { return CURSOR_TEXT; }
    return CURSOR_ARROW;
}

// Typing goes to the field at the bottom when it is open, else to every caret.
fn flush_typed(ed: Editor&, v: View&, typed: u8[>..]&) {
    if typed.len == 0 { return; }
    if v.bar != BAR_NONE {
        append_field(v.query, typed);
    } else if writable(v) {
        insert_text(ed, typed, KIND_TYPE);
        touched(v);
    }
    typed.clear();
}
