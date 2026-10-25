// Selections. There is always at least one; each is an anchor and a head
// (the caret), equal when nothing is selected. `goal` is the cell column
// up and down aim for, kept across lines that are too short; -1 for none.

import std;

struct Sel { anchor: i64, head: i64, goal: i64 = -1 }

fn caret(pos: i64) -> Sel { Sel { anchor: pos, head: pos, goal: -1 } }
fn lo(s: Sel) -> i64 { min(s.anchor, s.head) }
fn hi(s: Sel) -> i64 { max(s.anchor, s.head) }
fn is_empty(s: Sel) -> bool { s.anchor == s.head }

// Sorts by start and merges selections that overlap, or carets that coincide.
fn normalize(sels: Sel[>..<]&) {
    sort(sels) { a, b => lo(a) < lo(b) || (lo(a) == lo(b) && hi(a) < hi(b)) };
    var w = 0;
    for i in sels.len {
        let s = sels[i];
        if w > 0 {
            let p = sels[w - 1];
            if lo(s) < hi(p) || (lo(s) == hi(p) && (is_empty(s) || is_empty(p))) {
                let a = min(lo(p), lo(s));
                let b = max(hi(p), hi(s));
                // Keep the direction of the selection that was there first.
                sels[w - 1] = if p.head < p.anchor { Sel { anchor: b, head: a } } else { Sel { anchor: a, head: b } };
                continue;
            }
        }
        sels[w] = s;
        w++;
    }
    sels.resize(w, caret(0));
}

fn clamp_sels(sels: Sel[>..<]&, len: i64) {
    for &s in sels {
        s.anchor = clamp(s.anchor, 0, len);
        s.head = clamp(s.head, 0, len);
    }
}
