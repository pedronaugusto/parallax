//! git's xpatience, line for line. A region is diffed by the lines that occur
//! exactly once in it on each side: the longest run of those in the same
//! order on both sides is the backbone, each backbone line grows outward over
//! equal neighbours, and the gaps between are regions of their own, where a
//! line repeated before may now be unique. A region with no unique line in
//! common goes to Myers as a pair of files of its own.
//!
//! The regions are disjoint and each writes only its own flags, so the order
//! of a list of regions still to do cannot change the answer, and a deep
//! file cannot run the stack out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Flags = @import("flags.zig").Flags;
const myers = @import("myers.zig");
const histogram = @import("histogram.zig");
const fit = @import("fit.zig");

pub const Buffers = struct {
    slots: std.ArrayList(Slot) = .empty,
    piles: std.ArrayList(u32) = .empty,
    tops: std.ArrayList(u32) = .empty,
    backbone: std.ArrayList(u32) = .empty,
    todo: std.ArrayList(Region) = .empty,
    /// Per id: its slot in the current region, or `absent`; each region
    /// clears the entries of its own ids first.
    slot_of: std.ArrayList(u32) = .empty,
};

const absent = std.math.maxInt(u32);

/// Count lines from line1 of the old side against count2 from line2 of the
/// new, zero-based.
pub const Region = struct { line1: u32, count1: u32, line2: u32, count2: u32 };

/// A line of the old side and what the new side holds of it. `line2` is
/// `none` until the new side is seen and `repeated` once either side has
/// it twice, which takes it out of the running.
pub const Slot = struct {
    line1: u32,
    line2: u32 = none,
    anchor: bool,
    /// The backbone entry before this one, as a slot index.
    previous: u32 = no_slot,

    const none = std.math.maxInt(u32);
    const repeated = std.math.maxInt(u32) - 1;
};

const no_slot = std.math.maxInt(u32);

/// `Anchor` has `fn at(Anchor, u32) bool`: whether old line i must stay as
/// context where an order allows (git --anchored).
pub fn diff(
    comptime Anchor: type,
    anchor: Anchor,
    c: *myers.Context,
    p: *Buffers,
    a: []const u32,
    b: []const u32,
    fa: Flags,
    fb: Flags,
) Allocator.Error!void {
    const gpa = c.gpa;
    if (p.slot_of.items.len < c.classes) try fit.resize(gpa, &p.slot_of, c.classes);
    var s: State(Anchor) = .{ .anchor = anchor, .c = c, .p = p, .a = a, .b = b, .fa = fa, .fb = fb };
    p.todo.clearRetainingCapacity();
    try p.todo.append(gpa, .{ .line1 = 0, .count1 = @intCast(a.len), .line2 = 0, .count2 = @intCast(b.len) });
    while (p.todo.pop()) |r| {
        // Asked to stop: what is left is one deletion and one insertion
        // per region.
        if (c.stop != null and c.stopped()) {
            s.fa.setRange(r.line1, r.count1);
            s.fb.setRange(r.line2, r.count2);
            continue;
        }
        try s.region(r);
    }
}

fn State(comptime Anchor: type) type {
    return struct {
        anchor: Anchor,
        c: *myers.Context,
        p: *Buffers,
        a: []const u32,
        b: []const u32,
        fa: Flags,
        fb: Flags,

        const Self = @This();

        fn region(s: *Self, r: Region) Allocator.Error!void {
            if (r.count1 == 0) {
                if (r.count2 != 0) s.fb.setRange(r.line2, r.count2);
                return;
            }
            if (r.count2 == 0) return s.fa.setRange(r.line1, r.count1);
            const p = s.p;
            const gpa = s.c.gpa;

            const slot_of = p.slot_of.items;
            for (s.a[r.line1..][0..r.count1]) |id| slot_of[id] = absent;
            for (s.b[r.line2..][0..r.count2]) |id| slot_of[id] = absent;

            // Every distinct line of the old side, in the order it first
            // appears, which is the order the backbone is built in.
            p.slots.clearRetainingCapacity();
            try p.slots.ensureTotalCapacityPrecise(gpa, r.count1);
            for (r.line1..r.line1 + r.count1) |i| {
                const id = s.a[i];
                if (slot_of[id] != absent) {
                    p.slots.items[slot_of[id]].line2 = Slot.repeated;
                    continue;
                }
                slot_of[id] = @intCast(p.slots.items.len);
                p.slots.appendAssumeCapacity(.{ .line1 = @intCast(i), .anchor = s.anchor.at(@intCast(i)) });
            }

            var has_matches = false;
            for (r.line2..r.line2 + r.count2) |j| {
                const id = s.b[j];
                if (slot_of[id] == absent) continue;
                has_matches = true;
                const slot = &p.slots.items[slot_of[id]];
                slot.line2 = if (slot.line2 == Slot.none) @intCast(j) else Slot.repeated;
            }

            if (!has_matches) {
                s.fa.setRange(r.line1, r.count1);
                s.fb.setRange(r.line2, r.count2);
                return;
            }

            const backbone = try s.longestCommon();
            if (backbone.len == 0) {
                return histogram.fallBack(s.c, s.a, s.fa, r.line1, r.count1, s.b, s.fb, r.line2, r.count2);
            }
            try s.walk(r, backbone);
        }

        /// The longest run of lines unique on both sides that is in order on
        /// both, as slot indices in order. Patience sorting: each line goes
        /// on the pile after the longest run ending lower on the new side,
        /// and an anchor, once placed, is never displaced.
        fn longestCommon(s: *Self) Allocator.Error![]const u32 {
            const p = s.p;
            const slots = p.slots.items;
            try fit.resize(s.c.gpa, &p.piles, slots.len);
            const piles = p.piles.items;
            // The new-side line on top of each pile, beside the piles, so
            // the search reads one array.
            try fit.resize(s.c.gpa, &p.tops, slots.len);
            const tops = p.tops.items;
            var longest: usize = 0;
            // No pile at or below this one may be replaced.
            var anchor_at: i64 = -1;

            for (slots, 0..) |*slot, at| {
                if (slot.line2 == Slot.none or slot.line2 == Slot.repeated) continue;
                var left: i64 = -1;
                if (longest != 0 and slot.line2 > tops[longest - 1]) {
                    // Above every pile, as lines in order mostly are.
                    left = @intCast(longest - 1);
                } else {
                    var right: i64 = @intCast(longest);
                    while (left + 1 < right) {
                        const middle = left + @divTrunc(right - left, 2);
                        if (tops[@intCast(middle)] > slot.line2) right = middle else left = middle;
                    }
                }
                slot.previous = if (left < 0) no_slot else piles[@intCast(left)];
                const i = left + 1;
                if (i <= anchor_at) continue;
                piles[@intCast(i)] = @intCast(at);
                tops[@intCast(i)] = slot.line2;
                if (slot.anchor) {
                    anchor_at = i;
                    longest = @intCast(anchor_at + 1);
                } else if (i == longest) {
                    longest += 1;
                }
            }

            try fit.resize(s.c.gpa, &p.backbone, longest);
            const out = p.backbone.items;
            if (longest == 0) return out;
            var cursor = piles[longest - 1];
            var n = longest;
            while (true) {
                n -= 1;
                out[n] = cursor;
                cursor = slots[cursor].previous;
                if (cursor == no_slot) break;
            }
            // The chain from the top pile back is one slot per pile.
            assert(n == 0);
            return out;
        }

        /// Grow each backbone line over the equal lines around it, and queue
        /// the gaps between.
        fn walk(s: *Self, r: Region, backbone: []const u32) Allocator.Error!void {
            const slots = s.p.slots.items;
            const end1 = r.line1 + r.count1;
            const end2 = r.line2 + r.count2;
            var line1 = r.line1;
            var line2 = r.line2;
            var k: usize = 0;
            while (true) {
                var next1: u32 = end1;
                var next2: u32 = end2;
                if (k < backbone.len) {
                    next1 = slots[backbone[k]].line1;
                    next2 = slots[backbone[k]].line2;
                    while (next1 > line1 and next2 > line2 and s.a[next1 - 1] == s.b[next2 - 1]) {
                        next1 -= 1;
                        next2 -= 1;
                    }
                }
                while (line1 < next1 and line2 < next2 and s.a[line1] == s.b[line2]) {
                    line1 += 1;
                    line2 += 1;
                }
                if (next1 > line1 or next2 > line2) {
                    try s.p.todo.append(s.c.gpa, .{ .line1 = line1, .count1 = next1 - line1, .line2 = line2, .count2 = next2 - line2 });
                }
                if (k == backbone.len) return;

                // Backbone lines that follow one another on both sides are
                // one match, and the next gap starts after all of it.
                while (k + 1 < backbone.len and
                    slots[backbone[k + 1]].line1 == slots[backbone[k]].line1 + 1 and
                    slots[backbone[k + 1]].line2 == slots[backbone[k]].line2 + 1) k += 1;
                line1 = slots[backbone[k]].line1 + 1;
                line2 = slots[backbone[k]].line2 + 1;
                k += 1;
            }
        }
    };
}
