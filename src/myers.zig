//! Myers in the shape git's xdiff gives it, on dense ids.
//!
//! A diff that is merely correct is not enough: a patch has to land on the
//! lines `git diff` shows. So, in order: trim the common head and tail; set
//! aside the lines no match can come from (the prune); run the greedy O(ND)
//! search with the linear-space middle-snake split; and give up on proving
//! the script minimal once the search has cost too much, which git does on
//! purpose and which changes its answer on large or noisy input. The slide
//! that follows is `slide.zig`.
//!
//! The split is an explicit work stack, so stack use is constant whatever
//! the input. The order the stack takes boxes in is the order git's
//! recursion would, which keeps `max_work` reproducible.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Flags = @import("flags.zig").Flags;

/// Below this edit cost the search never gives up, however small the input.
const max_cost_min: u64 = 256;
/// Above this edit cost a long enough snake may end the search.
const heur_min_cost: u64 = 256;
/// How many equal lines in a row count as a snake worth splitting on.
const snake_cnt: i64 = 20;
/// How far a snake has to reach, relative to the edit cost, to be taken.
const k_heur: i64 = 4;
/// How often a line appears in one file and is still worth matching.
const max_eqlimit: u64 = 1024;
/// How far the run scan either side of a common line reaches.
const simscan_window: i64 = 100;
/// A run has to be this much more no-match than multi-match before a
/// multi-match line in it is dropped as well.
const kpdis_run: i64 = 4;

/// xdiff's integer square root by shifts. It overshoots, which is fine: it
/// sets a give-up threshold, and the answer has to be the one git's
/// arithmetic gives or the give-up point moves.
pub fn bogosqrt(n: u64) u64 {
    var i: u64 = 1;
    var v = n;
    while (v > 0) : (v >>= 2) i <<= 1;
    return i;
}

/// Scratch the Myers pass keeps between calls.
pub const Buffers = struct {
    index_a: std.ArrayList(u32) = .empty,
    index_b: std.ArrayList(u32) = .empty,
    packed_a: std.ArrayList(u32) = .empty,
    packed_b: std.ArrayList(u32) = .empty,
    dis: std.ArrayList(u8) = .empty,
    kvd32: std.ArrayList(i32) = .empty,
    kvd64: std.ArrayList(i64) = .empty,
    stack: std.ArrayList(Box) = .empty,
    /// Occurrences of each id in the two regions, valid where `stamp`
    /// holds the current generation.
    count_a: std.ArrayList(u32) = .empty,
    count_b: std.ArrayList(u32) = .empty,
    stamp: std.ArrayList(u32) = .empty,
    generation: u32 = 0,
};

/// One box still to split: lines `off1 .. lim1` against `off2 .. lim2` of
/// the packed sides.
pub const Box = struct { off1: u32, lim1: u32, off2: u32, lim2: u32, need_min: bool };

/// What every algorithm of one diff shares.
pub const Context = struct {
    gpa: Allocator,
    /// Ids are below this.
    classes: u32,
    minimal: bool,
    /// Work units before the search describes what is left coarsely; 0 is
    /// no cap.
    max_work: u64,
    /// Work units spent, over every search the diff makes.
    work: u64 = 0,
    buffers: *Buffers,

    /// Make the id-indexed arrays fit `classes`. Called once per diff.
    pub fn prepare(c: *Context) Allocator.Error!void {
        const b = c.buffers;
        const old = b.stamp.items.len;
        if (old < c.classes) {
            try b.stamp.resize(c.gpa, c.classes);
            @memset(b.stamp.items[old..], 0);
            try b.count_a.resize(c.gpa, c.classes);
            try b.count_b.resize(c.gpa, c.classes);
        }
    }

    fn nextGeneration(c: *Context) u32 {
        const b = c.buffers;
        if (b.generation == std.math.maxInt(u32)) {
            @memset(b.stamp.items, 0);
            b.generation = 0;
        }
        b.generation += 1;
        return b.generation;
    }
};

/// Mark the changed lines of two whole files, the way git's `xdl_do_diff`
/// does: the equal head and tail set aside, then the lines no match can
/// come from, then the search. Patience and histogram call this on a region
/// as if the region were a pair of files, which is git's fallback. The flags
/// are written only to set lines.
pub fn whole(c: *Context, a: []const u32, b: []const u32, fa: Flags, fb: Flags) Allocator.Error!void {
    const bufs = c.buffers;
    var start: usize = 0;
    while (start < a.len and start < b.len and a[start] == b[start]) start += 1;
    var end_a = a.len;
    var end_b = b.len;
    while (end_a > start and end_b > start and a[end_a - 1] == b[end_b - 1]) {
        end_a -= 1;
        end_b -= 1;
    }

    // Each line's count in each whole file, before the trim, as git counts
    // them: the counts change the answer.
    const gen = c.nextGeneration();
    const stamp = bufs.stamp.items;
    const count_a = bufs.count_a.items;
    const count_b = bufs.count_b.items;
    for (a) |id| {
        if (stamp[id] != gen) {
            stamp[id] = gen;
            count_a[id] = 0;
            count_b[id] = 0;
        }
        count_a[id] += 1;
    }
    for (b) |id| {
        if (stamp[id] != gen) {
            stamp[id] = gen;
            count_a[id] = 0;
            count_b[id] = 0;
        }
        count_b[id] += 1;
    }

    try select(c, &bufs.index_a, a, count_b, gen, start, end_a, fa);
    try select(c, &bufs.index_b, b, count_a, gen, start, end_b, fb);
    const index_a = bufs.index_a.items;
    const index_b = bufs.index_b.items;
    try bufs.packed_a.resize(c.gpa, index_a.len);
    try bufs.packed_b.resize(c.gpa, index_b.len);
    for (index_a, bufs.packed_a.items) |at, *id| id.* = a[at];
    for (index_b, bufs.packed_b.items) |at, *id| id.* = b[at];

    // One diagonal per value of x - y, plus a sentinel diagonal at each end
    // that the sweep writes its out-of-box marker into.
    const ndiags: u64 = @as(u64, index_a.len) + index_b.len + 3;
    if (ndiags < std.math.maxInt(i32) / 2) {
        try run(i32, c, &bufs.kvd32, ndiags, fa, fb);
    } else {
        try run(i64, c, &bufs.kvd64, ndiags, fa, fb);
    }
}

fn run(comptime Int: type, c: *Context, kvd: *std.ArrayList(Int), ndiags: u64, fa: Flags, fb: Flags) Allocator.Error!void {
    const bufs = c.buffers;
    try kvd.resize(c.gpa, @intCast(2 * ndiags));
    const n: usize = @intCast(ndiags);
    var search: Search(Int) = .{
        .a = bufs.packed_a.items,
        .b = bufs.packed_b.items,
        .index_a = bufs.index_a.items,
        .index_b = bufs.index_b.items,
        .fa = fa,
        .fb = fb,
        .forward = kvd.items[0..n],
        .backward = kvd.items[n..],
        .diag_bias = @as(Int, @intCast(bufs.packed_b.items.len)) + 1,
        .max_cost = @max(max_cost_min, bogosqrt(ndiags)),
        .context = c,
    };
    try search.all(&bufs.stack, @intCast(bufs.packed_a.items.len), @intCast(bufs.packed_b.items.len), c.minimal);
}

/// The lines of `ids[start..end]` the search should see, as indices into
/// `ids`, in `out`. Everything else is marked changed here and never
/// reconsidered. A minimal diff keeps every line that has a counterpart,
/// however common.
fn select(
    c: *Context,
    out: *std.ArrayList(u32),
    ids: []const u32,
    counts_other: []const u32,
    gen: u32,
    start: usize,
    end: usize,
    changed: Flags,
) Allocator.Error!void {
    out.clearRetainingCapacity();
    if (start >= end) return;
    const stamp = c.buffers.stamp.items;
    // 0: no counterpart at all. 1: worth matching. 2: so common that a
    // match says little.
    try c.buffers.dis.resize(c.gpa, end - start);
    const dis = c.buffers.dis.items;
    const limit = @min(bogosqrt(ids.len), max_eqlimit);
    for (start..end) |i| {
        const id = ids[i];
        const nm: u64 = if (stamp[id] == gen) counts_other[id] else 0;
        dis[i - start] = if (nm == 0) 0 else if (nm >= limit and !c.minimal) 2 else 1;
    }
    try out.ensureTotalCapacity(c.gpa, end - start);
    for (start..end) |i| {
        const keep = switch (dis[i - start]) {
            1 => true,
            2 => !inDiscardableRun(dis, @intCast(i - start), 0, @intCast(end - start - 1)),
            else => false,
        };
        if (keep) {
            out.appendAssumeCapacity(@intCast(i));
        } else {
            changed.set(@intCast(i), true);
        }
    }
}

/// Whether the too-common line at `i` sits between two runs that are mostly
/// lines with no counterpart, where matching it would only pin the diff to
/// a coincidence.
fn inDiscardableRun(dis: []const u8, i: i64, start: i64, end: i64) bool {
    var low = start;
    var high = end;
    if (i - low > simscan_window) low = i - simscan_window;
    if (high - i > simscan_window) high = i + simscan_window;

    var no_match_before: i64 = 0;
    var common_before: i64 = 1;
    var r: i64 = 1;
    while (i - r >= low) : (r += 1) {
        switch (dis[@intCast(i - r)]) {
            0 => no_match_before += 1,
            2 => common_before += 1,
            else => break,
        }
    }
    if (no_match_before == 0) return false;

    var no_match_after: i64 = 0;
    var common_after: i64 = 1;
    r = 1;
    while (i + r <= high) : (r += 1) {
        switch (dis[@intCast(i + r)]) {
            0 => no_match_after += 1,
            2 => common_after += 1,
            else => break,
        }
    }
    if (no_match_after == 0) return false;

    const no_match = no_match_before + no_match_after;
    const common = common_before + common_after;
    return common * kpdis_run < common + no_match;
}

fn Search(comptime Int: type) type {
    return struct {
        a: []const u32,
        b: []const u32,
        /// Where each entry of `a` and `b` sits in its side.
        index_a: []const u32,
        index_b: []const u32,
        fa: Flags,
        fb: Flags,
        forward: []Int,
        backward: []Int,
        /// Added to a diagonal number to index `forward` and `backward`.
        diag_bias: Int,
        /// Edit cost past which the search takes the best split it has.
        max_cost: u64,
        context: *Context,

        const Self = @This();
        const out_of_box_low: Int = -1;
        const out_of_box_high: Int = std.math.maxInt(Int);

        fn getF(s: *const Self, d: Int) Int {
            return s.forward[@intCast(d + s.diag_bias)];
        }
        fn setF(s: *Self, d: Int, v: Int) void {
            s.forward[@intCast(d + s.diag_bias)] = v;
        }
        fn getB(s: *const Self, d: Int) Int {
            return s.backward[@intCast(d + s.diag_bias)];
        }
        fn setB(s: *Self, d: Int, v: Int) void {
            s.backward[@intCast(d + s.diag_bias)] = v;
        }

        fn markA(s: *Self, from: u32, to: u32) void {
            for (s.index_a[from..to]) |at| s.fa.set(at, true);
        }

        fn markB(s: *Self, from: u32, to: u32) void {
            for (s.index_b[from..to]) |at| s.fb.set(at, true);
        }

        /// Split every box at a middle snake until none is left, taking
        /// boxes in the order a recursion would.
        fn all(s: *Self, stack: *std.ArrayList(Box), lim1: u32, lim2: u32, need_min: bool) Allocator.Error!void {
            const gpa = s.context.gpa;
            stack.clearRetainingCapacity();
            try stack.append(gpa, .{ .off1 = 0, .lim1 = lim1, .off2 = 0, .lim2 = lim2, .need_min = need_min });
            while (stack.pop()) |box| {
                var off1 = box.off1;
                var l1 = box.lim1;
                var off2 = box.off2;
                var l2 = box.lim2;
                while (off1 < l1 and off2 < l2 and s.a[off1] == s.b[off2]) {
                    off1 += 1;
                    off2 += 1;
                }
                while (off1 < l1 and off2 < l2 and s.a[l1 - 1] == s.b[l2 - 1]) {
                    l1 -= 1;
                    l2 -= 1;
                }
                if (off1 == l1) {
                    s.markB(off2, l2);
                    continue;
                }
                if (off2 == l2) {
                    s.markA(off1, l1);
                    continue;
                }
                const split = s.middleSnake(off1, l1, off2, l2, box.need_min) orelse {
                    s.markA(off1, l1);
                    s.markB(off2, l2);
                    continue;
                };
                // A split on a corner leaves one half empty and the other the
                // whole box, which would split for ever. The give-up paths
                // pick a point by a measure rather than by a crossing, so
                // the degenerate answer is refused rather than trusted.
                if ((split.i1 == off1 and split.i2 == off2) or (split.i1 == l1 and split.i2 == l2)) {
                    s.markA(off1, l1);
                    s.markB(off2, l2);
                    continue;
                }
                assert(off1 <= split.i1 and split.i1 <= l1);
                assert(off2 <= split.i2 and split.i2 <= l2);
                // The upper half goes on first, so the lower one is done
                // first, as git's recursion does it.
                try stack.append(gpa, .{ .off1 = split.i1, .lim1 = l1, .off2 = split.i2, .lim2 = l2, .need_min = split.min_hi });
                try stack.append(gpa, .{ .off1 = off1, .lim1 = split.i1, .off2 = off2, .lim2 = split.i2, .need_min = split.min_lo });
            }
        }

        const Split = struct { i1: u32, i2: u32, min_lo: bool, min_hi: bool };

        /// Where the edit script through this box crosses it: run the greedy
        /// search from both corners until the frontiers touch, or until one
        /// of git's give-up rules fires. Null when `max_work` ran out.
        fn middleSnake(s: *Self, off1: u32, lim1: u32, off2: u32, lim2: u32, need_min: bool) ?Split {
            const c = s.context;
            const o1: Int = @intCast(off1);
            const l1: Int = @intCast(lim1);
            const o2: Int = @intCast(off2);
            const l2: Int = @intCast(lim2);

            const dmin = o1 - l2;
            const dmax = l1 - o2;
            const fmid = o1 - o2;
            const bmid = l1 - l2;
            // The frontiers can only touch on a diagonal of one parity, and
            // which one decides which sweep notices.
            const odd = @mod(fmid - bmid, 2) != 0;

            var fmin = fmid;
            var fmax = fmid;
            var bmin = bmid;
            var bmax = bmid;
            s.setF(fmid, o1);
            s.setB(bmid, l1);

            var ec: u64 = 1;
            while (true) : (ec += 1) {
                if (c.max_work != 0 and c.work >= c.max_work) return null;
                c.work += 1;
                var got_snake = false;

                // The band of live diagonals widens by one on each side, or,
                // at the edge of the box, narrows there so its width keeps
                // its parity.
                if (fmin > dmin) {
                    fmin -= 1;
                    s.setF(fmin - 1, out_of_box_low);
                } else fmin += 1;
                if (fmax < dmax) {
                    fmax += 1;
                    s.setF(fmax + 1, out_of_box_low);
                } else fmax -= 1;

                var d = fmax;
                while (d >= fmin) : (d -= 2) {
                    // A tie goes to the step that takes a line from the old
                    // side: the tie-break git's output rests on.
                    var x = if (s.getF(d - 1) >= s.getF(d + 1)) s.getF(d - 1) + 1 else s.getF(d + 1);
                    const from = x;
                    var y = x - d;
                    while (x < l1 and y < l2 and s.a[@intCast(x)] == s.b[@intCast(y)]) {
                        x += 1;
                        y += 1;
                    }
                    if (x - from > snake_cnt) got_snake = true;
                    s.setF(d, x);
                    if (odd and bmin <= d and d <= bmax and s.getB(d) <= x) {
                        return .{ .i1 = @intCast(x), .i2 = @intCast(y), .min_lo = true, .min_hi = true };
                    }
                }

                if (bmin > dmin) {
                    bmin -= 1;
                    s.setB(bmin - 1, out_of_box_high);
                } else bmin += 1;
                if (bmax < dmax) {
                    bmax += 1;
                    s.setB(bmax + 1, out_of_box_high);
                } else bmax -= 1;

                d = bmax;
                while (d >= bmin) : (d -= 2) {
                    var x = if (s.getB(d - 1) < s.getB(d + 1)) s.getB(d - 1) else s.getB(d + 1) - 1;
                    const from = x;
                    var y = x - d;
                    while (x > o1 and y > o2 and s.a[@intCast(x - 1)] == s.b[@intCast(y - 1)]) {
                        x -= 1;
                        y -= 1;
                    }
                    if (from - x > snake_cnt) got_snake = true;
                    s.setB(d, x);
                    if (!odd and fmin <= d and d <= fmax and x <= s.getF(d)) {
                        return .{ .i1 = @intCast(x), .i2 = @intCast(y), .min_lo = true, .min_hi = true };
                    }
                }

                if (need_min) continue;

                // A frontier that has run a long way along one diagonal has
                // almost certainly found the real correspondence: split there
                // and stop paying for a proof. The half behind the snake is
                // exact; the half in front is not, and is told so.
                if (got_snake and ec > heur_min_cost) {
                    if (s.forwardSnakeSplit(ec, fmin, fmax, fmid, o1, l1, o2, l2)) |split| return split;
                    if (s.backwardSnakeSplit(ec, bmin, bmax, bmid, o1, l1, o2, l2)) |split| return split;
                }

                // Enough. Take the furthest reaching path either frontier has.
                if (ec >= s.max_cost) return s.furthestSplit(fmin, fmax, bmin, bmax, o1, l1, o2, l2);
            }
        }

        /// git's last give-up rule: of the paths each frontier has pushed
        /// furthest into the box, split on the one that covered more of it.
        fn furthestSplit(s: *Self, fmin: Int, fmax: Int, bmin: Int, bmax: Int, o1: Int, l1: Int, o2: Int, l2: Int) Split {
            var fbest: Int = -1;
            var fbest1: Int = -1;
            var d = fmax;
            while (d >= fmin) : (d -= 2) {
                var x = @min(s.getF(d), l1);
                var y = x - d;
                if (l2 < y) {
                    x = l2 + d;
                    y = l2;
                }
                if (fbest < x + y) {
                    fbest = x + y;
                    fbest1 = x;
                }
            }

            var bbest: Int = std.math.maxInt(Int);
            var bbest1: Int = std.math.maxInt(Int);
            d = bmax;
            while (d >= bmin) : (d -= 2) {
                var x = @max(o1, s.getB(d));
                var y = x - d;
                if (y < o2) {
                    x = o2 + d;
                    y = o2;
                }
                if (x + y < bbest) {
                    bbest = x + y;
                    bbest1 = x;
                }
            }

            if ((l1 + l2) - bbest < fbest - (o1 + o2)) {
                return .{ .i1 = @intCast(fbest1), .i2 = @intCast(fbest - fbest1), .min_lo = true, .min_hi = false };
            }
            return .{ .i1 = @intCast(bbest1), .i2 = @intCast(bbest - bbest1), .min_lo = false, .min_hi = true };
        }

        /// The forward diagonal that has reached furthest, if it ends in a
        /// snake long enough to split on.
        fn forwardSnakeSplit(s: *Self, ec: u64, fmin: Int, fmax: Int, fmid: Int, o1: Int, l1: Int, o2: Int, l2: Int) ?Split {
            var best: Int = 0;
            var best_split: Split = undefined;
            var d = fmax;
            while (d >= fmin) : (d -= 2) {
                const off_mid = if (d > fmid) d - fmid else fmid - d;
                const x = s.getF(d);
                const y = x - d;
                const reach = (x - o1) + (y - o2) - off_mid;
                if (reach <= k_heur * @as(i64, @intCast(ec)) or reach <= best) continue;
                if (!(o1 + snake_cnt <= x and x < l1 and o2 + snake_cnt <= y and y < l2)) continue;
                var k: Int = 1;
                while (s.a[@intCast(x - k)] == s.b[@intCast(y - k)]) : (k += 1) {
                    if (k == snake_cnt) {
                        best = reach;
                        best_split = .{ .i1 = @intCast(x), .i2 = @intCast(y), .min_lo = true, .min_hi = false };
                        break;
                    }
                }
            }
            return if (best > 0) best_split else null;
        }

        /// The same for the backward frontier, where the exact half is the
        /// one in front of the split.
        fn backwardSnakeSplit(s: *Self, ec: u64, bmin: Int, bmax: Int, bmid: Int, o1: Int, l1: Int, o2: Int, l2: Int) ?Split {
            var best: Int = 0;
            var best_split: Split = undefined;
            var d = bmax;
            while (d >= bmin) : (d -= 2) {
                const off_mid = if (d > bmid) d - bmid else bmid - d;
                const x = s.getB(d);
                const y = x - d;
                const reach = (l1 - x) + (l2 - y) - off_mid;
                if (reach <= k_heur * @as(i64, @intCast(ec)) or reach <= best) continue;
                if (!(o1 < x and x <= l1 - snake_cnt and o2 < y and y <= l2 - snake_cnt)) continue;
                var k: Int = 0;
                while (s.a[@intCast(x + k)] == s.b[@intCast(y + k)]) : (k += 1) {
                    if (k == snake_cnt - 1) {
                        best = reach;
                        best_split = .{ .i1 = @intCast(x), .i2 = @intCast(y), .min_lo = false, .min_hi = true };
                        break;
                    }
                }
            }
            return if (best > 0) best_split else null;
        }
    };
}
