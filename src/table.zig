//! The line table: every line becomes a dense `u32` id, equal ids meaning
//! equal lines under the comparison in force. Open addressing over the
//! form's hash; the bytes are compared only when two hashes meet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compare_mod = @import("compare.zig");
const fit = @import("fit.zig");
/// Comparison contract accepted by the line table.
pub const Compare = compare_mod.Compare;
const Lines = @import("lines.zig").Lines;

/// The texts of one call, interned into one table: a diff's two, a merge's
/// three. A line is named globally by its side's offset plus its index.
pub const Texts = struct {
    sides: [3]Lines = .{ Lines.empty, Lines.empty, Lines.empty },
    offsets: [3]u32 = .{ 0, 0, 0 },
    count: u8 = 0,

    pub fn line(t: *const Texts, global: u32) []const u8 {
        var side: usize = t.count - 1;
        while (t.offsets[side] > global) side -= 1;
        return t.sides[side].get(global - t.offsets[side]);
    }
};

// aegis: measured-boundary: docs/design.md#numeric-boundaries; splitAll bounds total lines before the packed one-domain class table is built.
pub const Table = struct {
    /// Private: the slots, a power of two of them. A taken slot holds the
    /// high half of a line's hash (which also picks its slot) above its id
    /// plus one; zero is an empty slot.
    slots: std.ArrayList(u64) = .empty,
    /// Private: per id, the global index of its first line.
    first: std.ArrayList(u32) = .empty,
    /// Private: how many distinct lines, which is the next id.
    classes: u32 = 0,

    /// Lines hashed ahead of their lookups, each slot fetched while the
    /// others hash. At most 64, the bits of a mask.
    const batch = 16;

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.slots.deinit(gpa);
        t.first.deinit(gpa);
        t.* = undefined;
    }

    /// Forget every line, keeping room for `lines` of them before the
    /// table has to grow if half of them are distinct, the common case for
    /// two versions of a file, and before that if more are.
    pub fn reset(t: *Table, gpa: Allocator, lines: usize) Allocator.Error!void {
        t.classes = 0;
        t.first.clearRetainingCapacity();
        const want = std.math.ceilPowerOfTwoAssert(usize, @max(64, lines / 3 * 2));
        try fit.resize(gpa, &t.slots, want);
        @memset(t.slots.items, 0);
    }

    fn tagOf(h: u64) u32 {
        return @truncate(h >> 32);
    }

    /// The id of each of lines `from .. to` of side `side` of `texts`, into
    /// `out`, inserting the forms that are new.
    pub fn internLines(t: *Table, gpa: Allocator, texts: *const Texts, side: usize, from: u32, to: u32, out: []u32, compare: Compare) Allocator.Error!void {
        const lines = texts.sides[side];
        const offset = texts.offsets[side];
        var hashes: [batch]u64 = undefined;
        // A line with the bytes of the line before has its id: a run of
        // blank lines or closing braces costs no hash or lookup.
        var at = from;
        while (at < to) {
            const n = @min(batch, to - at);
            try t.reserve(gpa, n);
            const mask = t.slots.items.len - 1;
            var repeats: u64 = 0;
            for (hashes[0..n], at.., 0..) |*h, i, k| {
                const line = lines.get(@intCast(i));
                if (i > from and std.mem.eql(u8, line, lines.get(@intCast(i - 1)))) {
                    repeats |= @as(@TypeOf(repeats), 1) << @intCast(k);
                    continue;
                }
                h.* = compare_mod.hash(line, compare);
                @prefetch(&t.slots.items[tagOf(h.*) & mask], .{ .rw = .write });
            }
            for (hashes[0..n], at.., 0..) |h, i, k| {
                const repeat = repeats >> @intCast(k) & 1 != 0;
                out[i - from] = if (repeat) out[i - from - 1] else t.internHashed(texts, @intCast(offset + i), lines.get(@intCast(i)), h, compare);
            }
            at += n;
        }
    }

    /// Room for `n` more forms with the table at most three quarters full.
    fn reserve(t: *Table, gpa: Allocator, n: u32) Allocator.Error!void {
        while ((@as(u64, t.classes) + n) * 4 > t.slots.items.len * 3) try t.grow(gpa);
        if (t.first.capacity < t.first.items.len + n) try t.first.ensureTotalCapacityPrecise(gpa, @max(t.first.items.len + n, t.slots.items.len / 4 * 3));
    }

    /// The id of `line`, global index `global`, whose hash is `h`. Room for
    /// a new form is reserved.
    fn internHashed(t: *Table, texts: *const Texts, global: u32, line: []const u8, h: u64, compare: Compare) u32 {
        const tag = tagOf(h);
        const slots = t.slots.items;
        const mask = slots.len - 1;
        var at: usize = tag & mask;
        while (true) : (at = (at + 1) & mask) {
            const slot = slots[at];
            if (slot == 0) {
                const id = t.classes;
                slots[at] = @as(u64, tag) << 32 | (id + 1);
                t.first.appendAssumeCapacity(global);
                t.classes += 1;
                return id;
            }
            if (@as(u32, @truncate(slot >> 32)) == tag) {
                const id: u32 = @as(u32, @truncate(slot)) - 1;
                if (compare_mod.sameForm(texts.line(t.first.items[id]), line, compare)) return id;
            }
        }
    }

    fn grow(t: *Table, gpa: Allocator) Allocator.Error!void {
        const old_len = t.slots.items.len;
        // Room for the doubled table after the live slots, then fold the
        // live ones back into it, each in the slot its tag picks.
        try fit.resize(gpa, &t.slots, old_len * 3);
        const live = t.slots.items[0..old_len];
        const moved = t.slots.items[old_len * 2 ..][0..old_len];
        @memcpy(moved, live);
        const table = t.slots.items[0 .. old_len * 2];
        @memset(table, 0);
        const mask = table.len - 1;
        for (moved) |slot| {
            if (slot == 0) continue;
            var at: usize = @as(u32, @truncate(slot >> 32)) & mask;
            while (table[at] != 0) at = (at + 1) & mask;
            table[at] = slot;
        }
        t.slots.shrinkRetainingCapacity(old_len * 2);
    }
};

test "lines of one form share an id and the ids are dense" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    try t.reset(gpa, 4);
    const text = "a\nb\na\nb \n";
    const ends = [_]u32{ 2, 4, 6, 9 };
    var texts: Texts = .{ .count = 1 };
    texts.sides[0] = .{ .text = text, .ends = &ends };
    var ids: [4]u32 = undefined;
    try t.internLines(gpa, &texts, 0, 0, 4, &ids, .{});
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0, 2 }, &ids);
    try t.reset(gpa, 4);
    try t.internLines(gpa, &texts, 0, 0, 4, &ids, .{ .whitespace = .{ .at_eol = true } });
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0, 1 }, &ids);
}

test "the table grows past its first size and keeps every id" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    try t.reset(gpa, 0);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    for (0..1000) |i| {
        try text.print(gpa, "{d}\n", .{i % 300});
        try ends.append(gpa, @intCast(text.items.len));
    }
    var texts: Texts = .{ .count = 1 };
    texts.sides[0] = .{ .text = text.items, .ends = ends.items };
    var ids: [1000]u32 = undefined;
    // A few at a time, so the table grows between lookups.
    var at: u32 = 0;
    while (at < 1000) : (at += 7) try t.internLines(gpa, &texts, 0, at, @min(at + 7, 1000), ids[at..], .{});
    for (ids, 0..) |id, i| try std.testing.expectEqual(@as(u32, @intCast(i % 300)), id);
    try std.testing.expectEqual(@as(u32, 300), t.classes);
}

test "a run of one line keeps its id across batches and ranges" {
    const gpa = std.testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    try t.reset(gpa, 0);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    var want: [100]u32 = undefined;
    for (&want, 0..) |*w, i| {
        // Runs of 1 to 40 equal lines, a few values over and over.
        const value = (i / 23 + i / 40) % 3;
        try text.print(gpa, "{d}\n", .{value});
        try ends.append(gpa, @intCast(text.items.len));
        w.* = @intCast(value);
    }
    var texts: Texts = .{ .count = 1 };
    texts.sides[0] = .{ .text = text.items, .ends = ends.items };
    var ids: [100]u32 = undefined;
    try t.internLines(gpa, &texts, 0, 0, 37, ids[0..37], .{});
    try t.internLines(gpa, &texts, 0, 37, 100, ids[37..], .{});
    // Ids are given in the order values are first seen.
    for (ids, want) |id, value| try std.testing.expectEqual(ids[std.mem.findScalar(u32, &want, value).?], id);
}
