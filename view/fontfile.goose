// Font files: finding them by name among the system's fonts, taking one
// font out of a collection (.ttc), and reading which characters a font has.

import std;
import os;
import core.utf8;

// The fonts used when the settings name none, first choice first; the
// ones a system does not have are skipped.
let MAC_FONTS = "Menlo\nヒラギノ角ゴシック W3";
let LINUX_FONTS = "DejaVuSansMono\nNotoSansMonoCJKjp-Regular\nNotoSansCJK-Regular\nNotoSansCJKjp-Regular\nipag";
let WINDOWS_FONTS = "consola\nBIZ-UDGothicR\nmsgothic\nYuGothR";

fn is_mac() -> bool { file_exists("/System/Library/Fonts/Menlo.ttc") || is_dir("/System/Library/Fonts") }

fn is_windows() -> bool {
    var windir: u8[>..] = [];
    env("WINDIR", windir)
}

fn default_fonts() -> const u8[:] {
    if is_mac() { MAC_FONTS } else if is_windows() { WINDOWS_FONTS } else { LINUX_FONTS }
}

// Where the system keeps fonts, as lines.
fn font_dirs(out: u8[>..]&) {
    var home: u8[>..] = [];
    let has_home = env("HOME", home);
    if is_mac() {
        out.append("/System/Library/Fonts\n/System/Library/Fonts/Supplemental\n/Library/Fonts\n");
        if has_home { format(out, home, "/Library/Fonts\n"); }
    } else if is_windows() {
        var windir: u8[>..] = [];
        env("WINDIR", windir);
        format(out, windir, "/Fonts\n");
        var local: u8[>..] = [];
        if env("LOCALAPPDATA", local) { format(out, local, "/Microsoft/Windows/Fonts\n"); }
    } else {
        out.append("/usr/share/fonts\n/usr/local/share/fonts\n");
        if has_home { format(out, home, "/.local/share/fonts\n", home, "/.fonts\n"); }
    }
}

fn has_font_ext(name: const u8[:]) -> bool {
    var lower: u8[>..] = [];
    lower.append(name);
    to_lower(lower);
    ends_with(lower, ".ttf") || ends_with(lower, ".otf") || ends_with(lower, ".ttc")
}

// Kana that take a voiced mark (゛) as the next codepoint, and those that
// also take the semi-voiced one (゜); katakana are these plus 0x60.
let VOICED: u32[20] = [0x304B, 0x304D, 0x304F, 0x3051, 0x3053, 0x3055, 0x3057, 0x3059, 0x305B, 0x305D,
                       0x305F, 0x3061, 0x3064, 0x3066, 0x3068, 0x306F, 0x3072, 0x3075, 0x3078, 0x307B];

// `s` with each kana and a combining voiced or semi-voiced mark after it
// made one character, as macOS file names have them apart (NFD) and
// settings, typed, have them together (NFC).
fn compose_kana(s: const u8[:], out: u8[>..]&) {
    var i = 0;
    while i < s.len {
        var cp, n = decode(s, i);
        if i + n < s.len {
            let mark, m = decode(s, i + n);
            if mark == 0x3099 || mark == 0x309A {
                let base = if cp >= 0x30A0 { cp - 0x60 } else { cp };
                let k = position(VOICED, base);
                if k >= 0 && (mark == 0x3099 || k >= 15) {
                    cp += if mark == 0x3099 { 1 } else { 2 };
                    n += m;
                } else if mark == 0x3099 && base == 0x3046 {
                    cp = if cp >= 0x30A0 { 0x30F4 } else { 0x3094 };
                    n += m;
                }
            }
        }
        push_utf8(out, cp);
        i += n;
    }
}

// Looks in the directories `dirs` (one per line) and those below them, up
// to `depth` levels down, for the file `name` with a font extension (or
// `name` itself, when it has one).
fn find_in_dirs(dirs: const u8[:], name: const u8[:], depth: i64, out: u8[>..]&) -> bool {
    var want: u8[>..] = [];
    compose_kana(name, want);
    let with_ext = has_font_ext(want);
    var entry: u8[>..] = [];
    var level: u8[>..] = [];
    level.append(dirs);
    for d in depth + 1 {
        var below: u8[>..] = [];
        var listing: u8[>..] = [];
        var sub: u8[>..] = [];
        each_split(level, '\n') { dir =>
            listing.clear();
            if dir.len > 0 && list_dir(dir, listing) {
                each_split(listing, '\n') { e =>
                    entry.clear();
                    compose_kana(e, entry);
                    let matched = if with_ext { entry == want } else { entry.len == want.len + 4 && starts_with(entry, want) && has_font_ext(entry) };
                    if matched {
                        format(out, dir, "/", e);
                        return true;
                    }
                    if e.len > 0 && e[0] != '.' && d < depth {
                        sub.clear();
                        format(sub, dir, "/", e);
                        if is_dir(sub) { format(below, sub, "\n"); }
                    }
                };
            }
        };
        level = copy(below);
    }
    return false;
}

// The file for a font named in the settings: a path (with "~/" for the
// home directory), or a file name, with or without its extension, among
// the system's fonts.
fn resolve_font(name: const u8[:], out: u8[>..]&) -> bool {
    if find(name, "/") >= 0 || find(name, "\\") >= 0 {
        if starts_with(name, "~/") {
            var home: u8[>..] = [];
            if !env("HOME", home) { return false; }
            format(out, home, name[1..]);
        } else {
            out.append(name);
        }
        return file_exists(out);
    }
    var dirs: u8[>..] = [];
    font_dirs(dirs);
    return find_in_dirs(dirs, name, 3, out);
}

fn be16(d: const u8[:], i: i64) -> i64 { (d[i] as i64 << 8) | d[i + 1] }
fn be32(d: const u8[:], i: i64) -> i64 { (be16(d, i) << 16) | be16(d, i + 2) }

// Whether `d` starts like a single TrueType or OpenType font whose tables
// all lie within it.
fn plausible(d: const u8[:]) -> bool {
    if d.len < 12 { return false; }
    let tag = be32(d, 0);
    if tag != 0x00010000 && tag != 0x74727565 && tag != 0x4F54544F { return false; }
    let tables = be16(d, 4);
    if 12 + tables * 16 > d.len { return false; }
    for i in tables {
        let at = 12 + i * 16;
        let offset = be32(d, at + 8);
        let size = be32(d, at + 12);
        if offset > d.len || size > d.len - offset { return false; }
    }
    return true;
}

// The bytes of the first font of `data` as a font of its own. In a
// collection each font's tables lie where they are for all of them, so
// that font's table directory, copied over the start, is enough.
fn single_font(data: const u8[:], out: u8[>..]&) -> bool {
    out.append(data);
    if data.len >= 16 && data[0] == 't' && data[1] == 't' && data[2] == 'c' && data[3] == 'f' {
        let at = be32(data, 12);
        if at + 12 > data.len { return false; }
        let len = 12 + 16 * be16(data, at + 4);
        if at + len > data.len { return false; }
        for k in len { out[k] = data[at + k]; }
    }
    return plausible(out);
}

// Marks in `has` (one byte per codepoint below 0x10000) the characters the
// font maps to a glyph, from its cmap table.
fn coverage(font: const u8[:], has: u8[>..]&) {
    has.resize(0, 0);
    has.resize(0x10000, 0);
    if !plausible(font) { return; }
    var cmap = -1;
    for i in be16(font, 4) {
        let at = 12 + i * 16;
        if font[at] == 'c' && font[at + 1] == 'm' && font[at + 2] == 'a' && font[at + 3] == 'p' { cmap = be32(font, at + 8); }
    }
    if cmap < 0 || cmap + 4 > font.len { return; }
    // The Unicode subtable: format 12 (all of Unicode) if there is one, else format 4.
    var best = -1;
    var best_format = 0;
    for i in be16(font, cmap + 2) {
        let rec = cmap + 4 + i * 8;
        if rec + 8 > font.len { break; }
        let platform = be16(font, rec);
        let encoding = be16(font, rec + 2);
        let sub = cmap + be32(font, rec + 4);
        if sub + 2 > font.len { continue; }
        let format = be16(font, sub);
        let unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
        if unicode && (format == 12 || (format == 4 && best_format != 12)) {
            best = sub;
            best_format = format;
        }
    }
    if best < 0 { return; }
    if best_format == 12 {
        let groups = be32(font, best + 12);
        for g in groups {
            let at = best + 16 + g * 12;
            if at + 12 > font.len { break; }
            let first = be32(font, at);
            let last = min(be32(font, at + 4), 0xFFFF);
            for cp in first..last + 1 { has[cp] = 1; }
        }
        return;
    }
    let segs = be16(font, best + 6) / 2;
    let ends = best + 14;
    let starts = ends + segs * 2 + 2;
    if starts + segs * 2 > font.len { return; }
    for s in segs {
        let last = be16(font, ends + s * 2);
        let first = be16(font, starts + s * 2);
        if last == 0xFFFF && first == 0xFFFF { continue; }
        for cp in first..last + 1 { has[cp] = 1; }
    }
}
