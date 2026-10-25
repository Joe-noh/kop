// weigh: a text editor.
//
//   goose weigh.goose -- [file]                run it in the compiler
//   goose build weigh.goose && ./weigh [file]  or build it
//
// Options after the file: --script <file> plays input back (view/script.goose),
// --frames <n> stops after n frames, --profile prints how long loading and
// frames take.

import std;
import os;
import math;
import gfx;
import ui;
import core.text;
import core.select;
import core.undo;
import core.edit;
import core.doc;
import core.motion;
import view.state;
import view.font;
import view.render;
import view.input;
import view.platform;
import view.script;

// BIZ UDGothic (SIL Open Font License, assets/OFL.txt), built into the program.
let FONT: const u8[:] = embed_file("assets/BIZUDGothic-Regular.ttf");
let FONT_POINTS: f32 = 15.0;

fn basename(path: const u8[:]) -> const u8[:] {
    let k = rfind(path, "/");
    if k < 0 { path } else { path[k + 1..] }
}

// A modified document the window was closed on goes to ~/.weigh/recovery,
// since closing cannot be refused.
fn keep_recovery(ed: Editor&, v: View&) {
    var home: u8[>..] = [];
    if !env("HOME", home) { return; }
    let dir = str(home, "/.weigh");
    let rec = str(dir, "/recovery");
    if !make_dir(dir) || !make_dir(rec) { return; }
    let name = if v.path.len > 0 { basename(v.path) } else { "untitled" };
    let path = str(rec, "/", name, ".", time() as i64);
    if save(ed.t, v.info, path) { write_stderr(str("weigh: unsaved changes kept in ", path, "\n")); }
}

fn title_of(v: View&, dirty: bool) -> u8[>..] {
    str(if dirty { "● " } else { "" }, if v.path.len > 0 { basename(v.path) } else { "(無題)" }, " — weigh")
}

fn main() {
    let argv = args();
    var path_arg: u8[>..] = [];
    var script_path: u8[>..] = [];
    var frames = -1;
    var profile = false;
    let started = clock();
    var i = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "--script" && i + 1 < argv.len { script_path.append(argv[i + 1]); i++; }
        else if a == "--frames" && i + 1 < argv.len { let n, ok = parse_int(argv[i + 1]); frames = n; i++; }
        else if a == "--profile" { profile = true; }
        else { path_arg.clear(); path_arg.append(a); }
        i++;
    }

    // The file, read whole, and where its lines start.
    var file: u8[>..] = [];
    var opened_ok = true;
    if path_arg.len > 0 && file_exists(path_arg) { opened_ok = read_file(path_arg, file); }
    let info = detect(file);
    let orig = body(file);
    var orig_lf: i64[>..] = [];
    index_lf(orig, orig_lf);
    if profile { write_stderr(str("loaded ", orig.len, " bytes, ", orig_lf.len + 1, " lines in ", clock() - started, " s\n")); }

    // The document and its history.
    var add: u8[>..] = [];
    var pieces: Piece[>..<] = [];
    var t = text_new(orig, orig_lf, add, pieces);
    var ops: EditOp[>..<] = [];
    var dels: Piece[>..<] = [];
    var groups: Group[>..<] = [];
    var snaps: Sel[>..<] = [];
    var h = History { ops: ops, dels: dels, groups: groups, snaps: snaps, applied: 0, last_kind: KIND_NONE, saved_at: 0 };
    var sels: Sel[>..<] = [];
    sels.push(caret(0));
    var ed = Editor { t: t, h: h, sels: sels, crlf: info.crlf, tabs: info.tabs };
    var v = View { path: [], info: info, query: [], message: [] };
    append_field_path(v, path_arg);
    v.readonly = !info.utf8;
    if !opened_ok { say(v, str("開けませんでした: ", path_arg)); }
    else if v.readonly { say(v, "UTF-8 ではないので読み取り専用で開いています"); }

    var script_text: u8[>..] = [];
    if script_path.len > 0 && !read_file(script_path, script_text) { abort(str("cannot read ", script_path)); }
    let script_lines = split(script_text, '\n');
    var script = Script { lines: script_lines };

    guard gfx::open(title_of(v, false), 1100, 760, gfx::WINDOW_RESIZABLE) else {
        abort(str("gfx: ", gfx::error()));
    }
    let win = sdl_window();
    let density = pixel_density(win, gfx::screen_size().x);
    let f, font_ok = load_font(FONT, round(FONT_POINTS * density));
    guard font_ok else { abort(str("font: ", ui::error())); }
    learn_widths(f);
    let c = ui::create_context(f.font);
    guard c.id != 0 else { abort(str("ui: ", ui::error())); }
    style_window(c);
    gfx::text_input(true);
    let k = keys();
    let mac = gfx::driver() == "metal";
    var drawn = 0;
    var was_dirty = false;
    var ime_x: f32 = -1.0;
    var ime_y: f32 = -1.0;
    var frame_time = 0.0;
    var slowest = 0.0;

    while gfx::frame() {
        let frame_start = clock();
        ui::input_from_gfx(c);
        handle_input(ed, v, k, mac);
        if v.quit { break; }
        draw(c, f, ed, v);
        gfx::begin_screen(float4 { 0.118, 0.122, 0.133, 1.0 });
        gfx::end_pass();
        ui::render(c);

        // The input method's candidates open at the primary caret.
        let head = primary(ed).head;
        let n = line_of(ed.t, head);
        let cx = cell_x(v, col_of(ed.t, head));
        let cy = v.text_y + (n - v.top) * v.line_h;
        if cx != ime_x || cy != ime_y {
            set_ime_caret(win, density, cx, cy, v.line_h);
            ime_x = cx;
            ime_y = cy;
        }
        let dirty = modified(ed.h);
        if dirty != was_dirty {
            gfx::set_title(title_of(v, dirty));
            was_dirty = dirty;
        }
        let spent = clock() - frame_start;
        frame_time += spent;
        slowest = max(slowest, spent);
        if drawn == 0 && profile { write_stderr(str("first frame after ", clock() - started, " s\n")); }
        drawn++;
        if script_path.len > 0 && !step(script) { break; }
        if drawn == frames { break; }
    }
    if profile && drawn > 0 {
        write_stderr(str(drawn, " frames: ", frame_time / drawn * 1000.0, " ms of work each on average, slowest ",
                         slowest * 1000.0, " ms; ", ed.t.pieces.len, " pieces\n"));
    }
    if modified(ed.h) { keep_recovery(ed, v); }
    ui::destroy(c);
    gfx::close();
}

fn append_field_path(v: View&, path: const u8[:]) { v.path.append(path[..min(path.len, 1024)]); }
