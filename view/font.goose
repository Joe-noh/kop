// The fonts: the system's (or the settings') font files at two sizes, the
// text's and the ui's, and the cell widths learned from them.
//
// A face is a list of fonts, first choice first, and each character is
// drawn with the first font that has it: a monospace font for code, then
// a Japanese one for what it lacks. Each font is baked with just the
// characters it draws. A font atlas is one texture, which the GPU allows
// only so tall, so a font with many characters at a large size is baked
// into several atlases, its characters split between them.

import std;
import os;
import math;
import ui;
import core.utf8;
import core.width;
import view.fontfile;

// The characters wanted, as first and last pairs: ASCII and Latin-1,
// Greek and Cyrillic, general punctuation through arrows, box drawing and
// dingbats, CJK punctuation and kana, the kanji, and full-width forms.
let WANTED_RANGES: u32[14] = [0x20, 0xFF, 0x370, 0x4FF, 0x2000, 0x27BF, 0x3000, 0x30FF,
                              0x31F0, 0x31FF, 0x4E00, 0x9FFF, 0xFF00, 0xFFEF];
let MAX_PARTS = 16;
let MAX_ATLAS_HEIGHT = 16384;
let NO_PART: u8 = 255;
// Nuklear finds a glyph by going through its font's ranges one by one, so
// ranges a few characters apart are baked as one, the characters between
// them included: a font that lacks a scattering of kanji would otherwise
// come in thousands of ranges and every glyph drawn would search them.
let RANGE_GAP: u32 = 16;

struct Face {
    parts: ui::Font[16],
    atlases: ui::FontAtlas[16],
    lift: f32[16],          // how far down to draw a part so its baseline meets the first one's
    primary: i64,           // parts[..primary] are the first font's, drawn in runs on the grid
    count: i64,
    table: i64,             // where this face's part for each codepoint starts in glyph_part
    cell_w: f32,            // the advance of a half-width character, in pixels
    line_h: f32,
}

struct Fonts { text: Face, ui: Face }

// For each face, 0x10000 entries: the part that draws each codepoint, or NO_PART.
var glyph_part: u8[>..] = [];
// For each face, the same: how far the glyph is from the left of its cells
// when centered in them, or ON_GRID for one whose advance is its cells'
// width, which is drawn in runs with its neighbors.
var glyph_inset: f32[>..] = [];
let ON_GRID: f32 = -1.0;

fn part_of(face: Face, cp: u32) -> i64 {
    if cp >= 0x10000 { return -1; }
    let p = glyph_part[face.table + cp];
    if p == NO_PART { -1 } else { p }
}

fn font_for(face: Face, cp: u32) -> ui::Font {
    let p = part_of(face, cp);
    face.parts[max(p, 0)]
}

// Bakes `chars` (ascending) into `n` atlases from part face.count on.
fn bake_shards(ttf: const u8[:], px: f32, cfg: ui::FontConfig, chars: const u32[:], n: i64, face: Face&) -> bool {
    let per = (chars.len + n - 1) / n;
    for k in n {
        let chunk = chars[min(k * per, chars.len)..min((k + 1) * per, chars.len)];
        var ranges: u32[>..] = [];
        var has_fallback = false;
        var i = 0;
        while i < chunk.len {
            var j = i;
            while j + 1 < chunk.len && chunk[j + 1] <= chunk[j] + RANGE_GAP + 1 { j++; }
            ranges.push(chunk[i]);
            ranges.push(chunk[j]);
            if chunk[i] <= '?' && chunk[j] >= '?' { has_fallback = true; }
            i = j + 1;
        }
        if !has_fallback { ranges.push('?'); ranges.push('?'); }    // every atlas needs the fallback
        let a = ui::create_font_atlas();
        face.atlases[face.count] = a;
        face.count++;
        let f = ui::add_font_from_memory(a, ttf, px, cfg, ranges);
        if f.id == 0 || !ui::bake(a) || ui::atlas_size(a).y > MAX_ATLAS_HEIGHT { return false; }
        face.parts[face.count - 1] = f;
        for cp in chunk { glyph_part[face.table + cp] = (face.count - 1) as u8; }
    }
    return true;
}

// Adds the font in `ttf` for the wanted characters no earlier font has.
fn add_font(face: Face&, ttf: const u8[:], px: f32, has: u8[>..]&) -> bool {
    coverage(ttf, has);
    var chars: u32[>..] = [];
    for k in WANTED_RANGES.len / 2 {
        for cp in WANTED_RANGES[2 * k]..WANTED_RANGES[2 * k + 1] + 1 {
            if has[cp] != 0 && glyph_part[face.table + cp] == NO_PART { chars.push(cp); }
        }
    }
    if chars.len == 0 { return true; }
    if face.count == 0 { return bake_group(face, ttf, px, ui::FontConfig {}, chars); }
    // A later font, most likely a Japanese one: its wide characters are
    // baked a little apart, so that each advances by exactly two of the
    // first font's cells and a run of them stays on the grid.
    let cell_w = ui::text_width(face.parts[0], "M");
    var wide: u32[>..] = [];
    var narrow: u32[>..] = [];
    for cp in chars { if eaw_width(cp) == 2 { wide.push(cp); } else { narrow.push(cp); } }
    var spaced = ui::FontConfig {};
    spaced.spacing = float2 { 2.0 * cell_w - px, 0.0 };
    return bake_group(face, ttf, px, spaced, wide) && bake_group(face, ttf, px, ui::FontConfig {}, narrow);
}

// Bakes `chars` in as few atlases as they fit.
fn bake_group(face: Face&, ttf: const u8[:], px: f32, cfg: ui::FontConfig, chars: const u32[:]) -> bool {
    if chars.len == 0 { return true; }
    let first = face.count;
    var n = 1;
    while first + n <= MAX_PARTS {
        if bake_shards(ttf, px, cfg, chars, n, face) { return true; }
        for k in first..face.count { ui::destroy(face.atlases[k]); }
        face.count = first;
        for cp in chars { glyph_part[face.table + cp] = NO_PART; }
        n *= 2;
    }
    return false;
}

// The face for `names` (font names or paths, one per line) at `px` pixels.
// What could not be used is said in `problems`; with no font at all, it is
// Nuklear's own, which has ASCII only.
fn load_face(names: const u8[:], px: f32, problems: u8[>..]&) -> Face, bool {
    var face = default<Face>();
    face.table = glyph_part.len;
    glyph_part.resize(face.table + 0x10000, NO_PART);
    glyph_inset.resize(face.table + 0x10000, 0.0);
    var has: u8[>..] = [];
    var path: u8[>..] = [];
    var raw: u8[>..] = [];
    var ttf: u8[>..] = [];
    each_split(names, '\n') {
        if it.len > 0 {
            path.clear();
            raw.clear();
            ttf.clear();
            if !resolve_font(it, path) {
                format(problems, "フォントが見つかりません: ", it, "; ");
            } else if !read_file(path, raw) || !single_font(raw, ttf) {
                format(problems, "フォントを読めません: ", path, "; ");
            } else if !add_font(face, ttf, px, has) {
                format(problems, "フォントが大きすぎます: ", path, "; ");
            } else if face.primary == 0 {
                face.primary = face.count;
            }
        }
    };
    if face.count == 0 {
        let a = ui::create_font_atlas();
        let f = ui::add_default_font(a, px);
        if f.id == 0 || !ui::bake(a) { return face, false; }
        face.atlases[0] = a;
        face.parts[0] = f;
        face.count = 1;
        face.primary = 1;
        for cp in 0x20..0x7F { glyph_part[face.table + cp] = 0; }
    }
    face.cell_w = ui::text_width(face.parts[0], "M");
    face.line_h = round(px * 1.45);
    let ascent = ui::info(face.parts[0]).ascent;
    for k in face.count { face.lift[k] = round(ascent - ui::info(face.parts[k]).ascent); }
    return face, true;
}

// Finds which characters advance by exactly their cells, and how far to
// move the others to center them.
fn measure_insets(face: Face) {
    for cp: u32 in 0..0x10000 {
        let p = part_of(face, cp);
        if p >= 0 {
            let g, own = ui::find_glyph(face.parts[p], cp);
            let room = cell_width(cp) * face.cell_w;
            glyph_inset[face.table + cp] = if abs(room - g.xadvance) < 0.01 { ON_GRID } else { max((room - g.xadvance) * 0.5, 0.0) };
        }
    }
}

// Records how many cells each character takes, from its advance.
fn learn_widths(face: Face) {
    cell_widths.resize(0x10000, 0);
    for cp: u32 in 0..0x10000 {
        let p = part_of(face, cp);
        if p >= 0 {
            let g, own = ui::find_glyph(face.parts[p], cp);
            let w = clamp(round(g.xadvance / face.cell_w) as i64, 0, 2);
            cell_widths[cp] = (w + 1) as u8;
        }
    }
}

// Draws `s` in a row of height face.line_h whose top is at `y`, on the
// grid of cells: characters that advance by their cells in runs, one draw
// for each run within one atlas, and the others each centered in its own
// cells.
fn draw_str(c: ui::Context, face: Face, x: f32, y: f32, s: const u8[:], color: ui::Color) {
    let ty = y + round((face.line_h - face.cell_w * 2.0) * 0.5);
    let none = ui::Color { 0, 0, 0, 0 };
    var run_from = 0;
    var run_col = 0;
    var run_part = -1;
    var col = 0;
    var i = 0;
    while i <= s.len {
        var p = -2;             // the end: flush the run
        var cp: u32 = 0;
        var n = 1;
        if i < s.len {
            cp, n = decode(s, i);
            p = max(part_of(face, cp), 0);
        }
        let in_run = p >= 0 && cp < 0x10000 && glyph_inset[face.table + cp] == ON_GRID;
        if !in_run || p != run_part {
            if run_part >= 0 && i > run_from {
                let f = face.parts[run_part];
                ui::draw_text(c, ui::rect(x + run_col * face.cell_w, ty + face.lift[run_part], (col - run_col + 1) * face.cell_w, face.line_h),
                              s[run_from..i], f, none, color);
            }
            run_part = if in_run { p } else { -1 };
            run_from = i;
            run_col = col;
        }
        if i == s.len { break; }
        let w = cell_width(cp);
        if !in_run && w > 0 {
            let inset = if cp < 0x10000 { glyph_inset[face.table + cp] } else { 0.0 };
            ui::draw_text(c, ui::rect(x + col * face.cell_w + inset, ty + face.lift[p], (w + 1) * face.cell_w, face.line_h),
                          s[i..i + n], face.parts[p], none, color);
            run_from = i + n;
            run_col = col + w;
        }
        col += w;
        i += n;
    }
}
