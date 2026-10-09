//! What a project that depends on parallax and nothing else writes. Built
//! by `zig build check-consumer` with no packages to fetch, so parallax's
//! build.zig must work without any of its own CI dependencies.
const std = @import("std");
const parallax = @import("parallax");
const diff = @import("parallax.diff");
const patch = @import("parallax.patch");
const merge = @import("parallax.merge");
const interner = @import("parallax.interner");
const lines = @import("parallax.lines");
const compare = @import("parallax.compare");

comptime {
    std.debug.assert(parallax.Differ == diff.Differ);
    std.debug.assert(parallax.patch.Patch == patch.Patch);
    std.debug.assert(parallax.merge.Merge == merge.Merge);
    std.debug.assert(parallax.ClassId == interner.ClassId);
    std.debug.assert(parallax.Lines == lines.Lines);
    std.debug.assert(parallax.Compare == compare.Compare);
}

pub fn main() !void {
    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var owned = try parallax.diffLines(fba.allocator(), "a\nb\n", "a\nc\n", .{});
    defer owned.deinit();
    std.debug.assert(owned.diff.changes.len == 1);
    var parsed = try patch.parse(fba.allocator(), "@@ -1 +1 @@\n-a\n+b\n", .{});
    defer parsed.deinit();
    var values: interner.Interner(u8, std.hash_map.AutoContext(u8)) = .init(fba.allocator(), .{});
    defer values.deinit();
    const id = try values.intern(7);
    std.debug.assert(values.get(id) == 7);
}
