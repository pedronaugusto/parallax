//! What a project that depends on parallax and nothing else writes. Built
//! by `zig build check-consumer` with no packages to fetch, so parallax's
//! build.zig must work without any of its own CI dependencies.
const std = @import("std");
const parallax = @import("parallax");

pub fn main() !void {
    var buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var diff = try parallax.diffLines(fba.allocator(), "a\nb\n", "a\nc\n", .{});
    defer diff.deinit();
    std.debug.assert(diff.diff.changes.len == 1);
}
