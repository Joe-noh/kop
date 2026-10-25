// Undo and redo.
//
// An edit is recorded as where it happened, the add-buffer span it
// inserted, and the pieces it removed, kept in `dels`: the removed bytes
// are still in their buffers, so nothing is copied. A group is what one
// command did, for every selection at once, with the selections before and
// after it. Typing extends the last group until something else happens.

import std;
import core.text;
import core.select;

struct EditOp { pos: i64, ins_start: i64, ins_len: i64, del_first: i64, del_count: i64, del_len: i64 }

struct Group {
    op_first: i64, op_count: i64,
    before_first: i64, before_count: i64,
    after_first: i64, after_count: i64,
    kind: i64,
}

let KIND_NONE = 0;
let KIND_TYPE = 1;          // typed characters: merged with the previous typing
let KIND_EDIT = 2;          // anything else that changes the text

struct History {
    ops: EditOp[>..<]&,
    dels: Piece[>..<]&,
    groups: Group[>..<]&,
    snaps: Sel[>..<]&,       // selections before and after each group
    applied: i64,           // groups[..applied] are in effect; the rest can be redone
    last_kind: i64,         // what the last command was, for merging typing
    saved_at: i64,          // `applied` when the file was saved; -1 if that state is gone
}

fn modified(h: History&) -> bool { h.applied != h.saved_at }

fn mark_saved(h: History&) {
    h.saved_at = h.applied;
    h.last_kind = KIND_NONE;
}

// Ends merging: the next typing starts a group of its own.
fn seal(h: History&) { h.last_kind = KIND_NONE; }

// Forgets what could be redone.
fn drop_redo(h: History&) {
    if h.applied == h.groups.len { return; }
    let g = h.groups[h.applied];
    if g.op_first < h.ops.len { h.dels.resize(h.ops[g.op_first].del_first, default<Piece>()); }
    h.ops.resize(g.op_first, default<EditOp>());
    h.snaps.resize(g.before_first, caret(0));
    h.groups.resize(h.applied, default<Group>());
    if h.saved_at > h.applied { h.saved_at = -1; }
}

// Starts recording a command of `kind` done to `sels`.
fn begin_group(h: History&, sels: const Sel[:], kind: i64) {
    let merge = kind == KIND_TYPE && h.last_kind == KIND_TYPE && h.applied == h.groups.len &&
                h.applied > 0 && h.saved_at != h.applied;
    if merge {
        // Reopen the last group: its "after" selections are the last snapshot.
        let g = h.groups[h.applied - 1];
        h.snaps.resize(g.after_first, caret(0));
        return;
    }
    drop_redo(h);
    let first = h.snaps.len;
    for s in sels { h.snaps.push(s); }
    h.groups.push(Group { op_first: h.ops.len, op_count: 0, before_first: first, before_count: sels.len,
                          after_first: h.snaps.len, after_count: 0, kind: kind });
    h.applied = h.groups.len;
}

fn end_group(h: History&, sels: const Sel[:], kind: i64) {
    let gi = h.applied - 1;
    var g = h.groups[gi];
    g.op_count = h.ops.len - g.op_first;
    g.after_first = h.snaps.len;
    g.after_count = sels.len;
    for s in sels { h.snaps.push(s); }
    h.groups[gi] = g;
    h.last_kind = kind;
}

// Replaces [pos, pos + len) with `bytes`, recording it in the open group.
fn replace(t: Text&, h: History&, pos: i64, len: i64, bytes: const u8[:]) {
    let del_first = h.dels.len;
    cut(t, pos, len, h.dels);
    let start = insert(t, pos, bytes);
    let del_count = h.dels.len - del_first;
    let gi = h.applied - 1;
    if h.ops.len > h.groups[gi].op_first && del_count == 0 {
        // Typing straight after the last insertion: one op, not one per key.
        let last = h.ops.len - 1;
        var op = h.ops[last];
        if op.del_count == 0 && op.pos + op.ins_len == pos && op.ins_start + op.ins_len == start {
            op.ins_len += bytes.len;
            h.ops[last] = op;
            return;
        }
    }
    h.ops.push(EditOp { pos: pos, ins_start: start, ins_len: bytes.len,
                        del_first: del_first, del_count: del_count, del_len: len });
}

fn restore_sels(sels: Sel[>..<]&, snaps: const Sel[:]) {
    sels.resize(0, caret(0));
    for s in snaps { sels.push(s); }
}

fn undo(t: Text&, h: History&, sels: Sel[>..<]&) -> bool {
    if h.applied == 0 { return false; }
    let g = h.groups[h.applied - 1];
    var scratch: Piece[>..] = [];
    var i = g.op_first + g.op_count;
    while i > g.op_first {
        i--;
        let op = h.ops[i];
        scratch.clear();
        cut(t, op.pos, op.ins_len, scratch);
        // A copy: insert_pieces cannot take a view into an array it might be shrinking.
        scratch.clear();
        for k in op.del_first..op.del_first + op.del_count { scratch.push(h.dels[k]); }
        insert_pieces(t, op.pos, scratch);
    }
    restore_sels(sels, h.snaps[g.before_first..g.before_first + g.before_count]);
    h.applied--;
    h.last_kind = KIND_NONE;
    return true;
}

fn redo(t: Text&, h: History&, sels: Sel[>..<]&) -> bool {
    if h.applied == h.groups.len { return false; }
    let g = h.groups[h.applied];
    var scratch: Piece[>..] = [];
    for i in g.op_first..g.op_first + g.op_count {
        let op = h.ops[i];
        scratch.clear();
        cut(t, op.pos, op.del_len, scratch);
        if op.ins_len > 0 {
            let p: Piece[1] = [Piece { src: SRC_ADD, start: op.ins_start, len: op.ins_len,
                                       lf: count_lf(t, SRC_ADD, op.ins_start, op.ins_len) }];
            insert_pieces(t, op.pos, p);
        }
    }
    restore_sels(sels, h.snaps[g.after_first..g.after_first + g.after_count]);
    h.applied++;
    h.last_kind = KIND_NONE;
    return true;
}
