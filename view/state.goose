// What the window shows and what it is in the middle of, apart from the
// document itself.

import std;
import os;
import core.doc;

let BAR_NONE = 0;
let BAR_FIND = 1;           // the search field at the bottom
let BAR_SAVE_AS = 2;        // asking where to save an untitled document

let DRAG_NONE = 0;
let DRAG_CHARS = 1;
let DRAG_WORDS = 2;
let DRAG_LINES = 3;

struct View {
    path: u8[..1024],
    info: FileInfo,
    readonly: bool = false,
    // The grid: the first line and cell column shown, how many fit, and
    // where the text starts, in pixels.
    top: i64 = 0,
    left: i64 = 0,
    rows: i64 = 1,
    cols: i64 = 1,
    panel_w: f32 = 0.0,             // the file tree's width, left of the text
    text_x: f32 = 0.0,
    text_y: f32 = 0.0,
    text_bottom: f32 = 0.0,
    cell_w: f32 = 8.0,              // the text's cells
    line_h: f32 = 16.0,
    ui_cell_w: f32 = 8.0,           // the tree's and the bars'
    ui_line_h: f32 = 16.0,
    tree_y: f32 = 0.0,              // where the tree's header row starts
    tree_bottom: f32 = 0.0,
    tree_rows: i64 = 1,             // entry rows that fit below the header
    follow: bool = true,            // scroll to the primary caret at the next draw
    wheel: f32 = 0.0,               // scrolling not yet a whole line
    drag: i64 = DRAG_NONE,
    drag_a: i64 = 0,                // the word or line first clicked, for drags by words or lines
    drag_b: i64 = 0,
    bar: i64 = BAR_NONE,
    query: u8[..256],
    message: u8[..240],
    message_at: f64 = 0.0,
    blink_at: f64 = 0.0,            // the caret shows steadily for a moment after it moves
    quit: bool = false,
    // A file picked in the tree, to open once this document lets go of the
    // window; picking it again while this one has unsaved changes drops them.
    open_request: bool = false,
    open_path: u8[..1024],
    discard_path: u8[..1024],
}

fn say(v: View&, text: const u8[:]) {
    v.message.resize(0, 0);
    v.message.append(text[..min(text.len, 240)]);
    v.message_at = clock();
}
