// The lexer for programming languages: Zig, Goose, Ruby, JavaScript and
// TypeScript, told apart by their Language. It colors line[start..end],
// which starts in `state`, and returns the state the next line starts in:
//
//   0          normal
//   1 to 63    in a block comment, that deep
//   64         in a raw string (Goose's """)
//   65 to 67   in a string of " ' or ` that goes on past its line
//   68         in a comment of whole lines (Ruby's =begin)
//   96 to 127  in a heredoc, by its terminator's hash

const std = @import("std");
const Allocator = std.mem.Allocator;
const L = @import("lang.zig");
const Language = L.Language;
const Span = L.Span;

pub const code_raw: u8 = 64;
pub const code_long: u8 = 65;
pub const code_line_block: u8 = 68;
pub const code_heredoc: u8 = 96;
const long_quotes = "\"'`";

pub fn heredocState(id: []const u8) u8 {
    return code_heredoc + @as(u8, @intCast(std.hash.Fnv1a_32.hash(id) % 32));
}

const End = struct { end: usize, closed: bool };

// Past the string whose opening quote `q` is just before line[from], within
// [from, end), and whether it closed there.
fn stringEnd(line: []const u8, from: usize, end: usize, q: u8) End {
    var j = from;
    while (j < end) {
        if (line[j] == '\\') {
            j += 2;
            continue;
        }
        if (line[j] == q) return .{ .end = j + 1, .closed = true };
        j += 1;
    }
    return .{ .end = end, .closed = false };
}

const Block = struct { end: usize, depth: u8 };

// Where the block comment that is `depth` deep at `i` ends, and how deep
// it is there: at `end`, with the depth still open, if not before it.
fn skipBlock(lang: *const Language, line: []const u8, i: usize, end: usize, depth: u8) Block {
    var j = i;
    var d = depth;
    while (j < end) {
        if (L.at(line, j, lang.block_close)) {
            j += lang.block_close.len;
            d -= 1;
            if (d == 0) return .{ .end = j, .depth = 0 };
        } else if (lang.nested_blocks and L.at(line, j, lang.block_open)) {
            j += lang.block_open.len;
            d = @min(d + 1, 63);
        } else j += 1;
    }
    return .{ .end = end, .depth = d };
}

const Heredoc = struct { len: usize, id: []const u8 };

// A Ruby heredoc's opening at line[i] ("<<~EOS", "<<-'SQL'", "<<EOS"): its
// length and its terminator, or a length of 0.
fn heredocAt(line: []const u8, i: usize, end: usize) Heredoc {
    const none = Heredoc{ .len = 0, .id = "" };
    var j = i + 2;
    if (j < end and (line[j] == '~' or line[j] == '-')) j += 1;
    var quote: u8 = 0;
    if (j < end and (line[j] == '\'' or line[j] == '"')) {
        quote = line[j];
        j += 1;
    }
    const from = j;
    if (j >= end or !(L.isUpper(line[j]) or (quote != 0 and L.isIdentStart(line[j])))) return none;
    while (j < end and L.isIdent(line[j])) j += 1;
    const id = line[from..j];
    if (quote != 0) {
        if (j >= end or line[j] != quote) return none;
        j += 1;
    }
    return .{ .len = j - i, .id = id };
}

fn isCapsChar(c: u8) bool {
    return L.isUpper(c) or L.isDigit(c) or c == '_';
}

pub fn lex(gpa: Allocator, lang: *const Language, line: []const u8, start: usize, end: usize, state: u8, spans: *std.ArrayList(Span)) !u8 {
    var i = start;
    // What the line before left open.
    if (state == code_raw) {
        const k = std.mem.indexOf(u8, line[i..end], lang.raw_quote) orelse {
            try L.pushSpan(gpa, spans, i, end - i, .string);
            return code_raw;
        };
        try L.pushSpan(gpa, spans, i, k + lang.raw_quote.len, .string);
        i += k + lang.raw_quote.len;
    } else if (state >= code_long and state < code_long + 3) {
        const e = stringEnd(line, i, end, long_quotes[state - code_long]);
        try L.pushSpan(gpa, spans, i, e.end - i, .string);
        if (!e.closed) return state;
        i = e.end;
    } else if (state == code_line_block) {
        try L.pushSpan(gpa, spans, i, end - i, .comment);
        return if (L.at(line, start, lang.line_block_close)) L.state_normal else code_line_block;
    } else if (state >= code_heredoc) {
        try L.pushSpan(gpa, spans, i, end - i, .string);
        const word = std.mem.trim(u8, line[start..end], " \t");
        const ends = word.len > 0 and L.allOf(word, L.isIdent) and heredocState(word) == state;
        return if (ends) L.state_normal else state;
    } else if (state != L.state_normal) {
        const b = skipBlock(lang, line, i, end, state);
        try L.pushSpan(gpa, spans, i, b.end - i, .comment);
        if (b.depth > 0) return b.depth;
        i = b.end;
    }
    if (state == L.state_normal and L.at(line, start, lang.line_block_open)) {
        try L.pushSpan(gpa, spans, start, end - start, .comment);
        return code_line_block;
    }

    var after_fn = false; // the last word names a function to come
    var next_state = L.state_normal; // a heredoc begun on this line starts on the next
    while (i < end) {
        const c = line[i];
        if (L.at(line, i, lang.line_comment)) {
            try L.pushSpan(gpa, spans, i, end - i, .comment);
            break;
        }
        if (L.at(line, i, lang.raw_line)) {
            try L.pushSpan(gpa, spans, i, end - i, .string);
            break;
        }
        if (L.at(line, i, lang.block_open)) {
            const b = skipBlock(lang, line, i + lang.block_open.len, end, 1);
            try L.pushSpan(gpa, spans, i, b.end - i, .comment);
            if (b.depth > 0) return b.depth;
            i = b.end;
            continue;
        }
        if (L.at(line, i, lang.raw_quote)) {
            const from = i + lang.raw_quote.len;
            const k = std.mem.indexOf(u8, line[from..end], lang.raw_quote) orelse {
                try L.pushSpan(gpa, spans, i, end - i, .string);
                return code_raw;
            };
            const e = from + k + lang.raw_quote.len;
            try L.pushSpan(gpa, spans, i, e - i, .string);
            i = e;
            continue;
        }
        if (L.contains(lang.long_quotes, c)) {
            const e = stringEnd(line, i + 1, end, c);
            try L.pushSpan(gpa, spans, i, e.end - i, .string);
            if (!e.closed) return code_long + @as(u8, @intCast(std.mem.indexOfScalar(u8, long_quotes, c).?));
            i = e.end;
            continue;
        }
        if (L.contains(lang.quotes, c)) {
            const e = stringEnd(line, i + 1, end, c);
            try L.pushSpan(gpa, spans, i, e.end - i, .string);
            i = e.end;
            continue;
        }
        if (lang.heredocs and L.at(line, i, "<<")) {
            const h = heredocAt(line, i, end);
            if (h.len > 0) {
                try L.pushSpan(gpa, spans, i, h.len, .string);
                next_state = heredocState(h.id);
                i += h.len;
                continue;
            }
        }
        if (lang.builtin_mark != 0 and c == lang.builtin_mark and i + 1 < end and L.isIdentStart(line[i + 1])) {
            var j = i + 1;
            while (j < end and L.isIdent(line[j])) j += 1;
            try L.pushSpan(gpa, spans, i, j - i, .function);
            i = j;
            continue;
        }
        if (L.contains(lang.variable_marks, c) and i + 1 < end and (L.isIdentStart(line[i + 1]) or line[i + 1] == c)) {
            var j = i + 1;
            while (j < end and line[j] == c) j += 1;
            while (j < end and L.isIdent(line[j])) j += 1;
            try L.pushSpan(gpa, spans, i, j - i, .variable);
            i = j;
            continue;
        }
        if (lang.symbols and c == ':' and i + 1 < end and L.isIdentStart(line[i + 1]) and
            (i == start or (line[i - 1] != ':' and !L.isIdent(line[i - 1]))))
        {
            var j = i + 1;
            while (j < end and L.isIdent(line[j])) j += 1;
            if (j < end and L.contains(lang.name_marks, line[j])) j += 1;
            try L.pushSpan(gpa, spans, i, j - i, .constant);
            i = j;
            continue;
        }
        if (L.isDigit(c) and (i == start or !L.isIdent(line[i - 1]))) {
            var j = i + 1;
            while (j < end) {
                const d = line[j];
                if (L.isIdent(d)) {
                    // An exponent's sign belongs to the number: 1e-3, 0x1.8p+3.
                    const e = d == 'e' or d == 'E' or d == 'p' or d == 'P';
                    j += 1;
                    if (e and j < end and (line[j] == '+' or line[j] == '-')) j += 1;
                } else if (d == '.' and j + 1 < end and L.isDigit(line[j + 1])) {
                    j += 1;
                } else break;
            }
            try L.pushSpan(gpa, spans, i, j - i, .number);
            i = j;
            continue;
        }
        if (L.isIdentStart(c)) {
            var j = i + 1;
            while (j < end and L.isIdent(line[j])) j += 1;
            // Ruby's empty? and save!, but not a != b.
            if (j < end and L.contains(lang.name_marks, line[j]) and !(j + 1 < end and line[j + 1] == '=')) j += 1;
            const word = line[i..j];
            var kind = lang.wordKind(word);
            if (kind == .text) {
                var k = j;
                while (k < end and L.isBlank(line[k])) k += 1;
                if (after_fn) {
                    kind = .function;
                } else if (lang.capitalized_types and L.isUpper(c)) {
                    kind = if (L.allOf(word, isCapsChar) and word.len > 1) .constant else .type;
                } else if (lang.symbols and k < end and line[k] == ':' and !(k + 1 < end and line[k + 1] == ':') and k == j) {
                    kind = .constant; // a Ruby hash key: name: value
                } else if (k < end and line[k] == '(') {
                    kind = .function;
                }
            }
            // `def self.name` names the function after self.
            after_fn = L.isWordIn(lang.function_words, word) or (after_fn and std.mem.eql(u8, word, "self"));
            try L.pushSpan(gpa, spans, i, j - i, kind);
            i = j;
            continue;
        }
        if (!L.isBlank(c) and c != '.' and c != '*' and c != ':') after_fn = false;
        i += 1;
    }
    return next_state;
}
