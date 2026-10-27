// The lexer for style sheets: CSS, SCSS and Sass's indented syntax. Where
// a word is says what it is: a selector's tag, .class, #id and :pseudo; a
// declaration's property, then its value's numbers, colors, functions and
// keywords. The state a line starts in is how deep in braces it is, and
// whether it is in a /* comment:
//
//   0 to 15    that many braces deep
//   + 16       in a block comment

import std;
import core.syntax.lang;

let STYLE_COMMENT: u8 = 16;

fn is_css_ident(c: u8) -> bool { is_ident(c) || c == '-' }

fn css_ident_end(line: const u8[:], i: i64, end: i64) -> i64 {
    var j = i;
    while j < end && is_css_ident(line[j]) { j++; }
    return j;
}

// Whether the word ending at line[j] begins a declaration, "name: value":
// a colon follows, and no brace opens before the declaration ends, which
// would make it a selector, as SCSS's nested a:hover { is.
fn is_property(lang: Language, line: const u8[:], j: i64, end: i64, depth: i64) -> bool {
    if !lang.indented && depth == 0 { return false; }
    var k = j;
    while k < end && is_blank(line[k]) { k++; }
    if k >= end || line[k] != ':' { return false; }
    // Sass, without braces, tells a:hover from "color: red" by the space.
    if lang.indented && k + 1 < end && !is_blank(line[k + 1]) { return false; }
    var m = k + 1;
    while m < end && line[m] != ';' && line[m] != '}' {
        if line[m] == '{' && !(m > 0 && line[m - 1] == '#') { return false; }     // #{...} is SCSS's interpolation
        m++;
    }
    return true;
}

fn lex_style(lang: Language, line: const u8[:], start: i64, end: i64, state: u8, spans: Span[>..<]&) -> u8 {
    var depth: i64 = state & 15;
    var i = start;
    if (state & STYLE_COMMENT) != 0 {
        let k = find(line[i..end], "*/");
        if k < 0 {
            push_span(spans, i, end - i, TOK_COMMENT);
            return state;
        }
        push_span(spans, i, k + 2, TOK_COMMENT);
        i += k + 2;
    }
    var in_value = false;           // after a declaration's colon, until its end
    // Sass's mixins: =name to define one, +name to include it.
    if lang.indented {
        var k = i;
        while k < end && is_blank(line[k]) { k++; }
        if k < end && (line[k] == '=' || line[k] == '+') && k + 1 < end && is_ident_start(line[k + 1]) {
            let e = css_ident_end(line, k + 1, end);
            push_span(spans, k, e - k, TOK_KEYWORD);
            i = e;
            in_value = true;
        }
    }
    while i < end {
        let c = line[i];
        let next: u8 = if i + 1 < end { line[i + 1] } else { 0 };
        if c == '/' && next == '*' {
            let k = find(line[i + 2..end], "*/");
            if k < 0 {
                push_span(spans, i, end - i, TOK_COMMENT);
                return depth as u8 | STYLE_COMMENT;
            }
            push_span(spans, i, k + 4, TOK_COMMENT);
            i += k + 4;
            continue;
        }
        if lang.scss && c == '/' && next == '/' {
            push_span(spans, i, end - i, TOK_COMMENT);
            break;
        }
        if c == '"' || c == '\'' {
            var j = i + 1;
            while j < end && line[j] != c {
                if line[j] == '\\' { j++; }
                j++;
            }
            let e = min(j + 1, end);
            push_span(spans, i, e - i, TOK_STRING);
            i = e;
            continue;
        }
        if c == '{' { depth = min(depth + 1, 15); in_value = false; i++; continue; }
        if c == '}' { depth = max(depth - 1, 0); in_value = false; i++; continue; }
        if c == ';' { in_value = false; i++; continue; }
        if c == '@' && is_ident_start(next) {
            let e = css_ident_end(line, i + 1, end);
            push_span(spans, i, e - i, TOK_KEYWORD);
            i = e;
            continue;
        }
        if c == '!' && is_ident_start(next) {
            let e = css_ident_end(line, i + 1, end);
            push_span(spans, i, e - i, word_kind(lang.id, line[i..e]));
            i = e;
            continue;
        }
        if (lang.scss && c == '$' && is_ident_start(next)) || (c == '-' && next == '-' && i + 2 < end && is_css_ident(line[i + 2])) {
            let e = css_ident_end(line, i + 1, end);
            push_span(spans, i, e - i, TOK_VARIABLE);
            var k = e;
            while k < end && is_blank(line[k]) { k++; }
            if k < end && line[k] == ':' { in_value = true; }
            i = e;
            continue;
        }
        if c == '#' && next != '{' {
            // A color in a value; an id in a selector.
            let e = css_ident_end(line, i + 1, end);
            push_span(spans, i, e - i, if in_value { TOK_CONSTANT } else { TOK_ATTRIBUTE });
            i = e;
            continue;
        }
        if !in_value && c == '.' && (is_ident_start(next) || next == '-') {
            let e = css_ident_end(line, i + 1, end);
            push_span(spans, i, e - i, TOK_ATTRIBUTE);
            i = e;
            continue;
        }
        if !in_value && c == ':' && (is_ident_start(next) || next == ':') {
            var j = i + 1;
            if next == ':' { j++; }
            let e = css_ident_end(line, j, end);
            push_span(spans, i, e - i, TOK_KEYWORD);
            i = e;
            continue;
        }
        if is_digit(c) || ((c == '.' || c == '-') && is_digit(next)) {
            var j = i + 1;
            while j < end && (is_digit(line[j]) || line[j] == '.') { j++; }
            // Its unit: px, em, %, ...
            while j < end && (is_ident_start(line[j]) || line[j] == '%') { j++; }
            push_span(spans, i, j - i, TOK_NUMBER);
            i = j;
            continue;
        }
        if is_ident_start(c) || (c == '-' && (is_ident_start(next) || next == '-')) {
            let e = css_ident_end(line, i, end);
            var kind = TOK_TEXT;
            if !in_value && is_property(lang, line, e, end, depth) {
                kind = TOK_PROPERTY;
                in_value = true;
            } else if in_value {
                var k = e;
                while k < end && is_blank(line[k]) { k++; }
                kind = if k < end && line[k] == '(' { TOK_FUNCTION } else if word_kind(lang.id, line[i..e]) != TOK_TEXT { TOK_KEYWORD } else { TOK_CONSTANT };
            } else {
                // A selector's word: a tag's name is lower case.
                let tag = line[i..e].all() { (it >= 'a' && it <= 'z') || is_digit(it) };
                kind = if tag { TOK_TAG } else { word_kind(lang.id, line[i..e]) };
            }
            push_span(spans, i, e - i, kind);
            i = e;
            continue;
        }
        i++;
    }
    return depth as u8;
}
