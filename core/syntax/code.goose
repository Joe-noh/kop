// The lexer for programming languages: Goose, Ruby, JavaScript and
// TypeScript, told apart by their Language. It colors line[start..end],
// which starts in `state`, and returns the state the next line starts in:
//
//   0          normal
//   1 to 63    in a block comment, that deep
//   64         in a raw string (Goose's """)
//   65 to 67   in a string of " ' or ` that goes on past its line
//   68         in a comment of whole lines (Ruby's =begin)
//   96 to 127  in a heredoc, by its terminator's hash

import std;
import core.syntax.lang;

let CODE_RAW: u8 = 64;
let CODE_LONG: u8 = 65;
let CODE_LINE_BLOCK: u8 = 68;
let CODE_HEREDOC: u8 = 96;
let LONG_QUOTES = "\"'`";

fn heredoc_state(id: const u8[:]) -> u8 { CODE_HEREDOC + (hash(id) % 32) as u8 }

// Past the string whose opening quote `q` is just before line[from], within
// [from, end), and whether it closed there.
fn string_end(line: const u8[:], from: i64, end: i64, q: u8) -> i64, bool {
    var j = from;
    while j < end {
        if line[j] == '\\' { j += 2; continue; }
        if line[j] == q { return j + 1, true; }
        j++;
    }
    return end, false;
}

// Where the block comment that is `depth` deep at `i` ends, and how deep
// it is there: at `end`, with the depth still open, if not before it.
fn skip_block(lang: Language, line: const u8[:], i: i64, end: i64, depth: i64) -> i64, i64 {
    var j = i;
    var d = depth;
    while j < end {
        if at(line, j, lang.block_close) {
            j += lang.block_close.len;
            d--;
            if d == 0 { return j, 0; }
        } else if lang.nested_blocks && at(line, j, lang.block_open) {
            j += lang.block_open.len;
            d = min(d + 1, 63);
        } else {
            j++;
        }
    }
    return end, d;
}

// A Ruby heredoc's opening at line[i] ("<<~EOS", "<<-'SQL'", "<<EOS"): its
// length and its terminator, or 0.
fn heredoc_at(line: const u8[:], i: i64, end: i64) -> i64, const u8[:] {
    var j = i + 2;
    if j < end && (line[j] == '~' || line[j] == '-') { j++; }
    var quote: u8 = 0;
    if j < end && (line[j] == '\'' || line[j] == '"') { quote = line[j]; j++; }
    let from = j;
    if j >= end || !(is_upper(line[j]) || (quote != 0 && is_ident_start(line[j]))) { return 0, line[i..i]; }
    while j < end && is_ident(line[j]) { j++; }
    let id = line[from..j];
    if quote != 0 {
        if j >= end || line[j] != quote { return 0, line[i..i]; }
        j++;
    }
    return j - i, id;
}

fn lex_code(lang: Language, line: const u8[:], start: i64, end: i64, state: u8, spans: Span[>..<]&) -> u8 {
    var i = start;
    // What the line before left open.
    if state == CODE_RAW {
        let k = find(line[i..end], lang.raw_quote);
        if k < 0 {
            push_span(spans, i, end - i, TOK_STRING);
            return CODE_RAW;
        }
        push_span(spans, i, k + lang.raw_quote.len, TOK_STRING);
        i += k + lang.raw_quote.len;
    } else if state >= CODE_LONG && state < CODE_LONG + 3 {
        let e, closed = string_end(line, i, end, LONG_QUOTES[state - CODE_LONG]);
        push_span(spans, i, e - i, TOK_STRING);
        if !closed { return state; }
        i = e;
    } else if state == CODE_LINE_BLOCK {
        push_span(spans, i, end - i, TOK_COMMENT);
        return if at(line, start, lang.line_block_close) { STATE_NORMAL } else { CODE_LINE_BLOCK };
    } else if state >= CODE_HEREDOC {
        push_span(spans, i, end - i, TOK_STRING);
        let word = trim(line[start..end]);
        let ends = word.len > 0 && word.all() { is_ident(it) } && heredoc_state(word) == state;
        return if ends { STATE_NORMAL } else { state };
    } else if state != STATE_NORMAL {
        let e, depth = skip_block(lang, line, i, end, state);
        push_span(spans, i, e - i, TOK_COMMENT);
        if depth > 0 { return depth as u8; }
        i = e;
    }
    if state == STATE_NORMAL && at(line, start, lang.line_block_open) {
        push_span(spans, start, end - start, TOK_COMMENT);
        return CODE_LINE_BLOCK;
    }

    var after_fn = false;           // the last word names a function to come
    var next_state = STATE_NORMAL;  // a heredoc begun on this line starts on the next
    while i < end {
        let c = line[i];
        if at(line, i, lang.line_comment) {
            push_span(spans, i, end - i, TOK_COMMENT);
            break;
        }
        if at(line, i, lang.block_open) {
            let e, depth = skip_block(lang, line, i + lang.block_open.len, end, 1);
            push_span(spans, i, e - i, TOK_COMMENT);
            if depth > 0 { return depth as u8; }
            i = e;
            continue;
        }
        if at(line, i, lang.raw_quote) {
            let k = find(line[i + lang.raw_quote.len..end], lang.raw_quote);
            if k < 0 {
                push_span(spans, i, end - i, TOK_STRING);
                return CODE_RAW;
            }
            let e = i + 2 * lang.raw_quote.len + k;
            push_span(spans, i, e - i, TOK_STRING);
            i = e;
            continue;
        }
        if contains(lang.long_quotes, c) {
            let e, closed = string_end(line, i + 1, end, c);
            push_span(spans, i, e - i, TOK_STRING);
            if !closed { return CODE_LONG + position(LONG_QUOTES, c) as u8; }
            i = e;
            continue;
        }
        if contains(lang.quotes, c) {
            let e, closed = string_end(line, i + 1, end, c);
            push_span(spans, i, e - i, TOK_STRING);
            i = e;
            continue;
        }
        if lang.heredocs && at(line, i, "<<") {
            let n, id = heredoc_at(line, i, end);
            if n > 0 {
                push_span(spans, i, n, TOK_STRING);
                next_state = heredoc_state(id);
                i += n;
                continue;
            }
        }
        if contains(lang.variable_marks, c) && i + 1 < end && (is_ident_start(line[i + 1]) || line[i + 1] == c) {
            var j = i + 1;
            while j < end && line[j] == c { j++; }
            while j < end && is_ident(line[j]) { j++; }
            push_span(spans, i, j - i, TOK_VARIABLE);
            i = j;
            continue;
        }
        if lang.symbols && c == ':' && i + 1 < end && is_ident_start(line[i + 1]) &&
           (i == start || (line[i - 1] != ':' && !is_ident(line[i - 1]))) {
            var j = i + 1;
            while j < end && is_ident(line[j]) { j++; }
            if j < end && contains(lang.name_marks, line[j]) { j++; }
            push_span(spans, i, j - i, TOK_CONSTANT);
            i = j;
            continue;
        }
        if is_digit(c) && (i == start || !is_ident(line[i - 1])) {
            var j = i + 1;
            while j < end {
                let d = line[j];
                if is_ident(d) {
                    // An exponent's sign belongs to the number: 1e-3, 0x1.8p+3.
                    let e = d == 'e' || d == 'E' || d == 'p' || d == 'P';
                    j++;
                    if e && j < end && (line[j] == '+' || line[j] == '-') { j++; }
                } else if d == '.' && j + 1 < end && is_digit(line[j + 1]) {
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
            while j < end && is_ident(line[j]) { j++; }
            // Ruby's empty? and save!, but not a != b.
            if j < end && contains(lang.name_marks, line[j]) && !(j + 1 < end && line[j + 1] == '=') { j++; }
            let word = line[i..j];
            var kind = word_kind(lang.id, word);
            if kind == TOK_TEXT {
                var k = j;
                while k < end && is_blank(line[k]) { k++; }
                if after_fn {
                    kind = TOK_FUNCTION;
                } else if lang.capitalized_types && is_upper(c) {
                    let caps = word.all() { is_upper(it) || is_digit(it) || it == '_' };
                    kind = if caps && word.len > 1 { TOK_CONSTANT } else { TOK_TYPE };
                } else if lang.symbols && k < end && line[k] == ':' && !(k + 1 < end && line[k + 1] == ':') && k == j {
                    kind = TOK_CONSTANT;            // a Ruby hash key: name: value
                } else if k < end && line[k] == '(' {
                    kind = TOK_FUNCTION;
                }
            }
            // `def self.name` names the function after self.
            after_fn = is_word_in(lang.function_words, word) || (after_fn && word == "self");
            push_span(spans, i, j - i, kind);
            i = j;
            continue;
        }
        if !is_blank(c) && c != '.' && c != '*' && c != ':' { after_fn = false; }
        i++;
    }
    return next_state;
}
