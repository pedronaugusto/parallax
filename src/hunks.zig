//! Hunks: changes grouped with their context, as git's `xdl_get_hunk` and
//! `xdl_emit_diff` group them, with ignorable changes (`--ignore-blank-lines`,
//! `-I`) and inter-hunk context. An iterator; nothing is allocated.

const Change = @import("change.zig").Change;
const Lines = @import("lines.zig").Lines;
const compare = @import("compare.zig");

/// A caller's test of one line, given with its newline.
pub const LinePredicate = struct {
    context: ?*const anyopaque = null,
    at: *const fn (context: ?*const anyopaque, line: []const u8) bool,
};

pub const HunkOptions = struct {
    /// Lines of context on each side of a change.
    context: u32 = 3,
    /// Further unchanged lines two changes may have between them and still
    /// share a hunk: git --inter-hunk-context.
    inter_hunk_context: u32 = 0,
    /// Changes made only of blank lines (or of lines `ignore` accepts) start
    /// no hunk: git --ignore-blank-lines and -I. They still print inside a
    /// hunk another change opens.
    ignore_blank_lines: bool = false,
    ignore: ?LinePredicate = null,
};

/// One hunk: the lines it shows on each side, and the changes inside.
pub const Hunk = struct {
    old_start: u32,
    old_len: u32,
    new_start: u32,
    new_len: u32,
    /// Borrowed from the diff's script.
    changes: []const Change,
};

pub const HunkIterator = struct {
    changes: []const Change,
    old: Lines,
    new: Lines,
    whitespace: compare.Whitespace,
    options: HunkOptions,
    /// Private: the first change not yet in a hunk.
    at: usize = 0,

    fn ignorable(it: *const HunkIterator, i: usize) bool {
        const c = it.changes[i];
        if (it.options.ignore_blank_lines and it.allBlank(c)) return true;
        if (it.options.ignore) |p| return it.allMatch(c, p);
        return false;
    }

    fn allBlank(it: *const HunkIterator, c: Change) bool {
        for (c.old_start..c.old_start + c.old_len) |i| if (!compare.isBlank(it.old.get(@intCast(i)), it.whitespace)) return false;
        for (c.new_start..c.new_start + c.new_len) |i| if (!compare.isBlank(it.new.get(@intCast(i)), it.whitespace)) return false;
        return true;
    }

    fn allMatch(it: *const HunkIterator, c: Change, p: LinePredicate) bool {
        for (c.old_start..c.old_start + c.old_len) |i| if (!p.at(p.context, it.old.get(@intCast(i)))) return false;
        for (c.new_start..c.new_start + c.new_len) |i| if (!p.at(p.context, it.new.get(@intCast(i)))) return false;
        return true;
    }

    fn endOld(c: Change) i64 {
        return @as(i64, c.old_start) + c.old_len;
    }

    pub fn next(it: *HunkIterator) ?Hunk {
        const changes = it.changes;
        const any_ignorable = it.options.ignore_blank_lines or it.options.ignore != null;
        const ctx: i64 = it.options.context;
        const max_common: i64 = 2 * ctx + it.options.inter_hunk_context;
        const max_ignorable: i64 = ctx;

        // Drop ignorable changes too far before other changes.
        var first = it.at;
        if (any_ignorable) {
            var p = it.at;
            while (p < changes.len and it.ignorable(p)) : (p += 1) {
                const x = p + 1;
                if (x == changes.len or changes[x].old_start - endOld(changes[p]) >= max_ignorable) first = x;
            }
        }
        if (first >= changes.len) {
            it.at = changes.len;
            return null;
        }

        var last = first;
        var ignored: i64 = 0;
        var p = first;
        var x = first + 1;
        while (x < changes.len) : ({
            p = x;
            x += 1;
        }) {
            const distance = changes[x].old_start - endOld(changes[p]);
            if (distance > max_common) break;
            const ign = any_ignorable and it.ignorable(x);
            if (distance < max_ignorable and (!ign or last == p)) {
                last = x;
                ignored = 0;
            } else if (distance < max_ignorable and ign) {
                ignored += changes[x].new_len;
            } else if (last != p and changes[x].old_start + ignored - endOld(changes[last]) > max_common) {
                break;
            } else if (!ign) {
                last = x;
                ignored = 0;
            } else {
                ignored += changes[x].new_len;
            }
        }

        const f = changes[first];
        const l = changes[last];
        const s1: i64 = @max(@as(i64, f.old_start) - ctx, 0);
        const s2: i64 = @max(@as(i64, f.new_start) - ctx, 0);
        var lctx = ctx;
        lctx = @min(lctx, @as(i64, it.old.len()) - (@as(i64, l.old_start) + l.old_len));
        lctx = @min(lctx, @as(i64, it.new.len()) - (@as(i64, l.new_start) + l.new_len));
        const e1 = @as(i64, l.old_start) + l.old_len + lctx;
        const e2 = @as(i64, l.new_start) + l.new_len + lctx;
        it.at = last + 1;
        return .{
            .old_start = @intCast(s1),
            .old_len = @intCast(e1 - s1),
            .new_start = @intCast(s2),
            .new_len = @intCast(e2 - s2),
            .changes = changes[first .. last + 1],
        };
    }
};
