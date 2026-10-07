//! A text split into lines without copying it: the end offset of each line.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A text split at '\n'. Line i is `text[start(i)..ends[i]]`, newline
/// included; a last line without one is still a line.
pub const Lines = struct {
    text: []const u8,
    ends: []const u32,

    pub const empty: Lines = .{ .text = "", .ends = &.{} };

    pub fn len(l: Lines) u32 {
        return @intCast(l.ends.len);
    }

    pub fn start(l: Lines, i: u32) u32 {
        return if (i == 0) 0 else l.ends[i - 1];
    }

    pub fn get(l: Lines, i: u32) []const u8 {
        return l.text[l.start(i)..l.ends[i]];
    }

    /// Lines `from .. from + count` as one slice of the text.
    pub fn span(l: Lines, from: u32, count: u32) []const u8 {
        if (count == 0) return l.text[l.start(from)..l.start(from)];
        return l.text[l.start(from)..l.ends[from + count - 1]];
    }
};

/// The largest input, in bytes, a line offset can name.
pub const max_bytes: usize = std.math.maxInt(u32);

pub const SplitError = error{ OutOfMemory, InputTooLarge };

/// Append the end offset of every line of `text` to `ends`.
pub fn split(gpa: Allocator, ends: *std.ArrayList(u32), text: []const u8) SplitError!void {
    if (text.len > max_bytes) return error.InputTooLarge;
    var at: usize = 0;
    while (at < text.len) {
        const end = if (std.mem.findScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        try ends.append(gpa, @intCast(end));
        at = end;
    }
}

test "split keeps the newline and keeps a last line without one" {
    const gpa = std.testing.allocator;
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    try split(gpa, &ends, "a\nbb\nc");
    const l: Lines = .{ .text = "a\nbb\nc", .ends = ends.items };
    try std.testing.expectEqual(@as(u32, 3), l.len());
    try std.testing.expectEqualStrings("a\n", l.get(0));
    try std.testing.expectEqualStrings("bb\n", l.get(1));
    try std.testing.expectEqualStrings("c", l.get(2));
    try std.testing.expectEqualStrings("bb\nc", l.span(1, 2));
    ends.clearRetainingCapacity();
    try split(gpa, &ends, "");
    try std.testing.expectEqual(@as(usize, 0), ends.items.len);
}

/// Vector width for the byte scans, or null where the target has none.
const vector_len = std.simd.suggestVectorLength(u8);

/// The byte length of the longest common prefix of `a` and `b`.
pub fn commonPrefix(a: []const u8, b: []const u8) usize {
    return if (vector_len != null) commonPrefixVector(a, b) else commonPrefixScalar(a, b);
}

/// The byte length of the longest common suffix, at most `limit`.
pub fn commonSuffix(a: []const u8, b: []const u8, limit: usize) usize {
    return if (vector_len != null) commonSuffixVector(a, b, limit) else commonSuffixScalar(a, b, limit);
}

fn commonPrefixScalar(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

fn commonSuffixScalar(a: []const u8, b: []const u8, limit: usize) usize {
    const n = @min(@min(a.len, b.len), limit);
    var i: usize = 0;
    while (i < n and a[a.len - 1 - i] == b[b.len - 1 - i]) i += 1;
    return i;
}

const width = vector_len orelse 16;

fn commonPrefixVector(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i + width <= n) : (i += width) {
        const x: @Vector(width, u8) = a[i..][0..width].*;
        const y: @Vector(width, u8) = b[i..][0..width].*;
        if (!@reduce(.And, x == y)) break;
    }
    return i + commonPrefixScalar(a[i..n], b[i..n]);
}

fn commonSuffixVector(a: []const u8, b: []const u8, limit: usize) usize {
    const n = @min(@min(a.len, b.len), limit);
    var i: usize = 0;
    while (i + width <= n) : (i += width) {
        const x: @Vector(width, u8) = a[a.len - i - width ..][0..width].*;
        const y: @Vector(width, u8) = b[b.len - i - width ..][0..width].*;
        if (!@reduce(.And, x == y)) break;
    }
    return i + commonSuffixScalar(a[0 .. a.len - i], b[0 .. b.len - i], n - i);
}

test "the vector and scalar byte scans agree" {
    var prng: std.Random.DefaultPrng = .init(0x7363616e);
    const r = prng.random();
    var a: [200]u8 = undefined;
    var b: [200]u8 = undefined;
    for (0..2000) |_| {
        const na = r.uintLessThan(usize, a.len + 1);
        const nb = r.uintLessThan(usize, b.len + 1);
        for (a[0..na]) |*c| c.* = 'a' + r.uintLessThan(u8, 2);
        @memcpy(b[0..@min(na, nb)], a[0..@min(na, nb)]);
        for (b[@min(na, nb)..nb]) |*c| c.* = 'a';
        if (nb > 0 and r.boolean()) b[r.uintLessThan(usize, nb)] = 'c';
        const limit = r.uintLessThan(usize, 210);
        try std.testing.expectEqual(commonPrefixScalar(a[0..na], b[0..nb]), commonPrefixVector(a[0..na], b[0..nb]));
        try std.testing.expectEqual(commonSuffixScalar(a[0..na], b[0..nb], limit), commonSuffixVector(a[0..na], b[0..nb], limit));
    }
}
