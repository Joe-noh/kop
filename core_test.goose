import std;
import core.text;
import core.select;
import core.undo;
import core.motion;
import core.edit;
import core.width;
import core.utf8;
import core.doc;
import core.settings;
import view.fontfile;
import os;

var failures = 0;

fn check(ok: bool, what: const u8[:]) {
    if !ok {
        failures++;
        print("FAIL: ", what);
    }
}

fn whole(t: Text&) -> u8[>..] {
    var out: u8[>..] = [];
    read(t, 0, t.len, out);
    return out;
}

fn test_text_basics() {
    let src = "hello\nworld\n";
    var lf: i64[>..] = [];
    index_lf(src, lf);
    var add: u8[>..] = [];
    var pieces: Piece[>..<] = [];
    var t = text_new(src, lf, add, pieces);
    check(t.len == 12 && line_count(t) == 3, "initial counts");
    insert(t, 5, ", big");
    check(whole(t) == "hello, big\nworld\n", "insert middle");
    insert(t, 0, ">");
    insert(t, t.len, "end");
    check(whole(t) == ">hello, big\nworld\nend", "insert ends");
    var gone: Piece[>..] = [];
    cut(t, 6, 5, gone);
    check(whole(t) == ">hello\nworld\nend", "cut");
    check(line_start(t, 1) == 7 && line_start(t, 2) == 13, "line_start");
    check(line_of(t, 6) == 0 && line_of(t, 7) == 1 && line_of(t, 20) == 2, "line_of");
    check(line_end(t, 0) == 6 && line_end(t, 2) == t.len, "line_end");
    insert_pieces(t, 6, gone);
    check(whole(t) == ">hello, big\nworld\nend", "reinsert cut pieces");
    check(find_forward(t, 0, "world") == 12, "find_forward");
    check(find_backward(t, t.len, "l") == 15, "find_backward");
}

// Random edits against a plain byte array, checking contents and line queries.
fn test_text_fuzz() {
    var r = rng { 12345 };
    let src = "alpha\nbeta\r\ngamma\n\ndelta";
    var lf: i64[>..] = [];
    index_lf(src, lf);
    var add: u8[>..] = [];
    var pieces: Piece[>..<] = [];
    var t = text_new(src, lf, add, pieces);
    var model: u8[>..] = [];
    model.append(src);
    let alphabet = "ab\nあ\r";
    var gone: Piece[>..] = [];
    for step in 3000 {
        let pos = r.rand_int(model.len + 1);
        if r.rand_int(3) > 0 || model.len == 0 {
            var ins: u8[>..] = [];
            for k in r.rand_int(4) + 1 { ins.push(alphabet[r.rand_int(alphabet.len)]); }
            insert(t, pos, ins);
            var next: u8[>..] = [];
            next.append(model[..pos]);
            next.append(ins);
            next.append(model[pos..]);
            model = copy(next);
        } else {
            let n = min(r.rand_int(6) + 1, model.len - pos);
            gone.clear();
            cut(t, pos, n, gone);
            if r.rand_int(4) == 0 {
                insert_pieces(t, pos, gone);         // as undo would
            } else {
                var next: u8[>..] = [];
                next.append(model[..pos]);
                next.append(model[pos + n..]);
                model = copy(next);
            }
        }
        if step % 97 == 0 || step == 2999 {
            check(whole(t) == model, str("fuzz contents at step ", step));
            var nls = 0;
            for c in model { if c == '\n' { nls++; } }
            check(t.lf == nls && t.len == model.len, str("fuzz totals at step ", step));
            var expect_start = 0;
            var line = 0;
            for c, i in model {
                if c == '\n' {
                    line++;
                    if line_start(t, line) != i + 1 { check(false, str("line_start ", line, " at step ", step)); }
                }
            }
            let probe = r.rand_int(model.len + 1);
            var l = 0;
            for c in model[..probe] { if c == '\n' { l++; } }
            check(line_of(t, probe) == l, str("line_of at step ", step));
            let needle = model[probe..min(probe + 3, model.len)];
            if needle.len > 0 {
                check(find_forward(t, 0, needle) == find(model, needle), str("find_forward at step ", step));
                check(find_backward(t, t.len, needle) == rfind(model, needle), str("find_backward at step ", step));
            }
        }
    }
    print("fuzz: ", t.pieces.len, " pieces over ", t.len, " bytes");
}

// Runs F on a fresh editor over `src`.
fn with_editor<F>(src: const u8[:], crlf: bool) {
    var lf: i64[>..] = [];
    index_lf(src, lf);
    var add: u8[>..] = [];
    var pieces: Piece[>..<] = [];
    var t = text_new(src, lf, add, pieces);
    var ops: EditOp[>..<] = [];
    var dels: Piece[>..<] = [];
    var groups: Group[>..<] = [];
    var snaps: Sel[>..<] = [];
    var h = History { ops: ops, dels: dels, groups: groups, snaps: snaps, applied: 0, last_kind: KIND_NONE, saved_at: 0 };
    var sels: Sel[>..<] = [];
    sels.push(caret(0));
    var ed = Editor { t: t, h: h, sels: sels, crlf: crlf, tabs: false };
    F(ed);
}

fn type_str(ed: Editor&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        let cp, n = decode(s, i);
        insert_text(ed, s[i..i + n], KIND_TYPE);
        i += n;
    }
}

fn test_editing() {
    with_editor("", false) { ed =>
        type_str(ed, "  日本語");
        newline(ed);
        type_str(ed, "abc");
        check(whole(ed.t) == "  日本語\n  abc", "typing with auto-indent");
        check(ed.h.groups.len == 3, str("typing groups: ", ed.h.groups.len));
        delete_each(ed) { char_left(ed.t, it) };
        delete_each(ed) { char_left(ed.t, it) };
        check(whole(ed.t) == "  日本語\n  a", "backspace");
        check(undo(ed.t, ed.h, ed.sels) && whole(ed.t) == "  日本語\n  ab", "undo one backspace");
        check(undo(ed.t, ed.h, ed.sels) && whole(ed.t) == "  日本語\n  abc", "undo other backspace");
        check(undo(ed.t, ed.h, ed.sels) && whole(ed.t) == "  日本語\n  ", "undo typing");
        check(undo(ed.t, ed.h, ed.sels) && whole(ed.t) == "  日本語", "undo newline");
        check(redo(ed.t, ed.h, ed.sels) && redo(ed.t, ed.h, ed.sels) && whole(ed.t) == "  日本語\n  abc", "redo");
        check(primary(ed).head == ed.t.len, "caret after redo");
        type_str(ed, "!");
        check(!redo(ed.t, ed.h, ed.sels), "typing drops redo");
    };
    with_editor("one\r\ntwo", true) { ed =>
        set_single(ed, caret(5));
        delete_each(ed) { char_left(ed.t, it) };
        check(whole(ed.t) == "onetwo", "backspace removes \\r\\n at once");
        newline(ed);
        check(whole(ed.t) == "one\r\ntwo", "newline is the document's");
        paste(ed, "x\ny\n");
        check(whole(ed.t) == "one\r\nx\r\ny\r\ntwo", "paste converts line breaks");
    };
}

fn test_multi_cursor() {
    with_editor("aa\nbb\ncc", false) { ed =>
        ed.sels.resize(0, caret(0));
        ed.sels.push(caret(6));
        ed.sels.push(caret(0));
        ed.sels.push(caret(3));
        insert_text(ed, "> ", KIND_TYPE);
        check(whole(ed.t) == "> aa\n> bb\n> cc", "insert at three carets");
        delete_each(ed) { char_left(ed.t, it) };
        check(whole(ed.t) == ">aa\n>bb\n>cc", "backspace at three carets");
        check(undo(ed.t, ed.h, ed.sels) && whole(ed.t) == "> aa\n> bb\n> cc", "undo multi");
        check(ed.sels.len == 3, "selections restored");
        var copied: u8[>..] = [];
        copy_text(ed, copied);
        check(copied == "> aa\n> bb\n> cc\n", str("copy whole lines: ", copied));
        set_single(ed, caret(0));
        ed.sels.push(caret(5));
        ed.sels.push(caret(10));
        paste(ed, "1\n2\n3");
        check(whole(ed.t) == "1> aa\n2> bb\n3> cc", "paste one line per caret");
    };
}

fn test_motion() {
    with_editor("日本語テキストです abc_1 ok\n  x", false) { ed =>
        let t = ed.t;
        check(word_right(t, 0) == 9, "word: kanji");
        check(word_right(t, 9) == 21, "word: katakana");
        check(word_right(t, 21) == 27, "word: hiragana");
        check(word_right(t, 27) == 33, "word: ascii after space");
        check(word_left(t, 33) == 28, "word left");
        let a, b = word_range(t, 12);
        check(a == 9 && b == 21, "word range");
        check(char_right(t, 0) == 3 && char_left(t, 3) == 0, "char steps");
        check(col_of(t, 9) == 6, "columns of wide chars");
        let p, g = vertical(t, 9, -1, 1);
        check(p == line_start(t, 1) + 3 && g == 6, str("down to a short line: ", p, " ", g));
        let p2, g2 = vertical(t, p, g, -1);
        check(p2 == 9, "back up keeps the goal");
        check(smart_home(t, line_start(t, 1) + 3) == line_start(t, 1) + 2, "smart home");
    };
    check(eaw_width(0x3042) == 2 && eaw_width('a') == 1 && eaw_width(0x0301) == 0, "east asian width");
    check(offset_at_col("aあb", 1) == 1 && offset_at_col("aあb", 3) == 4, "offset at column");
    check(looks_utf8("日本語", 100) && !looks_utf8("\x82\xA0", 100), "utf-8 check");
}

// Random commands, then undo all of them and redo all of them.
fn test_undo_fuzz() {
    let src = "first line\nsecond\n\tthird 日本\n";
    with_editor(src, false) { ed =>
        var r = rng { 777 };
        var states: u64[>..] = [];             // a hash of the text after each edit
        states.push(hash(whole(ed.t)));
        for step in 400 {
            let n = ed.t.len;
            ed.sels.resize(0, caret(0));
            for k in r.rand_int(3) + 1 {
                let a = r.rand_int(n + 1);
                let b = if r.rand_int(2) == 0 { a } else { r.rand_int(n + 1) };
                ed.sels.push(Sel { anchor: a, head: b });
            }
            // Keep the carets on character boundaries.
            for &s in ed.sels {
                while s.anchor > 0 && s.anchor < n && is_cont(byte_at(ed.t, s.anchor)) { s.anchor--; }
                while s.head > 0 && s.head < n && is_cont(byte_at(ed.t, s.head)) { s.head--; }
            }
            seal(ed.h);
            let before = ed.h.applied;
            match r.rand_int(5) {
                0 => insert_text(ed, "xy", KIND_EDIT),
                1 => insert_text(ed, "語\n", KIND_EDIT),
                2 => delete_each(ed) { char_left(ed.t, it) },
                3 => newline(ed),
                _ => paste(ed, "p\nq"),
            }
            if ed.h.applied != before { states.push(hash(whole(ed.t))); }
        }
        var i = states.len - 1;
        var ok = true;
        while i > 0 {
            i--;
            ok = ok && undo(ed.t, ed.h, ed.sels) && hash(whole(ed.t)) == states[i];
        }
        check(ok && !undo(ed.t, ed.h, ed.sels), "undo back to the start");
        ok = true;
        var j = 0;
        for s in states {
            if j > 0 { ok = ok && redo(ed.t, ed.h, ed.sels) && hash(whole(ed.t)) == s; }
            j++;
        }
        check(ok && !redo(ed.t, ed.h, ed.sels), "redo to the end");
    };
}

fn test_doc() {
    let info = detect("\xEF\xBB\xBFa\r\n\tb\r\n\tc\r\n d");
    check(info.bom && info.crlf && info.utf8 && info.tabs, "detect");
    check(body("\xEF\xBB\xBFab") == "ab", "body after BOM");
    let sjis = detect("\x93\xFA\x96\x7B\x8C\xEA\n");
    check(!sjis.utf8, "Shift_JIS is not UTF-8");
}

fn test_settings() {
    var s = Settings {};
    var problems: u8[>..] = [];
    check(apply_settings(s, """{ "editor": { "fontSize": 18 } }""", problems) && problems.len == 0, "editor size");
    check(s.editor_font_size == 18.0 && s.ui_font_size == 11.0, "only what the file names changes");
    check(apply_settings(s, """{ "ui": { "fontSize": 11.5 } }""", problems), "ui size over the first");
    check(s.editor_font_size == 18.0 && s.ui_font_size == 11.5, "files layer");
    check(apply_settings(s, """{ "ui": { "fontSize": 100, "theme": "x" }, "other": 1 }""", problems), "problems are not fatal");
    check(s.ui_font_size == MAX_FONT_SIZE, "out of range is clamped");
    check(find(problems, "ui.fontSize") >= 0 && find(problems, "ui.theme") >= 0 && find(problems, "other") >= 0,
          str("problems named: ", problems));
    problems.clear();
    check(!apply_settings(s, """{ "editor": { "fontSize": 9 """, problems) && problems.len > 0, "broken JSON");
    check(s.editor_font_size == 18.0, "broken JSON changes nothing");
    var t = Settings {};
    check(apply_settings(t, """{ "editor": { "fontFamily": ["Menlo", "/x/y.ttf"] }, "ui": { "fontFamily": "Osaka" } }""", problems),
          "font families");
    check(t.editor_fonts == "Menlo\n/x/y.ttf\n" && t.ui_fonts == "Osaka\n", str("font lists: ", t.editor_fonts, t.ui_fonts));
    var dir: u8[>..] = [];
    project_dir("a/b/c.txt", dir);
    check(dir == "a/b", "project of a file");
}

// On a Mac: finding system fonts by name, a font out of a collection, and
// what a font has.
fn test_font_files() {
    var nfc: u8[>..] = [];
    compose_kana("\xE3\x82\xAD\xE3\x82\x99\xE3\x83\x8F\xE3\x82\x9A\xE3\x81\xAF", nfc);    // キ゛ハ゜は, decomposed
    check(nfc == "ギパは", str("kana composed: ", nfc));
    if !file_exists("/System/Library/Fonts/Menlo.ttc") { return; }
    var path: u8[>..] = [];
    check(resolve_font("Menlo", path) && path == "/System/Library/Fonts/Menlo.ttc", str("resolve Menlo: ", path));
    path.clear();
    check(resolve_font("ヒラギノ角ゴシック W3", path), "resolve Hiragino");
    path.clear();
    check(!resolve_font("NoSuchFont-Regular", path), "unknown font");
    var raw: u8[>..] = [];
    var ttf: u8[>..] = [];
    check(read_file("/System/Library/Fonts/Menlo.ttc", raw) && single_font(raw, ttf), "a font out of a collection");
    var has: u8[>..] = [];
    coverage(ttf, has);
    check(has['A'] != 0 && has[0x3042] == 0, "Menlo has A, not あ");
    var raw2: u8[>..] = [];
    var ttf2: u8[>..] = [];
    path.clear();
    resolve_font("ヒラギノ角ゴシック W3", path);
    check(read_file(path, raw2) && single_font(raw2, ttf2), "Hiragino out of its collection");
    coverage(ttf2, has);
    check(has[0x3042] != 0 && has[0x6F22] != 0, "Hiragino has あ and 漢");
}

fn main() {
    test_font_files();
    test_settings();
    test_undo_fuzz();
    test_doc();
    test_editing();
    test_multi_cursor();
    test_motion();
    test_text_basics();
    test_text_fuzz();
    if failures == 0 { print("all ok"); } else { print(failures, " failure(s)"); exit(1); }
}
