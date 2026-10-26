// The document's bytes as a piece table.
//
// The file is read once into `orig` and never written; everything typed is
// appended to `add`, which only grows, so neither ever moves and a piece is
// just (which buffer, where, how long). The document is the pieces read in
// order. Deleted text stays in its buffer, so undo keeps the pieces it
// removed instead of copying their bytes.
//
// Each piece also counts its newlines, and `orig_lf` lists where every
// newline of `orig` is, so splitting a piece of a huge file costs a binary
// search, not a scan.

import std;

let SRC_ORIG: u8 = 0;
let SRC_ADD: u8 = 1;

struct Piece { src: u8, start: i64, len: i64, lf: i64 }

// The document: views of the two buffers, the pieces, and their totals.
// The arrays belong to whoever made the Text (see text_new).
struct Text {
    orig: const u8[:],
    orig_lf: const i64[:],
    add: u8[>..]&,
    pieces: Piece[>..<]&,
    len: i64,
    lf: i64,
    dirty_from: i64 = NOT_DIRTY,    // the first offset changed since the last take_dirty
}

let NOT_DIRTY: i64 = 0x7FFFFFFFFFFFFFFF;

// Where the text first changed since the last call, or NOT_DIRTY.
fn take_dirty(t: Text&) -> i64 {
    let d = t.dirty_from;
    t.dirty_from = NOT_DIRTY;
    return d;
}

// Appends the offset of every '\n' in `s` to `out`.
fn index_lf(s: const u8[:], out: i64[>..]&) {
    let nl = byte_set("\n");
    var pos = 0;
    loop {
        let k = find_any(s[pos..], nl);
        if k < 0 { break; }
        out.push(pos + k);
        pos += k + 1;
    }
}

fn text_new(orig: const u8[:], orig_lf: const i64[:], add: u8[>..]&, pieces: Piece[>..<]&) -> Text {
    pieces.resize(0, default<Piece>());
    if orig.len > 0 {
        pieces.push(Piece { src: SRC_ORIG, start: 0, len: orig.len, lf: orig_lf.len });
    }
    return Text { orig: orig, orig_lf: orig_lf, add: add, pieces: pieces, len: orig.len, lf: orig_lf.len };
}

fn bytes_of(t: Text&, src: u8, start: i64, len: i64) -> const u8[:] {
    if src == SRC_ORIG { t.orig[start..start + len] } else { t.add[start..start + len] }
}

fn count_lf(t: Text&, src: u8, start: i64, len: i64) -> i64 {
    if len <= 0 { return 0; }
    if src == SRC_ORIG {
        let a = lower_bound(t.orig_lf) { it < start };
        let b = lower_bound(t.orig_lf) { it < start + len };
        return b - a;
    }
    var n = 0;
    for c in t.add[start..start + len] { if c == '\n' { n++; } }
    return n;
}

fn line_count(t: Text&) -> i64 { t.lf + 1 }

// Splits the pieces so that one starts at `pos`, and returns its index:
// pieces[..k] are exactly the bytes before `pos`.
fn split_at(t: Text&, pos: i64) -> i64 {
    var at = 0;
    for i in t.pieces.len {
        let p = t.pieces[i];
        if pos == at { return i; }
        if pos < at + p.len {
            let off = pos - at;
            let left_lf = count_lf(t, p.src, p.start, off);
            t.pieces[i] = Piece { src: p.src, start: p.start, len: off, lf: left_lf };
            insert_at(t.pieces, i + 1,
                      Piece { src: p.src, start: p.start + off, len: p.len - off, lf: p.lf - left_lf });
            return i + 1;
        }
        at += p.len;
    }
    return t.pieces.len;
}

// Makes room for `n` pieces at index `k`.
fn open_gap(ps: Piece[>..<]&, k: i64, n: i64) {
    let old = ps.len;
    ps.resize(old + n, default<Piece>());
    var j = old;
    while j > k {
        j--;
        ps[j + n] = ps[j];
    }
}

// Joins pieces k-1 and k when the second continues the first in the same buffer.
fn merge_at(t: Text&, k: i64) {
    if k <= 0 || k >= t.pieces.len { return; }
    let a = t.pieces[k - 1];
    let b = t.pieces[k];
    if a.src == b.src && a.start + a.len == b.start {
        t.pieces[k - 1] = Piece { src: a.src, start: a.start, len: a.len + b.len, lf: a.lf + b.lf };
        remove_at(t.pieces, k);
    }
}

// Inserts the given pieces at `pos`.
fn insert_pieces(t: Text&, pos: i64, ps: const Piece[:]) {
    if ps.len == 0 { return; }
    t.dirty_from = min(t.dirty_from, pos);
    let k = split_at(t, pos);
    open_gap(t.pieces, k, ps.len);
    for p, i in ps {
        t.pieces[k + i] = p;
        t.len += p.len;
        t.lf += p.lf;
    }
    merge_at(t, k + ps.len);
    merge_at(t, k);
}

// Appends `bytes` to the add buffer and inserts them at `pos`; returns
// where they went in the add buffer.
fn insert(t: Text&, pos: i64, bytes: const u8[:]) -> i64 {
    let start = t.add.len;
    if bytes.len == 0 { return start; }
    t.add.append(bytes);
    let p = Piece { src: SRC_ADD, start: start, len: bytes.len, lf: count_lf(t, SRC_ADD, start, bytes.len) };
    let one: Piece[1] = [p];
    insert_pieces(t, pos, one);
    return start;
}

// Removes [pos, pos + len) and appends the pieces that held it to `out`,
// a Piece array of either growable kind.
fn cut(t: Text&, pos: i64, len: i64, out) {
    if len <= 0 { return; }
    t.dirty_from = min(t.dirty_from, pos);
    let a = split_at(t, pos);
    let b = split_at(t, pos + len);
    for i in a..b {
        let p = t.pieces[i];
        out.push(p);
        t.len -= p.len;
        t.lf -= p.lf;
    }
    let n = b - a;
    for j in b..t.pieces.len { t.pieces[j - n] = t.pieces[j]; }
    t.pieces.resize(t.pieces.len - n, default<Piece>());
    merge_at(t, a);
}

// Appends the bytes of [a, b) to `out`.
fn read(t: Text&, a: i64, b: i64, out: u8[>..]&) {
    if b <= a { return; }
    var at = 0;
    for p in t.pieces {
        let end = at + p.len;
        if end > a && at < b {
            let lo = max(a, at) - at;
            let hi = min(b, end) - at;
            out.append(bytes_of(t, p.src, p.start + lo, hi - lo));
        }
        if end >= b { break; }
        at = end;
    }
}

fn byte_at(t: Text&, pos: i64) -> u8 {
    var at = 0;
    for p in t.pieces {
        if pos < at + p.len { return bytes_of(t, p.src, p.start, p.len)[pos - at]; }
        at += p.len;
    }
    return 0;
}

// The offset where line `n` (0-based) starts.
fn line_start(t: Text&, n: i64) -> i64 {
    if n <= 0 { return 0; }
    if n > t.lf { return t.len; }
    var at = 0;
    var lf = 0;
    for p in t.pieces {
        if lf + p.lf >= n {
            let k = n - lf;                                 // the k-th newline in this piece, from 1
            if p.src == SRC_ORIG {
                let first = lower_bound(t.orig_lf) { it < p.start };
                return at + t.orig_lf[first + k - 1] - p.start + 1;
            }
            var seen = 0;
            for c, i in t.add[p.start..p.start + p.len] {
                if c == '\n' {
                    seen++;
                    if seen == k { return at + i + 1; }
                }
            }
        }
        at += p.len;
        lf += p.lf;
    }
    return t.len;
}

// The line `pos` is on.
fn line_of(t: Text&, pos: i64) -> i64 {
    var at = 0;
    var lf = 0;
    for p in t.pieces {
        if pos < at + p.len { return lf + count_lf(t, p.src, p.start, pos - at); }
        at += p.len;
        lf += p.lf;
    }
    return lf;
}

// Where line `n`'s text ends: before its "\n" or "\r\n".
fn line_end(t: Text&, n: i64) -> i64 {
    if n >= t.lf { return t.len; }
    let nl = line_start(t, n + 1) - 1;
    if nl > line_start(t, n) && byte_at(t, nl - 1) == '\r' { return nl - 1; }
    return nl;
}

// Appends line `n`'s text, without its line break, to `out`.
fn read_line(t: Text&, n: i64, out: u8[>..]&) {
    read(t, line_start(t, n), line_end(t, n), out);
}

// The first match of `needle` at or after `from`, or -1.
fn find_forward(t: Text&, from: i64, needle: const u8[:]) -> i64 {
    let m = needle.len;
    if m == 0 || from >= t.len { return -1; }
    var carry: u8[>..] = [];           // the last m - 1 bytes before the current piece
    var carry_at = 0;
    var at = 0;
    for p in t.pieces {
        let end = at + p.len;
        if end <= from { at = end; continue; }
        let lo = max(from, at);
        let seg = bytes_of(t, p.src, p.start + lo - at, end - lo);
        if carry.len > 0 {
            var w = copy(carry);
            w.append(seg[..min(m - 1, seg.len)]);
            let k = find(w, needle);
            if k >= 0 && k < carry.len { return carry_at + k; }
        }
        let k = find(seg, needle);
        if k >= 0 { return lo + k; }
        var next = copy(carry);
        next.append(seg);
        let keep = min(m - 1, next.len);
        carry.clear();
        carry.append(next[next.len - keep..]);
        carry_at = end - keep;
        at = end;
    }
    return -1;
}

// The last match of `needle` that ends at or before `before`, or -1.
fn find_backward(t: Text&, before: i64, needle: const u8[:]) -> i64 {
    let m = needle.len;
    if m == 0 || before <= 0 { return -1; }
    var carry: u8[>..] = [];           // the first m - 1 bytes after the current piece
    var end_at = t.len;
    var i = t.pieces.len;
    while i > 0 {
        i--;
        let p = t.pieces[i];
        let at = end_at - p.len;
        if at >= before { end_at = at; continue; }
        let hi = min(before, end_at);
        let seg = bytes_of(t, p.src, p.start, hi - at);
        if carry.len > 0 {
            let head = seg[max(0, seg.len - (m - 1))..];
            var w: u8[>..] = [];
            w.append(head);
            w.append(carry);
            let k = rfind(w, needle);
            if k >= 0 && k + m > head.len { return hi - head.len + k; }
        }
        let k = rfind(seg, needle);
        if k >= 0 { return at + k; }
        var next: u8[>..] = [];
        next.append(seg);
        next.append(carry);
        let keep = min(m - 1, next.len);
        carry.clear();
        carry.append(next[..keep]);
        end_at = at;
    }
    return -1;
}
