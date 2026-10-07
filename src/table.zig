//! The line table: every line becomes a dense `u32` id, equal ids meaning
//! equal lines under the comparison in force. Open addressing over the
//! form's hash; the bytes are compared only when two hashes meet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compare_mod = @import("compare.zig");
const Compare = compare_mod.Compare;
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

pub const Table = struct {
    /// Private: the slots, a power of two of them.
    slots: std.ArrayList(Slot) = .empty,
    /// Private: how many distinct lines, which is the next id.
    classes: u32 = 0,

    const Slot = struct {
        hash: u64,
        /// The id plus one; zero is an empty slot.
        id: u32,
        /// The global index of the first line with this id.
        first: u32,
    };

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.slots.deinit(gpa);
        t.* = undefined;
    }

    /// Forget every line, keeping room for about `lines` of them.
    pub fn reset(t: *Table, gpa: Allocator, lines: usize) Allocator.Error!void {
        t.classes = 0;
        const want = std.math.ceilPowerOfTwoAssert(usize, @max(64, lines / 2));
        try t.slots.resize(gpa, want);
        @memset(t.slots.items, std.mem.zeroes(Slot));
    }

    /// The id of `line`, global index `global` of `texts`, inserting it if
    /// its form is new.
    pub fn intern(t: *Table, gpa: Allocator, texts: *const Texts, global: u32, line: []const u8, compare: Compare) Allocator.Error!u32 {
        if ((t.classes + 1) * 2 > t.slots.items.len) try t.grow(gpa);
        const h = compare_mod.hash(line, compare);
        const mask = t.slots.items.len - 1;
        var at: usize = @intCast(h & mask);
        while (true) : (at = (at + 1) & mask) {
            const slot = &t.slots.items[at];
            if (slot.id == 0) {
                slot.* = .{ .hash = h, .id = t.classes + 1, .first = global };
                t.classes += 1;
                return slot.id - 1;
            }
            if (slot.hash == h and compare_mod.sameForm(texts.line(slot.first), line, compare)) return slot.id - 1;
        }
    }

    fn grow(t: *Table, gpa: Allocator) Allocator.Error!void {
        const old_len = t.slots.items.len;
        // Room for the doubled table after the live slots, then fold the
        // live ones back into it.
        try t.slots.resize(gpa, old_len * 3);
        const live = t.slots.items[0..old_len];
        const moved = t.slots.items[old_len * 2 ..][0..old_len];
        @memcpy(moved, live);
        const table = t.slots.items[0 .. old_len * 2];
        @memset(table, std.mem.zeroes(Slot));
        const mask = table.len - 1;
        for (moved) |slot| {
            if (slot.id == 0) continue;
            var at: usize = @intCast(slot.hash & mask);
            while (table[at].id != 0) at = (at + 1) & mask;
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
    const exact: Compare = .{};
    var ids: [4]u32 = undefined;
    for (&ids, 0..) |*id, i| id.* = try t.intern(gpa, &texts, @intCast(i), texts.sides[0].get(@intCast(i)), exact);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0, 2 }, &ids);
    try t.reset(gpa, 4);
    const loose: Compare = .{ .whitespace = .{ .at_eol = true } };
    for (&ids, 0..) |*id, i| id.* = try t.intern(gpa, &texts, @intCast(i), texts.sides[0].get(@intCast(i)), loose);
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
    for (0..1000) |i| {
        const id = try t.intern(gpa, &texts, @intCast(i), texts.sides[0].get(@intCast(i)), .{});
        try std.testing.expectEqual(@as(u32, @intCast(i % 300)), id);
    }
    try std.testing.expectEqual(@as(u32, 300), t.classes);
}
