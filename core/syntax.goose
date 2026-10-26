// Syntax highlighting: a small lexer driven by a language's description,
// one line at a time, and a cache of the state each line starts in.
//
// A line's highlighting depends only on its text and the state it starts
// in: normal, inside a block comment (and how deep, as they nest), or
// inside a raw string that spans lines. So the state at the start of each
// line is kept, one byte a line; only the lines on screen are lexed for
// their colors, and an edit forgets the states from its line on.

import std;
import os;
import dictionary;
import core.text;

let TOK_TEXT: u8 = 0;
let TOK_KEYWORD: u8 = 1;
let TOK_TYPE: u8 = 2;
let TOK_CONSTANT: u8 = 3;
let TOK_NUMBER: u8 = 4;
let TOK_STRING: u8 = 5;
let TOK_COMMENT: u8 = 6;
let TOK_FUNCTION: u8 = 7;

let STATE_NORMAL: u8 = 0;
let STATE_RAW: u8 = 128;            // in a raw string; 1 to 127: in a block comment, that deep

// What the lexer needs to know about a language.
struct Language {
    name: const u8[:],
    extensions: const u8[:],        // space-separated, with their dots
    keywords: const u8[:],          // space-separated
    types: const u8[:],
    constants: const u8[:],
    line_comment: const u8[:],
    block_open: const u8[:],
    block_close: const u8[:],
    nested_blocks: bool,
    raw_quote: const u8[:],         // a string without escapes that may span lines
    quotes: const u8[:],            // the characters that open a string with escapes
    capitalized_types: bool,        // Capitalized names a type, and ALL_CAPS a constant
}

let GOOSE = Language {
    name: "Goose",
    extensions: ".goose",
    keywords: """import namespace struct enum type fn thread_fn export simd recursive let var extern const pad reusable if else while for in loop block guard match return break continue as from upto inline checkfree""",
    types: "bool varint i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 int2 int3 int4 float2 float3 float4",
    constants: "true false null self",
    line_comment: "//",
    block_open: "/*",
    block_close: "*/",
    nested_blocks: true,
    raw_quote: "\"\"\"",
    quotes: "\"'",
    capitalized_types: true,
};

struct Span { start: i64, len: i64, kind: u8 }

// The word table of the language being highlighted: what kind each of its
// words is. Words are kept inline, so the table points into nothing.
type Word = u8[..24];
var word_kinds = dictionary<Word, u8> {};

fn word_key(s: const u8[:]) -> Word, bool {
    var w: Word = [];
    if s.len > 24 { return w, false; }
    w.append(s);
    return w, true;
}

fn add_words(words: const u8[:], kind: u8) {
    each_split(words, ' ') {
        let w, ok = word_key(it);
        if it.len > 0 && ok { word_kinds.insert(w, kind); }
    };
}

fn word_kind(s: const u8[:]) -> u8 {
    let w, ok = word_key(s);
    if !ok { return TOK_TEXT; }
    let k = word_kinds.get(w);
    if k { k } else { TOK_TEXT }
}

fn use_language(lang: Language) {
    word_kinds.clear();
    add_words(lang.keywords, TOK_KEYWORD);
    add_words(lang.types, TOK_TYPE);
    add_words(lang.constants, TOK_CONSTANT);
}

// The language for a file, by its extension; false for none.
fn language_for(path: const u8[:]) -> Language, bool {
    let dot = rfind(path, ".");
    if dot < 0 || dot < rfind(path, "/") { return GOOSE, false; }
    let ext = path[dot..];
    var found = false;
    each_split(GOOSE.extensions, ' ') { if it == ext { found = true; } };
    return GOOSE, found;
}

fn is_ident_start(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn is_ident(c: u8) -> bool { is_ident_start(c) || (c >= '0' && c <= '9') }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

fn at(line: const u8[:], i: i64, s: const u8[:]) -> bool {
    s.len > 0 && i + s.len <= line.len && line[i..i + s.len] == s
}

fn push_span(spans: Span[>..<]&, start: i64, len: i64, kind: u8) {
    if len <= 0 || kind == TOK_TEXT { return; }
    if spans.len > 0 {
        let last = spans.len - 1;
        let p = spans[last];
        if p.kind == kind && p.start + p.len == start {
            spans[last] = Span { start: p.start, len: p.len + len, kind: kind };
            return;
        }
    }
    spans.push(Span { start: start, len: len, kind: kind });
}

// Where the block comment that is `depth` deep at `i` ends, and how deep
// it is there: past the line's end, with the depth still open, if not on it.
fn skip_block(lang: Language, line: const u8[:], i: i64, depth: i64) -> i64, i64 {
    var j = i;
    var d = depth;
    while j < line.len {
        if at(line, j, lang.block_close) {
            j += lang.block_close.len;
            d--;
            if d == 0 { return j, 0; }
        } else if lang.nested_blocks && at(line, j, lang.block_open) {
            j += lang.block_open.len;
            d = min(d + 1, 127);
        } else {
            j++;
        }
    }
    return line.len, d;
}

// Appends the colored spans of `line`, which starts in `state`, to
// `spans`, and returns the state the next line starts in.
fn lex_line(lang: Language, line: const u8[:], state: u8, spans: Span[>..<]&) -> u8 {
    var i = 0;
    // Carried over from the line before: a comment or a raw string.
    if state == STATE_RAW {
        let k = find(line, lang.raw_quote);
        if k < 0 {
            push_span(spans, 0, line.len, TOK_STRING);
            return STATE_RAW;
        }
        i = k + lang.raw_quote.len;
        push_span(spans, 0, i, TOK_STRING);
    } else if state != STATE_NORMAL {
        let end, depth = skip_block(lang, line, 0, state);
        push_span(spans, 0, end, TOK_COMMENT);
        if depth > 0 { return depth as u8; }
        i = end;
    }
    var after_fn = false;
    while i < line.len {
        let c = line[i];
        if at(line, i, lang.line_comment) {
            push_span(spans, i, line.len - i, TOK_COMMENT);
            return STATE_NORMAL;
        }
        if at(line, i, lang.block_open) {
            let end, depth = skip_block(lang, line, i + lang.block_open.len, 1);
            push_span(spans, i, end - i, TOK_COMMENT);
            if depth > 0 { return depth as u8; }
            i = end;
            continue;
        }
        if at(line, i, lang.raw_quote) {
            let k = find(line[i + lang.raw_quote.len..], lang.raw_quote);
            if k < 0 {
                push_span(spans, i, line.len - i, TOK_STRING);
                return STATE_RAW;
            }
            let end = i + lang.raw_quote.len + k + lang.raw_quote.len;
            push_span(spans, i, end - i, TOK_STRING);
            i = end;
            continue;
        }
        if contains(lang.quotes, c) {
            // To the matching quote, past escapes; an unclosed one ends with the line.
            var j = i + 1;
            while j < line.len && line[j] != c {
                if line[j] == '\\' { j++; }
                j++;
            }
            let end = min(j + 1, line.len);
            push_span(spans, i, end - i, TOK_STRING);
            i = end;
            continue;
        }
        if is_digit(c) {
            var j = i + 1;
            while j < line.len {
                let d = line[j];
                if is_ident(d) {
                    // An exponent's sign belongs to the number: 1e-3, 0x1.8p+3.
                    let e = d == 'e' || d == 'E' || d == 'p' || d == 'P';
                    j++;
                    if e && j < line.len && (line[j] == '+' || line[j] == '-') { j++; }
                } else if d == '.' && j + 1 < line.len && is_digit(line[j + 1]) {
                    j++;
                } else {
                    break;
                }
            }
            push_span(spans, i, j - i, TOK_NUMBER);
            i = j;
            continue;
        }
        if is_ident_start(c) {
            var j = i + 1;
            while j < line.len && is_ident(line[j]) { j++; }
            let word = line[i..j];
            var kind = word_kind(word);
            if kind != TOK_TEXT { }
            else if after_fn { kind = TOK_FUNCTION; }
            else if lang.capitalized_types && c >= 'A' && c <= 'Z' {
                let caps = word.all() { (it >= 'A' && it <= 'Z') || is_digit(it) || it == '_' };
                kind = if caps && word.len > 1 { TOK_CONSTANT } else { TOK_TYPE };
            }
            else {
                var k = j;
                while k < line.len && line[k] == ' ' { k++; }
                if k < line.len && line[k] == '(' { kind = TOK_FUNCTION; }
            }
            after_fn = word == "fn" || word == "thread_fn";
            push_span(spans, i, j - i, kind);
            i = j;
            continue;
        }
        if c != ' ' && c != '\t' && c != ':' { after_fn = false; }
        i++;
    }
    return STATE_NORMAL;
}

// The states lines start in, for lines[..valid], and where to go on from.
struct Highlight {
    lang: Language,
    on: bool,                       // false for a file of no known language
    states: u8[>..<]&,
}

fn highlight_new(path: const u8[:], states: u8[>..<]&) -> Highlight {
    let lang, found = language_for(path);
    if found { use_language(lang); }
    states.resize(0, 0);
    states.push(STATE_NORMAL);
    return Highlight { lang: lang, on: found, states: states };
}

// Forgets the states of the lines after the one `pos` was edited on.
fn highlight_edited(hl: Highlight&, t: Text&, pos: i64) {
    let n = line_of(t, pos);
    if n + 1 < hl.states.len { hl.states.resize(n + 1, 0); }
}

// Lexes on from the last known state, for at most `budget` seconds or up to
// line `upto`, whichever comes first; true when the states reach `upto`.
fn highlight_extend(hl: Highlight&, t: Text&, upto: i64, budget: f64) -> bool {
    if !hl.on { return true; }
    let target = min(upto, t.lf);
    if hl.states.len > target { return true; }
    let started = clock();
    var spans: Span[>..<] = [];
    // Read on in chunks from the start of the last line whose state is known.
    var n = hl.states.len - 1;
    var pos = line_start(t, n);
    var chunk: u8[>..] = [];
    while hl.states.len <= target {
        chunk.clear();
        let end = min(pos + 65536, t.len);
        read(t, pos, end, chunk);
        var from = 0;
        loop {
            let k = find(chunk[from..], "\n");
            if k < 0 { break; }
            var line_end = from + k;
            if line_end > from && chunk[line_end - 1] == '\r' { line_end--; }
            spans.resize(0, default<Span>());
            hl.states.push(lex_line(hl.lang, chunk[from..line_end], hl.states[n], spans));
            n++;
            from += k + 1;
            if hl.states.len > target { return true; }
        }
        if from == 0 {
            // A line longer than the chunk: read it whole.
            chunk.clear();
            read_line(t, n, chunk);
            spans.resize(0, default<Span>());
            hl.states.push(lex_line(hl.lang, chunk, hl.states[n], spans));
            n++;
            pos = line_start(t, n);
        } else {
            pos += from;
        }
        if end == t.len && from == chunk.len { break; }
        if clock() - started > budget { return false; }
    }
    return hl.states.len > target;
}

// The state line `n` starts in, if it is known yet.
fn state_at(hl: Highlight&, n: i64) -> u8, bool {
    if n < hl.states.len { return hl.states[n], true; }
    return STATE_NORMAL, false;
}
