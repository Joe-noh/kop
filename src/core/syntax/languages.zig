// The languages highlighted, and which one a file is.

const std = @import("std");
const lang = @import("lang.zig");
const Language = lang.Language;
const words = lang.words;

const js_keywords = "var let const function return if else for while do switch case default break continue new delete typeof instanceof in of try catch finally throw class extends super import export from as async await yield static get set with debugger void";
const js_constants = "true false null undefined NaN Infinity this";

pub const zig = Language{
    .lexer = .code,
    .name = "Zig",
    .extensions = ".zig .zon",
    .words = words(
        "const var fn pub return if else while for switch break continue defer errdefer try catch orelse and or struct enum union error test comptime inline noinline extern export packed opaque threadlocal callconv align linksection asm volatile allowzero noalias anytype anyframe async await suspend resume nosuspend usingnamespace",
        "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f16 f32 f64 f80 f128 bool void noreturn type anyerror anyopaque comptime_int comptime_float c_char c_short c_int c_long c_longlong c_uint c_ulong c_ushort c_ulonglong",
        "true false null undefined unreachable",
    ),
    .line_comment = "//",
    .raw_line = "\\\\",
    .quotes = "\"'",
    .function_words = "fn",
    .builtin_mark = '@',
    .capitalized_types = true,
};

pub const goose = Language{
    .lexer = .code,
    .name = "Goose",
    .extensions = ".goose",
    .words = words(
        "import namespace struct enum type fn thread_fn export simd recursive let var extern const pad reusable if else while for in loop block guard match return break continue as from upto inline checkfree",
        "bool varint i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 int2 int3 int4 float2 float3 float4",
        "true false null self",
    ),
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .nested_blocks = true,
    .raw_quote = "\"\"\"",
    .quotes = "\"'",
    .function_words = "fn thread_fn",
    .capitalized_types = true,
};

pub const ruby = Language{
    .lexer = .code,
    .name = "Ruby",
    .extensions = ".rb .rake .gemspec .ru .builder",
    .filenames = "Gemfile Rakefile Guardfile Capfile Podfile Vagrantfile Brewfile",
    .words = words(
        "def class module if elsif else unless while until for in do end begin rescue ensure raise return yield then case when break next redo retry and or not alias undef super defined? lambda proc require require_relative include extend attr_reader attr_writer attr_accessor private protected public",
        "",
        "nil true false self __FILE__ __LINE__ __method__ __dir__",
    ),
    .line_comment = "#",
    .line_block_open = "=begin",
    .line_block_close = "=end",
    .long_quotes = "\"'`",
    .function_words = "def",
    .variable_marks = "@$",
    .name_marks = "?!",
    .symbols = true,
    .heredocs = true,
    .capitalized_types = true,
};

pub const javascript = Language{
    .lexer = .code,
    .name = "JavaScript",
    .extensions = ".js .mjs .cjs .jsx",
    .words = words(js_keywords, "", js_constants),
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .quotes = "\"'",
    .long_quotes = "`",
    .function_words = "function",
    .capitalized_types = true,
};

pub const typescript = Language{
    .lexer = .code,
    .name = "TypeScript",
    .extensions = ".ts .tsx .mts .cts",
    .words = words(
        js_keywords ++ " type interface enum implements declare namespace module abstract readonly public private protected satisfies keyof infer is asserts override",
        "string number boolean any unknown never object symbol bigint",
        js_constants,
    ),
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .quotes = "\"'",
    .long_quotes = "`",
    .function_words = "function",
    .capitalized_types = true,
};

pub const html = Language{ .lexer = .markup, .name = "HTML", .extensions = ".html .htm .xhtml .erb" };

pub const css = Language{ .lexer = .style, .name = "CSS", .extensions = ".css", .words = words("!important and not only", "", "") };

pub const scss = Language{
    .lexer = .style,
    .name = "SCSS",
    .extensions = ".scss",
    .words = words("!important !default !global and not only", "", ""),
    .scss = true,
};

pub const sass = Language{
    .lexer = .style,
    .name = "Sass",
    .extensions = ".sass",
    .words = words("!important !default !global and not only", "", ""),
    .scss = true,
    .indented = true,
};

pub const all = [_]*const Language{ &zig, &goose, &ruby, &javascript, &typescript, &html, &css, &scss, &sass };

// The language of a file, by its extension or its whole name.
pub fn languageFor(path: []const u8) ?*const Language {
    const name = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    for (all) |l| {
        if (lang.isWordIn(l.filenames, name)) return l;
        if (dot) |d| if (lang.isWordIn(l.extensions, name[d..])) return l;
    }
    return null;
}
