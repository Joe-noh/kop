// The languages highlighted, and which one a file is.

import std;
import core.syntax.lang;

let JS_KEYWORDS = """var let const function return if else for while do switch case default break continue new delete typeof instanceof in of try catch finally throw class extends super import export from as async await yield static get set with debugger void""";
let JS_CONSTANTS = "true false null undefined NaN Infinity this";

let GOOSE = Language {
    id: 0, lexer: LEX_CODE, name: "Goose", extensions: ".goose", filenames: "",
    keywords: """import namespace struct enum type fn thread_fn export simd recursive let var extern const pad reusable if else while for in loop block guard match return break continue as from upto inline checkfree""",
    types: "bool varint i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 int2 int3 int4 float2 float3 float4",
    constants: "true false null self",
    line_comment: "//", block_open: "/*", block_close: "*/", nested_blocks: true,
    raw_quote: "\"\"\"", quotes: "\"'",
    function_words: "fn thread_fn",
    capitalized_types: true,
};

let RUBY = Language {
    id: 1, lexer: LEX_CODE, name: "Ruby", extensions: ".rb .rake .gemspec .ru .builder",
    filenames: "Gemfile Rakefile Guardfile Capfile Podfile Vagrantfile Brewfile",
    keywords: """def class module if elsif else unless while until for in do end begin rescue ensure raise return yield then case when break next redo retry and or not alias undef super defined? lambda proc require require_relative include extend attr_reader attr_writer attr_accessor private protected public""",
    constants: "nil true false self __FILE__ __LINE__ __method__ __dir__",
    line_comment: "#", line_block_open: "=begin", line_block_close: "=end",
    long_quotes: "\"'`",
    function_words: "def",
    variable_marks: "@$",
    name_marks: "?!",
    symbols: true,
    heredocs: true,
    capitalized_types: true,
};

let JAVASCRIPT = Language {
    id: 2, lexer: LEX_CODE, name: "JavaScript", extensions: ".js .mjs .cjs .jsx", filenames: "",
    keywords: JS_KEYWORDS,
    constants: JS_CONSTANTS,
    line_comment: "//", block_open: "/*", block_close: "*/",
    quotes: "\"'", long_quotes: "`",
    function_words: "function",
    capitalized_types: true,
};

let TYPESCRIPT = Language {
    id: 3, lexer: LEX_CODE, name: "TypeScript", extensions: ".ts .tsx .mts .cts", filenames: "",
    keywords: """var let const function return if else for while do switch case default break continue new delete typeof instanceof in of try catch finally throw class extends super import export from as async await yield static get set with debugger void type interface enum implements declare namespace module abstract readonly public private protected satisfies keyof infer is asserts override""",
    types: "string number boolean any unknown never object symbol bigint",
    constants: JS_CONSTANTS,
    line_comment: "//", block_open: "/*", block_close: "*/",
    quotes: "\"'", long_quotes: "`",
    function_words: "function",
    capitalized_types: true,
};

let HTML = Language {
    id: 4, lexer: LEX_MARKUP, name: "HTML", extensions: ".html .htm .xhtml .erb", filenames: "",
};

let CSS = Language {
    id: 5, lexer: LEX_STYLE, name: "CSS", extensions: ".css", filenames: "",
    keywords: "!important and not only",
};

let SCSS = Language {
    id: 6, lexer: LEX_STYLE, name: "SCSS", extensions: ".scss", filenames: "",
    keywords: "!important !default !global and not only",
    scss: true,
};

let SASS = Language {
    id: 7, lexer: LEX_STYLE, name: "Sass", extensions: ".sass", filenames: "",
    keywords: "!important !default !global and not only",
    scss: true,
    indented: true,
};

let LANGUAGES: Language[8] = [GOOSE, RUBY, JAVASCRIPT, TYPESCRIPT, HTML, CSS, SCSS, SASS];

// Fills the word table the first time it is needed.
fn ensure_words() {
    if word_kinds.count > 0 { return; }
    for lang in LANGUAGES { add_language_words(lang); }
}

// The language of a file, by its extension or its whole name; false for none.
fn language_for(path: const u8[:]) -> Language, bool {
    let slash = rfind(path, "/");
    let name = path[slash + 1..];
    let dot = rfind(name, ".");
    for lang in LANGUAGES {
        if is_word_in(lang.filenames, name) { return lang, true; }
        if dot >= 0 && is_word_in(lang.extensions, name[dot..]) { return lang, true; }
    }
    return GOOSE, false;
}
