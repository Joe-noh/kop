// Color themes, chosen with "theme" in the settings.

const std = @import("std");
const Tok = @import("../core/syntax/lang.zig").Tok;

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

pub const Theme = struct {
    bg: Color, // the text's background
    fg: Color,
    gutter_fg: Color, // line numbers
    gutter_fg_current: Color, // the caret's line number
    current_line: Color, // the caret's line
    selection: Color,
    match_bg: Color, // what the search finds
    caret: Color,
    invisible: Color, // tabs, trailing spaces, full-width spaces
    bar_bg: Color, // the status bar
    bar_fg: Color,
    field_bg: Color, // the search field
    hint_fg: Color, // hints, the tree's heading and its triangles
    notice: Color, // messages
    panel_bg: Color, // the tree
    panel_edge: Color,
    panel_current: Color, // the row of the file being edited
    tree_fg: Color, // a file's name
    tree_dir_fg: Color, // a directory's
    tree_current_fg: Color, // the file being edited
    changed: Color, // a file git says is modified, and its changed lines
    added: Color, // a new file, and lines added
    removed: Color, // a deleted file, and lines removed
    added_bg: Color, // behind lines added, where a diff shows them
    removed_bg: Color, // and lines removed
    tokens: [@typeInfo(Tok).@"enum".fields.len]Color, // by Tok

    pub fn token(t: *const Theme, kind: Tok) Color {
        return t.tokens[@intFromEnum(kind)];
    }
};

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b };
}

// `b` laid over `a`, `t` of the way.
fn mix(a: Color, b: Color, t: f32) Color {
    const m = struct {
        fn f(x: u8, y: u8, k: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k));
        }
    }.f;
    return .{ .r = m(a.r, b.r, t), .g = m(a.g, b.g, t), .b = m(a.b, b.b, t) };
}

// Flexoki dark (https://github.com/kepano/flexoki), as its Helix theme uses it.
pub fn flexokiDark() Theme {
    const base = rgb(0x10, 0x0F, 0x0F);
    const bg_2 = rgb(0x1C, 0x1B, 0x1A);
    const ui_2 = rgb(0x28, 0x27, 0x26);
    const ui_3 = rgb(0x34, 0x33, 0x31);
    const tx = rgb(0xCE, 0xCD, 0xC3);
    const tx_1 = rgb(0xB7, 0xB5, 0xAC);
    const tx_2 = rgb(0x87, 0x85, 0x80);
    const tx_3 = rgb(0x57, 0x56, 0x53);
    const orange = rgb(0xDA, 0x70, 0x2C);
    const yellow = rgb(0xD0, 0xA2, 0x15);
    const green = rgb(0x87, 0x9A, 0x39);
    const cyan = rgb(0x3A, 0xA9, 0x9F);
    const blue = rgb(0x43, 0x85, 0xBE);
    return .{
        .bg = base,
        .fg = tx, // ui.background
        .gutter_fg = ui_3,
        .gutter_fg_current = cyan, // ui.linenr, ui.linenr.selected
        .current_line = bg_2, // ui.cursorline.primary
        .selection = ui_3, // ui.selection
        .match_bg = ui_2,
        .caret = cyan, // ui.cursor.primary
        .invisible = tx_3, // ui.virtual
        .bar_bg = bg_2,
        .bar_fg = tx_1, // ui.statusline
        .field_bg = ui_2, // ui.popup
        .hint_fg = tx_2, // ui.help
        .notice = yellow, // warning
        .panel_bg = bg_2,
        .panel_edge = ui_2,
        .panel_current = ui_2, // ui.text.focus
        .tree_fg = tx,
        .tree_dir_fg = blue,
        .tree_current_fg = tx, // ui.text.directory
        .changed = yellow,
        .added = green,
        .removed = rgb(0xD1, 0x4D, 0x41), // red
        .added_bg = mix(base, green, 0.16),
        .removed_bg = mix(base, rgb(0xD1, 0x4D, 0x41), 0.16),
        // text, keyword, type, constant, number, string, comment (italic in
        // Helix), function, tag, attribute, property (variable.other.member)
        // and variable (the same)
        .tokens = .{ tx, green, yellow, orange, orange, cyan, tx_3, orange, blue, blue, blue, blue },
    };
}

// Spacegray (https://github.com/SublimeText/Spacegray): its theme for the
// window around the text, and Base16 Ocean Dark, its color scheme, for the
// text. The theme's labels are a step brighter than its own (base02 and
// base03), which are hard to read.
pub fn spacegray() Theme {
    const base_00 = rgb(28, 31, 38);
    const base_01 = rgb(35, 40, 48);
    const base00 = rgb(43, 48, 59);
    const base01 = rgb(52, 61, 70);
    const base02 = rgb(79, 91, 102);
    const base03 = rgb(101, 115, 126);
    const base04 = rgb(167, 173, 186);
    const base05 = rgb(192, 197, 206);
    const base06 = rgb(223, 225, 232);
    const base08 = rgb(191, 97, 106);
    const base09 = rgb(208, 135, 112);
    const base0a = rgb(235, 203, 139);
    const base0b = rgb(163, 190, 140);
    const base0d = rgb(143, 161, 179);
    const base0e = rgb(180, 142, 173);
    return .{
        .bg = base00,
        .fg = base05, // background, foreground
        .gutter_fg = base03,
        .gutter_fg_current = base05, // gutter_foreground(_highlight)
        .current_line = rgb(49, 55, 66), // line_highlight: base03 at 10% over base00
        .selection = base02,
        .match_bg = base01,
        .caret = base05,
        .invisible = base03, // invisibles
        .bar_bg = base_00,
        .bar_fg = base04, // status_bar and its labels
        .field_bg = base_00, // panel_control, text_line_control
        .hint_fg = base03, // sidebar_heading, disclosure_button_control
        .notice = base0a, // accent
        .panel_bg = base_01,
        .panel_edge = base_00,
        .panel_current = base01, // sidebar_container, selected tree_row
        .tree_fg = base04,
        .tree_dir_fg = base04,
        .tree_current_fg = base06, // sidebar_label, selected
        .changed = base0a,
        .added = base0b,
        .removed = base08,
        .added_bg = mix(base00, base0b, 0.16),
        .removed_bg = mix(base00, base08, 0.16),
        // text, keyword, type (classes), constant, number, string, comment,
        // function, tag, attribute (-name), property (support.type.property-name),
        // variable
        .tokens = .{ base05, base0e, base0a, base09, base09, base0b, base03, base0d, base08, base09, base0e, base06 },
    };
}

pub const names = "flexoki-dark, spacegray";

pub fn named(name: []const u8) ?Theme {
    if (std.mem.eql(u8, name, "flexoki-dark")) return flexokiDark();
    if (std.mem.eql(u8, name, "spacegray")) return spacegray();
    return null;
}

// The theme in use.
pub var current: Theme = flexokiDark();
