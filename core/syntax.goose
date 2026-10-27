// Syntax highlighting: which lexer a language takes, and a cache of the
// state each line starts in.
//
// A line's highlighting depends only on its text and the state it starts
// in, such as inside a block comment, or in a string or a <style> that
// goes on from the line before. So the state at the start of each line is
// kept, one byte a line; only the lines on screen are lexed for their
// colors, and an edit forgets the states from its line on. The lexers
// themselves are in core/syntax/: code, style and markup, with what they
// share in lang and the languages in languages.

import std;
import os;
import core.text;
import core.syntax.lang;
import core.syntax.languages;
import core.syntax.code;
import core.syntax.style;
import core.syntax.markup;

// Appends the colored spans of `line`, which starts in `state`, to
// `spans`, and returns the state the next line starts in.
fn lex_line(lang: Language, line: const u8[:], state: u8, spans: Span[>..<]&) -> u8 {
    ensure_words();
    if lang.lexer == LEX_STYLE { return lex_style(lang, line, 0, line.len, state, spans); }
    if lang.lexer == LEX_MARKUP { return lex_markup(lang, line, 0, line.len, state, spans); }
    return lex_code(lang, line, 0, line.len, state, spans);
}

// The states lines start in, for lines[..valid], and where to go on from.
struct Highlight {
    lang: Language,
    on: bool,                       // false for a file of no known language
    states: u8[>..<]&,
}

fn highlight_new(path: const u8[:], states: u8[>..<]&) -> Highlight {
    let lang, found = language_for(path);
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
