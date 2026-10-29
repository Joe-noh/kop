// Syntax highlighting: which lexer a language takes, and a cache of the
// state each line starts in.
//
// A line's highlighting depends only on its text and the state it starts
// in, such as inside a block comment, or in a string or a <style> that
// goes on from the line before. So the state at the start of each line is
// kept, one byte a line; only the lines on screen are lexed for their
// colors, and an edit forgets the states from its line on. The lexers
// themselves are in syntax/: code, style and markup, with what they share
// in lang and the languages in languages.

const std = @import("std");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const Text = @import("text.zig").Text;
pub const lang = @import("syntax/lang.zig");
pub const languages = @import("syntax/languages.zig");
pub const code = @import("syntax/code.zig");
pub const style = @import("syntax/style.zig");
pub const markup = @import("syntax/markup.zig");

pub const Language = lang.Language;
pub const Span = lang.Span;
pub const Tok = lang.Tok;
pub const state_normal = lang.state_normal;

// Appends the colored spans of `line`, which starts in `state`, to
// `spans`, and returns the state the next line starts in.
pub fn lexLine(gpa: Allocator, l: *const Language, line: []const u8, state: u8, spans: *std.ArrayList(Span)) !u8 {
    return switch (l.lexer) {
        .code => code.lex(gpa, l, line, 0, line.len, state, spans),
        .style => style.lex(gpa, l, line, 0, line.len, state, spans),
        .markup => markup.lex(gpa, l, line, 0, line.len, state, spans),
    };
}

// The states lines start in, for the lines known so far.
pub const Highlight = struct {
    gpa: Allocator,
    lang: ?*const Language, // null for a file of no known language
    states: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    chunk: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, path: []const u8) !Highlight {
        var hl = Highlight{ .gpa = gpa, .lang = languages.languageFor(path) };
        try hl.states.append(gpa, state_normal);
        return hl;
    }

    pub fn deinit(hl: *Highlight) void {
        hl.states.deinit(hl.gpa);
        hl.spans.deinit(hl.gpa);
        hl.chunk.deinit(hl.gpa);
    }

    // Forgets the states of the lines after the one `pos` was edited on.
    pub fn edited(hl: *Highlight, t: *const Text, pos: usize) void {
        const n = t.lineOf(pos);
        if (n + 1 < hl.states.items.len) hl.states.shrinkRetainingCapacity(n + 1);
    }

    // Lexes on from the last known state, for at most `budget` seconds or up to
    // line `upto`, whichever comes first; true when the states reach `upto`.
    pub fn extend(hl: *Highlight, t: *const Text, upto: usize, budget: f64) !bool {
        const l = hl.lang orelse return true;
        const target = @min(upto, t.lf);
        if (hl.states.items.len > target) return true;
        const started = sys.monotonic();
        // Read on in chunks from the start of the last line whose state is known.
        var n = hl.states.items.len - 1;
        var pos = t.lineStart(n);
        while (hl.states.items.len <= target) {
            hl.chunk.clearRetainingCapacity();
            const end = @min(pos + 65536, t.len);
            try t.read(pos, end, &hl.chunk);
            const chunk = hl.chunk.items;
            var from: usize = 0;
            while (std.mem.indexOfScalarPos(u8, chunk, from, '\n')) |k| {
                var line_end = k;
                if (line_end > from and chunk[line_end - 1] == '\r') line_end -= 1;
                hl.spans.clearRetainingCapacity();
                try hl.states.append(hl.gpa, try lexLine(hl.gpa, l, chunk[from..line_end], hl.states.items[n], &hl.spans));
                n += 1;
                from = k + 1;
                if (hl.states.items.len > target) return true;
            }
            if (from == 0) {
                // A line longer than the chunk: read it whole.
                hl.chunk.clearRetainingCapacity();
                try t.readLine(n, &hl.chunk);
                hl.spans.clearRetainingCapacity();
                try hl.states.append(hl.gpa, try lexLine(hl.gpa, l, hl.chunk.items, hl.states.items[n], &hl.spans));
                n += 1;
                pos = t.lineStart(n);
            } else pos += from;
            if (end == t.len and from == chunk.len) break;
            if (sys.monotonic() - started > budget) return false;
        }
        return hl.states.items.len > target;
    }

    // The state line `n` starts in, if it is known yet.
    pub fn stateAt(hl: *const Highlight, n: usize) ?u8 {
        return if (n < hl.states.items.len) hl.states.items[n] else null;
    }
};

// Tests.

const testing = std.testing;

// The spans of `line` as "kind:text" words, for comparing.
fn spansOf(l: *const Language, line: []const u8, state: u8, out: *std.ArrayList(u8)) !u8 {
    const gpa = testing.allocator;
    out.clearRetainingCapacity();
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    const next = try lexLine(gpa, l, line, state, &spans);
    for (spans.items) |s| try out.print(gpa, "{d}:{s} ", .{ @backingInt(s.kind), line[s.start .. s.start + s.len] });
    return next;
}

fn expectSpans(l: *const Language, line: []const u8, state: u8, want: []const u8, want_state: u8) !u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const next = try spansOf(l, line, state, &out);
    testing.expectEqualStrings(want, out.items) catch |e| {
        std.debug.print("{s}: {s}\n", .{ l.name, line });
        return e;
    };
    try testing.expectEqual(want_state, next);
    return next;
}

test "goose" {
    const g = &languages.goose;
    _ = try expectSpans(g, "fn main() -> i64 { let x = 0x1F + 2.5e-3; }", 0, "1:fn 7:main 2:i64 1:let 4:0x1F 4:2.5e-3 ", 0);
    _ = try expectSpans(g, "for i in 1..n { print(\"a\\\"b\", 'c', Point { true }); }  // done", 0, "1:for 1:in 4:1 7:print 5:\"a\\\"b\" 5:'c' 2:Point 3:true 6:// done ", 0);
    const st = try expectSpans(g, "x /* a /* b */ c", 0, "6:/* a /* b */ c ", 1);
    _ = try expectSpans(g, "d */ let", st, "6:d */ 1:let ", 0);
    _ = try expectSpans(g, "    let s = \"\"\"", 0, "1:let 5:\"\"\" ", code.code_raw);
    _ = try expectSpans(g, "  text \"\"\"; fn", code.code_raw, "5:  text \"\"\" 1:fn ", 0);
    _ = try expectSpans(g, "let MAX_SIZE: Point = A;", 0, "1:let 3:MAX_SIZE 2:Point 2:A ", 0);
    try testing.expect(languages.languageFor("dir/a.goose") != null);
    try testing.expect(languages.languageFor("dir.goose/README") == null);
}

test "zig" {
    const z = &languages.zig;
    _ = try expectSpans(z, "pub fn main() !void { const x: u8 = @intCast(0x1F); }", 0, "1:pub 1:fn 7:main 2:void 1:const 2:u8 7:@intCast 4:0x1F ", 0);
    _ = try expectSpans(z, "    \\\\a raw line", 0, "5:\\\\a raw line ", 0);
    _ = try expectSpans(z, "var s: Sel = .{ .head = null }; // c", 0, "1:var 2:Sel 3:null 6:// c ", 0);
}

test "highlight cache" {
    const tt = try @import("text.zig").TestText.init("a\n/* x\ny */\nb\n\"\"\"\nraw\n\"\"\"\nc");
    defer tt.deinit();
    const t = &tt.t;
    var hl = try Highlight.init(testing.allocator, "x.goose");
    defer hl.deinit();
    try testing.expect(try hl.extend(t, 100, 1.0));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0, 64, 64, 0 }, hl.states.items);
    _ = try t.insert(0, "/*\n");
    const d = t.takeDirty();
    try testing.expectEqual(@as(usize, 0), d);
    hl.edited(t, d);
    try testing.expectEqual(@as(usize, 1), hl.states.items.len);
    try testing.expect(try hl.extend(t, 100, 1.0));
    try testing.expectEqual(@as(u8, 1), hl.states.items[1]);
}

test "languages" {
    const L = languages;
    const ruby = &L.ruby;
    _ = try expectSpans(ruby, "def self.greet(name)", 0, "1:def 3:self 7:greet ", 0);
    _ = try expectSpans(ruby, "  @count += 1 # inc", 0, "11:@count 4:1 6:# inc ", 0);
    _ = try expectSpans(ruby, "puts :sym, key: \"v\", empty?", 0, "3::sym 3:key 5:\"v\" ", 0);
    _ = try expectSpans(ruby, "class Foo < Bar::BAZ", 0, "1:class 2:Foo 2:Bar 3:BAZ ", 0);
    var st = try expectSpans(ruby, "sql = <<~SQL", 0, "5:<<~SQL ", code.heredocState("SQL"));
    st = try expectSpans(ruby, "  select 1", st, "5:  select 1 ", st);
    _ = try expectSpans(ruby, "  SQL", st, "5:  SQL ", 0);
    st = try expectSpans(ruby, "=begin", 0, "6:=begin ", code.code_line_block);
    st = try expectSpans(ruby, "def x", st, "6:def x ", code.code_line_block);
    _ = try expectSpans(ruby, "=end", st, "6:=end ", 0);
    st = try expectSpans(ruby, "s = \"one", 0, "5:\"one ", code.code_long);
    _ = try expectSpans(ruby, "two\" if ok", st, "5:two\" 1:if ", 0);

    const js = &L.javascript;
    _ = try expectSpans(js, "function add(a, b) { return a + b; } // sum", 0, "1:function 7:add 1:return 6:// sum ", 0);
    st = try expectSpans(js, "const s = `a", 0, "1:const 5:`a ", code.code_long + 2);
    _ = try expectSpans(js, "b` + this.x(null)", st, "5:b` 3:this 7:x 3:null ", 0);
    _ = try expectSpans(js, "/* c */ let X_MAX = 0x1F;", 0, "6:/* c */ 1:let 3:X_MAX 4:0x1F ", 0);
    _ = try expectSpans(&L.typescript, "interface User { name: string; age?: number }", 0, "1:interface 2:User 2:string 2:number ", 0);

    const css = &L.css;
    _ = try expectSpans(css, "a.btn:hover, #main > ul li { color: #fff; margin: 0 auto; }", 0, "8:a 9:.btn 1::hover 9:#main 8:ul 8:li 10:color 3:#fff 10:margin 4:0 3:auto ", 0);
    _ = try expectSpans(css, "@media (max-width: 600px) {", 0, "1:@media 4:600px ", 1);
    _ = try expectSpans(css, "  width: calc(100% - 2px) !important; /* note", 1, "10:width 7:calc 4:100% 4:2px 1:!important 6:/* note ", 1 | style.style_comment);
    _ = try expectSpans(css, "end */ p { }", 1 | style.style_comment, "6:end */ 8:p ", 1);
    _ = try expectSpans(&L.scss, "$main: #333; .a { &:hover { color: $main; } } // c", 0, "11:$main 3:#333 9:.a 1::hover 10:color 11:$main 6:// c ", 0);
    const sass = &L.sass;
    _ = try expectSpans(sass, "nav", 0, "8:nav ", 0);
    _ = try expectSpans(sass, "  color: red", 0, "10:color 3:red ", 0);
    _ = try expectSpans(sass, "  a:hover", 0, "8:a 1::hover ", 0);
    _ = try expectSpans(sass, "  +button(2px)", 0, "1:+button 4:2px ", 0);

    const html = &L.html;
    _ = try expectSpans(html, "<a href=\"/x\" class=btn>Hi &amp; bye</a>", 0, "8:a 9:href 5:\"/x\" 9:class 5:btn 3:&amp; 8:a ", 0);
    _ = try expectSpans(html, "<!DOCTYPE html>", 0, "1:<!DOCTYPE html> ", 0);
    st = try expectSpans(html, "<!-- open", 0, "6:<!-- open ", markup.markup_comment);
    _ = try expectSpans(html, "close --> <b>", st, "6:close --> 8:b ", 0);
    st = try expectSpans(html, "<script>let x = 1;", 0, "8:script 1:let 4:1 ", markup.markup_script);
    st = try expectSpans(html, "</script><style>a { color: red }", st, "8:script 8:style 8:a 10:color 3:red ", markup.markup_style);
    _ = try expectSpans(html, "</style>", st, "8:style ", 0);
    st = try expectSpans(html, "<div", 0, "8:div ", markup.markup_tag);
    _ = try expectSpans(html, "  id=\"top\">text", st, "9:id 5:\"top\" ", 0);

    try testing.expect(L.languageFor("app/Gemfile") == &L.ruby);
    try testing.expect(L.languageFor("src/x.tsx") == &L.typescript);
    try testing.expect(L.languageFor("a/b.scss") == &L.scss);
    try testing.expect(L.languageFor("notes.txt") == null);
    try testing.expect(L.languageFor("build.zig") == &L.zig);
}
