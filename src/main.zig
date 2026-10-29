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
const sys = @import("sys.zig");
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
const search_view = @import("view/search_view.zig");
const diff_view = @import("view/diff_view.zig");
const git = @import("core/git.zig");
const changes_view = @import("view/changes.zig");
const diff = @import("core/diff.zig");
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
    goto: ?struct { line: usize, col: usize } = null, // where to put the caret in the next document, col in bytes
    last_query: state.Buf(256) = .{}, // of the last search of the project
    // What git says has changed, asked again now and then on a thread.
    git: git.Refresher,
    head: git.HeadLoader, // the document's file as HEAD has it
    changes: ?git.Changes = null,
    changes_shown: bool = true,
    changes_panel: changes_view.Panel = .{},
    git_asked: f64 = -100,
    started: f64 = 0,
    frame_time: f64 = 0, // the work of a frame, from input to handing the GPU its commands
    slowest: f64 = 0,
};

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

// A modified document the window was closed on goes to ~/.kop/recovery.
fn keepRecovery(gpa: Allocator, ed: *const Editor, v: *const View) !void {
    const home = sys.getenv("HOME") orelse return;
    const dir = try std.fs.path.join(gpa, &.{ home, ".kop/recovery" });
    defer gpa.free(dir);
    sys.makePath(dir) catch return;
    const name = if (v.path.len > 0) basename(v.path.slice()) else "untitled";
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.{d}", .{ dir, name, sys.unixTime() });
    defer gpa.free(path);
    doc.save(&ed.t, v.info, path) catch return;
    std.debug.print("kop: unsaved changes kept in {s}\n", .{path});
}

fn setTitle(app: *App, v: *const View, dirty: bool) void {
    var buf: [1200]u8 = undefined;
    const name = if (v.path.len > 0) basename(v.path.slice()) else "(untitled)";
    const title = std.mem.printSentinel(&buf, "{s}{s} — kop", .{ if (dirty) "● " else "", name }, 0) catch return;
    _ = c.SDL_SetWindowTitle(app.win, title.ptr);
}

// Saves the frame to a PNG file.
fn screenshot(app: *App, path: []const u8) void {
    var buf: [1024]u8 = undefined;
    const z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return;
    const surface = c.SDL_RenderReadPixels(app.ren, null) orelse return;
    defer c.SDL_DestroySurface(surface);
    if (!c.SDL_SavePNG(surface, z.ptr)) std.debug.print("kop: cannot save {s}: {s}\n", .{ path, c.SDL_GetError() });
}

// How long the window may wait for input before something on it changes
// by itself: the caret blinking, the file looked at again.
fn idleTimeout(app: *const App, v: *const View, now: f64) i32 {
    const since = now - v.blink_at;
    const phase = @mod(since, 1.1);
    var next: f64 = if (since < 0.6) 0.65 - since else if (phase < 0.65) 0.65 - phase else 1.1 - phase;
    next = @min(next, 1.0 - (now - v.disk_checked));
    if (now - v.message_at < 4.0) next = @min(next, 4.0 - (now - v.message_at));
    // git, answering or to be asked again.
    next = @min(next, if (app.git.busy() or app.head.busy()) 0.03 else git_every - (now - app.git_asked));
    return @intFromFloat(std.math.clamp(next * 1000, 1, 1000));
}

// Takes this frame's input into app.in: the script's, or the window's,
// waiting for it up to `timeout_ms` when nothing on the screen moves by
// itself (null: not at all). False once the script is done.
fn gather(app: *App, timeout_ms: ?i32) !bool {
    app.in.clear();
    if (app.script) |*s| {
        var e: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&e)) {}
        return s.step(&app.in);
    }
    var e: c.SDL_Event = undefined;
    if (timeout_ms) |t| if (c.SDL_WaitEventTimeout(&e, t)) try app.in.take(&e);
    try app.in.poll();
    return true;
}

// Hands the frame drawn since `frame_start` to the screen; true once the
// run has had the frames it was to have.
fn finish(app: *App, frame_start: f64) bool {
    const spent = clock() - frame_start;
    if (app.script) |s| if (s.shot) |p| screenshot(app, p);
    app.frame_time += spent;
    app.slowest = @max(app.slowest, spent);
    if (app.profile and spent > 0.02) std.debug.print("frame {d} took {d:.1} ms\n", .{ app.drawn, spent * 1000 });
    _ = c.SDL_RenderPresent(app.ren);
    if (app.drawn == 0 and app.profile) std.debug.print("first frame after {d:.3} s\n", .{clock() - app.started});
    app.drawn += 1;
    return if (app.frames) |f| app.drawn >= f else false;
}

// The directory a search of the project looks in: the tree's, or the
// file's, or the working directory.
fn projectRoot(app: *const App, path: []const u8) []const u8 {
    if (app.tr.root.len > 0) return app.tr.root;
    if (path.len > 0) return std.fs.path.dirname(path) orelse ".";
    return ".";
}

// Shows a search of the project over the document, until it goes back to
// it or picks a place to open.
fn searchProject(app: *App, root: []const u8, query: []const u8, sc: *render.Scratch) !search_view.Action {
    var s = search_view.Screen{ .gpa = app.gpa, .root = root };
    defer s.deinit();
    s.query.set(query);
    if (query.len > 0) try s.run();
    _ = c.SDL_SetWindowTitle(app.win, "Search — kop");
    defer app.last_query = s.query;
    while (true) {
        const idle = @mod(clock() - s.v.blink_at, 1.1);
        const wait: i32 = @intFromFloat(@max((if (idle < 0.65) 0.65 - idle else 1.1 - idle) * 1000, 1));
        if (!try gather(app, wait)) return .quit;
        const frame_start = clock();
        const action = try s.handle(app.gpa, &app.in, app.km, app.mac, app.tr);
        switch (action) {
            .none => {},
            // The path lives in the results, which go with this screen.
            .open => |o| {
                app.next.set(o.path);
                return .{ .open = .{ .path = app.next.slice(), .line = o.line, .col = o.col } };
            },
            else => return action,
        }
        try s.draw(app.ren, app.fonts, app.tr, sc);
        app.cursors.show(if (app.in.mouse_x < s.v.panel_w) .arrow else .text);
        if (finish(app, frame_start)) return .quit;
    }
}

// How often to ask git again, in seconds, while nothing else prompts it.
const git_every = 3.0;

fn askGit(app: *App, path: []const u8) !void {
    try app.git.start(projectRoot(app, path));
    if (path.len > 0) try app.head.start(path);
    app.git_asked = clock();
}

// Takes git's answer, if one has come.
fn takeGit(app: *App) !void {
    const got = try app.git.take() orelse return;
    if (app.changes) |*old| old.deinit();
    app.changes = got.value;
}

// Shows what has changed since HEAD over the document `ed`, until it goes
// back to it or picks a place to open.
fn showChanges(app: *App, ed: *Editor, v: *const View, sc: *render.Scratch) !diff_view.Action {
    var s = diff_view.Screen.init(app.gpa);
    defer s.deinit();
    s.panel = &app.changes_panel;
    s.panel_shown = &app.changes_shown;
    const ch = app.changes orelse return .back;
    try s.load(ch.list.items, ed, v.path.slice(), v.info);
    _ = c.SDL_SetWindowTitle(app.win, "Changes — kop");
    while (true) {
        const idle = @mod(clock() - s.v.blink_at, 1.1);
        const wait: i32 = @intFromFloat(@max((if (idle < 0.65) 0.65 - idle else 1.1 - idle) * 1000, 1));
        if (!try gather(app, wait)) return .quit;
        const frame_start = clock();
        const action = try s.handle(app.gpa, &app.in, app.km, app.mac, app.tr);
        switch (action) {
            .none => {},
            .open => |o| {
                app.next.set(o.path);
                return .{ .open = .{ .path = app.next.slice(), .line = o.line, .col = o.col } };
            },
            else => return action,
        }
        try s.draw(app.ren, app.fonts, app.tr, sc);
        app.cursors.show(s.cursorAt(app.in.mouse_x, app.in.mouse_y));
        if (finish(app, frame_start)) return .quit;
    }
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
        sys.readFile(gpa, path, std.math.maxInt(usize)) catch |e| switch (e) {
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
    if (app.goto) |g| {
        app.goto = null;
        const n = @min(g.line, ed.t.lf);
        ed.setSingle(Sel.caret(@min(ed.t.lineStart(n) + g.col, ed.t.lineEnd(n))));
        v.center = true;
    }

    var sc = render.Scratch{ .gpa = gpa };
    defer sc.deinit();
    var live = diff.Live{ .gpa = gpa };
    defer live.deinit();
    try askGit(app, path);
    var saves_seen: usize = 0;
    var edited_at: f64 = 0;
    setTitle(app, &v, false);
    var was_dirty = false;
    var ime_x: f32 = -1;
    var ime_y: f32 = -1;
    const cx = input.Context{ .gpa = gpa, .ed = &ed, .v = &v, .tr = app.tr, .km = app.km, .mac = app.mac };
    var done = false;
    while (!done) {
        // Input, waiting for it when nothing on the screen moves by itself.
        const busy = v.drag != .none or v.follow or hl.stateAt(@min(v.top + v.rows + 1, ed.t.lf)) == null or (live.has_base and live.stale);
        if (!try gather(app, if (busy) null else idleTimeout(app, &v, clock()))) done = true;
        const frame_start = clock();
        try input.handle(cx, &app.in);
        if (v.quit) break;
        // The changes: asked for again when the document is saved, the
        // window comes to the front, or a while has passed.
        var focused = false;
        for (app.in.events.items) |e| if (e == .focus) {
            focused = true;
        };
        if (v.saves != saves_seen or focused or frame_start - app.git_asked > git_every) {
            saves_seen = v.saves;
            try askGit(app, v.path.slice());
        }
        try takeGit(app);
        if (try app.head.take()) |answer| {
            var value = answer.value;
            defer if (value) |*h| h.deinit();
            // An answer about a document gone since is no use.
            if (std.mem.eql(u8, answer.question, v.path.slice())) {
                if (value) |h| try live.setBase(h.data, h.tracked) else live.clearBase();
            }
        }
        if (v.changes_toggle) {
            v.changes_toggle = false;
            app.changes_shown = !app.changes_shown;
        }
        v.right_cells = if (app.changes_shown and app.changes != null) changes_view.cells else 0;
        if (app.changes != null) {
            app.changes_panel.scroll(&v, app.changes_panel.rows.items.len);
            if (v.changes_click) |y| {
                // The heading shows them all as a diff.
                if (y >= v.tree_y and y < v.tree_y + v.ui_line_h) v.diff_request = true;
                if (app.changes_panel.changeAt(&v, y)) |e| if (e.kind != .deleted) {
                    v.open_path.set(e.path);
                    v.open_request = true;
                };
            }
        }
        v.changes_click = null;
        if (v.diff_request) {
            v.diff_request = false;
            if (app.changes == null) {
                say(&v, "Not in a git repository");
            } else {
                const action = try showChanges(app, &ed, &v, &sc);
                // The document may have been edited, and saved, there.
                live.stale = true;
                if (!ed.h.modified()) {
                    v.disk = state.DiskStamp.of(v.path.slice());
                    v.disk_told = v.disk;
                }
                try askGit(app, v.path.slice());
                switch (action) {
                    .quit => break,
                    .open => |o| {
                        if (v.path.eql(o.path)) {
                            const n = @min(o.line, ed.t.lf);
                            ed.setSingle(Sel.caret(@min(ed.t.lineStart(n) + o.col, ed.t.lineEnd(n))));
                            v.center = true;
                        } else {
                            v.open_path.set(o.path);
                            v.open_request = true;
                            app.goto = .{ .line = o.line, .col = o.col };
                        }
                    },
                    else => {},
                }
                v.follow = true;
                v.blink_at = clock();
                setTitle(app, &v, ed.h.modified());
            }
        }
        if (v.search_request) {
            v.search_request = false;
            // The selection, when it is a few words on one line; else the last query.
            var query = app.last_query;
            const p = ed.primary();
            if (!p.isEmpty() and p.hi() - p.lo() <= 200) {
                var sel: std.ArrayList(u8) = .empty;
                defer sel.deinit(gpa);
                try ed.t.read(p.lo(), p.hi(), &sel);
                if (std.mem.indexOfScalar(u8, sel.items, '\n') == null) query.set(sel.items);
            }
            switch (try searchProject(app, projectRoot(app, v.path.slice()), query.slice(), &sc)) {
                .quit => break,
                .open => |o| {
                    if (v.path.eql(o.path)) {
                        const n = @min(o.line, ed.t.lf);
                        ed.setSingle(Sel.caret(@min(ed.t.lineStart(n) + o.col, ed.t.lineEnd(n))));
                        v.center = true;
                    } else {
                        v.open_path.set(o.path);
                        v.open_request = true;
                        app.goto = .{ .line = o.line, .col = o.col };
                    }
                },
                else => {},
            }
            v.follow = true;
            v.blink_at = clock();
            setTitle(app, &v, ed.h.modified());
        }
        if (v.open_request) {
            v.open_request = false;
            if (!std.mem.eql(u8, v.open_path.slice(), v.path.slice())) {
                if (!ed.h.modified() or v.open_path.eql(v.discard_path.slice())) {
                    app.next.set(v.open_path.slice());
                    return .open;
                }
                v.discard_path.set(v.open_path.slice());
                app.goto = null;
                say(&v, "Unsaved changes: open it again to discard them");
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
        // The difference from HEAD, found again after an edit: for a big
        // file, only once typing pauses for a moment.
        if (dirty_from != text.not_dirty) {
            live.stale = true;
            edited_at = frame_start;
        }
        if (ed.t.len < 512 << 10 or frame_start - edited_at > 0.2) try live.update(&ed.t);

        try render.draw(app.ren, app.fonts, &ed, &v, app.tr, &hl, if (live.has_base) &live else null, &sc);
        var cursor = input.cursorAt(&v, app.tr, &app.in);
        if (v.right_cells > 0) if (app.changes) |*ch| {
            const now_live: ?changes_view.Live = if (live.has_base and v.path.len > 0)
                .{ .path = v.path.slice(), .added = live.added, .removed = live.removed, .tracked = live.tracked }
            else
                null;
            try app.changes_panel.build(gpa, ch, now_live);
            try app.changes_panel.draw(app.ren, &app.fonts.ui, &v, &sc);
            // A change opens its file, and the heading the diff of them all.
            const my = app.in.mouse_y;
            const on_heading = my >= v.tree_y and my < v.tree_y + v.ui_line_h;
            if (app.in.mouse_x >= v.right_x and (on_heading or app.changes_panel.changeAt(&v, my) != null)) cursor = .pointer;
        };
        app.cursors.show(cursor);
        if (finish(app, frame_start)) done = true;

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
    }
    if (ed.h.modified()) try keepRecovery(gpa, &ed, &v);
    return .quit;
}

fn fail(comptime what: []const u8) noreturn {
    std.debug.print("kop: " ++ what ++ ": {s}\n", .{c.SDL_GetError()});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    sys.setIo(init.io);
    _ = clock();

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
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
    const script_src: ?[]u8 = if (script_path) |p| sys.readFile(gpa, p, 1 << 20) catch {
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
    const is_dir = path_arg.len > 0 and sys.isDir(path_arg);
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
        .git = .{ .gpa = gpa },
        .head = .{ .gpa = gpa },
        .profile = profile,
        .started = clock(),
    };
    defer app.in.deinit();
    defer app.git.deinit();
    defer app.head.deinit();
    defer app.changes_panel.deinit(gpa);
    defer if (app.changes) |*ch| ch.deinit();
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
