// The text font: one Japanese monospace font baked at the display's pixel
// size, and the cell widths learned from it.

import std;
import ui;
import core.width;

// What is baked, as first and last pairs: ASCII and Latin-1, Greek and
// Cyrillic, general punctuation through arrows, box drawing and dingbats,
// CJK punctuation and kana, the unified kanji, and full-width forms.
let GLYPH_RANGES: u32[14] = [0x20, 0xFF, 0x370, 0x4FF, 0x2000, 0x27BF, 0x3000, 0x30FF,
                             0x31F0, 0x31FF, 0x4E00, 0x9FFF, 0xFF00, 0xFFEF];

struct Fonts {
    atlas: ui::FontAtlas,
    font: ui::Font,
    cell_w: f32,            // the advance of a half-width character, in pixels
    line_h: f32,
}

fn load_font(ttf: const u8[:], px: f32) -> Fonts, bool {
    let atlas = ui::create_font_atlas();
    let font = ui::add_font_from_memory(atlas, ttf, px, ui::FontConfig {}, GLYPH_RANGES);
    if font.id == 0 || !ui::bake(atlas) { return Fonts { atlas, font, 0.0, 0.0 }, false; }
    let cell_w = ui::text_width(font, "M");
    return Fonts { atlas: atlas, font: font, cell_w: cell_w, line_h: round(px * 1.45) }, true;
}

// Records how many cells each baked character takes, from its advance.
fn learn_widths(f: Fonts) {
    cell_widths.resize(0x10000, 0);
    for k in GLYPH_RANGES.len / 2 {
        for cp in GLYPH_RANGES[2 * k]..GLYPH_RANGES[2 * k + 1] + 1 {
            let g, own = ui::find_glyph(f.font, cp);
            if own {
                let w = clamp(round(g.xadvance / f.cell_w) as i64, 0, 2);
                cell_widths[cp] = (w + 1) as u8;
            }
        }
    }
}
