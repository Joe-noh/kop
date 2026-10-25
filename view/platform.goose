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
