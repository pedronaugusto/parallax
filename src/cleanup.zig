//! diff-match-patch's cleanups, on the script of a token diff, decision for
//! decision. The semantic cleanup drops an equality no longer than the
//! edits on both sides of it, slides each edit that sits between two
//! equalities to the best word or line boundary, and turns the tokens a
//! deletion ends with and the insertion after it starts with into an
//! equality between them. The efficiency cleanup drops an equality shorter
//! than the cost of the edits it keeps apart. Both measure in tokens, as
//! diff-match-patch's word and line modes do.
//!
//! The script is a list of runs, equal, deleted or inserted, each with its
//! length and where it starts on each side; diff-match-patch's text
//! operations become moves of those bounds, and its text comparisons
//! comparisons of token ids.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Change = @import("change.zig").Change;

/// What `Differ.refine` does to the token script before it becomes spans.
pub const Cleanup = enum {
    /// The script as the diff gives it.
    none,
    /// diff-match-patch's `diff_cleanupSemantic`: fewer, longer edits on
    /// word and line boundaries, for a reader.
    semantic,
    /// diff-match-patch's `diff_cleanupEfficiency`: fewer edits where an
    /// equality between them is shorter than `edit_cost`, for a machine.
    efficiency,
};

const Kind = enum(u8) { equal, delete, insert };

/// One run of the script. `old` and `new` are where it starts on each
/// side; an equality covers `len` tokens of both, a deletion of the old
/// side and an insertion of the new.
const Op = struct { kind: Kind, len: u32, old: u32, new: u32 };

pub const Buffers = struct {
    ops: std.ArrayList(Op) = .empty,
    /// Indices of the equalities still in play.
    stack: std.ArrayList(u32) = .empty,

    pub fn deinit(b: *Buffers, gpa: Allocator) void {
        b.ops.deinit(gpa);
        b.stack.deinit(gpa);
        b.* = undefined;
    }

    /// Bytes held.
    pub fn capacity(b: *const Buffers) usize {
        return b.ops.capacity * @sizeOf(Op) + b.stack.capacity * 4;
    }
};

/// One side's tokens: their ids, and the bytes each covers, for the
/// boundary scores.
pub const Side = struct {
    ids: []const u32,
    text: []const u8,
    /// Where token 0 starts in `text`.
    from: u32,
    /// The end of each token in `text`.
    ends: []const u32,

    fn bytes(s: Side, start: u32, len: u32) []const u8 {
        if (len == 0) return "";
        const begin = if (start == 0) s.from else s.ends[start - 1];
        return s.text[begin..s.ends[start + len - 1]];
    }
};

/// Everything one cleanup reads.
pub const Input = struct {
    gpa: Allocator,
    buffers: *Buffers,
    old: Side,
    new: Side,
    /// For `.efficiency`: what one edit costs, in tokens.
    edit_cost: u32,
};

/// Clean up `changes`, a script over `in.old.ids` and `in.new.ids`, in
/// place.
pub fn run(in: Input, cleanup: Cleanup, changes: *std.ArrayList(Change)) Allocator.Error!void {
    if (cleanup == .none) return;
    var s: Script = .{ .in = in, .ops = &in.buffers.ops };
    try s.load(changes.items);
    switch (cleanup) {
        .none => {},
        .semantic => try s.semantic(),
        .efficiency => try s.efficiency(),
    }
    changes.clearRetainingCapacity();
    try s.store(changes);
}

const Script = struct {
    in: Input,
    ops: *std.ArrayList(Op),

    fn side(s: *const Script, kind: Kind) Side {
        return if (kind == .insert) s.in.new else s.in.old;
    }

    /// Where `op` starts on the side its tokens are read from.
    fn at(op: Op) u32 {
        return if (op.kind == .insert) op.new else op.old;
    }

    fn ids(s: *const Script, op: Op) []const u32 {
        return s.side(op.kind).ids[at(op)..][0..op.len];
    }

    fn bytes(s: *const Script, op: Op) []const u8 {
        return s.side(op.kind).bytes(at(op), op.len);
    }

    fn insertOp(s: *Script, index: usize, op: Op) Allocator.Error!void {
        try s.ops.insert(s.in.gpa, index, op);
    }

    /// The script as runs: each change's deletion before its insertion,
    /// equalities between, as diff-match-patch's diffs come.
    fn load(s: *Script, changes: []const Change) Allocator.Error!void {
        const gpa = s.in.gpa;
        s.ops.clearRetainingCapacity();
        var old: u32 = 0;
        var new: u32 = 0;
        for (changes) |c| {
            if (c.old_start > old) try s.ops.append(gpa, .{ .kind = .equal, .len = c.old_start - old, .old = old, .new = new });
            if (c.old_len != 0) try s.ops.append(gpa, .{ .kind = .delete, .len = c.old_len, .old = c.old_start, .new = c.new_start });
            if (c.new_len != 0) try s.ops.append(gpa, .{ .kind = .insert, .len = c.new_len, .old = c.old_start + c.old_len, .new = c.new_start });
            old = c.old_start + c.old_len;
            new = c.new_start + c.new_len;
        }
        const n_old: u32 = @intCast(s.in.old.ids.len);
        if (n_old > old) try s.ops.append(gpa, .{ .kind = .equal, .len = n_old - old, .old = old, .new = new });
    }

    /// The runs as changes, empty runs dropped and edits that come to
    /// touch made one.
    fn store(s: *const Script, out: *std.ArrayList(Change)) Allocator.Error!void {
        var open: ?Change = null;
        for (s.ops.items) |op| {
            if (op.len == 0) continue;
            if (op.kind == .equal) {
                if (open) |c| try out.append(s.in.gpa, c);
                open = null;
                continue;
            }
            var c = open orelse Change{ .old_start = op.old, .old_len = 0, .new_start = op.new, .new_len = 0 };
            if (op.kind == .delete) c.old_len += op.len else c.new_len += op.len;
            open = c;
        }
        if (open) |c| try out.append(s.in.gpa, c);
    }

    // ---- diff_cleanupMerge ------------------------------------------------

    /// `diff_cleanupMerge`: edits between two equalities gathered into one
    /// deletion and one insertion with what they share at either end moved
    /// into the equalities, neighbouring equalities joined, then any edit
    /// that ends or starts with the equality beside it shifted over it;
    /// again until no shift is left.
    fn merge(s: *Script) Allocator.Error!void {
        while (true) {
            try s.gather();
            if (!s.shiftOver()) return;
        }
    }

    fn gather(s: *Script) Allocator.Error!void {
        const ops = s.ops;
        const end_old: u32 = @intCast(s.in.old.ids.len);
        const end_new: u32 = @intCast(s.in.new.ids.len);
        // A dummy equality at the end closes the last run of edits.
        try ops.append(s.in.gpa, .{ .kind = .equal, .len = 0, .old = end_old, .new = end_new });
        var pointer: usize = 0;
        var count_delete: usize = 0;
        var count_insert: usize = 0;
        // Where the run of edits starts, and what it deletes and inserts.
        var run_old: u32 = 0;
        var run_new: u32 = 0;
        var delete_len: u32 = 0;
        var insert_len: u32 = 0;
        while (pointer < ops.items.len) {
            const op = ops.items[pointer];
            if (op.kind != .equal) {
                if (count_delete + count_insert == 0) {
                    run_old = op.old;
                    run_new = op.new;
                }
                if (op.kind == .insert) {
                    count_insert += 1;
                    insert_len += op.len;
                } else {
                    count_delete += 1;
                    delete_len += op.len;
                }
                pointer += 1;
                continue;
            }
            if (count_delete + count_insert > 1) {
                if (count_delete != 0 and count_insert != 0) {
                    // What both start with goes to the equality before.
                    const prefix = commonPrefix(s.in.new.ids[run_new..][0..insert_len], s.in.old.ids[run_old..][0..delete_len]);
                    if (prefix != 0) {
                        const x = @as(isize, @intCast(pointer)) - @as(isize, @intCast(count_delete + count_insert)) - 1;
                        if (x >= 0 and ops.items[@intCast(x)].kind == .equal) {
                            ops.items[@intCast(x)].len += prefix;
                        } else {
                            try s.insertOp(0, .{ .kind = .equal, .len = prefix, .old = run_old, .new = run_new });
                            pointer += 1;
                        }
                        run_old += prefix;
                        run_new += prefix;
                        delete_len -= prefix;
                        insert_len -= prefix;
                    }
                    // What both end with goes to the equality after.
                    const suffix = commonSuffix(s.in.new.ids[run_new..][0..insert_len], s.in.old.ids[run_old..][0..delete_len]);
                    if (suffix != 0) {
                        const eq = &ops.items[pointer];
                        eq.len += suffix;
                        eq.old -= suffix;
                        eq.new -= suffix;
                        delete_len -= suffix;
                        insert_len -= suffix;
                    }
                }
                const first = pointer - count_delete - count_insert;
                var merged: [2]Op = undefined;
                var n: usize = 0;
                if (delete_len != 0) {
                    merged[n] = .{ .kind = .delete, .len = delete_len, .old = run_old, .new = run_new };
                    n += 1;
                }
                if (insert_len != 0) {
                    merged[n] = .{ .kind = .insert, .len = insert_len, .old = run_old + delete_len, .new = run_new };
                    n += 1;
                }
                try ops.replaceRange(s.in.gpa, first, count_delete + count_insert, merged[0..n]);
                pointer = first + n + 1;
            } else if (pointer != 0 and ops.items[pointer - 1].kind == .equal) {
                ops.items[pointer - 1].len += op.len;
                _ = ops.orderedRemove(pointer);
            } else {
                pointer += 1;
            }
            count_insert = 0;
            count_delete = 0;
            delete_len = 0;
            insert_len = 0;
        }
        if (ops.items[ops.items.len - 1].len == 0) _ = ops.pop();
    }

    /// The second pass of `diff_cleanupMerge`: an edit between two
    /// equalities that ends with the one before, or starts with the one
    /// after, moves over it, and the two equalities become one. True when
    /// one moved.
    fn shiftOver(s: *Script) bool {
        const ops = s.ops;
        var changed = false;
        var pointer: usize = 1;
        while (pointer + 1 < ops.items.len) : (pointer += 1) {
            const before = ops.items[pointer - 1];
            const edit = ops.items[pointer];
            const after = ops.items[pointer + 1];
            if (before.kind != .equal or after.kind != .equal) continue;
            const edit_ids = s.ids(edit);
            if (std.mem.endsWith(u32, edit_ids, s.ids(before))) {
                // Over the equality before: the edit starts where it did.
                if (before.len != 0) {
                    ops.items[pointer].old = before.old;
                    ops.items[pointer].new = before.new;
                    ops.items[pointer + 1].len += before.len;
                    ops.items[pointer + 1].old -= before.len;
                    ops.items[pointer + 1].new -= before.len;
                }
                _ = ops.orderedRemove(pointer - 1);
                changed = true;
            } else if (std.mem.startsWith(u32, edit_ids, s.ids(after))) {
                // Over the equality after, which joins the one before.
                ops.items[pointer - 1].len += after.len;
                ops.items[pointer].old += after.len;
                ops.items[pointer].new += after.len;
                _ = ops.orderedRemove(pointer + 1);
                changed = true;
            }
        }
        return changed;
    }

    /// Turn the equality at `index` into a deletion and an insertion of its
    /// tokens.
    fn split(s: *Script, index: usize) Allocator.Error!void {
        const eq = s.ops.items[index];
        s.ops.items[index] = .{ .kind = .insert, .len = eq.len, .old = eq.old + eq.len, .new = eq.new };
        try s.insertOp(index, .{ .kind = .delete, .len = eq.len, .old = eq.old, .new = eq.new });
    }

    // ---- diff_cleanupSemantic --------------------------------------------

    fn semantic(s: *Script) Allocator.Error!void {
        const ops = s.ops;
        const stack = &s.in.buffers.stack;
        stack.clearRetainingCapacity();
        var changed = false;
        var last_equality: ?u32 = null;
        var pointer: isize = 0;
        // Tokens changed before the last equality, and after it.
        var inserted_before: u32 = 0;
        var deleted_before: u32 = 0;
        var inserted_after: u32 = 0;
        var deleted_after: u32 = 0;
        while (pointer < ops.items.len) : (pointer += 1) {
            const op = ops.items[@intCast(pointer)];
            if (op.kind == .equal) {
                try stack.append(s.in.gpa, @intCast(pointer));
                inserted_before = inserted_after;
                inserted_after = 0;
                deleted_before = deleted_after;
                deleted_after = 0;
                last_equality = op.len;
                continue;
            }
            if (op.kind == .insert) inserted_after += op.len else deleted_after += op.len;
            // An equality no longer than the edits on both sides goes.
            const len = last_equality orelse continue;
            if (len == 0 or len > @max(inserted_before, deleted_before) or len > @max(inserted_after, deleted_after)) continue;
            try s.split(stack.pop().?);
            // The equality before needs another look.
            _ = stack.pop();
            pointer = if (stack.items.len != 0) stack.items[stack.items.len - 1] else -1;
            inserted_before = 0;
            deleted_before = 0;
            inserted_after = 0;
            deleted_after = 0;
            last_equality = null;
            changed = true;
        }
        if (changed) try s.merge();
        s.lossless();
        try s.overlaps();
    }

    /// The last step of `diff_cleanupSemantic`: where a deletion ends with
    /// what the insertion after it starts with, or the other way round, and
    /// that overlap is at least half of either, it becomes an equality.
    fn overlaps(s: *Script) Allocator.Error!void {
        const ops = s.ops;
        var pointer: usize = 1;
        while (pointer < ops.items.len) : (pointer += 1) {
            const del = ops.items[pointer - 1];
            const ins = ops.items[pointer];
            if (del.kind != .delete or ins.kind != .insert) continue;
            const del_ids = s.ids(del);
            const ins_ids = s.ids(ins);
            const forward = commonOverlap(del_ids, ins_ids);
            const backward = commonOverlap(ins_ids, del_ids);
            if (forward >= backward) {
                if (2 * forward >= del.len or 2 * forward >= ins.len) {
                    ops.items[pointer - 1].len = del.len - forward;
                    ops.items[pointer] = .{ .kind = .insert, .len = ins.len - forward, .old = del.old + del.len, .new = ins.new + forward };
                    try s.insertOp(pointer, .{ .kind = .equal, .len = forward, .old = del.old + del.len - forward, .new = ins.new });
                    pointer += 1;
                }
            } else if (2 * backward >= del.len or 2 * backward >= ins.len) {
                ops.items[pointer - 1] = .{ .kind = .insert, .len = ins.len - backward, .old = del.old, .new = ins.new };
                ops.items[pointer] = .{ .kind = .delete, .len = del.len - backward, .old = del.old + backward, .new = ins.new + ins.len };
                try s.insertOp(pointer, .{ .kind = .equal, .len = backward, .old = del.old, .new = ins.new + ins.len - backward });
                pointer += 1;
            }
            pointer += 1;
        }
    }

    /// `diff_cleanupSemanticLossless`: each edit between two equalities
    /// slides, as far as the tokens allow, to the boundary that scores
    /// best, ties going right.
    fn lossless(s: *Script) void {
        const ops = s.ops;
        // Signed: removing both equalities around the first edit steps it
        // back past the start, as diff-match-patch's index does.
        var p: isize = 1;
        while (p + 1 < ops.items.len) : (p += 1) {
            const pointer: usize = @intCast(p);
            if (ops.items[pointer - 1].kind != .equal or ops.items[pointer + 1].kind != .equal) continue;
            var eq1 = ops.items[pointer - 1];
            var edit = ops.items[pointer];
            var eq2 = ops.items[pointer + 1];

            // As far left as it goes.
            const common = commonSuffix(s.ids(eq1), s.ids(edit));
            if (common != 0) {
                eq1.len -= common;
                edit.old -= common;
                edit.new -= common;
                eq2.old -= common;
                eq2.new -= common;
                eq2.len += common;
            }

            // Then right one token at a time, keeping the best boundary.
            var best = [3]Op{ eq1, edit, eq2 };
            var best_score = s.score(eq1, edit) + s.score(edit, eq2);
            while (edit.len != 0 and eq2.len != 0 and s.ids(edit)[0] == s.ids(eq2)[0]) {
                eq1.len += 1;
                edit.old += 1;
                edit.new += 1;
                eq2.old += 1;
                eq2.new += 1;
                eq2.len -= 1;
                const score_now = s.score(eq1, edit) + s.score(edit, eq2);
                // The >= puts whitespace at the end of an edit rather than
                // its start.
                if (score_now >= best_score) {
                    best_score = score_now;
                    best = .{ eq1, edit, eq2 };
                }
            }

            if (ops.items[pointer - 1].len == best[0].len) continue;
            var edit_at = pointer;
            if (best[0].len != 0) {
                ops.items[pointer - 1] = best[0];
            } else {
                _ = ops.orderedRemove(pointer - 1);
                edit_at -= 1;
                p -= 1;
            }
            ops.items[edit_at] = best[1];
            if (best[2].len != 0) {
                ops.items[edit_at + 1] = best[2];
            } else {
                _ = ops.orderedRemove(edit_at + 1);
                p -= 1;
            }
        }
    }

    /// `diff_cleanupSemanticScore`: how good a boundary between `one` and
    /// `two` is, from 6 (an end) down to 0 (inside a word).
    fn score(s: *const Script, one: Op, two: Op) u32 {
        if (one.len == 0 or two.len == 0) return 6;
        const a = s.bytes(one);
        const b = s.bytes(two);
        const c1 = a[a.len - 1];
        const c2 = b[0];
        const other1 = !alphanumeric(c1);
        const other2 = !alphanumeric(c2);
        const space1 = other1 and isSpace(c1);
        const space2 = other2 and isSpace(c2);
        const break1 = space1 and (c1 == '\r' or c1 == '\n');
        const break2 = space2 and (c2 == '\r' or c2 == '\n');
        const blank1 = break1 and (std.mem.endsWith(u8, a, "\n\n") or std.mem.endsWith(u8, a, "\n\r\n"));
        const blank2 = break2 and blankLineStart(b);
        if (blank1 or blank2) return 5;
        if (break1 or break2) return 4;
        if (other1 and !space1 and space2) return 3;
        if (space1 or space2) return 2;
        if (other1 or other2) return 1;
        return 0;
    }

    // ---- diff_cleanupEfficiency ------------------------------------------

    fn efficiency(s: *Script) Allocator.Error!void {
        const ops = s.ops;
        const stack = &s.in.buffers.stack;
        stack.clearRetainingCapacity();
        const cost = s.in.edit_cost;
        var changed = false;
        var last_equality: ?u32 = null;
        var pointer: isize = 0;
        // Whether there is an insertion or deletion before the last
        // equality, and after it.
        var pre_ins = false;
        var pre_del = false;
        var post_ins = false;
        var post_del = false;
        while (pointer < ops.items.len) : (pointer += 1) {
            const op = ops.items[@intCast(pointer)];
            if (op.kind == .equal) {
                if (op.len < cost and (post_ins or post_del)) {
                    // A candidate.
                    try stack.append(s.in.gpa, @intCast(pointer));
                    pre_ins = post_ins;
                    pre_del = post_del;
                    last_equality = op.len;
                } else {
                    // Not one, and never to become one.
                    stack.clearRetainingCapacity();
                    last_equality = null;
                }
                post_ins = false;
                post_del = false;
                continue;
            }
            if (op.kind == .delete) post_del = true else post_ins = true;
            const len = last_equality orelse continue;
            const sides = @as(u32, @intFromBool(pre_ins)) + @intFromBool(pre_del) + @intFromBool(post_ins) + @intFromBool(post_del);
            const all_four = pre_ins and pre_del and post_ins and post_del;
            if (len == 0 or !(all_four or (2 * len < cost and sides == 3))) continue;
            try s.split(stack.pop().?);
            last_equality = null;
            if (pre_ins and pre_del) {
                // Nothing before can change: go on.
                post_ins = true;
                post_del = true;
                stack.clearRetainingCapacity();
            } else {
                _ = stack.pop();
                pointer = if (stack.items.len != 0) stack.items[stack.items.len - 1] else -1;
                post_ins = false;
                post_del = false;
            }
            changed = true;
        }
        if (changed) try s.merge();
    }
};

fn commonPrefix(a: []const u32, b: []const u32) u32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return @intCast(i);
}

fn commonSuffix(a: []const u32, b: []const u32) u32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[a.len - 1 - i] == b[b.len - 1 - i]) i += 1;
    return @intCast(i);
}

/// `diff_commonOverlap`: the longest end of `a` that `b` starts with.
fn commonOverlap(a_whole: []const u32, b_whole: []const u32) u32 {
    if (a_whole.len == 0 or b_whole.len == 0) return 0;
    const n = @min(a_whole.len, b_whole.len);
    const a = a_whole[a_whole.len - n ..];
    const b = b_whole[0..n];
    if (std.mem.eql(u32, a, b)) return @intCast(n);
    // Look for an end of `a` in `b`, growing it by where it was found.
    var best: usize = 0;
    var length: usize = 1;
    while (length <= n) {
        const found = std.mem.find(u32, b, a[n - length ..]) orelse return @intCast(best);
        length += found;
        if (found == 0 or std.mem.eql(u32, a[n - length ..], b[0..length])) {
            best = length;
            length += 1;
        }
    }
    return @intCast(best);
}

/// Python's `str.isalnum` for one byte; any byte of a multi-byte UTF-8
/// character counts, as letters there mostly are.
fn alphanumeric(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Python's `str.isspace` for an ASCII byte.
fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r', 0x1c, 0x1d, 0x1e, 0x1f => true,
        else => false,
    };
}

/// diff-match-patch's `^\r?\n\r?\n`.
fn blankLineStart(b: []const u8) bool {
    var i: usize = 0;
    if (i < b.len and b[i] == '\r') i += 1;
    if (i >= b.len or b[i] != '\n') return false;
    i += 1;
    if (i < b.len and b[i] == '\r') i += 1;
    return i < b.len and b[i] == '\n';
}

test "the overlap of one end with the other's start, as diff-match-patch finds it" {
    const ids = struct {
        fn of(comptime text: []const u8) [text.len]u32 {
            var out: [text.len]u32 = undefined;
            for (text, &out) |c, *o| o.* = c;
            return out;
        }
    };
    try std.testing.expectEqual(@as(u32, 0), commonOverlap(&ids.of(""), &ids.of("abcd")));
    try std.testing.expectEqual(@as(u32, 3), commonOverlap(&ids.of("abc"), &ids.of("abcd")));
    try std.testing.expectEqual(@as(u32, 0), commonOverlap(&ids.of("123456"), &ids.of("abcd")));
    try std.testing.expectEqual(@as(u32, 3), commonOverlap(&ids.of("123456xxx"), &ids.of("xxxabcd")));
}
