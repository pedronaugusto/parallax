//! One changed-flag per line. The algorithms write their answer here and the
//! slide moves changes by moving flags. A whole side carries a clear sentinel
//! before its first line and after its last, so the slide reads one line
//! past either end without a bounds test.

const std = @import("std");

// aegis: measured-boundary: docs/design.md#numeric-boundaries; bounded sequence lengths and sentinel storage establish these raw kernel indexes.
pub const Flags = struct {
    /// Private: byte `i + 1` is line i's flag.
    bytes: [*]u8,
    len: u32,

    /// A whole side over `storage`, which holds `n + 2` bytes, all clear.
    pub fn whole(storage: []u8, n: u32) Flags {
        std.debug.assert(storage.len == @as(usize, n) + 2);
        @memset(storage, 0);
        return .{ .bytes = storage.ptr, .len = n };
    }

    /// Line i's flag; i may be -1 or `len` on a whole side.
    pub fn get(f: Flags, i: i64) bool {
        return f.bytes[@intCast(i + 1)] != 0;
    }

    pub fn set(f: Flags, i: u32, value: bool) void {
        f.bytes[@as(usize, i) + 1] = @intFromBool(value);
    }

    /// Lines `start .. start + n` as flags of their own. Only a whole side
    /// has sentinels.
    pub fn sub(f: Flags, start: u32, n: u32) Flags {
        return .{ .bytes = f.bytes + start, .len = n };
    }

    pub fn clear(f: Flags) void {
        @memset(f.bytes[1..][0..f.len], 0);
    }

    /// How many lines from `from` on are clear here and from `other_from`
    /// on are clear in `other`, both at once: the shorter run, eight flags
    /// a word at a time on each side, neither read past it.
    pub fn unchangedRun(f: Flags, from: u32, other: Flags, other_from: u32) u32 {
        const here = f.bytes[1..][from..f.len];
        const there = other.bytes[1..][other_from..other.len];
        const n = @min(here.len, there.len);
        var at: usize = 0;
        while (at + 8 <= n) : (at += 8) {
            const word = std.mem.readInt(u64, here[at..][0..8], .little) | std.mem.readInt(u64, there[at..][0..8], .little);
            if (word != 0) return @intCast(at + @ctz(word) / 8);
        }
        while (at < n and here[at] == 0 and there[at] == 0) at += 1;
        return @intCast(at);
    }

    pub fn setRange(f: Flags, from: u32, count: u32) void {
        @memset(f.bytes[@as(usize, from) + 1 ..][0..count], 1);
    }
};

test "a run of clear flags is counted on both sides to the first set one or an end" {
    var storage: [42]u8 = undefined;
    const f: Flags = .whole(&storage, 40);
    var other_storage: [32]u8 = undefined;
    const other: Flags = .whole(&other_storage, 30);
    try std.testing.expectEqual(@as(u32, 30), f.unchangedRun(0, other, 0));
    try std.testing.expectEqual(@as(u32, 20), f.unchangedRun(20, other, 0));
    f.set(13, true);
    other.set(25, true);
    try std.testing.expectEqual(@as(u32, 13), f.unchangedRun(0, other, 0));
    try std.testing.expectEqual(@as(u32, 0), f.unchangedRun(13, other, 0));
    try std.testing.expectEqual(@as(u32, 11), f.unchangedRun(14, other, 14));
    try std.testing.expectEqual(@as(u32, 5), f.unchangedRun(14, other, 20));
    try std.testing.expectEqual(@as(u32, 0), f.unchangedRun(40, other, 0));
}
