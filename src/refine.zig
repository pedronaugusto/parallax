//! Inline refinement: which bytes inside one change differ. The change's old
//! lines and new lines are each cut into tokens (words, characters or
//! bytes), the token sequences are diffed and slid like lines, and the token
//! runs come back as byte spans that never cross a line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fit = @import("fit.zig");
const compare_mod = @import("compare.zig");
const Compare = compare_mod.Compare;
const Lines = @import("lines.zig").Lines;
const change_mod = @import("change.zig");
const Change = change_mod.Change;
const Algorithm = change_mod.Algorithm;
const core = @import("core.zig");
const Interner = @import("interner.zig").Interner;
const cleanup_mod = @import("cleanup.zig");

/// What refinement does to the token script before it becomes spans.
pub const Cleanup = cleanup_mod.Cleanup;

/// How a line is cut into tokens.
pub const Tokens = enum {
    /// A run of [A-Za-z0-9_] and bytes >= 0x80; a run of spaces, tabs and
    /// carriage returns; any other byte alone. A newline is always a token
    /// of its own.
    words,
    /// UTF-8 scalar values; a byte that starts no valid one is one token.
    chars,
    bytes,
};

pub const RefineOptions = struct {
    tokens: Tokens = .words,
    algorithm: Algorithm = .histogram,
    /// Tokens are equal when their comparison forms are.
    compare: Compare = .{},
    /// the reference's cleanups over the token script, measured in
    /// tokens.
    cleanup: Cleanup = .none,
    /// For `.efficiency`: what one edit costs, in tokens; an equality
    /// shorter than this between edits goes (the reference's
    /// `Diff_EditCost`).
    edit_cost: u32 = 4,
    /// A flag the caller may raise, from another thread, to abandon the
    /// call. It is read once per work unit and once per histogram or
    /// patience region; from the first time it reads true, what is left is
    /// described as one deletion and one insertion, as when `max_work` runs
    /// out, so the call returns soon with a result that is correct but
    /// coarse. The caller that raised it knows to discard that result.
    stop: ?*const std.atomic.Value(bool) = null,
};

/// Bytes `start .. start + len` of a side's text, changed or not.
// aegis: measured-boundary: docs/design.md#numeric-boundaries; bounded token/line ends produce compact byte-only span views for iteration.
pub const Span = struct { start: u32, len: u32, changed: bool };

/// Spans covering the change's lines on each side, in order. No span
/// crosses the end of a line.
pub const Refined = struct { old: []const Span, new: []const Span };

/// A token as its comparison form decides.
pub const TokenContext = struct {
    compare: Compare,
    pub fn hash(c: TokenContext, token: []const u8) u64 {
        return compare_mod.hash(token, c.compare);
    }
    pub fn eql(c: TokenContext, a: []const u8, b: []const u8) bool {
        return compare_mod.sameForm(a, b, c.compare);
    }
};

pub const Buffers = struct {
    /// The end offset of every token, per side.
    ends: [2]std.ArrayList(u32) = .{ .empty, .empty },
    ids: std.ArrayList(u32) = .empty,
    changes: std.ArrayList(Change) = .empty,
    spans: [2]std.ArrayList(Span) = .{ .empty, .empty },
    interner: ?Interner([]const u8, TokenContext) = null,
    cleanup: cleanup_mod.Buffers = .{},

    pub fn deinit(b: *Buffers, gpa: Allocator) void {
        for (&b.ends) |*e| e.deinit(gpa);
        b.ids.deinit(gpa);
        b.changes.deinit(gpa);
        for (&b.spans) |*s| s.deinit(gpa);
        if (b.interner) |*i| i.deinit();
        b.cleanup.deinit(gpa);
        b.* = undefined;
    }

    /// Bytes held.
    pub fn capacity(b: *const Buffers) fit.Bytes {
        var n: fit.Bytes = fit.add(fit.add(fit.bytes(b.ids), fit.bytes(b.changes)), b.cleanup.capacity());
        for (b.ends) |e| n = fit.add(n, fit.bytes(e));
        for (b.spans) |s| n = fit.add(n, fit.bytes(s));
        if (b.interner) |i| n = fit.add(n, fit.add(fit.bytes(i.items), fit.bytes(i.slots)));
        return n;
    }
};

const word_class: [256]u8 = blk: {
    // 0: a byte alone, 1: word, 2: space, 3: newline.
    var t: [256]u8 = @splat(0);
    for ('a'..'z' + 1) |c| t[c] = 1;
    for ('A'..'Z' + 1) |c| t[c] = 1;
    for ('0'..'9' + 1) |c| t[c] = 1;
    t['_'] = 1;
    for (0x80..0x100) |c| t[c] = 1;
    t[' '] = 2;
    t['\t'] = 2;
    t['\r'] = 2;
    t['\n'] = 3;
    break :blk t;
};

/// Append the end offset of every token of `text[from..to]` to `ends`.
fn tokenize(gpa: Allocator, ends: *std.ArrayList(u32), text: []const u8, from: u32, to: u32, tokens: Tokens) Allocator.Error!void {
    var at: usize = from;
    while (at < to) {
        var end = at + 1;
        switch (tokens) {
            .bytes => {},
            .chars => {
                const n = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
                if (n > 1 and at + n <= to) {
                    if (std.unicode.utf8ValidateSlice(text[at..][0..n])) end = at + n;
                }
            },
            .words => {
                const class = word_class[text[at]];
                if (class == 1 or class == 2) {
                    while (end < to and word_class[text[end]] == class) end += 1;
                }
            },
        }
        try ends.append(gpa, @intCast(end));
        at = end;
    }
}

/// Everything one refinement reads.
pub const Input = struct {
    gpa: Allocator,
    core: *core.Buffers,
    buffers: *Buffers,
    old: Lines,
    new: Lines,
    change: Change,
    options: RefineOptions,
};

pub fn refine(in: Input) Allocator.Error!Refined {
    const b = in.buffers;
    const c = in.change;
    for (&b.spans) |*s| s.clearRetainingCapacity();
    const sides = [2]Lines{ in.old, in.new };
    const starts = [2]u32{ c.old_start, c.new_start };
    const lens = [2]u32{ c.old_len, c.new_len };
    if (c.old_len == 0 or c.new_len == 0) {
        // Nothing to line up: each line is one changed span.
        for (0..2) |s| {
            for (starts[s]..starts[s] + lens[s]) |i| {
                const line: u32 = @intCast(i);
                const at = sides[s].start(line);
                try b.spans[s].append(in.gpa, .{ .start = at, .len = sides[s].ends[line] - at, .changed = true });
            }
        }
        return .{ .old = b.spans[0].items, .new = b.spans[1].items };
    }

    if (b.interner == null) b.interner = .init(in.gpa, .{ .compare = in.options.compare });
    const interner = &b.interner.?;
    interner.context = .{ .compare = in.options.compare };
    interner.clear();
    var froms: [2]u32 = undefined;
    for (0..2) |s| {
        b.ends[s].clearRetainingCapacity();
        froms[s] = sides[s].start(starts[s]);
        const to = sides[s].ends[starts[s] + lens[s] - 1];
        try tokenize(in.gpa, &b.ends[s], sides[s].text, froms[s], to, in.options.tokens);
    }
    const n_old = b.ends[0].items.len;
    try b.ids.resize(in.gpa, n_old + b.ends[1].items.len);
    for (0..2) |s| {
        var at = froms[s];
        const ids = if (s == 0) b.ids.items[0..n_old] else b.ids.items[n_old..];
        for (b.ends[s].items, ids) |end, *id| {
            // aegis: measured-boundary: docs/design.md#numeric-boundaries; interned classes enter the raw token kernel after bounded tokenization.
            id.* = (interner.intern(sides[s].text[at..end]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Fewer tokens than bytes, and the inputs are under 4 GiB.
                error.TooManyClasses => unreachable,
            }).raw();
            at = end;
        }
    }
    b.changes.clearRetainingCapacity();
    _ = try core.diff(core.Plain, in.gpa, .{}, in.core, b.ids.items[0..n_old], b.ids.items[n_old..], .{
        .algorithm = in.options.algorithm,
        .minimal = false,
        .max_work = .fromRaw(0),
        .classes = interner.classes().raw(),
        .indent_heuristic = false,
        .stop = in.options.stop,
    }, &b.changes);
    try cleanup_mod.run(.{
        .gpa = in.gpa,
        .buffers = &b.cleanup,
        .old = .{ .ids = b.ids.items[0..n_old], .text = sides[0].text, .from = froms[0], .ends = b.ends[0].items },
        .new = .{ .ids = b.ids.items[n_old..], .text = sides[1].text, .from = froms[1], .ends = b.ends[1].items },
        .edit_cost = in.options.edit_cost,
    }, in.options.cleanup, &b.changes);

    for (0..2) |s| try spans(in.gpa, &b.spans[s], sides[s].text, froms[s], b.ends[s].items, b.changes.items, s == 0);
    return .{ .old = b.spans[0].items, .new = b.spans[1].items };
}

/// The tokens of one side as spans: runs of changed or unchanged tokens,
/// cut after every newline.
fn spans(gpa: Allocator, out: *std.ArrayList(Span), text: []const u8, from: u32, ends: []const u32, changes: []const Change, old_side: bool) Allocator.Error!void {
    var at = from;
    var next_change: usize = 0;
    var line_break = true;
    for (ends, 0..) |end, i| {
        while (next_change < changes.len and runEnd(changes[next_change], old_side) <= i) next_change += 1;
        const changed = next_change < changes.len and runStart(changes[next_change], old_side) <= i;
        const items = out.items;
        if (!line_break and items.len != 0 and items[items.len - 1].changed == changed) {
            items[items.len - 1].len += end - at;
        } else {
            try out.append(gpa, .{ .start = at, .len = end - at, .changed = changed });
        }
        line_break = text[end - 1] == '\n';
        at = end;
    }
}

fn runStart(c: Change, old_side: bool) u32 {
    return if (old_side) c.old_start else c.new_start;
}

fn runEnd(c: Change, old_side: bool) u32 {
    return if (old_side) c.old_start + c.old_len else c.new_start + c.new_len;
}

test "words split at punctuation and keep runs of letters and of spaces" {
    const gpa = std.testing.allocator;
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    const text = "foo_1(bar,  baz)\n\x0bé";
    try tokenize(gpa, &ends, text, 0, text.len, .words);
    try std.testing.expectEqualSlices(u32, &.{ 5, 6, 9, 10, 12, 15, 16, 17, 18, 20 }, ends.items);
    ends.clearRetainingCapacity();
    try tokenize(gpa, &ends, text, 17, text.len, .chars);
    try std.testing.expectEqualSlices(u32, &.{ 18, 20 }, ends.items);
    ends.clearRetainingCapacity();
    try tokenize(gpa, &ends, "a\xffb\xc3", 0, 4, .chars);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, ends.items);
}
