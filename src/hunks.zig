//! Hunks: changes grouped with their context, as git's `xdl_get_hunk` and
//! `xdl_emit_diff` group them, with ignorable changes (`--ignore-blank-lines`,
//! `-I`), inter-hunk context and whole functions (`-W`). An iterator;
//! nothing is allocated.

const std = @import("std");
const Change = @import("change.zig").Change;
const Lines = @import("lines.zig").Lines;
const compare = @import("compare.zig");

/// A caller's test of one line, given with its newline.
pub const LinePredicate = struct {
    context: ?*const anyopaque = null,
    at: *const fn (context: ?*const anyopaque, line: []const u8) bool,
};

/// Which lines start a function, and what a hunk shows of one: the text
/// after a hunk's second `@@`, and the bounds `HunkOptions.function_context`
/// widens a hunk to.
pub const Heading = struct {
    context: ?*const anyopaque = null,
    /// Given an old-side line without its newline: the text to show, or
    /// null when the line starts nothing.
    find: *const fn (context: ?*const anyopaque, line: []const u8) ?[]const u8,
    /// Longer text is cut here, then its trailing whitespace dropped.
    max_len: u32 = 80,

    /// First byte a letter, '_' or '$': git's default rule and GNU diff -p.
    pub const c_function: Heading = .{ .find = cFunction };

    fn cFunction(_: ?*const anyopaque, line: []const u8) ?[]const u8 {
        if (line.len == 0) return null;
        const first = line[0];
        if (std.ascii.isAlphabetic(first) or first == '_' or first == '$') return line;
        return null;
    }

    /// Whether `line`, newline and all, starts a function.
    fn starts(h: Heading, line: []const u8) bool {
        const bare = if (line.len != 0 and line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
        return h.find(h.context, bare) != null;
    }
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
    /// Widen each hunk to the whole function around its changes, functions
    /// starting where this finds a heading: git -W. A function runs from
    /// its heading line, and the lines above it up to a blank line or
    /// another heading, to just before the next heading less the blank
    /// lines before it; changes in one function share a hunk.
    function_context: ?Heading = null,
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

    fn endNew(c: Change) i64 {
        return @as(i64, c.new_start) + c.new_len;
    }

    /// git's `get_func_line`: the first old line from `start` towards
    /// `limit`, which it never reaches, that starts a function; -1 for none.
    fn functionLine(it: *const HunkIterator, heading: Heading, start: i64, limit: i64) i64 {
        const step: i64 = if (start > limit) -1 else 1;
        var l = start;
        while (l != limit and 0 <= l and l < it.old.len()) : (l += step) {
            if (heading.starts(it.old.get(@intCast(l)))) return l;
        }
        return -1;
    }

    /// git's `is_empty_rec`: a line of git whitespace only.
    fn emptyLine(lines: Lines, i: i64) bool {
        for (lines.get(@intCast(i))) |c| if (!compare.isSpace(c)) return false;
        return true;
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

        const from = it.hunkStart(first);
        const to = it.hunkEnd(last);
        first = from.change;
        last = to.change;
        it.at = last + 1;
        return .{
            .old_start = @intCast(from.old),
            .old_len = @intCast(to.old - from.old),
            .new_start = @intCast(from.new),
            .new_len = @intCast(to.new - from.new),
            .changes = changes[first .. last + 1],
        };
    }

    /// Where a hunk starts or ends on each side, and the change that bounds it.
    const Bound = struct { old: i64, new: i64, change: usize };

    /// The start of the hunk whose first change is `first`, widened to the
    /// function's under `function_context` (git's xdl_emit_diff). An
    /// ignorable change the wider context reaches is shown after all, and
    /// becomes the first.
    fn hunkStart(it: *const HunkIterator, first_change: usize) Bound {
        const changes = it.changes;
        const ctx: i64 = it.options.context;
        const n_old: i64 = it.old.len();
        const n_new: i64 = it.new.len();
        var first = first_change;
        var reached = it.at;
        while (true) {
            const f = changes[first];
            var s1: i64 = @max(@as(i64, f.old_start) - ctx, 0);
            var s2: i64 = @max(@as(i64, f.new_start) - ctx, 0);
            const heading = it.options.function_context orelse return .{ .old = s1, .new = s2, .change = first };
            var from: i64 = f.old_start;
            if (from >= n_old) {
                // Lines added at the end: a whole new function needs no
                // more context, and anything else takes the old side's
                // last function.
                var at: i64 = f.new_start;
                while (at < n_new) : (at += 1) {
                    if (heading.starts(it.new.get(@intCast(at)))) return .{ .old = s1, .new = s2, .change = first };
                }
                from = n_old - 1;
            }
            var fs1 = it.functionLine(heading, from, -1);
            while (fs1 > 0 and !emptyLine(it.old, fs1 - 1) and !heading.starts(it.old.get(@intCast(fs1 - 1)))) fs1 -= 1;
            if (fs1 < 0) fs1 = 0;
            if (fs1 < s1) {
                s2 = @max(s2 - (s1 - fs1), 0);
                s1 = fs1;
                while (reached != first and endOld(changes[reached]) <= s1 and endNew(changes[reached]) <= s2) reached += 1;
                if (reached != first) {
                    first = reached;
                    continue;
                }
            }
            return .{ .old = s1, .new = s2, .change = first };
        }
    }

    /// The end of the hunk whose last change is `last`, widened to the
    /// function's under `function_context`; a change in the same function
    /// joins the hunk, and the end is found again from it.
    fn hunkEnd(it: *const HunkIterator, last_change: usize) Bound {
        const changes = it.changes;
        const ctx: i64 = it.options.context;
        const n_old: i64 = it.old.len();
        const n_new: i64 = it.new.len();
        var last = last_change;
        while (true) {
            const l = changes[last];
            var lctx = ctx;
            lctx = @min(lctx, n_old - endOld(l));
            lctx = @min(lctx, n_new - endNew(l));
            var e1 = endOld(l) + lctx;
            var e2 = endNew(l) + lctx;
            const heading = it.options.function_context orelse return .{ .old = e1, .new = e2, .change = last };
            var fe1 = it.functionLine(heading, endOld(l), n_old);
            while (fe1 > 0 and emptyLine(it.old, fe1 - 1)) fe1 -= 1;
            if (fe1 < 0) fe1 = n_old;
            if (fe1 > e1) {
                e2 = @min(e2 + (fe1 - e1), n_new);
                e1 = fe1;
            }
            if (last + 1 < changes.len) {
                const next_start = @min(@as(i64, changes[last + 1].old_start), n_old - 1);
                if (next_start - ctx <= e1 or it.functionLine(heading, next_start, e1) < 0) {
                    last += 1;
                    continue;
                }
            }
            return .{ .old = e1, .new = e2, .change = last };
        }
    }
};
