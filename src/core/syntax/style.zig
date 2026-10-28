// The lexer for style sheets: CSS, SCSS and Sass's indented syntax. Where
// a word is says what it is: a selector's tag, .class, #id and :pseudo; a
// declaration's property, then its value's numbers, colors, functions and
// keywords. The state a line starts in is how deep in braces it is, and
// whether it is in a /* comment:
//
//   0 to 15    that many braces deep
//   + 16       in a block comment

const std = @import("std");
const Allocator = std.mem.Allocator;
const L = @import("lang.zig");
const Language = L.Language;
const Span = L.Span;

pub const style_comment: u8 = 16;

fn isCssIdent(c: u8) bool {
    return L.isIdent(c) or c == '-';
}

fn cssIdentEnd(line: []const u8, i: usize, end: usize) usize {
    var j = i;
    while (j < end and isCssIdent(line[j])) j += 1;
    return j;
}

fn isTagChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or L.isDigit(c);
}

// Whether the word ending at line[j] begins a declaration, "name: value":
// a colon follows, and no brace opens before the declaration ends, which
// would make it a selector, as SCSS's nested a:hover { is.
fn isProperty(lang: *const Language, line: []const u8, j: usize, end: usize, depth: u8) bool {
    if (!lang.indented and depth == 0) return false;
    var k = j;
    while (k < end and L.isBlank(line[k])) k += 1;
    if (k >= end or line[k] != ':') return false;
    // Sass, without braces, tells a:hover from "color: red" by the space.
    if (lang.indented and k + 1 < end and !L.isBlank(line[k + 1])) return false;
    var m = k + 1;
    while (m < end and line[m] != ';' and line[m] != '}') : (m += 1) {
        if (line[m] == '{' and !(m > 0 and line[m - 1] == '#')) return false; // #{...} is SCSS's interpolation
    }
    return true;
}

pub fn lex(gpa: Allocator, lang: *const Language, line: []const u8, start: usize, end: usize, state: u8, spans: *std.ArrayList(Span)) !u8 {
    var depth: u8 = state & 15;
    var i = start;
    if ((state & style_comment) != 0) {
        const k = std.mem.indexOf(u8, line[i..end], "*/") orelse {
            try L.pushSpan(gpa, spans, i, end - i, .comment);
            return state;
        };
        try L.pushSpan(gpa, spans, i, k + 2, .comment);
        i += k + 2;
    }
    var in_value = false; // after a declaration's colon, until its end
    // Sass's mixins: =name to define one, +name to include it.
    if (lang.indented) {
        var k = i;
        while (k < end and L.isBlank(line[k])) k += 1;
        if (k < end and (line[k] == '=' or line[k] == '+') and k + 1 < end and L.isIdentStart(line[k + 1])) {
            const e = cssIdentEnd(line, k + 1, end);
            try L.pushSpan(gpa, spans, k, e - k, .keyword);
            i = e;
            in_value = true;
        }
    }
    while (i < end) {
        const c = line[i];
        const next: u8 = if (i + 1 < end) line[i + 1] else 0;
        if (c == '/' and next == '*') {
            const k = std.mem.indexOf(u8, line[i + 2 .. end], "*/") orelse {
                try L.pushSpan(gpa, spans, i, end - i, .comment);
                return depth | style_comment;
            };
            try L.pushSpan(gpa, spans, i, k + 4, .comment);
            i += k + 4;
            continue;
        }
        if (lang.scss and c == '/' and next == '/') {
            try L.pushSpan(gpa, spans, i, end - i, .comment);
            break;
        }
        if (c == '"' or c == '\'') {
            var j = i + 1;
            while (j < end and line[j] != c) {
                if (line[j] == '\\') j += 1;
                j += 1;
            }
            const e = @min(j + 1, end);
            try L.pushSpan(gpa, spans, i, e - i, .string);
            i = e;
            continue;
        }
        if (c == '{') {
            depth = @min(depth + 1, 15);
            in_value = false;
            i += 1;
            continue;
        }
        if (c == '}') {
            depth -|= 1;
            in_value = false;
            i += 1;
            continue;
        }
        if (c == ';') {
            in_value = false;
            i += 1;
            continue;
        }
        if (c == '@' and L.isIdentStart(next)) {
            const e = cssIdentEnd(line, i + 1, end);
            try L.pushSpan(gpa, spans, i, e - i, .keyword);
            i = e;
            continue;
        }
        if (c == '!' and L.isIdentStart(next)) {
            const e = cssIdentEnd(line, i + 1, end);
            try L.pushSpan(gpa, spans, i, e - i, lang.wordKind(line[i..e]));
            i = e;
            continue;
        }
        if ((lang.scss and c == '$' and L.isIdentStart(next)) or (c == '-' and next == '-' and i + 2 < end and isCssIdent(line[i + 2]))) {
            const e = cssIdentEnd(line, i + 1, end);
            try L.pushSpan(gpa, spans, i, e - i, .variable);
            var k = e;
            while (k < end and L.isBlank(line[k])) k += 1;
            if (k < end and line[k] == ':') in_value = true;
            i = e;
            continue;
        }
        if (c == '#' and next != '{') {
            // A color in a value; an id in a selector.
            const e = cssIdentEnd(line, i + 1, end);
            try L.pushSpan(gpa, spans, i, e - i, if (in_value) .constant else .attribute);
            i = e;
            continue;
        }
        if (!in_value and c == '.' and (L.isIdentStart(next) or next == '-')) {
            const e = cssIdentEnd(line, i + 1, end);
            try L.pushSpan(gpa, spans, i, e - i, .attribute);
            i = e;
            continue;
        }
        if (!in_value and c == ':' and (L.isIdentStart(next) or next == ':')) {
            const j = if (next == ':') i + 2 else i + 1;
            const e = cssIdentEnd(line, j, end);
            try L.pushSpan(gpa, spans, i, e - i, .keyword);
            i = e;
            continue;
        }
        if (L.isDigit(c) or ((c == '.' or c == '-') and L.isDigit(next))) {
            var j = i + 1;
            while (j < end and (L.isDigit(line[j]) or line[j] == '.')) j += 1;
            // Its unit: px, em, %, ...
            while (j < end and (L.isIdentStart(line[j]) or line[j] == '%')) j += 1;
            try L.pushSpan(gpa, spans, i, j - i, .number);
            i = j;
            continue;
        }
        if (L.isIdentStart(c) or (c == '-' and (L.isIdentStart(next) or next == '-'))) {
            const e = cssIdentEnd(line, i, end);
            var kind: L.Tok = .text;
            if (!in_value and isProperty(lang, line, e, end, depth)) {
                kind = .property;
                in_value = true;
            } else if (in_value) {
                var k = e;
                while (k < end and L.isBlank(line[k])) k += 1;
                kind = if (k < end and line[k] == '(') .function else if (lang.wordKind(line[i..e]) != .text) .keyword else .constant;
            } else {
                // A selector's word: a tag's name is lower case.
                kind = if (L.allOf(line[i..e], isTagChar)) .tag else lang.wordKind(line[i..e]);
            }
            try L.pushSpan(gpa, spans, i, e - i, kind);
            i = e;
            continue;
        }
        i += 1;
    }
    return depth;
}
