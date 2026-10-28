// Which key does what: commands by name, keys written as "ctrl+shift+left",
// the defaults for macOS and for the others, and the settings' changes.
//
// A key is its modifiers and its name: the character a key types, as the
// keyboard's layout has it ("a", "/"), or the key's own name ("left",
// "return", "pageup", "f3"). "mod" stands for the command key: Cmd on
// macOS, Ctrl elsewhere. Moving with Shift held selects, so "shift+left"
// needs no binding of its own unless it should do something else.

import std;

// The modifier bits, as gfx's MOD_* have them.
let KEY_SHIFT: i32 = 1;
let KEY_CTRL: i32 = 2;
let KEY_ALT: i32 = 4;
let KEY_CMD: i32 = 8;

// The commands, by the names the settings use; a command's value is its
// line here, counting from 0.
let COMMAND_NAMES = """
    none
    left
    right
    up
    down
    word_left
    word_right
    line_start
    line_end
    doc_start
    doc_end
    page_up
    page_down
    delete_left
    delete_right
    delete_word_left
    delete_word_right
    delete_to_line_start
    delete_to_line_end
    newline
    indent
    undo
    redo
    copy
    cut
    paste
    select_all
    find
    find_next
    find_previous
    save
    quit
    toggle_tree
    cancel
    reload
    """;

let CMD_NONE = 0;
let CMD_LEFT = 1;
let CMD_RIGHT = 2;
let CMD_UP = 3;
let CMD_DOWN = 4;
let CMD_WORD_LEFT = 5;
let CMD_WORD_RIGHT = 6;
let CMD_LINE_START = 7;
let CMD_LINE_END = 8;
let CMD_DOC_START = 9;
let CMD_DOC_END = 10;
let CMD_PAGE_UP = 11;
let CMD_PAGE_DOWN = 12;
let CMD_DELETE_LEFT = 13;
let CMD_DELETE_RIGHT = 14;
let CMD_DELETE_WORD_LEFT = 15;
let CMD_DELETE_WORD_RIGHT = 16;
let CMD_DELETE_TO_LINE_START = 17;
let CMD_DELETE_TO_LINE_END = 18;
let CMD_NEWLINE = 19;
let CMD_INDENT = 20;
let CMD_UNDO = 21;
let CMD_REDO = 22;
let CMD_COPY = 23;
let CMD_CUT = 24;
let CMD_PASTE = 25;
let CMD_SELECT_ALL = 26;
let CMD_FIND = 27;
let CMD_FIND_NEXT = 28;
let CMD_FIND_PREVIOUS = 29;
let CMD_SAVE = 30;
let CMD_QUIT = 31;
let CMD_TOGGLE_TREE = 32;
let CMD_CANCEL = 33;
let CMD_RELOAD = 34;

// Commands that move the carets, which select when Shift is held.
fn is_motion(cmd: i64) -> bool { cmd >= CMD_LEFT && cmd <= CMD_PAGE_DOWN }

fn command_named(name: const u8[:]) -> i64 {
    var found = -1;
    var i = 0;
    each_split(COMMAND_NAMES, '\n') {
        if it == name { found = i; }
        i++;
    };
    return found;
}

// The bindings every platform has, "mod" being its command key.
let COMMON_KEYS = """
    left left
    right right
    up up
    down down
    home line_start
    end line_end
    pageup page_up
    pagedown page_down
    backspace delete_left
    delete delete_right
    return newline
    keypadenter newline
    tab indent
    escape cancel
    mod+z undo
    mod+shift+z redo
    mod+y redo
    mod+c copy
    mod+x cut
    mod+v paste
    mod+a select_all
    mod+f find
    mod+g find_next
    mod+shift+g find_previous
    mod+s save
    mod+q quit
    mod+b toggle_tree
    mod+r reload
    mod+home doc_start
    mod+end doc_end
    """;

// macOS: Option moves by words, Cmd to the ends, and Ctrl as Emacs does.
let MAC_KEYS = """
    alt+left word_left
    alt+right word_right
    cmd+left line_start
    cmd+right line_end
    cmd+up doc_start
    cmd+down doc_end
    alt+backspace delete_word_left
    alt+delete delete_word_right
    cmd+backspace delete_to_line_start
    ctrl+a line_start
    ctrl+e line_end
    ctrl+n down
    ctrl+p up
    ctrl+k delete_to_line_end
    """;

// Elsewhere Ctrl moves by words.
let OTHER_KEYS = """
    ctrl+left word_left
    ctrl+right word_right
    ctrl+backspace delete_word_left
    ctrl+delete delete_word_right
    """;

struct Binding { mods: i32, key: u8[..24], cmd: i64 }

var keymap: Binding[>..<] = [];

// A key's name as bindings compare it: lower case, without spaces, and
// the usual other names for a few keys made the one SDL gives.
fn key_name_of(name: const u8[:], out: u8[..24]&) {
    out.resize(0, 0);
    for c in name {
        if c == ' ' || out.len == 24 { continue; }
        out.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c });
    }
    let n = out[..];
    let alias = if n == "enter" { "return" } else if n == "esc" { "escape" } else if n == "del" { "delete" }
                else if n == "pgup" { "pageup" } else if n == "pgdn" { "pagedown" } else if n == "bs" { "backspace" }
                else if n == "space" { " " } else if n == "plus" { "+" } else { "" };
    if alias.len > 0 {
        out.resize(0, 0);
        out.append(alias);
    }
}

// Reads a key written as "ctrl+shift+a"; false if it is not one.
fn parse_key(spec: const u8[:], mac: bool, mods: i32&, key: u8[..24]&) -> bool {
    let parts = split(spec, '+');
    if parts.len == 0 || parts[parts.len - 1].len == 0 { return false; }
    mods = 0;
    for p, i in parts {
        if i == parts.len - 1 { break; }
        var m: u8[..24] = [];
        key_name_of(p, m);
        let name = m[..];
        if name == "shift" { mods |= KEY_SHIFT; }
        else if name == "ctrl" || name == "control" { mods |= KEY_CTRL; }
        else if name == "alt" || name == "option" || name == "opt" { mods |= KEY_ALT; }
        else if name == "cmd" || name == "command" || name == "super" || name == "win" || name == "meta" { mods |= KEY_CMD; }
        else if name == "mod" { mods |= if mac { KEY_CMD } else { KEY_CTRL }; }
        else { return false; }
    }
    key_name_of(parts[parts.len - 1], key);
    return key.len > 0;
}

// Binds `key` to `cmd`, in place of what it did; CMD_NONE unbinds it.
fn bind(mods: i32, key: const u8[:], cmd: i64) {
    var i = 0;
    while i < keymap.len {
        if keymap[i].mods == mods && keymap[i].key[..] == key { remove_at(keymap, i); } else { i++; }
    }
    if cmd == CMD_NONE { return; }
    var b = Binding { mods: mods, key: [], cmd: cmd };
    b.key.append(key);
    keymap.push(b);
}

// Applies "key command" lines; what cannot be read goes into `problems`.
fn bind_lines(lines: const u8[:], sep: u8, mac: bool, problems: u8[>..]&) {
    each_split(lines, '\n') {
        let at = position(it, sep);
        if it.len > 0 {
            var mods: i32 = 0;
            var key: u8[..24] = [];
            let spec = if at < 0 { it } else { it[..at] };
            let name = if at < 0 { it[it.len..] } else { it[at + 1..] };
            let cmd = command_named(name);
            if !parse_key(spec, mac, mods, key) { format(problems, "not a key: ", spec, "; "); }
            else if cmd < 0 { format(problems, "no such command: ", name, "; "); }
            else { bind(mods, key, cmd); }
        }
    };
}

// The defaults for the platform, then the settings' bindings over them
// ("key\tcommand" lines, in the order the files gave them).
fn build_keymap(mac: bool, settings: const u8[:], problems: u8[>..]&) {
    keymap.resize(0, default<Binding>());
    bind_lines(COMMON_KEYS, ' ', mac, problems);
    bind_lines(if mac { MAC_KEYS } else { OTHER_KEYS }, ' ', mac, problems);
    bind_lines(settings, '\t', mac, problems);
}

// What a key does: the command, and whether it moves selecting, which a
// motion's key does with Shift added when Shift has no binding of its own.
fn command_for(mods: i32, key: const u8[:]) -> i64, bool {
    let m = mods & (KEY_SHIFT | KEY_CTRL | KEY_ALT | KEY_CMD);
    for b in keymap { if b.mods == m && b.key[..] == key { return b.cmd, false; } }
    if (m & KEY_SHIFT) != 0 {
        for b in keymap {
            if b.mods == (m & ~KEY_SHIFT) && b.key[..] == key && is_motion(b.cmd) { return b.cmd, true; }
        }
    }
    return CMD_NONE, false;
}
