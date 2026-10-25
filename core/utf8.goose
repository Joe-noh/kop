// UTF-8 over byte slices, and the character classes word motion uses.

import std;

fn is_cont(b: u8) -> bool { (b & 0xC0) == 0x80 }

// The codepoint at s[i] and how many bytes it takes. A malformed sequence
// is one byte of U+FFFD, so every byte belongs to some character.
fn decode(s: const u8[:], i: i64) -> u32, i64 {
    let b0 = s[i];
    if b0 < 0x80 { return b0, 1; }
    var n = 0;
    var cp: u32 = 0;
    if b0 >= 0xF0 && b0 < 0xF8 { n = 4; cp = b0 & 0x07; }
    else if b0 >= 0xE0 { n = 3; cp = b0 & 0x0F; }
    else if b0 >= 0xC2 { n = 2; cp = b0 & 0x1F; }
    else { return 0xFFFD, 1; }
    if i + n > s.len { return 0xFFFD, 1; }
    for k in 1..n {
        let b = s[i + k];
        if !is_cont(b) { return 0xFFFD, 1; }
        cp = (cp << 6) | (b & 0x3F);
    }
    return cp, n;
}

// Where the character before s[i] starts.
fn prev_start(s: const u8[:], i: i64) -> i64 {
    var j = i - 1;
    while j > 0 && i - j < 4 && is_cont(s[j]) { j--; }
    let cp, n = decode(s, j);
    if j + n != i { return i - 1; }        // malformed: one byte back
    return j;
}

// Whether the first `limit` bytes look like UTF-8. A sequence cut off by the
// limit is allowed.
fn looks_utf8(s: const u8[:], limit: i64) -> bool {
    let n = min(s.len, limit);
    var i = 0;
    while i < n {
        if s[i] < 0x80 { i++; continue; }
        let cp, k = decode(s, i);
        if cp == 0xFFFD && k == 1 {
            if i + 4 > n && s[i] >= 0xC2 { return true; }
            return false;
        }
        i += k;
    }
    return true;
}

// Character classes for word motion: a word is a run of one class, so
// "日本語テキストです" stops between the kanji, the katakana and the hiragana.
let CLASS_SPACE = 0;
let CLASS_PUNCT = 1;
let CLASS_WORD = 2;            // ASCII and full-width letters, digits, '_'
let CLASS_HIRAGANA = 3;
let CLASS_KATAKANA = 4;
let CLASS_KANJI = 5;
let CLASS_OTHER = 6;

fn char_class(cp: u32) -> i64 {
    if cp == ' ' || cp == '\t' || cp == 0x3000 { return CLASS_SPACE; }
    if cp < 0x80 {
        if (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || (cp >= '0' && cp <= '9') || cp == '_' {
            return CLASS_WORD;
        }
        return CLASS_PUNCT;
    }
    if cp >= 0x3041 && cp <= 0x309F { return CLASS_HIRAGANA; }
    if (cp >= 0x30A0 && cp <= 0x30FF) || (cp >= 0xFF66 && cp <= 0xFF9F) { return CLASS_KATAKANA; }
    if (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) || cp == 0x3005 { return CLASS_KANJI; }
    if (cp >= 0xFF10 && cp <= 0xFF19) || (cp >= 0xFF21 && cp <= 0xFF3A) || (cp >= 0xFF41 && cp <= 0xFF5A) {
        return CLASS_WORD;
    }
    if (cp >= 0x3000 && cp <= 0x303F) || (cp >= 0xFF00 && cp <= 0xFF65) || (cp >= 0x2000 && cp <= 0x206F) {
        return CLASS_PUNCT;
    }
    if cp >= 0xC0 && cp < 0x2000 { return CLASS_WORD; }      // accented Latin, Greek, Cyrillic
    return CLASS_OTHER;
}
