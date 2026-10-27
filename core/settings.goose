// Settings, from JSON files read one over another: the defaults, then
// ~/.kop/settings.json, then the project's .kop/settings.json. A file
// sets only what it names.
//
//   {
//     "theme": "spacegray",
//     "editor": { "fontSize": 14, "fontFamily": ["Menlo", "ヒラギノ角ゴシック W3"] },
//     "ui": { "fontSize": 13 },
//     "keybindings": { "ctrl+k": "delete_to_line_end", "mod+b": "none" }
//   }
//
// A font is a file name among the system's fonts, with or without its
// extension, or a path; each character is drawn with the first font that
// has it. Without a fontFamily the text uses the system's usual fonts and
// the ui the text's.

import std;
import os;
import json;

let MIN_FONT_SIZE: f32 = 6.0;
let MAX_FONT_SIZE: f32 = 24.0;

struct Settings {
    editor_font_size: f32 = 14.0,   // in points
    ui_font_size: f32 = 13.0,
    editor_fonts: u8[..1024] = [],  // font names, one per line; empty for the defaults
    ui_fonts: u8[..1024] = [],
    theme: u8[..64] = [],           // a theme's name; empty for the default
    keybindings: u8[..4096] = [],   // "key\tcommand" lines, the later files' last
}

// "keybindings": { "key": "command", ... }, a null command unbinding the key.
fn read_keybindings(r: json::Reader&, at: u8[..4096]&, problems: u8[>..]&) {
    var lines: u8[>..] = [];
    lines.append(at);
    json::each_member(r) { key =>
        var scratch: u8[>..] = [];
        if json::peek(r) == 'n' {
            json::skip(r);
            format(lines, key, "\tnone\n");
        } else {
            format(lines, key, "\t", json::read_string(r, scratch), "\n");
        }
    };
    if lines.len > 4096 {
        problems.append("too many keybindings; ");
        return;
    }
    at.resize(0, 0);
    at.append(lines);
}

// "fontFamily": one name, or a list of them.
fn read_font_family(r: json::Reader&, key: const u8[:], at: u8[..1024]&, problems: u8[>..]&) {
    var scratch: u8[>..] = [];
    var names: u8[>..] = [];
    if json::peek(r) == '[' {
        json::each_element(r) {
            scratch.clear();
            let name = json::read_string(r, scratch);
            format(names, name, "\n");
        };
    } else {
        format(names, json::read_string(r, scratch), "\n");
    }
    if names.len > 1024 {
        format(problems, key, " is too long; ");
        return;
    }
    at.resize(0, 0);
    at.append(names);
}

fn read_font_size(r: json::Reader&, key: const u8[:], at: f32&, problems: u8[>..]&) {
    let v = json::read_number(r);
    if v < MIN_FONT_SIZE || v > MAX_FONT_SIZE {
        format(problems, key, " must be from ", MIN_FONT_SIZE as i64, " to ", MAX_FONT_SIZE as i64, "; ");
        at = clamp(v as f32, MIN_FONT_SIZE, MAX_FONT_SIZE);
    } else {
        at = v as f32;
    }
}

// Reads what `text` sets over `s`. Problems, such as a key it does not
// know or a value out of range, go into `problems`; false if the text is
// not JSON, which leaves `s` as it was and says only that.
fn apply_settings(s: Settings&, text: const u8[:], problems: u8[>..]&) -> bool {
    let start = problems.len;
    var next = s;
    var r = json::reader(text);
    json::each_member(r) { section =>
        if section == "editor" {
            json::each_member(r) { key =>
                if key == "fontSize" { read_font_size(r, "editor.fontSize", next.editor_font_size, problems); }
                else if key == "fontFamily" { read_font_family(r, "editor.fontFamily", next.editor_fonts, problems); }
                else { format(problems, "unknown setting: editor.", key, "; "); json::skip(r); }
            };
        } else if section == "ui" {
            json::each_member(r) { key =>
                if key == "fontSize" { read_font_size(r, "ui.fontSize", next.ui_font_size, problems); }
                else if key == "fontFamily" { read_font_family(r, "ui.fontFamily", next.ui_fonts, problems); }
                else { format(problems, "unknown setting: ui.", key, "; "); json::skip(r); }
            };
        } else if section == "keybindings" {
            read_keybindings(r, next.keybindings, problems);
        } else if section == "theme" {
            var scratch: u8[>..] = [];
            let name = json::read_string(r, scratch);
            next.theme.resize(0, 0);
            next.theme.append(name[..min(name.len, 64)]);
        } else {
            format(problems, "unknown setting: ", section, "; ");
            json::skip(r);
        }
    };
    if !json::finish(r) {
        problems.resize(start, 0);
        problems.append(json::message(r));
        return false;
    }
    s = next;
    return true;
}

// Reads the file at `path` over `s`, if there is one; what went wrong goes
// into `problems`, after the file's name.
fn load_settings_file(s: Settings&, path: const u8[:], problems: u8[>..]&) {
    if !file_exists(path) { return; }
    var text: u8[>..] = [];
    if !read_file(path, text) {
        format(problems, path, ": cannot read; ");
        return;
    }
    var found: u8[>..] = [];
    apply_settings(s, text, found);
    if found.len > 0 { format(problems, path, ": ", found, " "); }
}

// The directory a path's project settings belong to: the path itself for a
// directory, else the directory the file is in.
fn project_dir(path: const u8[:], out: u8[>..]&) {
    if path.len == 0 { return; }
    if is_dir(path) { out.append(path); return; }
    let k = rfind(path, "/");
    if k < 0 { out.append("."); } else if k == 0 { out.append("/"); } else { out.append(path[..k]); }
}

// The defaults, the user's settings, then the project's.
fn load_settings(path: const u8[:], problems: u8[>..]&) -> Settings {
    var s = Settings {};
    var home: u8[>..] = [];
    if env("HOME", home) { load_settings_file(s, str(home, "/.kop/settings.json"), problems); }
    var dir: u8[>..] = [];
    project_dir(path, dir);
    if dir.len > 0 { load_settings_file(s, str(dir, "/.kop/settings.json"), problems); }
    return s;
}
