// kop: a text editor.
//
//   zig build run -- [file or directory]
//   zig-out/bin/kop [file or directory]
//
// A directory shows as a tree on the left, whose files open on a click.
// Options after the path: --script <file> plays input back in a hidden
// window (src/view/script.zig), --frames <n> stops after n frames,
// --profile prints how long loading and frames take.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @import("view/c.zig").c;
const text = @import("core/text.zig");
const Editor = @import("core/edit.zig").Editor;
const Sel = @import("core/select.zig").Sel;
const motion = @import("core/motion.zig");
const doc = @import("core/doc.zig");
const settings_mod = @import("core/settings.zig");
const keymap = @import("core/keymap.zig");
const syntax = @import("core/syntax.zig");
const width = @import("core/width.zig");
const state = @import("view/state.zig");
const View = state.View;
const say = state.say;
const clock = state.clock;
const font = @import("view/font.zig");
const render = @import("view/render.zig");
const input = @import("view/input.zig");
const platform = @import("view/platform.zig");
const Script = @import("view/script.zig").Script;
const Tree = @import("view/tree.zig").Tree;
const fontfile = @import("view/fontfile.zig");
const theme = @import("view/theme.zig");

// What outlives one document: the window, its fonts, the tree, and how
// the run is driven and measured.
const App = struct {
    gpa: Allocator,
    win: *c.SDL_Window,
    ren: *c.SDL_Renderer,
    density: f32,
    mac: bool,
    fonts: *font.Fonts,
    km: *keymap.Keymap,
    tr: *Tree,
    in: input.Input,
    cursors: platform.Cursors,
    script: ?Script,
    frames: ?usize, // stop after this many frames
    drawn: usize = 0,
    profile: bool,
    notice: state.Buf(240) = .{}, // for the status bar of the first document: what was wrong with the settings
    next: state.Buf(1024) = .{}, // the file to open next
    // Where to put the caret and the view after a reload, which reads the
    // file again as the next document; `reloaded_auto` when no one asked.
    reloaded: bool = false,
    reloaded_auto: bool = false,
    reload_line: usize = 0,
    reload_col: usize = 0,
    reload_top: usize = 0,
    started: f64 = 0,
    frame_time: f64 = 0, // the work of a frame, from input to handing the GPU its commands
    slowest: f64 = 0,
};

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

// A modified document the window was closed on goes to ~/.kop/recovery.
fn keepRecovery(gpa: Allocator, ed: *const Editor, v: *const View) !void {
    const home = std.posix.getenv("HOME") orelse return;
    const dir = try std.fs.path.join(gpa, &.{ home, ".kop/recovery" });
    defer gpa.free(dir);
    std.fs.cwd().makePath(dir) catch return;
    const name = if (v.path.len > 0) basename(v.path.slice()) else "untitled";
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.{d}", .{ dir, name, std.time.timestamp() });
    defer gpa.free(path);
    doc.save(&ed.t, v.info, path) catch return;
    std.debug.print("kop: unsaved changes kept in {s}\n", .{path});
}

fn setTitle(app: *App, v: *const View, dirty: bool) void {
    var buf: [1200]u8 = undefined;
    const name = if (v.path.len > 0) basename(v.path.slice()) else "(untitled)";
    const title = std.fmt.bufPrintZ(&buf, "{s}{s} — kop", .{ if (dirty) "● " else "", name }) catch return;
    _ = c.SDL_SetWindowTitle(app.win, title.ptr);
}

// Saves the frame to a PNG file.
fn screenshot(app: *App, path: []const u8) void {
    var buf: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    const surface = c.SDL_RenderReadPixels(app.ren, null) orelse return;
    defer c.SDL_DestroySurface(surface);
    if (!c.SDL_SavePNG(surface, z.ptr)) std.debug.print("kop: cannot save {s}: {s}\n", .{ path, c.SDL_GetError() });
}

// How long the window may wait for input before something on it changes
// by itself: the caret blinking, the file looked at again.
fn idleTimeout(v: *const View, now: f64) i32 {
    const since = now - v.blink_at;
    const phase = @mod(since, 1.1);
    var next: f64 = if (since < 0.6) 0.65 - since else if (phase < 0.65) 0.65 - phase else 1.1 - phase;
    next = @min(next, 1.0 - (now - v.disk_checked));
    if (now - v.message_at < 4.0) next = @min(next, 4.0 - (now - v.message_at));
    return @intFromFloat(std.math.clamp(next * 1000, 1, 1000));
}

const Outcome = enum { quit, open };

// Edits the file at `path` (none: an untitled document) until the window
// closes, or a file is picked in the tree, which returns .open with its
// path in app.next. The document is gone when it returns.
fn editFile(app: *App, path: []const u8) !Outcome {
    const gpa = app.gpa;
    const started = clock();
    // The file, read whole, and where its lines start.
    var opened_ok = true;
    const file: []u8 = if (path.len > 0)
        std.fs.cwd().readFileAlloc(gpa, path, std.math.maxInt(usize)) catch |e| switch (e) {
            error.FileNotFound => try gpa.alloc(u8, 0),
            error.OutOfMemory => return e,
            else => blk: {
                opened_ok = false;
                break :blk try gpa.alloc(u8, 0);
            },
        }
    else
        try gpa.alloc(u8, 0);
    defer gpa.free(file);
    const info = doc.detect(file);
    const orig = doc.body(file);
    var orig_lf: std.ArrayList(usize) = .empty;
    defer orig_lf.deinit(gpa);
    try text.indexLf(gpa, orig, &orig_lf);
    if (app.profile) std.debug.print("loaded {d} bytes, {d} lines in {d:.3} s\n", .{ orig.len, orig_lf.items.len + 1, clock() - started });

    // The document and its history.
    var ed = try Editor.init(gpa, orig, orig_lf.items);
    defer ed.deinit();
    ed.crlf = info.crlf;
    ed.tabs = info.tabs;
    var hl = try syntax.Highlight.init(gpa, path);
    defer hl.deinit();
    var v = View{ .info = info };
    v.path.set(path);
    v.readonly = !info.utf8;
    var msg_buf: [240]u8 = undefined;
    if (!opened_ok) {
        say(&v, std.fmt.bufPrint(&msg_buf, "Could not open: {s}", .{path}) catch "Could not open");
    } else if (v.readonly) say(&v, "Opened read-only: not UTF-8");
    if (app.notice.len > 0) {
        say(&v, app.notice.slice());
        app.notice.set("");
    }
    v.disk = state.DiskStamp.of(path);
    v.disk_told = v.disk;
    v.disk_checked = clock();
    if (app.reloaded) {
        app.reloaded = false;
        ed.setSingle(Sel.caret(try motion.posAtCol(&ed.t, @min(app.reload_line, ed.t.lf), app.reload_col)));
        v.top = app.reload_top;
        v.follow = false;
        say(&v, if (app.reloaded_auto) "Reloaded: changed on disk" else "Reloaded");
    }

    var sc = render.Scratch{ .gpa = gpa };
    defer sc.deinit();
    setTitle(app, &v, false);
    var was_dirty = false;
    var ime_x: f32 = -1;
    var ime_y: f32 = -1;
    const cx = input.Context{ .gpa = gpa, .ed = &ed, .v = &v, .tr = app.tr, .km = app.km, .mac = app.mac };
    var done = false;
    while (!done) {
        // Input: the script's, or the window's, waiting for it when nothing
        // on the screen moves by itself.
        app.in.clear();
        if (app.script) |*s| {
            var e: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&e)) {}
            if (!try s.step(&app.in)) done = true;
        } else {
            const busy = v.drag != .none or v.follow or hl.stateAt(@min(v.top + v.rows + 1, ed.t.lf)) == null;
            var e: c.SDL_Event = undefined;
            if (!busy and c.SDL_WaitEventTimeout(&e, idleTimeout(&v, clock()))) try app.in.take(&e);
            try app.in.poll();
        }
        const frame_start = clock();
        try input.handle(cx, &app.in);
        if (v.quit) break;
        if (v.open_request) {
            v.open_request = false;
            if (!std.mem.eql(u8, v.open_path.slice(), v.path.slice())) {
                if (!ed.h.modified() or v.open_path.eql(v.discard_path.slice())) {
                    app.next.set(v.open_path.slice());
                    return .open;
                }
                v.discard_path.set(v.open_path.slice());
                say(&v, "Unsaved changes: click again to discard them");
            }
        }
        // The file on disk, looked at once a second. A change to it is read
        // in when this document has none of its own, and told of otherwise.
        var auto = false;
        if (v.path.len > 0 and frame_start - v.disk_checked > 1.0) {
            v.disk_checked = frame_start;
            const d = state.DiskStamp.of(v.path.slice());
            if (!d.same(v.disk) and !d.same(v.disk_told)) {
                v.disk_told = d;
                if (d.exists and !ed.h.modified()) {
                    v.reload_request = true;
                    auto = true;
                } else if (d.exists) {
                    say(&v, "Changed on disk: reload to take it, or save to overwrite it");
                } else say(&v, "Deleted on disk");
            }
        }
        if (v.reload_request) {
            const head = ed.primary().head;
            app.reloaded = true;
            app.reloaded_auto = auto;
            app.reload_line = ed.t.lineOf(head);
            app.reload_col = try motion.colOf(&ed.t, head);
            app.reload_top = v.top;
            app.next.set(v.path.slice());
            return .open;
        }
        // Colors: forget what an edit changed, then lex on towards the screen's
        // last line, a few milliseconds a frame, so a huge file never stalls.
        const dirty_from = ed.t.takeDirty();
        if (dirty_from != text.not_dirty) hl.edited(&ed.t, dirty_from);
        _ = try hl.extend(&ed.t, v.top + v.rows + 1, 0.003);

        try render.draw(app.ren, app.fonts, &ed, &v, app.tr, &hl, &sc);
        app.cursors.show(input.cursorAt(&v, app.tr, &app.in));
        const spent = clock() - frame_start;
        if (app.script) |s| if (s.shot) |p| screenshot(app, p);
        app.frame_time += spent;
        app.slowest = @max(app.slowest, spent);
        if (app.profile and spent > 0.02) std.debug.print("frame {d} took {d:.1} ms\n", .{ app.drawn, spent * 1000 });
        _ = c.SDL_RenderPresent(app.ren);

        // The input method's candidates open at the primary caret.
        const head = ed.primary().head;
        const n = ed.t.lineOf(head);
        const ix = render.cellX(&v, try motion.colOf(&ed.t, head));
        const iy = v.text_y + (@as(f32, @floatFromInt(n)) - @as(f32, @floatFromInt(v.top))) * v.line_h - v.scroll_y;
        if (ix != ime_x or iy != ime_y) {
            platform.setImeCaret(app.win, app.density, ix, iy, v.line_h);
            ime_x = ix;
            ime_y = iy;
        }
        const dirty = ed.h.modified();
        if (dirty != was_dirty) {
            setTitle(app, &v, dirty);
            was_dirty = dirty;
        }
        if (app.drawn == 0 and app.profile) std.debug.print("first frame after {d:.3} s\n", .{clock() - app.started});
        app.drawn += 1;
        if (app.frames) |f| if (app.drawn >= f) {
            done = true;
        };
    }
    if (ed.h.modified()) try keepRecovery(gpa, &ed, &v);
    return .quit;
}

fn fail(comptime what: []const u8) noreturn {
    std.debug.print("kop: " ++ what ++ ": {s}\n", .{c.SDL_GetError()});
    std.process.exit(1);
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const gpa = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    _ = clock();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);
    var path_arg: []const u8 = "";
    var script_path: ?[]const u8 = null;
    var frames: ?usize = null;
    var profile = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--script") and i + 1 < argv.len) {
            i += 1;
            script_path = argv[i];
        } else if (std.mem.eql(u8, a, "--frames") and i + 1 < argv.len) {
            i += 1;
            frames = std.fmt.parseInt(usize, argv[i], 10) catch null;
        } else if (std.mem.eql(u8, a, "--profile")) {
            profile = true;
        } else path_arg = a;
    }
    const mac = builtin.os.tag == .macos;
    const script_src: ?[]u8 = if (script_path) |p| std.fs.cwd().readFileAlloc(gpa, p, 1 << 20) catch {
        std.debug.print("kop: cannot read {s}\n", .{p});
        std.process.exit(1);
    } else null;
    defer if (script_src) |s| gpa.free(s);

    var problems: std.ArrayList(u8) = .empty;
    defer problems.deinit(gpa);
    var settings = try settings_mod.load(gpa, path_arg, &problems);
    defer settings.deinit();
    if (settings.theme.items.len > 0) {
        if (theme.named(settings.theme.items)) |t| {
            theme.current = t;
        } else try problems.print(gpa, "no such theme: {s} ({s}); ", .{ settings.theme.items, theme.names });
    }

    _ = c.SDL_SetHint(c.SDL_HINT_IME_IMPLEMENTED_UI, "composition");
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) fail("SDL");
    defer c.SDL_Quit();
    const hidden: c.SDL_WindowFlags = if (script_src != null) c.SDL_WINDOW_HIDDEN else 0;
    const win = c.SDL_CreateWindow("kop", 1100, 760, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | hidden) orelse fail("window");
    defer c.SDL_DestroyWindow(win);
    const ren = c.SDL_CreateRenderer(win, null) orelse fail("renderer");
    defer c.SDL_DestroyRenderer(ren);
    _ = c.SDL_SetRenderVSync(ren, 1);
    const density = c.SDL_GetWindowPixelDensity(win);

    var lib: c.FT_Library = null;
    if (c.FT_Init_FreeType(&lib) != 0) {
        std.debug.print("kop: FreeType did not start\n", .{});
        std.process.exit(1);
    }
    defer _ = c.FT_Done_FreeType(lib);
    var atlas = try font.Atlas.init(ren);
    defer atlas.deinit(gpa);
    const text_fonts = if (settings.editor_fonts.items.len > 0) settings.editor_fonts.items else fontfile.defaultFonts();
    const ui_fonts = if (settings.ui_fonts.items.len > 0) settings.ui_fonts.items else text_fonts;
    var fonts = font.Fonts{
        .text = font.loadFace(gpa, lib, &atlas, text_fonts, @round(settings.editor_font_size * density), &problems) catch {
            std.debug.print("kop: no font to draw the text with: {s}\n", .{problems.items});
            std.process.exit(1);
        },
        .ui = font.loadFace(gpa, lib, &atlas, ui_fonts, @round(settings.ui_font_size * density), &problems) catch {
            std.debug.print("kop: no font to draw the window with: {s}\n", .{problems.items});
            std.process.exit(1);
        },
    };
    defer fonts.text.deinit();
    defer fonts.ui.deinit();
    font.measureWith(&fonts.text);

    var km = keymap.Keymap.init(gpa);
    defer km.deinit();
    try km.build(mac, settings.keybindings.items, &problems);
    if (problems.items.len > 0) std.debug.print("kop: {s}\n", .{problems.items});
    _ = c.SDL_StartTextInput(win);

    // A directory opens as the tree, with no file yet; a file opens by itself.
    var tr = Tree.init(gpa);
    defer tr.deinit();
    const is_dir = if (path_arg.len > 0) (if (std.fs.cwd().statFile(path_arg)) |st| st.kind == .directory else |_| false) else false;
    var app = App{
        .gpa = gpa,
        .win = win,
        .ren = ren,
        .density = density,
        .mac = mac,
        .fonts = &fonts,
        .km = &km,
        .tr = &tr,
        .in = .{ .gpa = gpa, .density = density },
        .cursors = platform.Cursors.init(),
        .script = if (script_src) |s| Script.init(s, mac) else null,
        .frames = frames,
        .profile = profile,
        .started = clock(),
    };
    defer app.in.deinit();
    defer app.cursors.deinit();
    app.notice.set(problems.items);
    if (is_dir) try tr.open(path_arg) else app.next.set(path_arg);
    while (true) {
        var current: state.Buf(1024) = app.next;
        if (try editFile(&app, current.slice()) == .quit) break;
    }
    if (profile and app.drawn > 0) {
        const ms = 1000.0 / @as(f64, @floatFromInt(app.drawn));
        std.debug.print("{d} frames: {d:.2} ms of work each on average, slowest {d:.2} ms\n", .{ app.drawn, app.frame_time * ms, app.slowest * 1000 });
    }
}
