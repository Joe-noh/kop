// Color themes, chosen with "theme" in the settings.

import std;
import ui;

struct Theme {
    bg: ui::Color,                  // the text's background
    fg: ui::Color,
    gutter_fg: ui::Color,           // line numbers
    gutter_fg_current: ui::Color,   // the caret's line number
    current_line: ui::Color,        // the caret's line
    selection: ui::Color,
    match_bg: ui::Color,            // what the search finds
    caret: ui::Color,
    invisible: ui::Color,           // tabs, trailing spaces, full-width spaces
    bar_bg: ui::Color,              // the status bar
    bar_fg: ui::Color,
    field_bg: ui::Color,            // the search field
    hint_fg: ui::Color,             // hints, the tree's heading and its triangles
    notice: ui::Color,              // messages
    panel_bg: ui::Color,            // the tree
    panel_edge: ui::Color,
    panel_current: ui::Color,       // the row of the file being edited
    tree_fg: ui::Color,             // a file's name
    tree_dir_fg: ui::Color,         // a directory's
    tree_current_fg: ui::Color,     // the file being edited
    tokens: ui::Color[12],          // by TOK_* value
}

fn rgb(r: u8, g: u8, b: u8) -> ui::Color { ui::Color { r, g, b, 255 } }

// Flexoki dark (https://github.com/kepano/flexoki), as its Helix theme uses it.
fn flexoki_dark() -> Theme {
    let base = rgb(0x10, 0x0F, 0x0F);
    let bg_2 = rgb(0x1C, 0x1B, 0x1A);
    let ui_2 = rgb(0x28, 0x27, 0x26);
    let ui_3 = rgb(0x34, 0x33, 0x31);
    let tx = rgb(0xCE, 0xCD, 0xC3);
    let tx_1 = rgb(0xB7, 0xB5, 0xAC);
    let tx_2 = rgb(0x87, 0x85, 0x80);
    let tx_3 = rgb(0x57, 0x56, 0x53);
    let orange = rgb(0xDA, 0x70, 0x2C);
    let yellow = rgb(0xD0, 0xA2, 0x15);
    let green = rgb(0x87, 0x9A, 0x39);
    let cyan = rgb(0x3A, 0xA9, 0x9F);
    let blue = rgb(0x43, 0x85, 0xBE);
    return Theme {
        bg: base, fg: tx,                               // ui.background
        gutter_fg: ui_3, gutter_fg_current: cyan,       // ui.linenr, ui.linenr.selected
        current_line: bg_2,                             // ui.cursorline.primary
        selection: ui_3,                                // ui.selection
        match_bg: ui_2,
        caret: cyan,                                    // ui.cursor.primary
        invisible: tx_3,                                // ui.virtual
        bar_bg: bg_2, bar_fg: tx_1,                     // ui.statusline
        field_bg: ui_2,                                 // ui.popup
        hint_fg: tx_2,                                  // ui.help
        notice: yellow,                                 // warning
        panel_bg: bg_2, panel_edge: ui_2, panel_current: ui_2,     // ui.text.focus
        tree_fg: tx, tree_dir_fg: blue, tree_current_fg: tx,       // ui.text.directory
        // text, keyword, type, constant, number, string, comment (italic in
        // Helix; ui has no italic), function, tag, attribute, property
        // (variable.other.member) and variable (the same)
        tokens: [tx, green, yellow, orange, orange, cyan, tx_3, orange, blue, blue, blue, blue],
    };
}

// Spacegray (https://github.com/SublimeText/Spacegray): its theme for the
// window around the text, and Base16 Ocean Dark, its color scheme, for the
// text. The theme's labels are a step brighter than its own (base02 and
// base03), which are hard to read.
fn spacegray() -> Theme {
    let base_00 = rgb(28, 31, 38);
    let base_01 = rgb(35, 40, 48);
    let base00 = rgb(43, 48, 59);
    let base01 = rgb(52, 61, 70);
    let base02 = rgb(79, 91, 102);
    let base03 = rgb(101, 115, 126);
    let base04 = rgb(167, 173, 186);
    let base05 = rgb(192, 197, 206);
    let base06 = rgb(223, 225, 232);
    let base08 = rgb(191, 97, 106);
    let base09 = rgb(208, 135, 112);
    let base0a = rgb(235, 203, 139);
    let base0b = rgb(163, 190, 140);
    let base0d = rgb(143, 161, 179);
    let base0e = rgb(180, 142, 173);
    return Theme {
        bg: base00, fg: base05,                         // background, foreground
        gutter_fg: base03, gutter_fg_current: base05,   // gutter_foreground(_highlight)
        current_line: rgb(49, 55, 66),                  // line_highlight: base03 at 10% over base00
        selection: base02,
        match_bg: base01,
        caret: base05,
        invisible: base03,                              // invisibles
        bar_bg: base_00, bar_fg: base04,                // status_bar and its labels
        field_bg: base_00,                              // panel_control, text_line_control
        hint_fg: base03,                                // sidebar_heading, disclosure_button_control
        notice: base0a,                                 // accent
        panel_bg: base_01, panel_edge: base_00, panel_current: base01,   // sidebar_container, selected tree_row
        tree_fg: base04, tree_dir_fg: base04, tree_current_fg: base06,   // sidebar_label, selected
        // text, keyword, type (classes), constant, number, string, comment,
        // function, tag, attribute (-name), property (support.type.property-name),
        // variable
        tokens: [base05, base0e, base0a, base09, base09, base0b, base03, base0d, base08, base09, base0e, base06],
    };
}

let THEME_NAMES = "flexoki-dark, spacegray";

fn theme_named(name: const u8[:]) -> Theme, bool {
    if name == "flexoki-dark" { return flexoki_dark(), true; }
    if name == "spacegray" { return spacegray(), true; }
    return flexoki_dark(), false;
}

// The theme in use.
var theme = flexoki_dark();
