// The fonts: the system's (or the settings') font files at two sizes, the
// text's and the ui's, read with FreeType.
//
// A face is a list of fonts, first choice first, and each character is
// drawn with the first font that has it: a monospace font for code, then
// a Japanese one for what it lacks. Glyphs are rendered when first drawn
// into one texture that both faces share; when it fills up it starts over.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const theme = @import("theme.zig");
const fontfile = @import("fontfile.zig");
const utf8 = @import("../core/utf8.zig");
const width = @import("../core/width.zig");

// A row's height, as a multiple of the font's size.
pub const line_height: f32 = 1.4;

const max_fonts = 8;
const atlas_size = 2048;
const load_flags = c.FT_LOAD_DEFAULT | (1 << 16); // FT_LOAD_TARGET_LIGHT: hinted only up and down

// Where glyphs are kept: rows of them, filled left to right, top to bottom.
pub const Atlas = struct {
    ren: *c.SDL_Renderer,
    tex: *c.SDL_Texture,
    x: c_int = 0,
    y: c_int = 0,
    row_h: c_int = 0,
    generation: u32 = 1, // bumped when it starts over, which forgets every glyph
    pixels: std.ArrayList(u8) = .empty,

    pub fn init(ren: *c.SDL_Renderer) !Atlas {
        const tex = c.SDL_CreateTexture(ren, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, atlas_size, atlas_size) orelse return error.Texture;
        _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
        return .{ .ren = ren, .tex = tex };
    }

    pub fn deinit(a: *Atlas, gpa: Allocator) void {
        c.SDL_DestroyTexture(a.tex);
        a.pixels.deinit(gpa);
    }

    // Room for a w by h glyph; null when there is none left.
    fn place(a: *Atlas, w: c_int, h: c_int) ?[2]c_int {
        if (w > atlas_size or h > atlas_size) return null;
        if (a.x + w > atlas_size) {
            a.x = 0;
            a.y += a.row_h + 1;
            a.row_h = 0;
        }
        if (a.y + h > atlas_size) return null;
        const at = [2]c_int{ a.x, a.y };
        a.x += w + 1;
        a.row_h = @max(a.row_h, h);
        return at;
    }

    fn startOver(a: *Atlas) void {
        a.x = 0;
        a.y = 0;
        a.row_h = 0;
        a.generation += 1;
    }
};

pub const Glyph = struct {
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,
    left: f32 = 0, // from the pen to the bitmap's left
    top: f32 = 0, // from the baseline up to its top
    advance: f32 = 0,
    generation: u32 = 0,
    missing: bool = false, // no font has it
};

pub const Face = struct {
    gpa: Allocator,
    atlas: *Atlas,
    fonts: [max_fonts]c.FT_Face = @splat(null),
    count: usize = 0,
    px: f32,
    cell_w: f32 = 8, // the advance of a half-width character, in pixels
    line_h: f32 = 16,
    baseline: f32 = 12, // from a row's top
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,

    pub fn deinit(f: *Face) void {
        for (f.fonts[0..f.count]) |ft| _ = c.FT_Done_Face(ft);
        f.glyphs.deinit(f.gpa);
    }

    // The first of the fonts that has `cp`.
    pub fn fontFor(f: *const Face, cp: u32) ?c.FT_Face {
        for (f.fonts[0..f.count]) |ft| {
            if (c.FT_Get_Char_Index(ft, cp) != 0) return ft;
        }
        return null;
    }

    fn render(f: *Face, cp: u32) !Glyph {
        const ft = f.fontFor(cp) orelse return .{ .missing = true, .generation = f.atlas.generation };
        if (c.FT_Load_Char(ft, cp, load_flags | c.FT_LOAD_RENDER) != 0) return .{ .missing = true, .generation = f.atlas.generation };
        const slot = ft.*.glyph;
        const bm = slot.*.bitmap;
        var g = Glyph{
            .w = @intCast(bm.width),
            .h = @intCast(bm.rows),
            .left = @floatFromInt(slot.*.bitmap_left),
            .top = @floatFromInt(slot.*.bitmap_top),
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
        };
        if (g.w > 0 and g.h > 0 and bm.pixel_mode == c.FT_PIXEL_MODE_GRAY) {
            const spot = f.atlas.place(g.w, g.h) orelse blk: {
                f.atlas.startOver();
                break :blk f.atlas.place(g.w, g.h) orelse return .{ .missing = true, .generation = f.atlas.generation };
            };
            g.x = spot[0];
            g.y = spot[1];
            // White, with the coverage as its alpha; drawing tints it.
            const n: usize = @intCast(g.w * g.h);
            try f.atlas.pixels.resize(f.gpa, n * 4);
            const px = f.atlas.pixels.items;
            for (0..@intCast(g.h)) |row| {
                const src = bm.buffer + row * @as(usize, @intCast(bm.pitch));
                for (0..@intCast(g.w)) |col| {
                    const o = (row * @as(usize, @intCast(g.w)) + col) * 4;
                    px[o..][0..4].* = .{ 255, 255, 255, src[col] };
                }
            }
            const rect = c.SDL_Rect{ .x = g.x, .y = g.y, .w = g.w, .h = g.h };
            _ = c.SDL_UpdateTexture(f.atlas.tex, &rect, px.ptr, g.w * 4);
        } else {
            g.w = 0;
            g.h = 0;
        }
        g.generation = f.atlas.generation;
        return g;
    }

    pub fn glyph(f: *Face, cp: u32) !Glyph {
        if (f.glyphs.get(cp)) |g| {
            if (g.generation == f.atlas.generation) return g;
        }
        const g = try f.render(cp);
        try f.glyphs.put(f.gpa, cp, g);
        return g;
    }

    // Draws `cp` in `cells` cells from x, in the row whose top is y; a
    // glyph that does not fill its cells exactly is centered in them.
    // False if no font has it.
    pub fn drawChar(f: *Face, x: f32, y: f32, cp: u32, cells: usize, color: theme.Color) !bool {
        const g = try f.glyph(cp);
        if (g.missing) return false;
        if (g.w == 0) return true;
        const room = @as(f32, @floatFromInt(cells)) * f.cell_w;
        const inset = if (@abs(room - g.advance) < 0.01) 0 else @max((room - g.advance) * 0.5, 0);
        const src = c.SDL_FRect{ .x = @floatFromInt(g.x), .y = @floatFromInt(g.y), .w = @floatFromInt(g.w), .h = @floatFromInt(g.h) };
        const dst = c.SDL_FRect{
            .x = @round(x + inset + g.left),
            .y = @round(y + f.baseline - g.top),
            .w = src.w,
            .h = src.h,
        };
        _ = c.SDL_SetTextureColorMod(f.atlas.tex, color.r, color.g, color.b);
        _ = c.SDL_SetTextureAlphaMod(f.atlas.tex, color.a);
        _ = c.SDL_RenderTexture(f.atlas.ren, f.atlas.tex, &src, &dst);
        return true;
    }

    // Draws `s` on the grid of cells from x, in the row whose top is y; what
    // no font has is a box. Returns the cells it took.
    pub fn drawStr(f: *Face, x: f32, y: f32, s: []const u8, color: theme.Color) !usize {
        var col: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const d = utf8.decode(s, i);
            const w = width.cellWidth(d.cp);
            if (w > 0) {
                const cx = x + @as(f32, @floatFromInt(col)) * f.cell_w;
                if (!try f.drawChar(cx, y, d.cp, w, color)) f.box(cx, y, w, color);
            }
            col += w;
            i += d.len;
        }
        return col;
    }

    // A hollow box where a character would be.
    pub fn box(f: *Face, x: f32, y: f32, cells: usize, color: theme.Color) void {
        const ren = f.atlas.ren;
        _ = c.SDL_SetRenderDrawColor(ren, color.r, color.g, color.b, color.a);
        const r = c.SDL_FRect{ .x = x + 1, .y = y + 2, .w = @as(f32, @floatFromInt(cells)) * f.cell_w - 2, .h = f.line_h - 4 };
        _ = c.SDL_RenderRect(ren, &r);
    }

    // How many cells `cp` takes, by its advance, if a font has it.
    pub fn cellsOf(f: *const Face, cp: u32) ?u8 {
        const ft = f.fontFor(cp) orelse return null;
        if (c.FT_Load_Char(ft, cp, load_flags) != 0) return null;
        const adv = @as(f32, @floatFromInt(ft.*.glyph.*.advance.x)) / 64.0;
        return @intFromFloat(std.math.clamp(@round(adv / f.cell_w), 1, 2));
    }
};

// The face whose advances say how wide characters are: the text's.
var measured: ?*const Face = null;

fn measuredWidth(cp: u32) ?u8 {
    return if (measured) |f| f.cellsOf(cp) else null;
}

pub fn measureWith(f: *const Face) void {
    measured = f;
    width.forget();
    width.font_width = measuredWidth;
}

// The face for `names` (font names or paths, one per line) at `px` pixels.
// What could not be used is said in `problems`.
pub fn loadFace(gpa: Allocator, lib: c.FT_Library, atlas: *Atlas, names: []const u8, px: f32, problems: *std.ArrayList(u8)) !Face {
    var f = Face{ .gpa = gpa, .atlas = atlas, .px = px };
    errdefer f.deinit();
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    var lines = std.mem.splitScalar(u8, names, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;
        if (f.count == max_fonts) {
            try problems.print(gpa, "too many fonts: {s}; ", .{name});
            continue;
        }
        path.clearRetainingCapacity();
        if (!try fontfile.resolve(gpa, name, &path)) {
            try problems.print(gpa, "font not found: {s}; ", .{name});
            continue;
        }
        try path.append(gpa, 0);
        var ft: c.FT_Face = null;
        if (c.FT_New_Face(lib, path.items.ptr, 0, &ft) != 0 or ft == null) {
            try problems.print(gpa, "cannot read the font: {s}; ", .{path.items[0 .. path.items.len - 1]});
            continue;
        }
        _ = c.FT_Set_Char_Size(ft, 0, @intFromFloat(@round(px * 64)), 72, 72);
        f.fonts[f.count] = ft;
        f.count += 1;
    }
    if (f.count == 0) return error.NoFont;
    const first = f.fonts[0];
    const metrics = first.*.size.*.metrics;
    const ascent = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
    const descent = -@as(f32, @floatFromInt(metrics.descender)) / 64.0;
    f.line_h = @round(px * line_height);
    f.baseline = @round((f.line_h - (ascent + descent)) * 0.5 + ascent);
    f.cell_w = blk: {
        if (c.FT_Load_Char(first, 'M', load_flags) != 0) break :blk px * 0.6;
        break :blk @as(f32, @floatFromInt(first.*.glyph.*.advance.x)) / 64.0;
    };
    return f;
}

pub const Fonts = struct { text: Face, ui: Face };
