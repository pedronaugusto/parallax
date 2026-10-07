//! A finished diff: the two sides, the script, and what can be read off it.

const change = @import("change.zig");
const Change = change.Change;
const Lines = @import("lines.zig").Lines;
const Compare = @import("compare.zig").Compare;
const hunks_mod = @import("hunks.zig");

/// Added and removed line counts.
pub const Stat = struct { added: u32, removed: u32 };

/// One step of the script, in order: lines kept, removed, added, or
/// replaced.
pub const Op = union(enum) {
    equal: struct { old: u32, new: u32, len: u32 },
    delete: struct { old: u32, len: u32, new: u32 },
    insert: struct { old: u32, new: u32, len: u32 },
    replace: Change,
};

pub const Diff = struct {
    old: Lines,
    new: Lines,
    changes: []const Change,
    /// What counted as the same line; the blank-line rule of `hunks` reads
    /// its whitespace.
    compare: Compare = .{},

    pub fn stat(d: Diff) Stat {
        var s: Stat = .{ .added = 0, .removed = 0 };
        for (d.changes) |c| {
            s.added += c.new_len;
            s.removed += c.old_len;
        }
        return s;
    }

    /// 2 * matched / (old + new) lines, in [0, 1]. 1 for two empty inputs.
    pub fn ratio(d: Diff) f64 {
        const total: u64 = @as(u64, d.old.len()) + d.new.len();
        if (total == 0) return 1;
        const matched: u64 = d.old.len() - d.stat().removed;
        return @as(f64, @floatFromInt(2 * matched)) / @as(f64, @floatFromInt(total));
    }

    /// The script as steps. Allocates nothing.
    pub fn ops(d: Diff) OpIterator {
        return .{ .changes = d.changes, .old_len = d.old.len(), .new_len = d.new.len() };
    }

    pub fn hunks(d: Diff, options: hunks_mod.HunkOptions) hunks_mod.HunkIterator {
        return .{ .changes = d.changes, .old = d.old, .new = d.new, .whitespace = d.compare.whitespace, .options = options };
    }
};

pub const OpIterator = struct {
    changes: []const Change,
    old_len: u32,
    new_len: u32,
    /// Private: where the next step starts.
    old: u32 = 0,
    new: u32 = 0,
    index: usize = 0,

    pub fn next(it: *OpIterator) ?Op {
        if (it.index < it.changes.len) {
            const c = it.changes[it.index];
            if (it.old < c.old_start) {
                const len = c.old_start - it.old;
                defer {
                    it.old += len;
                    it.new += len;
                }
                return .{ .equal = .{ .old = it.old, .new = it.new, .len = len } };
            }
            it.index += 1;
            it.old = c.old_start + c.old_len;
            it.new = c.new_start + c.new_len;
            if (c.new_len == 0) return .{ .delete = .{ .old = c.old_start, .len = c.old_len, .new = c.new_start } };
            if (c.old_len == 0) return .{ .insert = .{ .old = c.old_start, .new = c.new_start, .len = c.new_len } };
            return .{ .replace = c };
        }
        if (it.old < it.old_len) {
            const len = it.old_len - it.old;
            defer {
                it.old += len;
                it.new += len;
            }
            return .{ .equal = .{ .old = it.old, .new = it.new, .len = len } };
        }
        return null;
    }
};
