// kop: a text editor.
//
//   goose kop.goose -- [file or directory]              run it in the compiler
//   goose build kop.goose && ./kop [file or directory]  or build it
//
// A directory shows as a tree on the left, whose files open on a click.
// Options after the path: --script <file> plays input back (view/script.goose),
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
import core.settings;
import core.utf8;
import view.state;
import view.font;
import view.render;
import view.input;
import view.platform;
import view.script;
import view.tree;
import view.fontfile;


fn basename(path: const u8[:]) -> const u8[:] {
    let k = rfind(path, "/");
    if k < 0 { path } else { path[k + 1..] }
}

// A modified document the window was closed on goes to ~/.kop/recovery,
// since closing cannot be refused.
fn keep_recovery(ed: Editor&, v: View&) {
    var home: u8[>..] = [];
    if !env("HOME", home) { return; }
    let dir = str(home, "/.kop");
    let rec = str(dir, "/recovery");
    if !make_dir(dir) || !make_dir(rec) { return; }
    let name = if v.path.len > 0 { basename(v.path) } else { "untitled" };
    let path = str(rec, "/", name, ".", time() as i64);
    if save(ed.t, v.info, path) { write_stderr(str("kop: unsaved changes kept in ", path, "\n")); }
}

fn title_of(v: View&, dirty: bool) -> u8[>..] {
    str(if dirty { "● " } else { "" }, if v.path.len > 0 { basename(v.path) } else { "(無題)" }, " — kop")
}

// What outlives one document: the window, its font and ui, and how the run
// is driven and measured.
struct App {
    c: ui::Context,
    f: Fonts,
    win: u64,
    density: f32,
    k: Keys,
    mac: bool,
    scripted: bool,
    frames: i64,            // stop after this many frames; -1 for never
    drawn: i64,
    profile: bool,
    notice: u8[..240],      // for the status bar of the first document: what was wrong with the settings
    started: f64,
    frame_time: f64,
    slowest: f64,
}

// Edits the file at `path` (none: an untitled document) until the window
// closes, which returns true, or a file is picked in the tree, which
// returns false with its path in `next`. The document lives in this call's
// locals and is gone when it returns.
fn edit_file(app: App&, tr: Tree&, script: Script&, path: const u8[:], next: u8[..1024]&) -> bool {
    let started = clock();
    // The file, read whole, and where its lines start.
    var file: u8[>..] = [];
    var opened_ok = true;
    if path.len > 0 && file_exists(path) { opened_ok = read_file(path, file); }
    let info = detect(file);
    let orig = body(file);
    var orig_lf: i64[>..] = [];
    index_lf(orig, orig_lf);
    if app.profile { write_stderr(str("loaded ", orig.len, " bytes, ", orig_lf.len + 1, " lines in ", clock() - started, " s\n")); }

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
    var v = View { path: [], info: info, query: [], message: [], open_path: [], discard_path: [] };
    v.path.append(path[..min(path.len, 1024)]);
    v.readonly = !info.utf8;
    if !opened_ok { say(v, str("開けませんでした: ", path)); }
    else if v.readonly { say(v, "UTF-8 ではないので読み取り専用で開いています"); }
    if app.notice.len > 0 {
        say(v, app.notice);
        app.notice.resize(0, 0);
    }

    gfx::set_title(title_of(v, false));
    var was_dirty = false;
    var ime_x: f32 = -1.0;
    var ime_y: f32 = -1.0;
    var done = false;
    while !done && gfx::frame() {
        let frame_start = clock();
        ui::input_from_gfx(app.c);
        handle_input(ed, v, tr, app.k, app.mac);
        if v.quit { break; }
        if v.open_request {
            v.open_request = false;
            if v.open_path[..] != v.path[..] {
                if !modified(ed.h) || v.open_path[..] == v.discard_path[..] {
                    next.resize(0, 0);
                    next.append(v.open_path);
                    return false;
                }
                v.discard_path.resize(0, 0);
                v.discard_path.append(v.open_path);
                say(v, "未保存の変更があります（もう一度クリックで破棄して開く）");
            }
        }
        draw(app.c, app.f, ed, v, tr);
        gfx::begin_screen(float4 { 0.118, 0.122, 0.133, 1.0 });
        gfx::end_pass();
        ui::render(app.c);

        // The input method's candidates open at the primary caret.
        let head = primary(ed).head;
        let n = line_of(ed.t, head);
        let cx = cell_x(v, col_of(ed.t, head));
        let cy = v.text_y + (n - v.top) * v.line_h;
        if cx != ime_x || cy != ime_y {
            set_ime_caret(app.win, app.density, cx, cy, v.line_h);
            ime_x = cx;
            ime_y = cy;
        }
        let dirty = modified(ed.h);
        if dirty != was_dirty {
            gfx::set_title(title_of(v, dirty));
            was_dirty = dirty;
        }
        let spent = clock() - frame_start;
        app.frame_time += spent;
        app.slowest = max(app.slowest, spent);
        if app.drawn == 0 && app.profile { write_stderr(str("first frame after ", clock() - app.started, " s\n")); }
        app.drawn++;
        if app.scripted && !step(script) { done = true; }
        if app.drawn == app.frames { done = true; }
    }
    if modified(ed.h) { keep_recovery(ed, v); }
    return true;
}

fn main() {
    let argv = args();
    var path_arg: u8[>..] = [];
    var script_path: u8[>..] = [];
    var frames = -1;
    var profile = false;
    var i = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "--script" && i + 1 < argv.len { script_path.append(argv[i + 1]); i++; }
        else if a == "--frames" && i + 1 < argv.len { let n, ok = parse_int(argv[i + 1]); frames = n; i++; }
        else if a == "--profile" { profile = true; }
        else { path_arg.clear(); path_arg.append(a); }
        i++;
    }
    var script_text: u8[>..] = [];
    if script_path.len > 0 && !read_file(script_path, script_text) { abort(str("cannot read ", script_path)); }
    let script_lines = split(script_text, '\n');
    var script = Script { lines: script_lines };

    var problems: u8[>..] = [];
    let settings = load_settings(path_arg, problems);

    guard gfx::open("kop", 1100, 760, gfx::WINDOW_RESIZABLE) else {
        abort(str("gfx: ", gfx::error()));
    }
    let win = sdl_window();
    let density = pixel_density(win, gfx::screen_size().x);
    let text_fonts = if settings.editor_fonts.len > 0 { settings.editor_fonts[..] } else { default_fonts() };
    let ui_fonts = if settings.ui_fonts.len > 0 { settings.ui_fonts[..] } else { text_fonts };
    let text_face, text_ok = load_face(text_fonts, round(settings.editor_font_size * density), problems);
    guard text_ok else { abort(str("font: ", ui::error())); }
    let ui_face, ui_ok = load_face(ui_fonts, round(settings.ui_font_size * density), problems);
    guard ui_ok else { abort(str("font: ", ui::error())); }
    if problems.len > 0 { write_stderr(str("kop: ", problems, "\n")); }
    let f = Fonts { text: text_face, ui: ui_face };
    learn_widths(f.text);
    let c = ui::create_context(f.ui.parts[0]);
    guard c.id != 0 else { abort(str("ui: ", ui::error())); }
    style_window(c);
    gfx::text_input(true);
    var app = App { c: c, f: f, win: win, density: density, k: keys(), mac: gfx::driver() == "metal",
                    scripted: script_path.len > 0, frames: frames, drawn: 0, profile: profile,
                    notice: [], started: clock(), frame_time: 0.0, slowest: 0.0 };
    var cut = min(problems.len, 240);
    while cut < problems.len && cut > 0 && is_cont(problems[cut]) { cut--; }
    app.notice.append(problems[..cut]);

    // A directory opens as the tree, with no file yet; a file opens by itself.
    var pool: u8[>..<] = [];
    var rows: Entry[>..<] = [];
    var tr = Tree { root: [], pool: pool, rows: rows };
    var current: u8[..1024] = [];
    if path_arg.len > 0 && is_dir(path_arg) { tree_open(tr, path_arg); }
    else { current.append(path_arg[..min(path_arg.len, 1024)]); }
    var next: u8[..1024] = [];
    while !edit_file(app, tr, script, current, next) { current = next; }

    if profile && app.drawn > 0 {
        write_stderr(str(app.drawn, " frames: ", app.frame_time / app.drawn * 1000.0, " ms of work each on average, slowest ",
                         app.slowest * 1000.0, " ms\n"));
    }
    ui::destroy(c);
    gfx::close();
}
