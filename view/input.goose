// The frame's keys, typing and mouse, turned into commands.
//
// On macOS Cmd is the command key and Option moves by words; elsewhere
// Ctrl does both.

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
import view.state;
import view.render;

struct Keys {
    left: i64, right: i64, up: i64, down: i64,
    home: i64, end: i64, page_up: i64, page_down: i64,
    backspace: i64, delete: i64, enter: i64, keypad_enter: i64, tab: i64, escape: i64,
}

fn keys() -> Keys {
    Keys {
        left: gfx::scancode("Left"), right: gfx::scancode("Right"),
        up: gfx::scancode("Up"), down: gfx::scancode("Down"),
        home: gfx::scancode("Home"), end: gfx::scancode("End"),
        page_up: gfx::scancode("PageUp"), page_down: gfx::scancode("PageDown"),
        backspace: gfx::scancode("Backspace"), delete: gfx::scancode("Delete"),
        enter: gfx::scancode("Return"), keypad_enter: gfx::scancode("Keypad Enter"),
        tab: gfx::scancode("Tab"), escape: gfx::scancode("Escape"),
    }
}

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

// Keys for the field at the bottom; false for keys it leaves to the document.
fn bar_key(ed: Editor&, v: View&, k: Keys, e: gfx::Event, cmd: bool, shift: bool) -> bool {
    let sc = e.scancode;
    if sc == k.escape { v.bar = BAR_NONE; return true; }
    if sc == k.backspace { pop_char(v.query); return true; }
    if sc == k.enter || sc == k.keypad_enter {
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
    if cmd && e.keycode == 'v' { append_field(v.query, gfx::clipboard()); return true; }
    return false;
}

fn on_key(ed: Editor&, v: View&, k: Keys, e: gfx::Event, mac: bool) {
    let shift = (e.mods & gfx::MOD_SHIFT) != 0;
    let cmd = (e.mods & (if mac { gfx::MOD_GUI } else { gfx::MOD_CTRL })) != 0;
    let word = (e.mods & (if mac { gfx::MOD_ALT } else { gfx::MOD_CTRL })) != 0;
    let sc = e.scancode;
    if v.bar != BAR_NONE && bar_key(ed, v, k, e, cmd, shift) { return; }
    let t = ed.t;
    if cmd && !(sc == k.left || sc == k.right || sc == k.up || sc == k.down || sc == k.backspace || sc == k.delete) {
        let key = e.keycode;
        if key == 's' { save_doc(ed, v); }
        else if key == 'z' && shift || key == 'y' {
            if writable(v) && redo(ed.t, ed.h, ed.sels) { touched(v); }
        } else if key == 'z' {
            if writable(v) && undo(ed.t, ed.h, ed.sels) { touched(v); }
        } else if key == 'c' || key == 'x' {
            var out: u8[>..] = [];
            copy_text(ed, out);
            gfx::set_clipboard(out);
            if key == 'x' && writable(v) { cut_selection(ed); touched(v); }
        } else if key == 'v' {
            if writable(v) { paste(ed, gfx::clipboard()); touched(v); }
        } else if key == 'a' { select_all(ed); }
        else if key == 'f' { open_find(ed, v); }
        else if key == 'g' { find_in_doc(ed, v, !shift); }
        else if key == 'q' { v.quit = true; }
        return;
    }
    if sc == k.left {
        move_each(ed, shift) { s =>
            s.head = if !shift && !is_empty(s) { lo(s) }
                     else if word { word_left(t, s.head) }
                     else if cmd { smart_home(t, s.head) }
                     else { char_left(t, s.head) };
            s.goal = -1;
        };
    } else if sc == k.right {
        move_each(ed, shift) { s =>
            s.head = if !shift && !is_empty(s) { hi(s) }
                     else if word { word_right(t, s.head) }
                     else if cmd { line_end_at(t, s.head) }
                     else { char_right(t, s.head) };
            s.goal = -1;
        };
    } else if sc == k.up || sc == k.down || sc == k.page_up || sc == k.page_down {
        let dir = if sc == k.up || sc == k.page_up { -1 } else { 1 };
        let step = if sc == k.page_up || sc == k.page_down { max(v.rows - 1, 1) } else { 1 };
        if cmd {
            move_each(ed, shift) { s => s.head = if dir < 0 { 0 } else { t.len }; s.goal = -1; };
        } else {
            move_each(ed, shift) { s =>
                let p, g = vertical(t, s.head, s.goal, dir * step);
                s.head = p;
                s.goal = g;
            };
            if step > 1 { v.top += dir * step; }
        }
    } else if sc == k.home {
        move_each(ed, shift) { s => s.head = if cmd { 0 } else { smart_home(t, s.head) }; s.goal = -1; };
    } else if sc == k.end {
        move_each(ed, shift) { s => s.head = if cmd { t.len } else { line_end_at(t, s.head) }; s.goal = -1; };
    } else if sc == k.backspace {
        if !writable(v) { return; }
        if cmd { delete_each(ed) { line_start(t, line_of(t, it)) }; }
        else if word { delete_each(ed) { word_left(t, it) }; }
        else { delete_each(ed) { char_left(t, it) }; }
    } else if sc == k.delete {
        if !writable(v) { return; }
        if word { delete_each(ed) { word_right(t, it) }; } else { delete_each(ed) { char_right(t, it) }; }
    } else if sc == k.enter || sc == k.keypad_enter {
        if writable(v) { newline(ed); }
    } else if sc == k.tab {
        if writable(v) { tab(ed); }
    } else if sc == k.escape {
        if ed.sels.len > 1 { set_single(ed, primary(ed)); }
        else { set_single(ed, caret(primary(ed).head)); }
    } else {
        return;
    }
    touched(v);
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

fn on_button(ed: Editor&, v: View&, e: gfx::Event) {
    if e.button != gfx::MOUSE_LEFT || !e.down { return; }
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

fn handle_input(ed: Editor&, v: View&, k: Keys, mac: bool) {
    var typed: u8[>..] = [];
    let cmd_key = if mac { gfx::MOD_GUI } else { gfx::MOD_CTRL };
    var mods: i32 = 0;
    for e in gfx::events() {
        if e.kind == gfx::EVENT_TEXT {
            if (mods & cmd_key) == 0 { push_utf8(typed, e.codepoint); }
            continue;
        }
        flush_typed(ed, v, typed);
        if e.kind == gfx::EVENT_KEY {
            mods = e.mods;
            if e.down { on_key(ed, v, k, e, mac); }
        } else if e.kind == gfx::EVENT_MOUSE_BUTTON {
            on_button(ed, v, e);
        } else if e.kind == gfx::EVENT_MOUSE_WHEEL {
            v.wheel += e.y * 3.0;
            let lines = trunc(v.wheel);
            v.top -= lines as i64;
            v.wheel -= lines;
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
