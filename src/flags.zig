//! One changed-flag per line. The algorithms write their answer here and the
//! slide moves changes by moving flags. A whole side carries a clear sentinel
//! before its first line and after its last, so the slide reads one line
//! past either end without a bounds test.

const std = @import("std");

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

    pub fn setRange(f: Flags, from: u32, count: u32) void {
        @memset(f.bytes[@as(usize, from) + 1 ..][0..count], 1);
    }
};
