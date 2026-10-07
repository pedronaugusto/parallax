//! parallax: line diff, three-way merge and patches.
//!
//! git's xdiff output byte for byte (Myers with git's heuristics, minimal,
//! patience, anchored, histogram, the slide and the indentation heuristic,
//! the whitespace flags, hunks and the unified body, the three-way merge in
//! the merge, diff3 and zdiff3 styles), on dense ids, with a reusable
//! workspace that allocates nothing once warm. No Io: every function is
//! pure computation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const compare = @import("compare.zig");
const lines_mod = @import("lines.zig");
const change = @import("change.zig");
const script = @import("script.zig");
const hunks = @import("hunks.zig");
const unified = @import("unified.zig");

/// Which whitespace differences two lines may have and still be the same.
pub const Whitespace = compare.Whitespace;
/// What counts as the same line: whitespace and ASCII case.
pub const Compare = compare.Compare;
/// Myers, patience or histogram.
pub const Algorithm = change.Algorithm;
/// A text split at '\n', by end offsets.
pub const Lines = lines_mod.Lines;
/// One run of the script that differs.
pub const Change = change.Change;
/// Added and removed line counts.
pub const Stat = script.Stat;
/// One step of the script: equal, delete, insert or replace.
pub const Op = script.Op;
/// Steps over a diff's script, allocating nothing.
pub const OpIterator = script.OpIterator;
/// A finished line diff: the two sides and the script.
pub const Diff = script.Diff;
/// The reusable workspace every diff and merge goes through.
pub const Differ = @import("Differ.zig");
/// How a line diff is taken.
pub const Options = Differ.Options;
/// How a diff of two id sequences is taken.
pub const SequenceOptions = Differ.SequenceOptions;
/// A caller's test of one position of the old sequence.
pub const Predicate = Differ.Predicate;
/// A caller's indentation per token.
pub const Indent = Differ.Indent;
/// How changes group into hunks.
pub const HunkOptions = hunks.HunkOptions;
/// A caller's test of one line, given with its newline.
pub const LinePredicate = hunks.LinePredicate;
/// One hunk and the changes inside it.
pub const Hunk = hunks.Hunk;
/// Hunks over a diff, allocating nothing.
pub const HunkIterator = hunks.HunkIterator;
/// The text after a hunk's second `@@`.
pub const Heading = unified.Heading;
/// How the unified writer writes.
pub const UnifiedOptions = unified.UnifiedOptions;
/// Write a diff as a unified diff body, as git prints it.
pub const writeUnified = unified.writeUnified;
/// The three-way merge.
pub const merge = @import("merge.zig");

/// A one-shot line diff that owns its memory.
pub const OwnedDiff = struct {
    diff: Diff,
    /// Private: what `diff` borrows.
    gpa: Allocator,
    ends: [2][]u32,
    changes: []Change,

    pub fn deinit(o: *OwnedDiff) void {
        o.gpa.free(o.ends[0]);
        o.gpa.free(o.ends[1]);
        o.gpa.free(o.changes);
        o.* = undefined;
    }
};

/// One-shot form of `Differ.lines`. The result borrows `old` and `new`.
pub fn diffLines(gpa: Allocator, old: []const u8, new: []const u8, options: Options) Differ.Error!OwnedDiff {
    var d: Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines(old, new, options);
    const ends_old = try gpa.dupe(u32, diff.old.ends);
    errdefer gpa.free(ends_old);
    const ends_new = try gpa.dupe(u32, diff.new.ends);
    errdefer gpa.free(ends_new);
    const changes = try gpa.dupe(Change, diff.changes);
    return .{
        .diff = .{
            .old = .{ .text = old, .ends = ends_old },
            .new = .{ .text = new, .ends = ends_new },
            .changes = changes,
            .compare = options.compare,
        },
        .gpa = gpa,
        .ends = .{ ends_old, ends_new },
        .changes = changes,
    };
}

test {
    _ = compare;
    _ = lines_mod;
    _ = @import("table.zig");
    _ = @import("slide.zig");
}
