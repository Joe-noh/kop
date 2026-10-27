// What gfx does not expose and SDL itself does: the window, for its size in
// points and for where the input method shows its candidates.

import std;

struct SdlRect { x: i32, y: i32, w: i32, h: i32 }

extern fn SDL_GetWindowFromID(id: u32) -> u64;
extern fn SDL_GetWindowSize(w: u64, width: i32&, height: i32&) -> bool;
extern fn SDL_SetTextInputArea(w: u64, rect: const SdlRect&, cursor: i32) -> bool;

// gfx's window: the only one there is.
fn sdl_window() -> u64 {
    for id: u32 in 1..64 {
        let w = SDL_GetWindowFromID(id);
        if w != 0 { return w; }
    }
    return 0;
}

// Pixels per point: 2 on a Retina display.
fn pixel_density(w: u64, pixel_width: i64) -> f32 {
    var pw: i32 = 0;
    var ph: i32 = 0;
    if w == 0 || !SDL_GetWindowSize(w, pw, ph) || pw <= 0 { return 1.0; }
    return pixel_width as f32 / pw;
}

// Tells the input method where the caret is, in pixels, so its candidate
// window opens beside it.
fn set_ime_caret(w: u64, density: f32, x: f32, y: f32, h: f32) {
    if w == 0 { return; }
    let r = SdlRect { (x / density) as! i32, (y / density) as! i32, 1, max((h / density) as! i32, 1) };
    SDL_SetTextInputArea(w, r, 0);
}

// The mouse's cursor, which gfx leaves as the system's arrow: SDL's own
// cursors, made once, and set when the one wanted changes.
extern fn SDL_CreateSystemCursor(id: i32) -> u64;
extern fn SDL_SetCursor(cursor: u64) -> bool;

let CURSOR_ARROW: i32 = 0;          // SDL_SYSTEM_CURSOR_DEFAULT
let CURSOR_TEXT: i32 = 1;           // SDL_SYSTEM_CURSOR_TEXT, an I-beam
let CURSOR_POINTER: i32 = 11;       // SDL_SYSTEM_CURSOR_POINTER, a pointing hand

struct Cursors { arrow: u64, text: u64, pointer: u64, shown: i32 }

fn make_cursors() -> Cursors {
    Cursors {
        arrow: SDL_CreateSystemCursor(CURSOR_ARROW),
        text: SDL_CreateSystemCursor(CURSOR_TEXT),
        pointer: SDL_CreateSystemCursor(CURSOR_POINTER),
        shown: CURSOR_ARROW,
    }
}

fn show_cursor(c: Cursors&, which: i32) {
    if which == c.shown { return; }
    let handle = if which == CURSOR_TEXT { c.text } else if which == CURSOR_POINTER { c.pointer } else { c.arrow };
    if handle != 0 { SDL_SetCursor(handle); }
    c.shown = which;
}
