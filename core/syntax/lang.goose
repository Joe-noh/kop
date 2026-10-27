// What the lexers share: the kinds of token, the spans they color, a
// language's description, and the table of each language's words.

import std;
import dictionary;

let TOK_TEXT: u8 = 0;
let TOK_KEYWORD: u8 = 1;
let TOK_TYPE: u8 = 2;
let TOK_CONSTANT: u8 = 3;
let TOK_NUMBER: u8 = 4;
let TOK_STRING: u8 = 5;
let TOK_COMMENT: u8 = 6;
let TOK_FUNCTION: u8 = 7;
let TOK_TAG: u8 = 8;                // an HTML element's name
let TOK_ATTRIBUTE: u8 = 9;          // an HTML attribute's name; a CSS class or id
let TOK_PROPERTY: u8 = 10;          // a CSS property
let TOK_VARIABLE: u8 = 11;          // Ruby's @x and $x, Sass's $x, CSS's --x
let TOKEN_KINDS = 12;

let STATE_NORMAL: u8 = 0;

// Which lexer a language takes.
let LEX_CODE: u8 = 0;
let LEX_STYLE: u8 = 1;
let LEX_MARKUP: u8 = 2;

// What a lexer needs to know about a language. A text field that does not
// apply is empty.
struct Language {
    id: u8,                         // its index in LANGUAGES
    lexer: u8,                      // LEX_*
    name: const u8[:],
    extensions: const u8[:],        // space-separated, with their dots
    filenames: const u8[:],         // whole file names that are this language: "Gemfile"
    keywords: const u8[:] = "",     // space-separated
    types: const u8[:] = "",
    constants: const u8[:] = "",
    line_comment: const u8[:] = "",
    block_open: const u8[:] = "",
    block_close: const u8[:] = "",
    nested_blocks: bool = false,
    line_block_open: const u8[:] = "",    // a comment from a line starting so: Ruby's =begin
    line_block_close: const u8[:] = "",
    raw_quote: const u8[:] = "",    // a string without escapes that may span lines: Goose's """
    quotes: const u8[:] = "",       // what opens a string with escapes that ends with its line
    long_quotes: const u8[:] = "",  // what opens one that may go on to the next lines
    function_words: const u8[:] = "",     // the word they come after names a function
    variable_marks: const u8[:] = "",     // what starts a variable's name: "@$"
    name_marks: const u8[:] = "",   // what may end a name: Ruby's "?!"
    symbols: bool = false,          // Ruby's :name and name: are constants
    heredocs: bool = false,         // Ruby's <<~EOS
    capitalized_types: bool = false,      // Capitalized names a type, and ALL_CAPS a constant
    scss: bool = false,             // for a style sheet: // comments, $variables, nesting
    indented: bool = false,         // for a style sheet: Sass's, without braces
}

struct Span { start: i64, len: i64, kind: u8 }

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

fn is_ident_start(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn is_ident(c: u8) -> bool { is_ident_start(c) || (c >= '0' && c <= '9') }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }
fn is_upper(c: u8) -> bool { c >= 'A' && c <= 'Z' }
fn is_blank(c: u8) -> bool { c == ' ' || c == '\t' }

// Whether `s` is at line[i].
fn at(line: const u8[:], i: i64, s: const u8[:]) -> bool {
    s.len > 0 && i + s.len <= line.len && line[i..i + s.len] == s
}

// The same, ignoring ASCII case: HTML's </SCRIPT>.
fn at_nocase(line: const u8[:], i: i64, s: const u8[:]) -> bool {
    if s.len == 0 || i + s.len > line.len { return false; }
    for k in s.len {
        var c = line[i + k];
        if c >= 'A' && c <= 'Z' { c += 32; }
        if c != s[k] { return false; }
    }
    return true;
}

// Where `s` next is in line[from..end], ignoring case; `end` if nowhere.
fn find_nocase(line: const u8[:], from: i64, end: i64, s: const u8[:]) -> i64 {
    var i = from;
    while i + s.len <= end {
        if at_nocase(line, i, s) { return i; }
        i++;
    }
    return end;
}

fn is_word_in(words: const u8[:], w: const u8[:]) -> bool {
    var found = false;
    each_split(words, ' ') { if it == w { found = true; } };
    return found;
}

// The words of every language, each key the language's id and the word.
// The keys are inline, so the table points into nothing.
type Word = u8[..32];
var word_kinds = dictionary<Word, u8> {};

fn word_key(id: u8, s: const u8[:]) -> Word, bool {
    var w: Word = [];
    if s.len > 31 { return w, false; }
    w.push(id);
    w.append(s);
    return w, true;
}

fn add_words(id: u8, words: const u8[:], kind: u8) {
    each_split(words, ' ') {
        let w, ok = word_key(id, it);
        if it.len > 0 && ok { word_kinds.insert(w, kind); }
    };
}

fn add_language_words(lang: Language) {
    add_words(lang.id, lang.keywords, TOK_KEYWORD);
    add_words(lang.id, lang.types, TOK_TYPE);
    add_words(lang.id, lang.constants, TOK_CONSTANT);
}

// The kind of `s` among the words of language `id`, or TOK_TEXT.
fn word_kind(id: u8, s: const u8[:]) -> u8 {
    let w, ok = word_key(id, s);
    if !ok { return TOK_TEXT; }
    let k = word_kinds.get(w);
    if k { k } else { TOK_TEXT }
}
