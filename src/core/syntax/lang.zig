// What the lexers share: the kinds of token, the spans they color, and a
// language's description, its words included.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tok = enum(u8) {
    text,
    keyword,
    type,
    constant,
    number,
    string,
    comment,
    function,
    tag, // an HTML element's name
    attribute, // an HTML attribute's name; a CSS class or id
    property, // a CSS property
    variable, // Ruby's @x and $x, Sass's $x, CSS's --x
};

pub const state_normal: u8 = 0;

pub const Lexer = enum { code, style, markup };

pub const Words = std.StaticStringMap(Tok);

// What a lexer needs to know about a language. A text field that does not
// apply is empty.
pub const Language = struct {
    lexer: Lexer,
    name: []const u8,
    extensions: []const u8, // space-separated, with their dots
    filenames: []const u8 = "", // whole file names that are this language: "Gemfile"
    words: Words = .{}, // its keywords, types and constants
    line_comment: []const u8 = "",
    block_open: []const u8 = "",
    block_close: []const u8 = "",
    nested_blocks: bool = false,
    line_block_open: []const u8 = "", // a comment from a line starting so: Ruby's =begin
    line_block_close: []const u8 = "",
    raw_quote: []const u8 = "", // a string without escapes that may span lines: Goose's """
    raw_line: []const u8 = "", // what starts a line of a string made of such lines: Zig's \\
    quotes: []const u8 = "", // what opens a string with escapes that ends with its line
    long_quotes: []const u8 = "", // what opens one that may go on to the next lines
    function_words: []const u8 = "", // the word they come after names a function
    variable_marks: []const u8 = "", // what starts a variable's name: "@$"
    name_marks: []const u8 = "", // what may end a name: Ruby's "?!"
    builtin_mark: u8 = 0, // what starts a builtin's name, colored as a function: Zig's @
    symbols: bool = false, // Ruby's :name and name: are constants
    heredocs: bool = false, // Ruby's <<~EOS
    capitalized_types: bool = false, // Capitalized names a type, and ALL_CAPS a constant
    scss: bool = false, // for a style sheet: // comments, $variables, nesting
    indented: bool = false, // for a style sheet: Sass's, without braces

    pub fn wordKind(lang: *const Language, w: []const u8) Tok {
        return lang.words.get(w) orelse .text;
    }
};

fn countWords(comptime s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |_| n += 1;
    return n;
}

// The words of a language, from space-separated lists of each kind.
pub fn words(comptime keywords: []const u8, comptime types: []const u8, comptime constants: []const u8) Words {
    return comptime blk: {
        @setEvalBranchQuota(200000);
        const KV = struct { []const u8, Tok };
        const lists = [_]KV{ .{ keywords, .keyword }, .{ types, .type }, .{ constants, .constant } };
        var kvs: [countWords(keywords) + countWords(types) + countWords(constants)]KV = undefined;
        var n: usize = 0;
        for (lists) |list| {
            var it = std.mem.tokenizeScalar(u8, list[0], ' ');
            while (it.next()) |w| {
                kvs[n] = .{ w, list[1] };
                n += 1;
            }
        }
        const done = kvs;
        break :blk Words.initComptime(done);
    };
}

pub const Span = struct { start: usize, len: usize, kind: Tok };

pub fn pushSpan(gpa: Allocator, spans: *std.ArrayList(Span), start: usize, len: usize, kind: Tok) !void {
    if (len == 0 or kind == .text) return;
    if (spans.items.len > 0) {
        const p = &spans.items[spans.items.len - 1];
        if (p.kind == kind and p.start + p.len == start) {
            p.len += len;
            return;
        }
    }
    try spans.append(gpa, .{ .start = start, .len = len, .kind = kind });
}

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
pub fn isIdent(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}
pub fn isDigit(c: u8) bool {
    return std.ascii.isDigit(c);
}
pub fn isUpper(c: u8) bool {
    return std.ascii.isUpper(c);
}
pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

// Whether `s` is at line[i].
pub fn at(line: []const u8, i: usize, s: []const u8) bool {
    return s.len > 0 and i + s.len <= line.len and std.mem.eql(u8, line[i .. i + s.len], s);
}

// The same, ignoring ASCII case: HTML's </SCRIPT>.
pub fn atNoCase(line: []const u8, i: usize, s: []const u8) bool {
    return s.len > 0 and i + s.len <= line.len and std.ascii.eqlIgnoreCase(line[i .. i + s.len], s);
}

// Where `s` next is in line[from..end], ignoring case; `end` if nowhere.
pub fn findNoCase(line: []const u8, from: usize, end: usize, s: []const u8) usize {
    var i = from;
    while (i + s.len <= end) : (i += 1) {
        if (atNoCase(line, i, s)) return i;
    }
    return end;
}

pub fn isWordIn(list: []const u8, w: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

pub fn contains(s: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, s, c) != null;
}

pub fn allOf(s: []const u8, comptime pred: fn (u8) bool) bool {
    for (s) |c| if (!pred(c)) return false;
    return true;
}
