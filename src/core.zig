//! One diff of two id sequences: the algorithm, the slide on both sides, and
//! the script read off the flags. Lines and generic sequences both come
//! through here; they differ only in where indentation and anchors come
//! from.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Flags = @import("flags").Flags;
const fit = @import("fit");
const change = @import("change");
const Change = change.Change;
const Algorithm = change.Algorithm;
const myers = @import("myers.zig");
const histogram = @import("histogram.zig");
const patience = @import("patience.zig");
const slide = @import("slide.zig");
const Lines = @import("parallax.lines").Lines;

pub const Buffers = struct {
    myers: myers.Buffers = .{},
    histogram: histogram.Buffers = .{},
    patience: patience.Buffers = .{},
    flags_a: std.ArrayList(u8) = .empty,
    flags_b: std.ArrayList(u8) = .empty,
};

/// Myers forward/backward sweep count, distinct from lines and bytes.
pub const Work = aegis.units.Count(struct {}, u32);
const KernelWork = aegis.units.Count(Work.Domain, u64);
comptime {
    std.debug.assert(@sizeOf(Work) == @sizeOf(u32));
    std.debug.assert(@sizeOf(KernelWork) == @sizeOf(u64));
}

pub const Run = struct {
    algorithm: Algorithm,
    minimal: bool,
    max_work: KernelWork,
    classes: u32,
    indent_heuristic: bool,
    stop: ?*const std.atomic.Value(bool) = null,
};

/// `Source` has `fn anchor(Source, u32) bool` for old lines and
/// `fn indentOld(Source, u32) i32` and `fn indentNew(Source, u32) i32`.
/// The script is appended to `out`; the result is the work units spent.
pub fn diff(
    comptime Source: type,
    gpa: Allocator,
    source: Source,
    bufs: *Buffers,
    a: []const u32,
    b: []const u32,
    run: Run,
    out: *std.ArrayList(Change),
) Allocator.Error!u64 {
    try fit.resize(gpa, &bufs.flags_a, a.len + 2);
    try fit.resize(gpa, &bufs.flags_b, b.len + 2);
    const fa: Flags = .whole(bufs.flags_a.items, @intCast(a.len));
    const fb: Flags = .whole(bufs.flags_b.items, @intCast(b.len));
    var c: myers.Context = .{
        .gpa = gpa,
        .classes = run.classes,
        .minimal = run.minimal,
        // aegis: measured-boundary: docs/design.md#numeric-boundaries; validated sweep cap enters the raw one-unit search kernel.
        .max_work = run.max_work.raw(),
        .stop = run.stop,
        .buffers = &bufs.myers,
    };

    switch (run.algorithm) {
        .myers => try myers.whole(&c, a, b, fa, fb),
        .histogram => try histogram.diff(&c, &bufs.histogram, a, b, fa, fb),
        .patience => try patience.diff(Anchor(Source), .{ .source = source }, &c, &bufs.patience, a, b, fa, fb),
    }

    const rediff_a: ?slide.Rediff = if (run.algorithm == .histogram) .{ .context = &c, .other_ids = b } else null;
    const rediff_b: ?slide.Rediff = if (run.algorithm == .histogram) .{ .context = &c, .other_ids = a } else null;
    try slide.compact(IndentOld(Source), .{ .source = source }, run.indent_heuristic, fa, a, fb, rediff_a);
    try slide.compact(IndentNew(Source), .{ .source = source }, run.indent_heuristic, fb, b, fa, rediff_b);

    try change.build(gpa, out, fa, fb);
    return c.work;
}

fn Anchor(comptime Source: type) type {
    return struct {
        source: Source,
        const Self = @This();
        pub fn at(s: Self, i: u32) bool {
            return s.source.anchor(i);
        }
    };
}

fn IndentOld(comptime Source: type) type {
    return struct {
        source: Source,
        const Self = @This();
        pub fn of(s: Self, i: u32) i32 {
            return s.source.indentOld(i);
        }
    };
}

fn IndentNew(comptime Source: type) type {
    return struct {
        source: Source,
        const Self = @This();
        pub fn of(s: Self, i: u32) i32 {
            return s.source.indentNew(i);
        }
    };
}

/// A caller's test of one position of the old sequence.
pub const Predicate = struct {
    context: ?*const anyopaque = null,
    at: *const fn (context: ?*const anyopaque, index: u32) bool,
};

/// A caller's indentation per token, for the indentation heuristic: -1 for
/// a blank one.
pub const Indent = struct {
    context: ?*const anyopaque = null,
    old: *const fn (context: ?*const anyopaque, index: u32) i32,
    new: *const fn (context: ?*const anyopaque, index: u32) i32,
};

/// Lines of a diff, where the slide finds indentation and patience finds
/// anchors.
pub const LineSource = struct {
    old: Lines,
    new: Lines,
    anchors: []const []const u8,

    pub fn anchor(s: LineSource, i: u32) bool {
        const line = s.old.get(i);
        for (s.anchors) |a| if (std.mem.startsWith(u8, line, a)) return true;
        return false;
    }
    pub fn indentOld(s: LineSource, i: u32) i32 {
        return slide.lineIndent(s.old.get(i));
    }
    pub fn indentNew(s: LineSource, i: u32) i32 {
        return slide.lineIndent(s.new.get(i));
    }
};

/// A caller's id sequences, with the caller's anchors and indentation.
pub const SequenceSource = struct {
    anchor_fn: ?Predicate,
    indent_fn: ?Indent,

    pub fn anchor(s: SequenceSource, i: u32) bool {
        const p = s.anchor_fn orelse return false;
        return p.at(p.context, i);
    }
    pub fn indentOld(s: SequenceSource, i: u32) i32 {
        const f = s.indent_fn.?;
        return f.old(f.context, i);
    }
    pub fn indentNew(s: SequenceSource, i: u32) i32 {
        const f = s.indent_fn.?;
        return f.new(f.context, i);
    }
};

/// No anchors and no indentation: the merge machinery's diffs.
pub const Plain = struct {
    pub fn anchor(_: Plain, _: u32) bool {
        return false;
    }
    pub fn indentOld(_: Plain, _: u32) i32 {
        return -1;
    }
    pub fn indentNew(_: Plain, _: u32) i32 {
        return -1;
    }
};
