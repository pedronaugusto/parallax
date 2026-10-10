//! The workspace every diff, merge and refinement goes through. It keeps its
//! scratch between calls, so once it has seen inputs of a size, further
//! calls on inputs no larger allocate nothing.
//!
//! Results borrow the inputs and the workspace: each is valid until the next
//! call on the same `Differ`.

const Differ = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const compare_mod = @import("compare.zig");
const Compare = compare_mod.Compare;
const lines_mod = @import("lines.zig");
const Lines = lines_mod.Lines;
const table_mod = @import("table.zig");
const fit = @import("fit.zig");
const change_mod = @import("change.zig");
/// One run produced by the workspace.
pub const Change = change_mod.Change;
const Algorithm = change_mod.Algorithm;
const core = @import("core.zig");
const Diff = @import("script.zig").Diff;
const threeway = @import("threeway.zig");
const class = @import("interner.zig");
const refine_mod = @import("refine.zig");

gpa: Allocator,
/// Private: the algorithms' scratch.
scratch: core.Buffers = .{},
/// Private: the line table.
table: table_mod.Table = .{},
/// Private: line ends of up to three inputs.
ends: [3]std.ArrayList(u32) = .{ .empty, .empty, .empty },
/// Private: the ids of every line of the inputs, side after side.
// aegis: measured-boundary: docs/design.md#numeric-boundaries; line/table input bounds establish this compact one-domain class array.
ids: std.ArrayList(u32) = .empty,
/// Private: scripts; a merge keeps two.
changes: std.ArrayList(Change) = .empty,
changes_theirs: std.ArrayList(Change) = .empty,
/// Private: the merge's scratch.
merge_buffers: threeway.Buffers = .{},
/// Private: the refinement's scratch.
refine_buffers: refine_mod.Buffers = .{},
/// Private: work units the last call spent, which the tests read.
work: u64 = 0,

/// The number of Myers forward/backward sweeps.
pub const Work = core.Work;
/// Retained storage in bytes.
pub const Bytes = fit.Bytes;

pub const Error = error{ OutOfMemory, InputTooLarge };

/// How a line diff is taken.
pub const Options = struct {
    algorithm: Algorithm = .myers,
    /// Prove the Myers script minimal, including the Myers runs patience and
    /// histogram fall back to.
    minimal: bool = false,
    /// git's default since 2.14. The merge machinery turns it off.
    indent_heuristic: bool = true,
    compare: Compare = .{},
    /// Work units (one forward plus backward Myers sweep) before the diff
    /// falls back to a coarser script that is still correct. 0 is no cap;
    /// git's own give-up rules stay in force.
    max_work: Work = .fromRaw(0),
    /// Old-side lines starting with one of these stay context where an
    /// order allows: git --anchored. Read by patience only (git's --anchored
    /// selects patience).
    anchors: []const []const u8 = &.{},
    /// A flag the caller may raise, from another thread, to abandon the
    /// call. It is read once per work unit and once per histogram or
    /// patience region; from the first time it reads true, what is left is
    /// described as one deletion and one insertion, as when `max_work` runs
    /// out, so the call returns soon with a result that is correct but
    /// coarse. The caller that raised it knows to discard that result.
    stop: ?*const std.atomic.Value(bool) = null,
};

/// A caller's test of one position of the old sequence.
pub const Predicate = core.Predicate;

/// A caller's indentation per token, for the indentation heuristic.
pub const Indent = core.Indent;

/// How a diff of two id sequences is taken.
pub const SequenceOptions = struct {
    algorithm: Algorithm = .myers,
    minimal: bool = false,
    max_work: Work = .fromRaw(0),
    /// Every id is below this.
    classes: class.ClassCount,
    /// Old-side positions to keep as context where possible (patience
    /// only).
    anchor: ?Predicate = null,
    /// Per-token indentation for the indentation heuristic; null is the
    /// plain slide.
    indent: ?Indent = null,
    /// A flag the caller may raise, from another thread, to abandon the
    /// call. It is read once per work unit and once per histogram or
    /// patience region; from the first time it reads true, what is left is
    /// described as one deletion and one insertion, as when `max_work` runs
    /// out, so the call returns soon with a result that is correct but
    /// coarse. The caller that raised it knows to discard that result.
    stop: ?*const std.atomic.Value(bool) = null,
};

pub fn init(gpa: Allocator) Differ {
    return .{ .gpa = gpa };
}

pub fn deinit(d: *Differ) void {
    d.eachList(d.gpa, struct {
        fn f(gpa: Allocator, list: anytype) void {
            list.deinit(gpa);
        }
    }.f);
    d.table.deinit(d.gpa);
    d.refine_buffers.deinit(d.gpa);
    d.* = undefined;
}

/// Release the scratch when it holds more than `keep` bytes: a long-lived
/// caller after one huge diff. The next call allocates again.
pub fn shrink(d: *Differ, keep: Bytes) void {
    var total: Bytes = fit.add(fit.bytes(d.table.slots), fit.bytes(d.table.first));
    total = fit.add(total, d.refine_buffers.capacity());
    d.eachList(&total, struct {
        fn f(sum: *Bytes, list: anytype) void {
            sum.* = fit.add(sum.*, fit.bytes(list));
        }
    }.f);
    // aegis: no-danger: docs/design.md#numeric-boundaries; both operands are Bytes; aegis has no typed ordering operation.
    if (total.raw() <= keep.raw()) return;
    d.eachList(d.gpa, struct {
        fn f(gpa: Allocator, list: anytype) void {
            list.clearAndFree(gpa);
        }
    }.f);
    d.table.slots.clearAndFree(d.gpa);
    d.table.first.clearAndFree(d.gpa);
    d.refine_buffers.deinit(d.gpa);
    d.refine_buffers = .{};
}

fn eachList(d: *Differ, context: anytype, comptime f: anytype) void {
    const c = &d.scratch;
    const m = &d.merge_buffers;
    inline for (.{
        &c.myers.index_a,     &c.myers.index_b,   &c.myers.packed_a,    &c.myers.packed_b,
        &c.myers.dis,         &c.myers.runs,      &c.myers.kvd32,       &c.myers.kvd64,
        &c.myers.stack,       &c.myers.counts,    &c.histogram.next,    &c.histogram.rec_ptr,
        &c.histogram.rec_cnt, &c.histogram.stamp, &c.histogram.stack,   &c.patience.slots,
        &c.patience.piles,    &c.patience.tops,   &c.patience.backbone, &c.patience.todo,
        &c.patience.slot_of,  &c.flags_a,         &c.flags_b,           &d.ends[0],
        &d.ends[1],           &d.ends[2],         &d.ids,               &d.changes,
        &d.changes_theirs,    &m.hunks,           &m.same,              &m.regions,
        &m.refine,
    }) |list| f(context, list);
}

/// Split up to three inputs into `d.ends`, refusing inputs a `u32` cannot
/// index: 4 GiB or more in one, or 2^32 lines or more between them.
fn splitAll(d: *Differ, texts: []const []const u8) Error!table_mod.Texts {
    var out: table_mod.Texts = .{ .count = @intCast(texts.len) };
    var total: u64 = 0;
    for (texts, 0..) |text, i| {
        d.ends[i].clearRetainingCapacity();
        try lines_mod.split(d.gpa, &d.ends[i], text);
        out.sides[i] = .{ .text = text, .ends = d.ends[i].items };
        out.offsets[i] = @intCast(total);
        total += d.ends[i].items.len;
        if (total > std.math.maxInt(u32)) return error.InputTooLarge;
    }
    return out;
}

/// Intern every line of every side into `d.ids`, side after side. For two
/// sides, the lines of the common prefix and suffix are hashed once.
fn internAll(d: *Differ, texts: *const table_mod.Texts, compare: Compare) Allocator.Error!u32 {
    var total: usize = 0;
    for (texts.sides[0..texts.count]) |s| total += s.len();
    try d.table.reset(d.gpa, total);
    try fit.resize(d.gpa, &d.ids, total);
    const ids = d.ids.items;

    if (texts.count != 2) {
        for (texts.sides[0..texts.count], 0..) |side, s| {
            const off = texts.offsets[s];
            try d.table.internLines(d.gpa, texts, s, 0, side.len(), ids[off..][0..side.len()], compare);
        }
        return d.table.classes;
    }

    const old = texts.sides[0];
    const new = texts.sides[1];
    const n_old = old.len();
    const n_new = new.len();
    // Whole lines inside the common byte prefix, each ending in a newline,
    // are the same line on both sides; so are whole lines inside the common
    // suffix that start after a common newline.
    const prefix = lines_mod.commonPrefix(old.text, new.text);
    var head: u32 = 0;
    while (head < n_old and head < n_new and old.ends[head] <= prefix and old.text[old.ends[head] - 1] == '\n') head += 1;
    const head_bytes = old.start(head);
    const suffix = lines_mod.commonSuffix(old.text, new.text, @min(old.text.len, new.text.len) - head_bytes);
    var tail: u32 = 0;
    while (tail < n_old - head and tail < n_new - head and old.start(n_old - 1 - tail) > old.text.len - suffix) tail += 1;

    try d.table.internLines(d.gpa, texts, 0, 0, n_old, ids[0..n_old], compare);
    const new_ids = ids[n_old..];
    @memcpy(new_ids[0..head], ids[0..head]);
    @memcpy(new_ids[n_new - tail ..], ids[n_old - tail .. n_old]);
    try d.table.internLines(d.gpa, texts, 1, head, n_new - tail, new_ids[head .. n_new - tail], compare);
    return d.table.classes;
}

/// The diff of two texts, line by line. The returned Diff borrows `old`,
/// `new` and the workspace until the next call on `d`.
pub fn lines(d: *Differ, old: []const u8, new: []const u8, options: Options) Error!Diff {
    d.work = 0;
    d.changes.clearRetainingCapacity();
    const texts = try d.splitAll(&.{ old, new });
    const result: Diff = .{
        .old = texts.sides[0],
        .new = texts.sides[1],
        .changes = &.{},
        .compare = options.compare,
    };
    if (std.mem.eql(u8, old, new)) return result;
    const classes = try d.internAll(&texts, options.compare);
    const n_old = texts.sides[0].len();
    const source: core.LineSource = .{ .old = texts.sides[0], .new = texts.sides[1], .anchors = options.anchors };
    d.work = try core.diff(core.LineSource, d.gpa, source, &d.scratch, d.ids.items[0..n_old], d.ids.items[n_old..], .{
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .max_work = options.max_work.convert(u64) catch @panic("u32 work cap must fit u64"),
        .classes = classes,
        .indent_heuristic = options.indent_heuristic,
        .stop = options.stop,
    }, &d.changes);
    var r = result;
    r.changes = d.changes.items;
    return r;
}

/// Diff two interned sequences (every id below `options.classes`). The
/// changes are valid until the next call on `d`.
pub fn sequences(d: *Differ, old_ids: []const class.ClassId, new_ids: []const class.ClassId, options: SequenceOptions) Error![]const Change {
    const old = rawIds(old_ids);
    const new = rawIds(new_ids);
    d.work = 0;
    d.changes.clearRetainingCapacity();
    if (@as(u64, old.len) + new.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (std.debug.runtime_safety) {
        for (old) |id| std.debug.assert(id < options.classes.raw());
        for (new) |id| std.debug.assert(id < options.classes.raw());
    }
    if (std.mem.eql(u32, old, new)) return d.changes.items;
    d.work = try core.diff(core.SequenceSource, d.gpa, .{ .anchor_fn = options.anchor, .indent_fn = options.indent }, &d.scratch, old, new, .{
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .max_work = options.max_work.convert(u64) catch @panic("u32 work cap must fit u64"),
        .classes = options.classes.raw(),
        .indent_heuristic = options.indent != null,
        .stop = options.stop,
    }, &d.changes);
    return d.changes.items;
}

/// The three-way merge of `ours` and `theirs` against `base`, as regions.
/// Valid until the next call on `d`.
pub fn merge(d: *Differ, base: []const u8, ours: []const u8, theirs: []const u8, options: threeway.Options) Error!threeway.Merge {
    d.work = 0;
    const texts = try d.splitAll(&.{ base, ours, theirs });
    const regions = &d.merge_buffers.regions;
    regions.clearRetainingCapacity();
    const b = texts.sides[0];
    const o = texts.sides[1];
    const t = texts.sides[2];
    var result: threeway.Merge = .{ .base = b, .ours = o, .theirs = t, .regions = &.{}, .conflicts = 0, .style = options.style };
    const lens: [3]u32 = .{ b.len(), o.len(), t.len() };

    // The sides git takes whole: both the same, or one side with no change.
    if (std.mem.eql(u8, ours, theirs)) {
        try d.whole(if (std.mem.eql(u8, base, ours)) .unchanged else .same, lens);
        result.regions = regions.items;
        return result;
    }
    const classes = try d.internAll(&texts, options.compare);
    const ids_b = d.ids.items[0..b.len()];
    const ids_o = d.ids.items[b.len()..][0..o.len()];
    const ids_t = d.ids.items[b.len() + o.len() ..];
    const run: core.Run = .{
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .max_work = .fromRaw(0),
        .classes = classes,
        .indent_heuristic = false,
        .stop = options.stop,
    };
    d.changes.clearRetainingCapacity();
    d.changes_theirs.clearRetainingCapacity();
    if (!std.mem.eql(u8, base, ours)) d.work += try core.diff(core.Plain, d.gpa, .{}, &d.scratch, ids_b, ids_o, run, &d.changes);
    if (d.changes.items.len == 0) {
        try d.whole(.theirs, lens);
        result.regions = regions.items;
        return result;
    }
    if (!std.mem.eql(u8, base, theirs)) d.work += try core.diff(core.Plain, d.gpa, .{}, &d.scratch, ids_b, ids_t, run, &d.changes_theirs);
    if (d.changes_theirs.items.len == 0) {
        try d.whole(.ours, lens);
        result.regions = regions.items;
        return result;
    }
    result.conflicts = try threeway.solve(.{
        .gpa = d.gpa,
        .core = &d.scratch,
        .buffers = &d.merge_buffers,
        .lens = lens,
        .ids_ours = ids_o,
        .ids_theirs = ids_t,
        .classes = classes,
        .source = .{ .lines = .{ .ours = o, .theirs = t, .compare = options.compare } },
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .style = options.style,
        .level = options.level,
        .stop = options.stop,
    }, d.changes.items, d.changes_theirs.items);
    result.regions = regions.items;
    return result;
}

/// The three-way merge of two interned sequences against a third (every id
/// below `options.classes`), as regions over the three. Valid until the
/// next call on `d`.
pub fn mergeSequences(d: *Differ, base_ids: []const class.ClassId, our_ids: []const class.ClassId, their_ids: []const class.ClassId, options: threeway.SequenceOptions) Error!threeway.SequenceMerge {
    const base = rawIds(base_ids);
    const ours = rawIds(our_ids);
    const theirs = rawIds(their_ids);
    d.work = 0;
    const regions = &d.merge_buffers.regions;
    regions.clearRetainingCapacity();
    if (@as(u64, base.len) + ours.len + theirs.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (std.debug.runtime_safety) {
        for ([_][]const u32{ base, ours, theirs }) |side| for (side) |id| std.debug.assert(id < options.classes.raw());
    }
    const lens: [3]u32 = .{ @intCast(base.len), @intCast(ours.len), @intCast(theirs.len) };
    if (std.mem.eql(u32, ours, theirs)) {
        try d.whole(if (std.mem.eql(u32, base, ours)) .unchanged else .same, lens);
        return .{ .regions = regions.items, .conflicts = 0 };
    }
    const run: core.Run = .{
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .max_work = .fromRaw(0),
        .classes = options.classes.raw(),
        .indent_heuristic = false,
        .stop = options.stop,
    };
    d.changes.clearRetainingCapacity();
    d.changes_theirs.clearRetainingCapacity();
    if (!std.mem.eql(u32, base, ours)) d.work += try core.diff(core.Plain, d.gpa, .{}, &d.scratch, base, ours, run, &d.changes);
    if (d.changes.items.len == 0) {
        try d.whole(.theirs, lens);
        return .{ .regions = regions.items, .conflicts = 0 };
    }
    if (!std.mem.eql(u32, base, theirs)) d.work += try core.diff(core.Plain, d.gpa, .{}, &d.scratch, base, theirs, run, &d.changes_theirs);
    if (d.changes_theirs.items.len == 0) {
        try d.whole(.ours, lens);
        return .{ .regions = regions.items, .conflicts = 0 };
    }
    const conflicts = try threeway.solve(.{
        .gpa = d.gpa,
        .core = &d.scratch,
        .buffers = &d.merge_buffers,
        .lens = lens,
        .ids_ours = ours,
        .ids_theirs = theirs,
        .classes = options.classes.raw(),
        .source = .{ .sequence = options.content },
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .style = options.style,
        .level = options.level,
        .stop = options.stop,
    }, d.changes.items, d.changes_theirs.items);
    return .{ .regions = regions.items, .conflicts = conflicts };
}

/// One region covering all three sides, of these lengths.
fn whole(d: *Differ, kind: threeway.Region.Kind, lens: [3]u32) Allocator.Error!void {
    const b = lens[0];
    const o = lens[1];
    const t = lens[2];
    if (b == 0 and o == 0 and t == 0) return;
    try d.merge_buffers.regions.append(d.gpa, .{
        .kind = kind,
        .base = .{ .start = 0, .len = b },
        .ours = .{ .start = 0, .len = o },
        .theirs = .{ .start = 0, .len = t },
    });
}

/// Which bytes inside one change of `diff` (a replace) differ, as spans of
/// tokens, for inline highlighting. `diff` may come from an earlier call on
/// `d`: refining does not disturb it. Valid until the next call on `d`.
pub fn refine(d: *Differ, diff: Diff, change: Change, options: refine_mod.RefineOptions) Allocator.Error!refine_mod.Refined {
    return refine_mod.refine(.{
        .gpa = d.gpa,
        .core = &d.scratch,
        .buffers = &d.refine_buffers,
        .old = diff.old,
        .new = diff.new,
        .change = change,
        .options = options,
    });
}

/// aegis: measured-boundary: docs/design.md#numeric-boundaries; class IDs
/// have the scalar layout checked by their owner. Callers establish shared
/// membership; runtime-safety builds also check it before kernel entry.
fn rawIds(ids: []const class.ClassId) []const u32 {
    return @ptrCast(ids); // safe: ClassId has u32 size/alignment and every bit pattern is a valid raw class representation
}
