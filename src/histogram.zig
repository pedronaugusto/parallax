//! xdiff's xhistogram, decision for decision. A region is split at its
//! longest common run anchored on the rarest line available, and what is
//! left either side is split the same way. The ties are the point: which run
//! is longest, which occurrence of a repeated line is tried first, and when
//! a line is too common to anchor anything all decide where a merge's
//! conflict lands, and git's merge machinery diffs with this algorithm. It
//! does not trim the equal ends first, and a region it cannot anchor goes to
//! a Myers diff of that region alone, as git's fallback prepares it.
//!
//! Where git recurses into the left region this keeps a stack of regions,
//! taken in the order the recursion would.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Flags = @import("flags.zig").Flags;
const myers = @import("myers.zig");
const fit = @import("fit.zig");

/// Lines occurring more often than this in a region anchor nothing.
const max_chain: u32 = 64;

pub const Buffers = struct {
    next: std.ArrayList(u32) = .empty,
    /// Per id: the first line it is on in the region's old side, and how
    /// many lines it is on, valid where `stamp` holds the generation.
    rec_ptr: std.ArrayList(u32) = .empty,
    rec_cnt: std.ArrayList(u32) = .empty,
    stamp: std.ArrayList(u32) = .empty,
    generation: u32 = 0,
    stack: std.ArrayList(Region) = .empty,
};

/// A region still to diff: one-based lines, as `histogram_diff` takes them.
pub const Region = struct { line1: u64, count1: u64, line2: u64, count2: u64 };

pub fn diff(c: *myers.Context, h: *Buffers, a: []const u32, b: []const u32, fa: Flags, fb: Flags) Allocator.Error!void {
    const gpa = c.gpa;
    const old = h.stamp.items.len;
    if (old < c.classes) {
        try fit.resize(gpa, &h.stamp, c.classes);
        @memset(h.stamp.items[old..], 0);
        try fit.resize(gpa, &h.rec_ptr, c.classes);
        try fit.resize(gpa, &h.rec_cnt, c.classes);
    }
    var s: State = .{ .c = c, .h = h, .a = a, .b = b, .fa = fa, .fb = fb };
    h.stack.clearRetainingCapacity();
    try h.stack.append(gpa, .{ .line1 = 1, .count1 = a.len, .line2 = 1, .count2 = b.len });
    while (h.stack.pop()) |r| {
        // Asked to stop: what is left is one deletion and one insertion
        // per region.
        if (c.stop != null and c.stopped()) {
            s.markA(r.line1, r.count1);
            s.markB(r.line2, r.count2);
            continue;
        }
        try s.region(r);
    }
}

const State = struct {
    c: *myers.Context,
    h: *Buffers,
    a: []const u32,
    b: []const u32,
    fa: Flags,
    fb: Flags,

    /// A common run, as one-based inclusive line numbers. All zeros is none.
    const Lcs = struct { begin1: u64 = 0, end1: u64 = 0, begin2: u64 = 0, end2: u64 = 0 };

    fn markA(s: *State, line: u64, count: u64) void {
        if (count != 0) s.fa.setRange(@intCast(line - 1), @intCast(count));
    }

    fn markB(s: *State, line: u64, count: u64) void {
        if (count != 0) s.fb.setRange(@intCast(line - 1), @intCast(count));
    }

    fn region(s: *State, r: Region) Allocator.Error!void {
        if (r.count1 == 0 and r.count2 == 0) return;
        if (r.count1 == 0) return s.markB(r.line2, r.count2);
        if (r.count2 == 0) return s.markA(r.line1, r.count1);

        var lcs: Lcs = .{};
        if (try s.findLcs(&lcs, r.line1, r.count1, r.line2, r.count2)) {
            return fallBack(s.c, s.a, s.fa, r.line1 - 1, r.count1, s.b, s.fb, r.line2 - 1, r.count2);
        }
        if (lcs.begin1 == 0 and lcs.begin2 == 0) {
            s.markA(r.line1, r.count1);
            s.markB(r.line2, r.count2);
            return;
        }
        const end1 = r.line1 + r.count1 - 1;
        const end2 = r.line2 + r.count2 - 1;
        // The right region waits under the left one, so the left is done
        // first, as git's recursion does it.
        try s.h.stack.append(s.c.gpa, .{ .line1 = lcs.end1 + 1, .count1 = end1 - lcs.end1, .line2 = lcs.end2 + 1, .count2 = end2 - lcs.end2 });
        try s.h.stack.append(s.c.gpa, .{ .line1 = r.line1, .count1 = lcs.begin1 - r.line1, .line2 = r.line2, .count2 = lcs.begin2 - r.line2 });
    }

    fn recordCount(s: *const State, id: u32, gen: u32) ?u32 {
        if (s.h.stamp.items[id] != gen) return null;
        return s.h.rec_cnt.items[id];
    }

    /// Find the anchor run. True when the region has common lines but every
    /// one of them is too common, git's signal to hand it to Myers.
    fn findLcs(s: *State, lcs: *Lcs, line1: u64, count1: u64, line2: u64, count2: u64) Allocator.Error!bool {
        const h = s.h;
        const end1 = line1 + count1 - 1;
        const end2 = line2 + count2 - 1;

        if (h.generation == std.math.maxInt(u32)) {
            @memset(h.stamp.items, 0);
            h.generation = 0;
        }
        h.generation += 1;
        const gen = h.generation;
        const stamp = h.stamp.items;
        const rec_ptr = h.rec_ptr.items;
        const rec_cnt = h.rec_cnt.items;

        // Every occurrence of a value chains to the next one down the file,
        // and the value's record starts at its first. Scanning from the end
        // leaves the chains in that order.
        try fit.resize(s.c.gpa, &h.next, @intCast(count1));
        const next = h.next.items;
        var ptr = end1;
        while (ptr >= line1) : (ptr -= 1) {
            const id = s.a[@intCast(ptr - 1)];
            if (stamp[id] == gen) {
                next[@intCast(ptr - line1)] = rec_ptr[id];
                rec_ptr[id] = @intCast(ptr);
                rec_cnt[id] +|= 1;
            } else {
                stamp[id] = gen;
                next[@intCast(ptr - line1)] = 0;
                rec_ptr[id] = @intCast(ptr);
                rec_cnt[id] = 1;
            }
            if (ptr == line1) break;
        }

        var best_cnt: u32 = max_chain + 1;
        var has_common = false;
        var b_ptr = line2;
        while (b_ptr <= end2) {
            var b_next = b_ptr + 1;
            const b_id = s.b[@intCast(b_ptr - 1)];
            if (stamp[b_id] != gen) {
                b_ptr = b_next;
                continue;
            }
            const rec_count = rec_cnt[b_id];
            has_common = true;
            if (rec_count > best_cnt) {
                b_ptr = b_next;
                continue;
            }
            var as: u64 = rec_ptr[b_id];
            occurrences: while (true) {
                var np: u64 = next[@intCast(as - line1)];
                var bs = b_ptr;
                var ae = as;
                var be = bs;
                var rc = rec_count;
                while (line1 < as and line2 < bs and s.a[@intCast(as - 2)] == s.b[@intCast(bs - 2)]) {
                    as -= 1;
                    bs -= 1;
                    if (1 < rc) rc = @min(rc, s.recordCount(s.a[@intCast(as - 1)], gen).?);
                }
                while (ae < end1 and be < end2 and s.a[@intCast(ae)] == s.b[@intCast(be)]) {
                    ae += 1;
                    be += 1;
                    if (1 < rc) rc = @min(rc, s.recordCount(s.a[@intCast(ae - 1)], gen).?);
                }
                if (b_next <= be) b_next = be + 1;
                if (lcs.end1 - lcs.begin1 < ae - as or rc < best_cnt) {
                    lcs.* = .{ .begin1 = as, .begin2 = bs, .end1 = ae, .end2 = be };
                    best_cnt = rc;
                }
                if (np == 0) break;
                while (np <= ae) {
                    np = next[@intCast(np - line1)];
                    if (np == 0) break :occurrences;
                }
                as = np;
            }
            b_ptr = b_next;
        }
        return has_common and max_chain < best_cnt;
    }
};

/// A Myers diff of one region of each side, prepared as if the regions were
/// whole files (git's `xdl_fall_back_diff`), its answer overwriting every
/// flag in both regions.
pub fn fallBack(
    c: *myers.Context,
    a: []const u32,
    fa: Flags,
    start_a: u64,
    count_a: u64,
    b: []const u32,
    fb: Flags,
    start_b: u64,
    count_b: u64,
) Allocator.Error!void {
    const sa: u32 = @intCast(start_a);
    const na: u32 = @intCast(count_a);
    const sb: u32 = @intCast(start_b);
    const nb: u32 = @intCast(count_b);
    const sub_a = fa.sub(sa, na);
    const sub_b = fb.sub(sb, nb);
    sub_a.clear();
    sub_b.clear();
    try myers.whole(c, a[sa..][0..na], b[sb..][0..nb], sub_a, sub_b);
}
