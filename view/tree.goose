// The file tree beside the text: a directory's entries as rows in the order
// they show, directories first. Opening a directory lists it then and puts
// its rows after its own; closing it takes them out again.

import std;
import os;
import core.width;

struct Entry {
    path_at: i64,           // the entry's path, in the tree's pool
    path_len: i64,
    name_at: i64,           // where its last component starts, from path_at
    depth: i64,
    is_dir: bool,
    open: bool,
}

struct Tree {
    root: u8[..1024],       // the directory opened; empty for none
    pool: u8[>..<]&,        // every path listed so far, end to end
    rows: Entry[>..<]&,
    shown: bool = false,
    top: i64 = 0,           // the first row shown
    width: i64 = 32,        // in cells
    wheel: f32 = 0.0,
}

fn path_of(tr: Tree&, e: Entry) -> const u8[:] { tr.pool[e.path_at..e.path_at + e.path_len] }
fn name_of(tr: Tree&, e: Entry) -> const u8[:] { tr.pool[e.path_at + e.name_at..e.path_at + e.path_len] }

// Names not worth showing.
fn hidden(name: const u8[:]) -> bool { name == ".git" || name == ".DS_Store" }

// Appends rows for the entries of directory `dir` to `out`, directories first.
fn list_entries(tr: Tree&, dir: const u8[:], depth: i64, out: Entry[>..<]&) {
    var names: u8[>..] = [];
    if !list_dir(dir, names) { return; }
    var path: u8[>..] = [];
    let sep = if dir.len > 0 && dir[dir.len - 1] != '/' { "/" } else { "" };
    let wanted: bool[2] = [true, false];
    for want_dirs in wanted {
        each_split(names, '\n') {
            path.clear();
            format(path, dir, sep, it);
            if it.len > 0 && !hidden(it) && is_dir(path) == want_dirs {
                let at = tr.pool.len;
                tr.pool.append(path);
                out.push(Entry { path_at: at, path_len: path.len, name_at: path.len - it.len, depth: depth,
                                 is_dir: want_dirs, open: false });
            }
        };
    }
}

fn tree_open(tr: Tree&, dir: const u8[:]) {
    tr.root.resize(0, 0);
    var end = dir.len;
    while end > 1 && dir[end - 1] == '/' { end--; }
    tr.root.append(dir[..min(end, 1024)]);
    tr.pool.resize(0, 0);
    tr.rows.resize(0, default<Entry>());
    list_entries(tr, tr.root, 0, tr.rows);
    tr.shown = true;
    tr.top = 0;
}

// Opens or closes directory row `i`.
fn toggle(tr: Tree&, i: i64) {
    let e = tr.rows[i];
    if !e.is_dir { return; }
    if e.open {
        var j = i + 1;
        while j < tr.rows.len && tr.rows[j].depth > e.depth { j++; }
        let n = j - i - 1;
        for m in j..tr.rows.len { tr.rows[m - n] = tr.rows[m]; }
        tr.rows.resize(tr.rows.len - n, default<Entry>());
        tr.rows[i].open = false;
        return;
    }
    var kids: Entry[>..<] = [];
    var dir: u8[>..] = [];
    dir.append(path_of(tr, e));
    list_entries(tr, dir, e.depth + 1, kids);
    let old = tr.rows.len;
    tr.rows.resize(old + kids.len, default<Entry>());
    var m = old;
    while m > i + 1 {
        m--;
        tr.rows[m + kids.len] = tr.rows[m];
    }
    for kid, k in kids { tr.rows[i + 1 + k] = kid; }
    tr.rows[i].open = true;
}

// The longest start of `s` that fits in `cells`, with "…" when cut.
fn fit(s: const u8[:], cells: i64, out: u8[>..]&) {
    if advance(s, 0) <= cells {
        out.append(s);
        return;
    }
    let cut = offset_at_col(s, max(cells - 2, 0));
    out.append(s[..cut]);
    out.append("…");
}
