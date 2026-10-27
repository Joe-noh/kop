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

import std;
import core.syntax.lang;
import core.syntax.languages;
import core.syntax.code;
import core.syntax.style;

let MARKUP_TAG: u8 = 1;
let MARKUP_SCRIPT_TAG: u8 = 2;
let MARKUP_STYLE_TAG: u8 = 3;
let MARKUP_VALUE: u8 = 4;           // + 0 for ", 1 for '
let MARKUP_COMMENT: u8 = 6;
let MARKUP_SCRIPT: u8 = 128;
let MARKUP_STYLE: u8 = 192;

// A script's states, which JavaScript's lexer can end a line in, packed small.
fn pack_script(js: u8) -> u8 {
    if js == CODE_LONG + 2 { MARKUP_SCRIPT + 2 } else if js == 1 { MARKUP_SCRIPT + 1 } else { MARKUP_SCRIPT }
}
fn unpack_script(st: u8) -> u8 {
    let k = st - MARKUP_SCRIPT;
    if k == 2 { CODE_LONG + 2 } else if k == 1 { 1 } else { STATE_NORMAL }
}

fn is_name(c: u8) -> bool { is_ident(c) || c == '-' || c == ':' || c == '.' }

// The rest of a tag from line[i]: its attributes, up to and past its `>`;
// returns where it stopped and the state then.
fn lex_tag(line: const u8[:], i0: i64, end: i64, tag_state: u8, spans: Span[>..<]&) -> i64, u8 {
    var i = i0;
    while i < end {
        let c = line[i];
        if c == '>' {
            i++;
            if tag_state == MARKUP_SCRIPT_TAG { return i, MARKUP_SCRIPT; }
            if tag_state == MARKUP_STYLE_TAG { return i, MARKUP_STYLE; }
            return i, STATE_NORMAL;
        }
        if c == '"' || c == '\'' {
            var j = i + 1;
            while j < end && line[j] != c { j++; }
            if j >= end {
                push_span(spans, i, end - i, TOK_STRING);
                return end, MARKUP_VALUE + (if c == '"' { 0 } else { 1 });
            }
            push_span(spans, i, j + 1 - i, TOK_STRING);
            i = j + 1;
            continue;
        }
        if c == '=' {
            // An unquoted value runs to a blank or the tag's end.
            var j = i + 1;
            while j < end && is_blank(line[j]) { j++; }
            if j < end && line[j] != '"' && line[j] != '\'' {
                var k = j;
                while k < end && !is_blank(line[k]) && line[k] != '>' { k++; }
                push_span(spans, j, k - j, TOK_STRING);
                i = k;
                continue;
            }
            i = j;
            continue;
        }
        if is_name(c) || c == '@' {
            var j = i + 1;
            while j < end && (is_name(line[j]) || line[j] == '@') { j++; }
            push_span(spans, i, j - i, TOK_ATTRIBUTE);
            i = j;
            continue;
        }
        i++;
    }
    return end, tag_state;
}

fn lex_markup(lang: Language, line: const u8[:], start: i64, end: i64, state: u8, spans: Span[>..<]&) -> u8 {
    var i = start;
    var st = state;
    while i < end || st >= MARKUP_SCRIPT {
        if st >= MARKUP_STYLE {
            let close = find_nocase(line, i, end, "</style");
            let css = lex_style(CSS, line, i, close, st - MARKUP_STYLE, spans);
            if close == end { return MARKUP_STYLE + css; }
            i = close;
            st = STATE_NORMAL;
            continue;
        }
        if st >= MARKUP_SCRIPT {
            let close = find_nocase(line, i, end, "</script");
            let js = lex_code(JAVASCRIPT, line, i, close, unpack_script(st), spans);
            if close == end { return pack_script(js); }
            i = close;
            st = STATE_NORMAL;
            continue;
        }
        if st == MARKUP_COMMENT {
            let k = find(line[i..end], "-->");
            if k < 0 {
                push_span(spans, i, end - i, TOK_COMMENT);
                return MARKUP_COMMENT;
            }
            push_span(spans, i, k + 3, TOK_COMMENT);
            i += k + 3;
            st = STATE_NORMAL;
            continue;
        }
        if st == MARKUP_VALUE || st == MARKUP_VALUE + 1 {
            let q: u8 = if st == MARKUP_VALUE { '"' } else { '\'' };
            var j = i;
            while j < end && line[j] != q { j++; }
            if j >= end {
                push_span(spans, i, end - i, TOK_STRING);
                return st;
            }
            push_span(spans, i, j + 1 - i, TOK_STRING);
            i = j + 1;
            st = MARKUP_TAG;
            continue;
        }
        if st != STATE_NORMAL {
            i, st = lex_tag(line, i, end, st, spans);
            continue;
        }
        // In text.
        let c = line[i];
        let next: u8 = if i + 1 < end { line[i + 1] } else { 0 };
        if c == '<' && at(line, i, "<!--") {
            let k = find(line[i + 4..end], "-->");
            if k < 0 {
                push_span(spans, i, end - i, TOK_COMMENT);
                return MARKUP_COMMENT;
            }
            push_span(spans, i, k + 7, TOK_COMMENT);
            i += k + 7;
            continue;
        }
        if c == '<' && next == '!' {
            var j = i + 2;
            while j < end && line[j] != '>' { j++; }
            push_span(spans, i, min(j + 1, end) - i, TOK_KEYWORD);
            i = min(j + 1, end);
            continue;
        }
        if c == '<' && (is_ident_start(next) || next == '/') {
            let closing = next == '/';
            var j = i + (if closing { 2 } else { 1 });
            let from = j;
            while j < end && is_name(line[j]) { j++; }
            push_span(spans, from, j - from, TOK_TAG);
            var tag = MARKUP_TAG;
            if !closing && j - from == 6 && at_nocase(line, from, "script") { tag = MARKUP_SCRIPT_TAG; }
            if !closing && j - from == 5 && at_nocase(line, from, "style") { tag = MARKUP_STYLE_TAG; }
            i, st = lex_tag(line, j, end, tag, spans);
            continue;
        }
        if c == '&' && (is_ident_start(next) || next == '#') {
            var j = i + 1;
            while j < end && (is_ident(line[j]) || line[j] == '#') { j++; }
            if j < end && line[j] == ';' {
                push_span(spans, i, j + 1 - i, TOK_CONSTANT);
                i = j + 1;
                continue;
            }
        }
        i++;
    }
    return st;
}
