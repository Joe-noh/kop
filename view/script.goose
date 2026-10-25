// Input played back from a file, one line per frame, for tests that run
// without a window (GOOSE_GFX_HEADLESS=1):
//
//   text 日本語          typed text
//   key Return           a key pressed and released; "key Left GUI+S" holds the first ones
//   click 120 40 [2]     the left button at a pixel, clicked once or more
//   wait 10              ten frames of nothing
//   shot out.png         the screen, saved
//   quit

import std;
import os;
import gfx;

struct Script {
    lines: const u8[:][:],
    next: i64 = 0,
    wait: i64 = 0,
    done: bool = false,
}

fn press(names: const u8[:]) {
    let keys = split(names, '+');
    for k in keys { gfx::inject_key(k, true); }
    var i = keys.len;
    while i > 0 {
        i--;
        gfx::inject_key(keys[i], false);
    }
}

// Runs the next line; returns false once the script says to quit.
fn step(s: Script&) -> bool {
    if s.wait > 0 { s.wait--; return true; }
    if s.next >= s.lines.len { return !s.done; }
    let line = s.lines[s.next];
    s.next++;
    let sp = find(line, " ");
    let cmd = if sp < 0 { line } else { line[..sp] };
    let arg = if sp < 0 { line[line.len..] } else { line[sp + 1..] };
    if cmd == "text" { gfx::inject_text(arg); }
    else if cmd == "key" { press(arg); }
    else if cmd == "click" {
        let parts = words(arg);
        let x, okx = parse_flt(parts[0]);
        let y, oky = parse_flt(parts[1]);
        var n = 1;
        if parts.len > 2 { let c, okc = parse_int(parts[2]); n = c; }
        for i in n {
            gfx::inject_mouse(x as f32, y as f32, gfx::MOUSE_LEFT, true);
            gfx::inject_mouse(x as f32, y as f32, gfx::MOUSE_LEFT, false);
        }
    }
    else if cmd == "wait" { let n, ok = parse_int(arg); s.wait = n; }
    else if cmd == "shot" { gfx::screenshot(arg); }
    else if cmd == "quit" { s.done = true; return false; }
    else if cmd.len > 0 && cmd[0] != '#' { write_stderr(str("script: unknown command: ", line, "\n")); }
    return true;
}
