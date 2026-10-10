//! The three-way line merge, xdiff's decision for decision: both sides are
//! diffed against the base; changes that touch or overlap become one
//! conflict; then, by style and level, a conflict is narrowed to the lines
//! the sides really disagree on, conflicts close together are joined, or
//! (zdiff3) the lines both sides agree on at either end are moved out.
//!
//! The answer is a list of regions in the order of our side. `merge.write`
//! renders them; the bytes are what `git merge-file` writes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const change_mod = @import("change.zig");
const Change = change_mod.Change;
const Algorithm = change_mod.Algorithm;
const compare_mod = @import("compare.zig");
const Compare = compare_mod.Compare;
const Lines = @import("lines.zig").Lines;
const core = @import("core.zig");
const class = @import("interner.zig");

/// Which conflict body `write` produces.
pub const Style = enum {
    /// Ours and theirs, separated by `=======`.
    merge,
    /// Also the base, after `|||||||`. Never narrowed: git caps its level
    /// at eager.
    diff3,
    /// diff3, with the lines both sides agree on at either end of a
    /// conflict moved out of it.
    zdiff3,
};

/// git's XDL_MERGE_* levels.
pub const Level = enum {
    /// The same change on both sides is still a conflict.
    minimal,
    /// The same change on both sides is taken once.
    eager,
    /// Conflicts are narrowed to the lines that differ, and conflicts three
    /// lines or fewer apart are joined. git's merge machinery.
    zealous,
    /// zealous, and conflicts with only lines holding no letter or digit
    /// between them are joined too. `git merge-file`.
    zealous_alnum,
};

pub const Options = struct {
    algorithm: Algorithm = .myers,
    /// Prove the Myers scripts minimal.
    minimal: bool = false,
    compare: Compare = .{},
    style: Style = .merge,
    /// git merge-file's; git's merge machinery passes `.zealous`.
    level: Level = .zealous_alnum,
    /// A flag the caller may raise, from another thread, to abandon the
    /// call. It is read once per work unit and once per histogram or
    /// patience region; from the first time it reads true, what is left is
    /// described as one deletion and one insertion, as when `max_work` runs
    /// out, so the call returns soon with a result that is correct but
    /// coarse. The caller that raised it knows to discard that result.
    stop: ?*const std.atomic.Value(bool) = null,
};

pub const Range = struct { start: u32, len: u32 };

pub const Region = struct {
    kind: Kind,
    base: Range,
    ours: Range,
    theirs: Range,

    pub const Kind = enum {
        /// Taken from ours, which may differ from base only in what the
        /// comparison ignores.
        unchanged,
        /// Only ours changed.
        ours,
        /// Only theirs changed.
        theirs,
        /// Both made the same change; taken from ours.
        same,
        conflict,
    };
};

pub const Merge = struct {
    base: Lines,
    ours: Lines,
    theirs: Lines,
    /// In the order of our side, covering it. A conflict narrowed to
    /// several pieces gives its base lines to the first piece.
    regions: []const Region,
    conflicts: u32,
    style: Style,
};

/// One region in xdiff's terms, signed as xdiff's are.
const Hunk = struct {
    mode: Mode,
    at0: i64,
    len0: i64,
    at1: i64,
    len1: i64,
    at2: i64,
    len2: i64,

    const Mode = enum { conflict, ours, theirs, identical };
};

pub const Buffers = struct {
    hunks: std.ArrayList(Hunk) = .empty,
    same: std.ArrayList(Hunk) = .empty,
    regions: std.ArrayList(Region) = .empty,
    refine: std.ArrayList(Change) = .empty,
};

/// How a merge of id sequences is taken: `Differ.mergeSequences`.
pub const SequenceOptions = struct {
    algorithm: Algorithm = .myers,
    /// Prove the Myers scripts minimal.
    minimal: bool = false,
    /// Every id is below this.
    classes: class.ClassCount,
    /// Changes the regions as for lines: narrowed or not, and (zdiff3) the
    /// ends both sides agree on moved out of each conflict.
    style: Style = .merge,
    level: Level = .zealous_alnum,
    /// Whether our token at an index holds content: `.zealous_alnum` joins
    /// two conflicts with only tokens without content between them, as it
    /// joins lines with no letter or digit. Null: every token has content,
    /// and `.zealous_alnum` is `.zealous`.
    content: ?core.Predicate = null,
    /// As `Options.stop`.
    stop: ?*const std.atomic.Value(bool) = null,
};

/// A merge of id sequences: regions over the three sequences, as `Merge`
/// has them over lines.
pub const SequenceMerge = struct {
    /// In the order of our side, covering it.
    regions: []const Region,
    conflicts: u32,
};

/// What a merge reads beyond the ids.
pub const Source = union(enum) {
    /// Lines: the texts settle the comparison's one quirk when two ids
    /// differ, and say which lines hold a letter or digit.
    lines: struct { ours: Lines, theirs: Lines, compare: Compare },
    /// Sequences: ids alone, and the caller's test of content.
    sequence: ?core.Predicate,
};

/// Everything one merge reads.
pub const Input = struct {
    gpa: Allocator,
    core: *core.Buffers,
    buffers: *Buffers,
    /// Lines or tokens in base, ours and theirs.
    lens: [3]u32,
    ids_ours: []const u32,
    ids_theirs: []const u32,
    classes: u32,
    source: Source,
    algorithm: Algorithm,
    minimal: bool,
    style: Style,
    level: Level,
    stop: ?*const std.atomic.Value(bool),
};

/// The merge whose scripts against the base are `xs1` (ours) and `xs2`
/// (theirs), neither empty, as regions in `in.buffers.regions`. Returns the
/// number of conflicts.
pub fn solve(in: Input, xs1: []const Change, xs2: []const Change) Allocator.Error!u32 {
    const b = in.buffers;
    b.hunks.clearRetainingCapacity();
    b.same.clearRetainingCapacity();
    b.regions.clearRetainingCapacity();
    var level = in.level;
    if (in.style == .diff3 and @backingInt(level) > @backingInt(Level.eager)) level = .eager;

    try walk(in, level, xs1, xs2);
    switch (in.style) {
        .zdiff3 => trim(in),
        .merge, .diff3 => if (@backingInt(level) >= @backingInt(Level.zealous)) {
            try refine(in);
            join(in, level == .zealous_alnum);
        },
    }
    return regions(in);
}

/// `xdl_append_merge`: a region that touches the previous one joins it, and
/// the joined region is a conflict unless both came from the same side.
fn append(in: Input, h: Hunk) Allocator.Error!void {
    const hunks = &in.buffers.hunks;
    if (hunks.items.len != 0) {
        const m = &hunks.items[hunks.items.len - 1];
        if (h.at1 <= m.at1 + m.len1 or h.at2 <= m.at2 + m.len2) {
            if (h.mode != m.mode) m.mode = .conflict;
            m.len0 = h.at0 + h.len0 - m.at0;
            m.len1 = h.at1 + h.len1 - m.at1;
            m.len2 = h.at2 + h.len2 - m.at2;
            return;
        }
    }
    try hunks.append(in.gpa, h);
}

/// Whether ours lines `at1 ..` and theirs lines `at2 ..` are the same, `n`
/// of them: `xdl_merge_cmp_lines`.
fn sameLines(in: Input, at1: i64, at2: i64, n: i64) bool {
    var k: i64 = 0;
    while (k < n) : (k += 1) {
        const i: u32 = @intCast(at1 + k);
        const j: u32 = @intCast(at2 + k);
        if (in.ids_ours[i] == in.ids_theirs[j]) continue;
        switch (in.source) {
            .lines => |l| if (!compare_mod.sameLine(l.ours.get(i), l.theirs.get(j), l.compare)) return false,
            .sequence => return false,
        }
    }
    return true;
}

/// Walk the two scripts together, as `xdl_do_merge` does.
fn walk(in: Input, level: Level, xs1: []const Change, xs2: []const Change) Allocator.Error!void {
    const base_len: i64 = in.lens[0];
    const our_len: i64 = in.lens[1];
    const their_len: i64 = in.lens[2];
    var x1_at: usize = 0;
    var x2_at: usize = 0;
    while (x1_at < xs1.len and x2_at < xs2.len) {
        const x1 = xs1[x1_at];
        const x2 = xs2[x2_at];
        const o1: i64 = x1.old_start;
        const n1: i64 = x1.old_len;
        const a1: i64 = x1.new_start;
        const m1: i64 = x1.new_len;
        const o2: i64 = x2.old_start;
        const n2: i64 = x2.old_len;
        const a2: i64 = x2.new_start;
        const m2: i64 = x2.new_len;
        if (o1 + n1 < o2) {
            try append(in, .{ .mode = .ours, .at0 = o1, .len0 = n1, .at1 = a1, .len1 = m1, .at2 = a2 - o2 + o1, .len2 = n1 });
            x1_at += 1;
            continue;
        }
        if (o2 + n2 < o1) {
            try append(in, .{ .mode = .theirs, .at0 = o2, .len0 = n2, .at1 = a1 - o1 + o2, .len1 = n2, .at2 = a2, .len2 = m2 });
            x2_at += 1;
            continue;
        }
        const identical = level != .minimal and o1 == o2 and n1 == n2 and m1 == m2 and sameLines(in, a1, a2, m1);
        if (identical) {
            try in.buffers.same.append(in.gpa, .{ .mode = .identical, .at0 = o1, .len0 = n1, .at1 = a1, .len1 = m1, .at2 = a2, .len2 = m2 });
        } else {
            const off = o1 - o2;
            const ffo = off + n1 - n2;
            var at0 = o1;
            var at1 = a1;
            var at2 = a2;
            if (off > 0) {
                at0 -= off;
                at1 -= off;
            } else at2 += off;
            var len0 = o1 + n1 - at0;
            var len1 = a1 + m1 - at1;
            var len2 = a2 + m2 - at2;
            if (ffo < 0) {
                len0 -= ffo;
                len1 -= ffo;
            } else len2 += ffo;
            try append(in, .{ .mode = .conflict, .at0 = at0, .len0 = len0, .at1 = at1, .len1 = len1, .at2 = at2, .len2 = len2 });
        }
        const end1 = o1 + n1;
        const end2 = o2 + n2;
        if (end1 >= end2) x2_at += 1;
        if (end2 >= end1) x1_at += 1;
    }
    while (x1_at < xs1.len) : (x1_at += 1) {
        const x1 = xs1[x1_at];
        const o1: i64 = x1.old_start;
        const n1: i64 = x1.old_len;
        try append(in, .{ .mode = .ours, .at0 = o1, .len0 = n1, .at1 = x1.new_start, .len1 = x1.new_len, .at2 = o1 + their_len - base_len, .len2 = n1 });
    }
    while (x2_at < xs2.len) : (x2_at += 1) {
        const x2 = xs2[x2_at];
        const o2: i64 = x2.old_start;
        const n2: i64 = x2.old_len;
        try append(in, .{ .mode = .theirs, .at0 = o2, .len0 = n2, .at1 = o2 + our_len - base_len, .len1 = n2, .at2 = x2.new_start, .len2 = x2.new_len });
    }
}

/// `xdl_refine_conflicts`: diff the two sides of each conflict against each
/// other and keep only the runs where they differ as conflicts. Nothing is
/// refined when one side is empty.
fn refine(in: Input) Allocator.Error!void {
    const hunks = &in.buffers.hunks;
    const out = &in.buffers.refine;
    var at: usize = 0;
    while (at < hunks.items.len) : (at += 1) {
        const m = hunks.items[at];
        if (m.mode != .conflict or m.len1 == 0 or m.len2 == 0) continue;
        out.clearRetainingCapacity();
        const s1: usize = @intCast(m.at1);
        const s2: usize = @intCast(m.at2);
        _ = try core.diff(core.Plain, in.gpa, .{}, in.core, in.ids_ours[s1..][0..@intCast(m.len1)], in.ids_theirs[s2..][0..@intCast(m.len2)], .{
            .algorithm = in.algorithm,
            .minimal = in.minimal,
            .max_work = .fromRaw(0),
            .classes = in.classes,
            .indent_heuristic = false,
            .stop = in.stop,
        }, out);
        if (out.items.len == 0) {
            hunks.items[at].mode = .identical;
            continue;
        }
        for (out.items, 0..) |c, n| {
            const first = n == 0;
            const piece: Hunk = .{
                .mode = .conflict,
                .at0 = if (first) m.at0 else m.at0 + m.len0,
                .len0 = if (first) m.len0 else 0,
                .at1 = m.at1 + c.old_start,
                .len1 = c.old_len,
                .at2 = m.at2 + c.new_start,
                .len2 = c.new_len,
            };
            if (first) {
                hunks.items[at] = piece;
            } else {
                at += 1;
                try hunks.insert(in.gpa, at, piece);
            }
        }
    }
}

/// `xdl_simplify_non_conflicts`: two conflicts with three lines or fewer
/// between them read more easily as one, and so, with `without_alnum`, do
/// two with nothing but punctuation and space between them.
fn join(in: Input, without_alnum: bool) void {
    const hunks = &in.buffers.hunks;
    var at: usize = 0;
    while (at + 1 < hunks.items.len) {
        const m = &hunks.items[at];
        const next = hunks.items[at + 1];
        const begin = m.at1 + m.len1;
        const far = next.at1 - begin > 3 and (!without_alnum or anyContent(in.source, begin, next.at1 - begin));
        if (m.mode != .conflict or next.mode != .conflict or far) {
            at += 1;
            continue;
        }
        m.len0 = next.at0 + next.len0 - m.at0;
        m.len1 = next.at1 + next.len1 - m.at1;
        m.len2 = next.at2 + next.len2 - m.at2;
        _ = hunks.orderedRemove(at + 1);
    }
}

/// `lines_contain_alnum`: whether any of our lines holds an ASCII letter or
/// digit; for a sequence, whether any of our tokens holds content.
fn anyContent(source: Source, at: i64, n: i64) bool {
    var k: i64 = 0;
    while (k < n) : (k += 1) {
        const i: u32 = @intCast(at + k);
        switch (source) {
            .lines => |l| for (l.ours.get(i)) |c| if (std.ascii.isAlphanumeric(c)) return true,
            .sequence => |content| {
                const p = content orelse return true;
                if (p.at(p.context, i)) return true;
            },
        }
    }
    return false;
}

/// `xdl_refine_zdiff3_conflicts`: move the lines both sides agree on at the
/// start and the end of each conflict out of it.
fn trim(in: Input) void {
    for (in.buffers.hunks.items) |*m| {
        if (m.mode != .conflict) continue;
        while (m.len1 != 0 and m.len2 != 0 and sameLines(in, m.at1, m.at2, 1)) {
            m.len1 -= 1;
            m.len2 -= 1;
            m.at1 += 1;
            m.at2 += 1;
        }
        while (m.len1 != 0 and m.len2 != 0 and sameLines(in, m.at1 + m.len1 - 1, m.at2 + m.len2 - 1, 1)) {
            m.len1 -= 1;
            m.len2 -= 1;
        }
    }
}

fn range(at: i64, len: i64) Range {
    const start = @max(at, 0);
    return .{ .start = @intCast(start), .len = @intCast(@max(at + len - start, 0)) };
}

/// The hunks, with the stretches between them as unchanged regions or, where
/// both sides made the same change, same regions.
fn regions(in: Input) Allocator.Error!u32 {
    const b = in.buffers;
    var cursor: Cursor = .{ .in = in };
    var conflicts: u32 = 0;
    for (b.hunks.items) |h| {
        try cursor.gap(h.at1, h.at0, h.at2);
        const kind: Region.Kind = switch (h.mode) {
            .conflict => .conflict,
            .ours => .ours,
            .theirs => .theirs,
            .identical => .same,
        };
        if (kind == .conflict) conflicts += 1;
        try b.regions.append(in.gpa, .{ .kind = kind, .base = range(h.at0, h.len0), .ours = range(h.at1, h.len1), .theirs = range(h.at2, h.len2) });
        cursor.o = @max(cursor.o, h.at1 + h.len1);
        cursor.b = @max(cursor.b, h.at0 + h.len0);
        cursor.t = @max(cursor.t, h.at2 + h.len2);
    }
    try cursor.gap(in.lens[1], in.lens[0], in.lens[2]);
    return conflicts;
}

const Cursor = struct {
    in: Input,
    o: i64 = 0,
    b: i64 = 0,
    t: i64 = 0,
    same: usize = 0,

    /// The stretch from the cursor to `o1` (ours), `b1` (base), `t1`
    /// (theirs): unchanged, except where the walk found the same change on
    /// both sides. Same changes a later hunk swallowed are skipped.
    fn gap(c: *Cursor, o1: i64, b1: i64, t1: i64) Allocator.Error!void {
        const same = c.in.buffers.same.items;
        while (c.same < same.len) {
            const s = same[c.same];
            if (s.at0 < c.b) {
                c.same += 1;
                continue;
            }
            if (s.at0 + s.len0 > b1 or s.at1 + s.len1 > o1) break;
            try c.piece(.unchanged, s.at1, s.at0, s.at2);
            try c.in.buffers.regions.append(c.in.gpa, .{ .kind = .same, .base = range(s.at0, s.len0), .ours = range(s.at1, s.len1), .theirs = range(s.at2, s.len2) });
            c.o = s.at1 + s.len1;
            c.b = s.at0 + s.len0;
            c.t = s.at2 + s.len2;
            c.same += 1;
        }
        try c.piece(.unchanged, o1, b1, t1);
    }

    fn piece(c: *Cursor, kind: Region.Kind, o1: i64, b1: i64, t1: i64) Allocator.Error!void {
        const ours = range(c.o, o1 - c.o);
        const base = range(c.b, b1 - c.b);
        const theirs = range(c.t, t1 - c.t);
        c.o = @max(c.o, o1);
        c.b = @max(c.b, b1);
        c.t = @max(c.t, t1);
        if (ours.len == 0 and base.len == 0 and theirs.len == 0) return;
        // The lines between hunks match one for one; a stretch that does not
        // is git's own arithmetic at work, and its lines are ours either way.
        const k: Region.Kind = if (kind == .unchanged and (ours.len != base.len or ours.len != theirs.len)) .same else kind;
        try c.in.buffers.regions.append(c.in.gpa, .{ .kind = k, .base = base, .ours = ours, .theirs = theirs });
    }
};
