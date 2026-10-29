// The lexer for HTML: tags with their attributes, comments, the doctype
// and entities, with <script> handed to the JavaScript lexer and <style>
// to the CSS one. The state a line starts in:
//
//   0          in text
//   1 to 3     in a tag: any, <script ...>, <style ...>
//   4, 5       in an attribute's value quoted with " or '
//   6          in a comment
//   128 to 130 in a script, + its lexer's state (0, a comment, a template)
//   192 to 223 in a style sheet, + its lexer's state

const std = @import("std");
const Allocator = std.mem.Allocator;
const L = @import("lang.zig");
const Language = L.Language;
const Span = L.Span;
const languages = @import("languages.zig");
const code = @import("code.zig");
const style = @import("style.zig");

pub const markup_tag: u8 = 1;
pub const markup_script_tag: u8 = 2;
pub const markup_style_tag: u8 = 3;
pub const markup_value: u8 = 4; // + 0 for ", 1 for '
pub const markup_comment: u8 = 6;
pub const markup_script: u8 = 128;
pub const markup_style: u8 = 192;

// A script's states, which JavaScript's lexer can end a line in, packed small.
fn packScript(js: u8) u8 {
    return if (js == code.code_long + 2) markup_script + 2 else if (js == 1) markup_script + 1 else markup_script;
}
fn unpackScript(st: u8) u8 {
    const k = st - markup_script;
    return if (k == 2) code.code_long + 2 else if (k == 1) 1 else L.state_normal;
}

fn isName(c: u8) bool {
    return L.isIdent(c) or c == '-' or c == ':' or c == '.';
}

const Stop = struct { at: usize, state: u8 };

// The rest of a tag from line[i]: its attributes, up to and past its `>`;
// returns where it stopped and the state then.
fn lexTag(gpa: Allocator, line: []const u8, from: usize, end: usize, tag_state: u8, spans: *std.ArrayList(Span)) !Stop {
    var i = from;
    while (i < end) {
        const c = line[i];
        if (c == '>') {
            i += 1;
            if (tag_state == markup_script_tag) return .{ .at = i, .state = markup_script };
            if (tag_state == markup_style_tag) return .{ .at = i, .state = markup_style };
            return .{ .at = i, .state = L.state_normal };
        }
        if (c == '"' or c == '\'') {
            var j = i + 1;
            while (j < end and line[j] != c) j += 1;
            if (j >= end) {
                try L.pushSpan(gpa, spans, i, end - i, .string);
                return .{ .at = end, .state = markup_value + @as(u8, if (c == '"') 0 else 1) };
            }
            try L.pushSpan(gpa, spans, i, j + 1 - i, .string);
            i = j + 1;
            continue;
        }
        if (c == '=') {
            // An unquoted value runs to a blank or the tag's end.
            var j = i + 1;
            while (j < end and L.isBlank(line[j])) j += 1;
            if (j < end and line[j] != '"' and line[j] != '\'') {
                var k = j;
                while (k < end and !L.isBlank(line[k]) and line[k] != '>') k += 1;
                try L.pushSpan(gpa, spans, j, k - j, .string);
                i = k;
                continue;
            }
            i = j;
            continue;
        }
        if (isName(c) or c == '@') {
            var j = i + 1;
            while (j < end and (isName(line[j]) or line[j] == '@')) j += 1;
            try L.pushSpan(gpa, spans, i, j - i, .attribute);
            i = j;
            continue;
        }
        i += 1;
    }
    return .{ .at = end, .state = tag_state };
}

pub fn lex(gpa: Allocator, lang: *const Language, line: []const u8, start: usize, end: usize, state: u8, spans: *std.ArrayList(Span)) !u8 {
    _ = lang;
    var i = start;
    var st = state;
    while (i < end or st >= markup_script) {
        if (st >= markup_style) {
            const close = L.findNoCase(line, i, end, "</style");
            const css = try style.lex(gpa, &languages.css, line, i, close, st - markup_style, spans);
            if (close == end) return markup_style + css;
            i = close;
            st = L.state_normal;
            continue;
        }
        if (st >= markup_script) {
            const close = L.findNoCase(line, i, end, "</script");
            const js = try code.lex(gpa, &languages.javascript, line, i, close, unpackScript(st), spans);
            if (close == end) return packScript(js);
            i = close;
            st = L.state_normal;
            continue;
        }
        if (st == markup_comment) {
            const k = std.mem.indexOf(u8, line[i..end], "-->") orelse {
                try L.pushSpan(gpa, spans, i, end - i, .comment);
                return markup_comment;
            };
            try L.pushSpan(gpa, spans, i, k + 3, .comment);
            i += k + 3;
            st = L.state_normal;
            continue;
        }
        if (st == markup_value or st == markup_value + 1) {
            const q: u8 = if (st == markup_value) '"' else '\'';
            var j = i;
            while (j < end and line[j] != q) j += 1;
            if (j >= end) {
                try L.pushSpan(gpa, spans, i, end - i, .string);
                return st;
            }
            try L.pushSpan(gpa, spans, i, j + 1 - i, .string);
            i = j + 1;
            st = markup_tag;
            continue;
        }
        if (st != L.state_normal) {
            const s = try lexTag(gpa, line, i, end, st, spans);
            i = s.at;
            st = s.state;
            continue;
        }
        // In text.
        const c = line[i];
        const next: u8 = if (i + 1 < end) line[i + 1] else 0;
        if (c == '<' and L.at(line, i, "<!--")) {
            const k = std.mem.indexOf(u8, line[i + 4 .. end], "-->") orelse {
                try L.pushSpan(gpa, spans, i, end - i, .comment);
                return markup_comment;
            };
            try L.pushSpan(gpa, spans, i, k + 7, .comment);
            i += k + 7;
            continue;
        }
        if (c == '<' and next == '!') {
            var j = i + 2;
            while (j < end and line[j] != '>') j += 1;
            const e = @min(j + 1, end);
            try L.pushSpan(gpa, spans, i, e - i, .keyword);
            i = e;
            continue;
        }
        if (c == '<' and (L.isIdentStart(next) or next == '/')) {
            const closing = next == '/';
            var j = i + @as(usize, if (closing) 2 else 1);
            const from = j;
            while (j < end and isName(line[j])) j += 1;
            try L.pushSpan(gpa, spans, from, j - from, .tag);
            var tag = markup_tag;
            if (!closing and j - from == 6 and L.atNoCase(line, from, "script")) tag = markup_script_tag;
            if (!closing and j - from == 5 and L.atNoCase(line, from, "style")) tag = markup_style_tag;
            const s = try lexTag(gpa, line, j, end, tag, spans);
            i = s.at;
            st = s.state;
            continue;
        }
        if (c == '&' and (L.isIdentStart(next) or next == '#')) {
            var j = i + 1;
            while (j < end and (L.isIdent(line[j]) or line[j] == '#')) j += 1;
            if (j < end and line[j] == ';') {
                try L.pushSpan(gpa, spans, i, j + 1 - i, .constant);
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    return st;
}
