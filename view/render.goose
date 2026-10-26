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
import view.tree;

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
let PANEL_BG = ui::Color { 25, 26, 29, 255 };
let PANEL_EDGE = ui::Color { 44, 46, 51, 255 };
let PANEL_CURRENT = ui::Color { 44, 52, 66, 255 };
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
// The text is laid out in the text face's cells, the tree and the bars in
// the ui face's.
fn layout(ed: Editor&, v: View&, tr: Tree&, f: Fonts) {
    let size = gfx::screen_size();
    let w: f32 = size.x;
    let h: f32 = size.y;
    let tf = f.text;
    let uf = f.ui;
    v.cell_w = tf.cell_w;
    v.line_h = tf.line_h;
    v.ui_cell_w = uf.cell_w;
    v.ui_line_h = uf.line_h;
    let bars_h = (if v.bar != BAR_NONE { 2.0 } else { 1.0 }) * uf.line_h;
    v.panel_w = if tr.shown { tr.width * uf.cell_w } else { 0.0 };
    v.text_x = v.panel_w + (max(digits(line_count(ed.t)), 3) + 2) * tf.cell_w;
    v.text_y = round(tf.line_h * 0.3);
    v.text_bottom = h - bars_h - round(tf.line_h * 0.3);
    v.rows = max(floor((v.text_bottom - v.text_y) / tf.line_h) as i64, 1);
    v.cols = max(floor((w - v.text_x - tf.cell_w) / tf.cell_w) as i64, 1);
    v.tree_y = round(uf.line_h * 0.3);
    v.tree_bottom = h - bars_h;
    v.tree_rows = max(floor((v.tree_bottom - v.tree_y) / uf.line_h) as i64 - 1, 1);
    tr.top = clamp(tr.top, 0, max(tr.rows.len - v.tree_rows, 0));
}

// Scrolls so the primary caret is on screen.
fn follow_caret(ed: Editor&, v: View&) {
    let head = primary(ed).head;
    let n = line_of(ed.t, head);
    if n < v.top || (n == v.top && v.scroll_y > 0.0) { v.top = n; v.scroll_y = 0.0; }
    if n >= v.top + v.rows { v.top = n - v.rows + 1; v.scroll_y = 0.0; }
    let col = col_of(ed.t, head);
    if col < v.left { v.left = max(col - 8, 0); }
    if col >= v.left + v.cols { v.left = col - v.cols + 8; }
}

fn clamp_scroll(ed: Editor&, v: View&) {
    // Whole lines of the pixel scroll go into the top line.
    let lines = floor(v.scroll_y / v.line_h);
    v.top += lines as i64;
    v.scroll_y -= lines * v.line_h;
    if v.top < 0 { v.top = 0; v.scroll_y = 0.0; }
    if v.top >= ed.t.lf { v.top = ed.t.lf; v.scroll_y = 0.0; }
    v.left = max(v.left, 0);
}

// The offset nearest to a point in pixels, clamped to the text area.
fn hit(ed: Editor&, v: View&, p: float2) -> i64 {
    let row = floor((p.y - v.text_y + v.scroll_y) / v.line_h) as i64;
    let n = clamp(v.top + row, 0, ed.t.lf);
    var line: u8[>..] = [];
    read_line(ed.t, n, line);
    let cells = (p.x - v.text_x) / v.cell_w + v.left;
    return line_start(ed.t, n) + offset_at_x(line, max(cells, 0.0));
}

fn cell_x(v: View&, col: i64) -> f32 { v.text_x + (col - v.left) * v.cell_w }

// One line of text at row `y`: runs of ordinary characters go to
// draw_str together, which keeps them on the grid, and the invisible ones
// are drawn as marks.
fn draw_line(c: ui::Context, f: Face, v: View&, line: const u8[:], y: f32) {
    // Where the trailing blanks start, which get marks.
    var blank_from = line.len;
    while blank_from > 0 && (line[blank_from - 1] == ' ' || line[blank_from - 1] == '\t') { blank_from--; }
    let last_col = v.left + v.cols;
    var run_from = -1;          // the byte where the pending run starts
    var run_col = 0;
    var col = 0;
    var i = 0;
    while i < line.len && col < last_col {
        let cp, n = decode(line, i);
        let w = if cp == '\t' { TAB_SIZE - col % TAB_SIZE } else { cell_width(cp) };
        let plain = w >= 1 && cp >= 0x20 && cp != 0x7F && cp != 0xFFFD && cp != 0x3000 && cp != '\t' &&
                    !(cp == ' ' && i >= blank_from);
        if plain && col >= v.left {
            if run_from < 0 { run_from = i; run_col = col; }
        } else if w == 0 && run_from >= 0 {
            // A combining mark rides on the run.
        } else {
            if run_from >= 0 {
                draw_str(c, f, cell_x(v, run_col), y, line[run_from..i], FG);
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
                    draw_str(c, f, x, y, line[i..i + n], FG);
                }
            }
        }
        col += w;
        i += n;
    }
    if run_from >= 0 { draw_str(c, f, cell_x(v, run_col), y, line[run_from..i], FG); }
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

fn draw_text_area(c: ui::Context, f: Face, ed: Editor&, v: View&, w: f32) {
    let t = ed.t;
    let p = primary(ed);
    let current = line_of(t, p.head);
    let blink_on = (clock() - v.blink_at) % 1.1 < 0.65 || clock() - v.blink_at < 0.6;
    var line: u8[>..] = [];
    var num: u8[>..] = [];
    // One more row than fits: when scrolled part of a line, it shows at the bottom.
    for row in v.rows + 1 {
        let n = v.top + row;
        if n > t.lf { break; }
        let y = v.text_y + row * f.line_h - v.scroll_y;
        let ls = line_start(t, n);
        line.clear();
        read_line(t, n, line);
        let le = ls + line.len;
        if n == current && is_empty(p) {
            ui::fill_rect(c, ui::rect(v.panel_w, y, w - v.panel_w, f.line_h), 0.0, CURRENT_LINE);
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
        draw_str(c, f, nx, y, num, if n == current { GUTTER_FG_CURRENT } else { GUTTER_FG });
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

fn draw_bars(c: ui::Context, f: Face, ed: Editor&, v: View&, w: f32, h: f32) {
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
    draw_str(c, f, f.cell_w, y, s, BAR_FG);
    if v.message.len > 0 && clock() - v.message_at < 4.0 {
        let mw = advance(v.message, 0) + 2;
        let x = max(w - mw * f.cell_w, w * 0.5);
        ui::fill_rect(c, ui::rect(x - f.cell_w, y, w - x + f.cell_w, f.line_h), 0.0, BAR_BG);
        draw_str(c, f, x, y, v.message, NOTICE);
    }
    if v.bar == BAR_NONE { return; }
    // The field above it: search, or where to save.
    y -= f.line_h;
    ui::fill_rect(c, ui::rect(0.0, y, w, f.line_h), 0.0, CURRENT_LINE);
    s.clear();
    s.append(if v.bar == BAR_FIND { "検索: " } else { "保存先: " });
    s.append(v.query);
    draw_str(c, f, f.cell_w, y, s, FG);
    let caret_col = advance(s, 0);
    ui::fill_rect(c, ui::rect((caret_col + 1) * f.cell_w, y, max(round(f.cell_w * 0.22), 2.0), f.line_h), 0.0, CARET);
    if v.bar == BAR_FIND {
        let hint = "Enter: 次   Shift+Enter: 前   Esc: 閉じる";
        let hx = w - (advance(hint, 0) + 2) * f.cell_w;
        if hx > (caret_col + 4) * f.cell_w { draw_str(c, f, hx, y, hint, GUTTER_FG); }
    }
}

// The tree's row at a point: -1 for its header, -2 for none.
fn tree_row_at(v: View&, tr: Tree&, p: float2) -> i64 {
    let row = floor((p.y - v.tree_y) / v.ui_line_h) as i64;
    if row < 0 || p.y >= v.tree_bottom { return -2; }
    if row == 0 { return -1; }
    let i = tr.top + row - 1;
    if i >= tr.rows.len { -2 } else { i }
}

// The tree: the directory's name, then a row per entry, indented by depth;
// the file being edited is marked.
fn draw_tree(c: ui::Context, f: Face, v: View&, tr: Tree&) {
    let pw = v.panel_w;
    ui::fill_rect(c, ui::rect(0.0, 0.0, pw, v.tree_bottom), 0.0, PANEL_BG);
    ui::fill_rect(c, ui::rect(pw - 1.0, 0.0, 1.0, v.tree_bottom), 0.0, PANEL_EDGE);
    var s: u8[>..] = [];
    let root = tr.root[..];
    let k = rfind(root, "/");
    fit(if k < 0 || k == root.len - 1 { root } else { root[k + 1..] }, tr.width - 2, s);
    draw_str(c, f, f.cell_w, v.tree_y, s, GUTTER_FG_CURRENT);
    for row in v.tree_rows {
        let i = tr.top + row;
        if i >= tr.rows.len { break; }
        let e = tr.rows[i];
        let y = v.tree_y + (row + 1) * f.line_h;
        if !e.is_dir && path_of(tr, e) == v.path[..] {
            ui::fill_rect(c, ui::rect(0.0, y, pw - 1.0, f.line_h), 0.0, PANEL_CURRENT);
        }
        let indent = 1 + e.depth * 2;
        if e.is_dir {
            // A small triangle: right when closed, down when open.
            let cx = (indent + 0.5) * f.cell_w;
            let cy = y + f.line_h * 0.5;
            let r = f.cell_w * 0.35;
            if e.open { ui::fill_triangle(c, cx - r, cy - r * 0.6, cx + r, cy - r * 0.6, cx, cy + r * 0.8, GUTTER_FG); }
            else { ui::fill_triangle(c, cx - r * 0.6, cy - r, cx - r * 0.6, cy + r, cx + r * 0.8, cy, GUTTER_FG); }
        }
        s.clear();
        fit(name_of(tr, e), tr.width - indent - 3, s);
        draw_str(c, f, (indent + 2) * f.cell_w, y, s, if e.is_dir { BAR_FG } else { FG });
    }
}

fn draw(c: ui::Context, f: Fonts, ed: Editor&, v: View&, tr: Tree&) {
    layout(ed, v, tr, f);
    clamp_scroll(ed, v);
    if v.follow {
        follow_caret(ed, v);
        v.follow = false;
        clamp_scroll(ed, v);
    }
    let size = gfx::screen_size();
    let w: f32 = size.x;
    let h: f32 = size.y;
    if ui::begin(c, "kop", ui::rect(0.0, 0.0, w, h), ui::WINDOW_NO_SCROLLBAR | ui::WINDOW_NO_INPUT) {
        if tr.shown { draw_tree(c, f.ui, v, tr); }
        draw_text_area(c, f.text, ed, v, w);
        draw_bars(c, f.ui, ed, v, w, h);
    }
    ui::end(c);
}
