// Drawing a frame: the gutter, the visible lines on a grid of cells, the
// selections and carets, and the status bar. Only the lines on screen are
// read, so a frame costs the same for any size of file.

import std;
import os;
import math;
import gfx;
import ui;
import core.text;
import core.select;
import core.undo;
import core.edit;
import core.motion;
import core.utf8;
import core.width;
import view.state;
import view.font;

let BG = ui::Color { 30, 31, 34, 255 };
let FG = ui::Color { 222, 222, 214, 255 };
let GUTTER_FG = ui::Color { 104, 107, 114, 255 };
let GUTTER_FG_CURRENT = ui::Color { 190, 190, 182, 255 };
let CURRENT_LINE = ui::Color { 38, 40, 45, 255 };
let SELECTION = ui::Color { 52, 80, 122, 255 };
let MATCH = ui::Color { 96, 84, 34, 255 };
let CARET = ui::Color { 255, 200, 60, 255 };
let INVISIBLE = ui::Color { 78, 82, 90, 255 };       // tabs, trailing spaces, full-width spaces
let BAR_BG = ui::Color { 22, 23, 25, 255 };
let BAR_FG = ui::Color { 168, 168, 162, 255 };
let NOTICE = ui::Color { 255, 190, 110, 255 };
let NONE = ui::Color { 0, 0, 0, 0 };

fn style_window(c: ui::Context) {
    var style = ui::style(c);
    style.window.fixed_background = ui::style_item_color(BG);
    style.window.padding = float2 { 0.0, 0.0 };
    style.window.border = 0.0;
    ui::set_style(c, style);
}

fn digits(n: i64) -> i64 {
    var d = 1;
    var x = n;
    while x >= 10 { x /= 10; d++; }
    return d;
}

// Lays the window out for its current size.
fn layout(ed: Editor&, v: View&, f: Fonts) {
    let size = gfx::screen_size();
    let w: f32 = size.x;
    let h: f32 = size.y;
    v.cell_w = f.cell_w;
    v.line_h = f.line_h;
    let bars = if v.bar != BAR_NONE { 2.0 } else { 1.0 };
    v.text_x = (max(digits(line_count(ed.t)), 3) + 2) * f.cell_w;
    v.text_y = round(f.line_h * 0.3);
    v.text_bottom = h - bars * f.line_h - round(f.line_h * 0.3);
    v.rows = max(floor((v.text_bottom - v.text_y) / f.line_h) as i64, 1);
    v.cols = max(floor((w - v.text_x - f.cell_w) / f.cell_w) as i64, 1);
}

// Scrolls so the primary caret is on screen.
fn follow_caret(ed: Editor&, v: View&) {
    let head = primary(ed).head;
    let n = line_of(ed.t, head);
    if n < v.top { v.top = n; }
    if n >= v.top + v.rows { v.top = n - v.rows + 1; }
    let col = col_of(ed.t, head);
    if col < v.left { v.left = max(col - 8, 0); }
    if col >= v.left + v.cols { v.left = col - v.cols + 8; }
}

fn clamp_scroll(ed: Editor&, v: View&) {
    v.top = clamp(v.top, 0, ed.t.lf);
    v.left = max(v.left, 0);
}

// The offset nearest to a point in pixels, clamped to the text area.
fn hit(ed: Editor&, v: View&, p: float2) -> i64 {
    let row = floor((p.y - v.text_y) / v.line_h) as i64;
    let n = clamp(v.top + row, 0, ed.t.lf);
    var line: u8[>..] = [];
    read_line(ed.t, n, line);
    let cells = (p.x - v.text_x) / v.cell_w + v.left;
    return line_start(ed.t, n) + offset_at_x(line, max(cells, 0.0));
}

fn cell_x(v: View&, col: i64) -> f32 { v.text_x + (col - v.left) * v.cell_w }

fn text_at(c: ui::Context, f: Fonts, x: f32, y: f32, cells: i64, s: const u8[:], color: ui::Color) {
    ui::draw_text(c, ui::rect(x, y, (cells + 1) * f.cell_w, f.line_h), s, f.font, NONE, color);
}

// One line of text at row `y`: runs of ordinary half-width characters are
// drawn together, wide ones one at a time on their two cells, and the
// invisible ones as marks.
fn draw_line(c: ui::Context, f: Fonts, v: View&, line: const u8[:], y: f32) {
    // Where the trailing blanks start, which get marks.
    var blank_from = line.len;
    while blank_from > 0 && (line[blank_from - 1] == ' ' || line[blank_from - 1] == '\t') { blank_from--; }
    let last_col = v.left + v.cols;
    let ty = y + round((f.line_h - f.cell_w * 2.0) * 0.5);
    var run_from = -1;          // the byte where the pending run starts
    var run_col = 0;
    var col = 0;
    var i = 0;
    while i < line.len && col < last_col {
        let cp, n = decode(line, i);
        let w = if cp == '\t' { TAB_SIZE - col % TAB_SIZE } else { cell_width(cp) };
        let plain = w == 1 && cp >= 0x20 && cp != 0x7F && cp != 0xFFFD && !(cp == ' ' && i >= blank_from);
        if plain && col >= v.left {
            if run_from < 0 { run_from = i; run_col = col; }
        } else if w == 0 && run_from >= 0 {
            // A combining mark rides on the run.
        } else {
            if run_from >= 0 {
                text_at(c, f, cell_x(v, run_col), ty, col - run_col, line[run_from..i], FG);
                run_from = -1;
            }
            if col >= v.left {
                let x = cell_x(v, col);
                if cp == '\t' {
                    let mid = y + round(f.line_h * 0.5);
                    ui::stroke_line(c, x + f.cell_w * 0.25, mid, x + w * f.cell_w - f.cell_w * 0.25, mid,
                                    max(round(f.cell_w * 0.1), 1.0), INVISIBLE);
                } else if cp == ' ' {
                    let d = max(round(f.cell_w * 0.2), 2.0);
                    ui::fill_rect(c, ui::rect(x + (f.cell_w - d) * 0.5, y + (f.line_h - d) * 0.5, d, d), 0.0, INVISIBLE);
                } else if cp == 0x3000 {
                    let inset = round(f.cell_w * 0.2);
                    ui::stroke_rect(c, ui::rect(x + inset, y + inset * 2.0, w * f.cell_w - inset * 2.0, f.line_h - inset * 4.0),
                                    0.0, max(round(f.cell_w * 0.1), 1.0), INVISIBLE);
                } else if cp < 0x20 || cp == 0x7F || cp == 0xFFFD {
                    ui::stroke_rect(c, ui::rect(x + 1.0, y + 2.0, f.cell_w - 2.0, f.line_h - 4.0), 0.0, 1.0, NOTICE);
                } else if w > 0 {
                    text_at(c, f, x, ty, w, line[i..i + n], FG);
                }
            }
        }
        col += w;
        i += n;
    }
    if run_from >= 0 { text_at(c, f, cell_x(v, run_col), ty, col - run_col, line[run_from..i], FG); }
}

// The part of [a, b) on a line starting at `ls` with text `line`, as cell
// columns; `past_end` when the range goes on beyond the line's break.
fn span_cols(line: const u8[:], ls: i64, a: i64, b: i64) -> i64, i64, bool {
    let lo_off = clamp(a - ls, 0, line.len);
    let hi_off = clamp(b - ls, 0, line.len);
    let ca = advance(line[..lo_off], 0);
    let cb = advance(line[lo_off..hi_off], ca);
    return ca, cb, b > ls + line.len;
}

fn fill_cols(c: ui::Context, v: View&, y: f32, ca: i64, cb: i64, color: ui::Color) {
    let a = max(ca, v.left);
    let b = min(cb, v.left + v.cols + 1);
    if b > a { ui::fill_rect(c, ui::rect(cell_x(v, a), y, (b - a) * v.cell_w, v.line_h), 0.0, color); }
}

fn draw_text_area(c: ui::Context, f: Fonts, ed: Editor&, v: View&, w: f32) {
    let t = ed.t;
    let p = primary(ed);
    let current = line_of(t, p.head);
    let blink_on = (clock() - v.blink_at) % 1.1 < 0.65 || clock() - v.blink_at < 0.6;
    var line: u8[>..] = [];
    var num: u8[>..] = [];
    for row in v.rows {
        let n = v.top + row;
        if n > t.lf { break; }
        let y = v.text_y + row * f.line_h;
        let ls = line_start(t, n);
        line.clear();
        read_line(t, n, line);
        let le = ls + line.len;
        if n == current && is_empty(p) {
            ui::fill_rect(c, ui::rect(0.0, y, w, f.line_h), 0.0, CURRENT_LINE);
        }
        // Matches of the search, on this line.
        if v.bar == BAR_FIND && v.query.len > 0 {
            var at = 0;
            loop {
                let k = find(line[at..], v.query);
                if k < 0 { break; }
                let ca, cb, past = span_cols(line, ls, ls + at + k, ls + at + k + v.query.len);
                fill_cols(c, v, y, ca, cb, MATCH);
                at += k + v.query.len;
            }
        }
        for s in ed.sels {
            if is_empty(s) || hi(s) < ls || lo(s) > le { continue; }
            let ca, cb, past = span_cols(line, ls, lo(s), hi(s));
            fill_cols(c, v, y, ca, if past { cb + 1 } else { cb }, SELECTION);
        }
        // The line number, right-aligned in the gutter.
        num.clear();
        format(num, n + 1);
        let nx = v.text_x - (num.len + 1) * f.cell_w;
        let ty = y + round((f.line_h - f.cell_w * 2.0) * 0.5);
        text_at(c, f, nx, ty, num.len, num, if n == current { GUTTER_FG_CURRENT } else { GUTTER_FG });
        draw_line(c, f, v, line, y);
        if blink_on {
            for s in ed.sels {
                if s.head < ls || s.head > le { continue; }
                let col = advance(line[..s.head - ls], 0);
                if col < v.left || col > v.left + v.cols { continue; }
                ui::fill_rect(c, ui::rect(cell_x(v, col) - 1.0, y, max(round(f.cell_w * 0.22), 2.0), f.line_h), 0.0, CARET);
            }
        }
    }
}

fn draw_bars(c: ui::Context, f: Fonts, ed: Editor&, v: View&, w: f32, h: f32) {
    let ty_off = round((f.line_h - f.cell_w * 2.0) * 0.5);
    var y = h - f.line_h;
    var s: u8[>..] = [];
    // The status bar: the file, the caret, and what the file is made of.
    ui::fill_rect(c, ui::rect(0.0, y, w, f.line_h), 0.0, BAR_BG);
    let p = primary(ed);
    let n = line_of(ed.t, p.head);
    s.append(if v.path.len > 0 { v.path[..] } else { "(無題)" });
    if modified(ed.h) { s.append(" ●"); }
    if v.readonly { s.append("  [読み取り専用]"); }
    format(s, "   行 ", n + 1, ", 桁 ", col_of(ed.t, p.head) + 1);
    if ed.sels.len > 1 { format(s, "   (", ed.sels.len, " 個のカーソル)"); }
    else if !is_empty(p) { format(s, "   (", hi(p) - lo(p), " バイト選択)"); }
    s.append(if v.info.utf8 { "   UTF-8" } else { "   UTF-8 ではありません" });
    if v.info.bom { s.append(" BOM"); }
    s.append(if ed.crlf { "   CRLF" } else { "   LF" });
    s.append(if ed.tabs { "   タブ" } else { "   スペース" });
    text_at(c, f, f.cell_w, y + ty_off, (w / f.cell_w) as i64, s, BAR_FG);
    if v.message.len > 0 && clock() - v.message_at < 4.0 {
        let mw = advance(v.message, 0) + 2;
        let x = max(w - mw * f.cell_w, w * 0.5);
        ui::fill_rect(c, ui::rect(x - f.cell_w, y, w - x + f.cell_w, f.line_h), 0.0, BAR_BG);
        text_at(c, f, x, y + ty_off, mw, v.message, NOTICE);
    }
    if v.bar == BAR_NONE { return; }
    // The field above it: search, or where to save.
    y -= f.line_h;
    ui::fill_rect(c, ui::rect(0.0, y, w, f.line_h), 0.0, CURRENT_LINE);
    s.clear();
    s.append(if v.bar == BAR_FIND { "検索: " } else { "保存先: " });
    let label_cells = advance(s, 0);
    s.append(v.query);
    text_at(c, f, f.cell_w, y + ty_off, (w / f.cell_w) as i64, s, FG);
    let caret_col = advance(s, 0);
    ui::fill_rect(c, ui::rect((caret_col + 1) * f.cell_w, y, max(round(f.cell_w * 0.22), 2.0), f.line_h), 0.0, CARET);
    if v.bar == BAR_FIND {
        let hint = "Enter: 次   Shift+Enter: 前   Esc: 閉じる";
        let hx = w - (advance(hint, 0) + 2) * f.cell_w;
        if hx > (caret_col + 4) * f.cell_w { text_at(c, f, hx, y + ty_off, advance(hint, 0), hint, GUTTER_FG); }
    }
}

fn draw(c: ui::Context, f: Fonts, ed: Editor&, v: View&) {
    layout(ed, v, f);
    if v.follow {
        follow_caret(ed, v);
        v.follow = false;
    }
    clamp_scroll(ed, v);
    let size = gfx::screen_size();
    let w: f32 = size.x;
    let h: f32 = size.y;
    if ui::begin(c, "weigh", ui::rect(0.0, 0.0, w, h), ui::WINDOW_NO_SCROLLBAR | ui::WINDOW_NO_INPUT) {
        draw_text_area(c, f, ed, v, w);
        draw_bars(c, f, ed, v, w, h);
    }
    ui::end(c);
}
