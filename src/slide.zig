//! xdiff's xdl_change_compact. Each run of changed lines is pushed as far up
//! the file as equal boundary lines allow and then as far down, absorbing
//! any run it meets. Where it ends up depends on whether the other side has
//! a change it can line up with; failing that, on the indentation heuristic,
//! git's default since 2.14, which is why an added block lands on the brace
//! a reader expects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Flags = @import("flags.zig").Flags;
const myers = @import("myers.zig");
const histogram = @import("histogram.zig");
const compare = @import("compare.zig");

/// A maximal run of changed lines. Empty when start equals end.
const Group = struct { start: i64, end: i64 };

fn groupInit(f: Flags) Group {
    var g: Group = .{ .start = 0, .end = 0 };
    while (f.get(g.end)) g.end += 1;
    return g;
}

/// Move to the run after this one, stepping over exactly one unchanged
/// line. False when this run already ends the file.
fn groupNext(f: Flags, g: *Group) bool {
    if (g.end == f.len) return false;
    g.start = g.end + 1;
    g.end = g.start;
    while (f.get(g.end)) g.end += 1;
    return true;
}

/// Move to the run before this one. False when this run starts the file.
fn groupPrevious(f: Flags, g: *Group) bool {
    if (g.start == 0) return false;
    g.end = g.start - 1;
    g.start = g.end;
    while (f.get(g.start - 1)) g.start -= 1;
    return true;
}

/// Push the run one line down, legal when the line it gives up matches the
/// line it takes on. Absorbs the next run if they come to touch.
fn slideDown(f: Flags, ids: []const u32, g: *Group) bool {
    if (g.end >= f.len) return false;
    if (ids[@intCast(g.start)] != ids[@intCast(g.end)]) return false;
    f.set(@intCast(g.start), false);
    g.start += 1;
    f.set(@intCast(g.end), true);
    g.end += 1;
    while (f.get(g.end)) g.end += 1;
    return true;
}

/// Push the run one line up, absorbing the previous run if they come to
/// touch.
fn slideUp(f: Flags, ids: []const u32, g: *Group) bool {
    if (g.start <= 0) return false;
    if (ids[@intCast(g.start - 1)] != ids[@intCast(g.end - 1)]) return false;
    g.start -= 1;
    f.set(@intCast(g.start), true);
    g.end -= 1;
    f.set(@intCast(g.end), false);
    while (f.get(g.start - 1)) g.start -= 1;
    return true;
}

/// What the slide needs to diff a merged run again, which only a histogram
/// diff asks for.
pub const Rediff = struct {
    context: *myers.Context,
    other_ids: []const u32,
};

/// Slide every run of changed lines in `f` to where git puts it. `other` is
/// the opposite side's flags, walked in step so a run can tell when it lines
/// up with a change there. `Indent` has `fn of(Indent, u32) i32`, a line's
/// indentation or -1 for a blank one; with `heuristic` off it is never read.
pub fn compact(
    comptime Indent: type,
    indent: Indent,
    heuristic: bool,
    f: Flags,
    ids: []const u32,
    other: Flags,
    rediff: ?Rediff,
) Allocator.Error!void {
    var g = groupInit(f);
    var go = groupInit(other);

    while (true) {
        if (g.end != g.start) {
            const g_orig = g;
            var earliest_end: i64 = g.end;
            var end_matching_other: i64 = -1;
            var groupsize: i64 = g.end - g.start;

            // Sliding one way can merge in a neighbour, which gives the
            // larger run room to slide further; repeat until it settles.
            while (true) {
                groupsize = g.end - g.start;
                end_matching_other = -1;

                while (slideUp(f, ids, &g)) {
                    assert(groupPrevious(other, &go));
                }
                earliest_end = g.end;
                if (go.end > go.start) end_matching_other = g.end;

                while (slideDown(f, ids, &g)) {
                    assert(groupNext(other, &go));
                    if (go.end > go.start) end_matching_other = g.end;
                }

                if (groupsize == g.end - g.start) break;
            }

            // The run sits as far down as it will go, so every remaining
            // choice is a move back up.
            if (g.end == earliest_end) {
                // Nowhere to go.
            } else if (end_matching_other != -1) {
                // Back to meet a change on the other side, so a deletion and
                // the insertion replacing it print as one hunk.
                while (go.end == go.start) {
                    assert(slideUp(f, ids, &g));
                    assert(groupPrevious(other, &go));
                }
            } else if (heuristic) {
                var shift = earliest_end;
                if (g.end - groupsize - 1 > shift) shift = g.end - groupsize - 1;
                if (g.end - indent_max_sliding > shift) shift = g.end - indent_max_sliding;

                var best_shift: i64 = -1;
                var best: Score = .{};
                while (shift <= g.end) : (shift += 1) {
                    var score: Score = .{};
                    scoreAdd(measure(Indent, indent, f.len, shift), &score);
                    scoreAdd(measure(Indent, indent, f.len, shift - groupsize), &score);
                    if (best_shift == -1 or scoreCmp(score, best) <= 0) {
                        best = score;
                        best_shift = shift;
                    }
                }

                while (g.end > best_shift) {
                    assert(slideUp(f, ids, &g));
                    assert(groupPrevious(other, &go));
                }
            }

            // A run that slid into a neighbour may now hold lines the other
            // side's run also holds, which histogram's anchoring allows and
            // Myers' does not. git diffs the merged pair again, this side
            // first.
            if (rediff) |r| {
                if (go.end != go.start and (g.start != g_orig.start or g.end != g_orig.end)) {
                    try histogram.fallBack(
                        r.context,
                        ids,
                        f,
                        @intCast(g.start),
                        @intCast(g.end - g.start),
                        r.other_ids,
                        other,
                        @intCast(go.start),
                        @intCast(go.end - go.start),
                    );
                }
            }
        }

        if (!groupNext(f, &g)) break;
        assert(groupNext(other, &go));
    }

    assert(!groupNext(other, &go));
}

// Weights from git's xdiff, fitted to a corpus rather than reasoned out.
// Changing any changes which line a hunk starts on, so they are copied
// exactly.

/// An indentation past this is not worth measuring precisely.
const max_indent: i32 = 200;
/// More consecutive blank lines than this all count the same.
const max_blanks: i32 = 20;
const start_of_file_penalty: i32 = 1;
const end_of_file_penalty: i32 = 21;
const total_blank_weight: i32 = -30;
const post_blank_weight: i32 = 6;
const relative_indent_penalty: i32 = -4;
const relative_indent_with_blank_penalty: i32 = 10;
const relative_outdent_penalty: i32 = 24;
const relative_outdent_with_blank_penalty: i32 = 17;
const relative_dedent_penalty: i32 = 23;
const relative_dedent_with_blank_penalty: i32 = 17;
/// How much a lower total indentation outweighs the penalties.
const indent_weight: i32 = 60;
/// A run that could slide further than this is not worth scoring.
const indent_max_sliding: i64 = 100;

/// The indentation of `line` in columns, tabs to the next multiple of eight;
/// -1 for a line of whitespace only. git's `get_indent`, with git's
/// whitespace class.
pub fn lineIndent(line: []const u8) i32 {
    var n: i32 = 0;
    for (line) |c| {
        if (!compare.isSpace(c)) return n;
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 8 - @rem(n, 8);
        }
        if (n >= max_indent) return max_indent;
    }
    return -1;
}

/// What the lines around a candidate boundary look like. `split` is the
/// first line below the boundary and may be one past the end.
const Measure = struct {
    end_of_file: bool,
    indent: i32,
    pre_blank: i32,
    pre_indent: i32,
    post_blank: i32,
    post_indent: i32,
};

fn measure(comptime Indent: type, indent: Indent, len: u32, split: i64) Measure {
    const n: i64 = len;
    var m: Measure = .{
        .end_of_file = split >= n,
        .indent = if (split >= n) -1 else indent.of(@intCast(split)),
        .pre_blank = 0,
        .pre_indent = -1,
        .post_blank = 0,
        .post_indent = -1,
    };

    var i = split - 1;
    while (i >= 0) : (i -= 1) {
        m.pre_indent = indent.of(@intCast(i));
        if (m.pre_indent != -1) break;
        m.pre_blank += 1;
        if (m.pre_blank == max_blanks) {
            m.pre_indent = 0;
            break;
        }
    }

    i = split + 1;
    while (i < n) : (i += 1) {
        m.post_indent = indent.of(@intCast(i));
        if (m.post_indent != -1) break;
        m.post_blank += 1;
        if (m.post_blank == max_blanks) {
            m.post_indent = 0;
            break;
        }
    }
    return m;
}

/// How bad a boundary is. Smaller is better on both counts.
const Score = struct { effective_indent: i32 = 0, penalty: i32 = 0 };

fn scoreAdd(m: Measure, s: *Score) void {
    if (m.pre_indent == -1 and m.pre_blank == 0) s.penalty += start_of_file_penalty;
    if (m.end_of_file) s.penalty += end_of_file_penalty;

    const post_blank: i32 = if (m.indent == -1) 1 + m.post_blank else 0;
    const total_blank = m.pre_blank + post_blank;
    s.penalty += total_blank_weight * total_blank;
    s.penalty += post_blank_weight * post_blank;

    const ind = if (m.indent != -1) m.indent else m.post_indent;
    const any_blanks = total_blank != 0;
    s.effective_indent += ind;

    if (ind == -1 or m.pre_indent == -1 or ind == m.pre_indent) {
        // Nothing to say about a boundary that keeps the indentation, ends
        // the file, or starts it.
    } else if (ind > m.pre_indent) {
        s.penalty += if (any_blanks) relative_indent_with_blank_penalty else relative_indent_penalty;
    } else if (m.post_indent != -1 and m.post_indent > ind) {
        // Less indented than what came before but more than what follows:
        // the start of a block, not the end of one.
        s.penalty += if (any_blanks) relative_outdent_with_blank_penalty else relative_outdent_penalty;
    } else {
        s.penalty += if (any_blanks) relative_dedent_with_blank_penalty else relative_dedent_penalty;
    }
}

/// Negative when `x` is the better boundary. Indentations compare only by
/// sign, so one column never outweighs another, but any difference
/// outweighs a small penalty.
fn scoreCmp(x: Score, y: Score) i32 {
    const above: i32 = @intFromBool(x.effective_indent > y.effective_indent);
    const below: i32 = @intFromBool(x.effective_indent < y.effective_indent);
    return indent_weight * (above - below) + (x.penalty - y.penalty);
}

test "indentation counts tabs to the next stop and leaves vertical tab and form feed alone" {
    try std.testing.expectEqual(@as(i32, 4), lineIndent("    x\n"));
    try std.testing.expectEqual(@as(i32, 8), lineIndent("  \tx\n"));
    try std.testing.expectEqual(@as(i32, -1), lineIndent("   \n"));
    try std.testing.expectEqual(@as(i32, 0), lineIndent("\x0bx\n"));
    try std.testing.expectEqual(@as(i32, 1), lineIndent(" \x0cx\n"));
}
