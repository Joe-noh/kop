// What a file looks like on disk: its byte-order mark, line breaks,
// indentation and encoding, found when it is opened and kept when it is saved.

import std;
import os;
import core.text;
import core.utf8;

struct FileInfo {
    bom: bool,              // starts with the UTF-8 byte-order mark
    crlf: bool,             // its first line break is "\r\n"
    utf8: bool,             // its start reads as UTF-8; if not, it opens read-only
    tabs: bool,             // more lines are indented with tabs than with spaces
}

fn has_bom(data: const u8[:]) -> bool {
    data.len >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF
}

// The bytes after the byte-order mark, if any.
fn body(data: const u8[:]) -> const u8[:] { if has_bom(data) { data[3..] } else { data } }

fn detect(data: const u8[:]) -> FileInfo {
    let b = body(data);
    var info = FileInfo { bom: has_bom(data), crlf: false, utf8: looks_utf8(b, 1 << 20), tabs: false };
    let nl = find(b, "\n");
    info.crlf = nl > 0 && b[nl - 1] == '\r';
    // Indentation: count the first thousand lines that start with each.
    var tab_lines = 0;
    var space_lines = 0;
    var lines = 0;
    var at_start = true;
    for c in b[..min(b.len, 1 << 20)] {
        if at_start {
            if c == '\t' { tab_lines++; }
            else if c == ' ' { space_lines++; }
            at_start = false;
        }
        if c == '\n' {
            at_start = true;
            lines++;
            if lines == 1000 { break; }
        }
    }
    info.tabs = tab_lines > space_lines;
    return info;
}

fn save(t: Text&, info: FileInfo, path: const u8[:]) -> bool {
    var out: u8[>..] = [];
    if info.bom { out.append("\xEF\xBB\xBF"); }
    read(t, 0, t.len, out);
    return write_file_atomic(path, out);
}
