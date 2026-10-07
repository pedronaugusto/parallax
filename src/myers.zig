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
const fit = @import("fit.zig");

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
    runs: std.ArrayList(u16) = .empty,
    kvd32: std.ArrayList(i32) = .empty,
    kvd64: std.ArrayList(i64) = .empty,
    stack: std.ArrayList(Box) = .empty,
    /// Per id, its occurrences in the two regions, up to 65535 each: in
    /// the old one in the low half, in the new one in the high half.
    counts: std.ArrayList(u32) = .empty,
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
    /// A caller's flag: once it reads true, what is left is described
    /// coarsely, as when `max_work` runs out.
    stop: ?*const std.atomic.Value(bool) = null,
    buffers: *Buffers,

    /// Whether the caller has asked the diff to stop. Read once per work
    /// unit and once per region.
    pub fn stopped(c: *const Context) bool {
        const flag = c.stop orelse return false;
        return flag.load(.monotonic);
    }

    /// Whether a cap or a stop flag can end the search early. Neither is,
    /// most of the time, and then a work unit costs one test of this.
    fn bounded(c: *const Context) bool {
        return c.max_work != 0 or c.stop != null;
    }

    /// Whether the cap is reached or the caller asked to stop: the search
    /// ends here.
    noinline fn exhausted(c: *const Context) bool {
        @branchHint(.cold);
        return (c.max_work != 0 and c.work >= c.max_work) or c.stopped();
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
    // them: the counts change the answer. Only whether a count is zero and
    // whether it reaches `max_eqlimit` matter, so they stop at 65535.
    if (bufs.counts.items.len < c.classes) try fit.resize(c.gpa, &bufs.counts, c.classes);
    const counts = bufs.counts.items;
    countLines(counts, a, b);

    try select(c, &bufs.index_a, a, counts, 16, start, end_a, fa);
    try select(c, &bufs.index_b, b, counts, 0, start, end_b, fb);
    const index_a = bufs.index_a.items;
    const index_b = bufs.index_b.items;
    try fit.resize(c.gpa, &bufs.packed_a, index_a.len);
    try fit.resize(c.gpa, &bufs.packed_b, index_b.len);
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

/// Each id's lines in `a` in the low half of its count, in `b` in the high
/// half, each stopping at 65535.
fn countLines(counts: []u32, a: []const u32, b: []const u32) void {
    for (a) |id| counts[id] = 0;
    for (b) |id| counts[id] = 0;
    for (a) |id| {
        if (counts[id] & 0xffff != 0xffff) counts[id] += 1;
    }
    for (b) |id| {
        if (counts[id] >> 16 != 0xffff) counts[id] += 1 << 16;
    }
}

noinline fn run(comptime Int: type, c: *Context, kvd: *std.ArrayList(Int), ndiags: u64, fa: Flags, fb: Flags) Allocator.Error!void {
    const bufs = c.buffers;
    try fit.resize(c.gpa, kvd, @intCast(2 * ndiags));
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
/// however common. The other side's count of each id is the half of
/// `counts` at `other`.
fn select(
    c: *Context,
    out: *std.ArrayList(u32),
    ids: []const u32,
    counts: []const u32,
    other: u5,
    start: usize,
    end: usize,
    changed: Flags,
) Allocator.Error!void {
    out.clearRetainingCapacity();
    if (start >= end) return;
    // 0: no counterpart at all. 1: worth matching. 2: so common that a
    // match says little.
    try fit.resize(c.gpa, &c.buffers.dis, end - start);
    const dis = c.buffers.dis.items;
    const limit = @min(bogosqrt(ids.len), max_eqlimit);
    var any_common = false;
    for (start..end) |i| {
        const nm: u64 = (counts[ids[i]] >> other) & 0xffff;
        dis[i - start] = if (nm == 0) 0 else if (nm >= limit and !c.minimal) 2 else 1;
        any_common = any_common or dis[i - start] == 2;
    }
    if (any_common) {
        try fit.resize(c.gpa, &c.buffers.runs, end - start);
        markDiscardable(dis, c.buffers.runs.items);
    }
    try out.ensureTotalCapacityPrecise(c.gpa, end - start);
    for (start..end) |i| {
        const keep = switch (dis[i - start]) {
            1 => true,
            2 => c.buffers.runs.items[i - start] & discard == 0,
            else => false,
        };
        if (keep) {
            out.appendAssumeCapacity(@intCast(i));
        } else {
            changed.set(@intCast(i), true);
        }
    }
}

/// In `runs`, the bit that says a too-common line is to be set aside.
const discard: u16 = 0x8000;

/// For every too-common line of `dis`, whether `inDiscardableRun` holds,
/// as the `discard` bit of `runs[i]`. The counts either side of each line
/// are kept in two sliding windows, one walked forwards and one
/// backwards, so each line costs the same however long the runs: the
/// direct scan reads up to a window either side of every line, which on a
/// file of repeated lines is a hundred lines read per line.
fn markDiscardable(dis: []const u8, runs: []u16) void {
    const n = dis.len;
    const w: usize = simscan_window;
    // Forwards: the no-match and too-common lines in the window before
    // each line, back to the last line worth matching.
    var zeros: u16 = 0;
    var twos: u16 = 0;
    var run_start: usize = 0;
    for (0..n) |k| {
        runs[k] = zeros | twos << 7;
        switch (dis[k]) {
            1 => {
                zeros = 0;
                twos = 0;
                run_start = k + 1;
            },
            0 => zeros += 1,
            else => twos += 1,
        }
        if (k >= w and k - w >= run_start) {
            if (dis[k - w] == 0) zeros -= 1 else twos -= 1;
        }
    }
    // Backwards: the same after each line, and the verdict.
    zeros = 0;
    twos = 0;
    var run_limit: usize = n;
    var k = n;
    while (k > 0) {
        k -= 1;
        if (dis[k] == 2) {
            const zeros_before = runs[k] & 0x7f;
            const common: u32 = 2 + ((runs[k] >> 7) & 0x7f) + twos;
            const no_match: u32 = zeros_before + zeros;
            if (zeros_before != 0 and zeros != 0 and common * kpdis_run < common + no_match) runs[k] |= discard;
        }
        switch (dis[k]) {
            1 => {
                zeros = 0;
                twos = 0;
                run_limit = k;
            },
            0 => zeros += 1,
            else => twos += 1,
        }
        if (k + w < run_limit) {
            if (dis[k + w] == 0) zeros -= 1 else twos -= 1;
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
        /// of git's give-up rules fires. Null when `max_work` ran out or the
        /// caller asked the diff to stop.
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

            const bounded = c.bounded();
            var ec: u64 = 1;
            while (true) : (ec += 1) {
                if (bounded and c.exhausted()) return null;
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

test "the windowed counts set aside what the direct scan does" {
    var prng: std.Random.DefaultPrng = .init(0x77696e64);
    const r = prng.random();
    var dis: [600]u8 = undefined;
    var runs: [600]u16 = undefined;
    for (0..400) |_| {
        const n = 1 + r.uintLessThan(usize, dis.len);
        const ones = r.uintLessThan(u8, 40);
        for (dis[0..n]) |*d| d.* = if (r.uintLessThan(u8, 100) < ones) 1 else if (r.boolean()) 0 else 2;
        markDiscardable(dis[0..n], runs[0..n]);
        for (0..n) |i| {
            if (dis[i] != 2) continue;
            const direct = inDiscardableRun(dis[0..n], @intCast(i), 0, @intCast(n - 1));
            try std.testing.expectEqual(direct, runs[i] & discard != 0);
        }
    }
}
