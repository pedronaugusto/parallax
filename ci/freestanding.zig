//! parallax has no Io and no OS calls: this object builds for
//! wasm32-freestanding in `zig build check-freestanding`.
const std = @import("std");
const parallax = @import("parallax");

var buffer: [1 << 20]u8 = undefined;

/// The number of changes between two texts, or -1 when the scratch runs out.
export fn parallaxChanges(old: [*]const u8, old_len: usize, new: [*]const u8, new_len: usize) i32 {
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var d: parallax.Differ = .init(fba.allocator());
    defer d.deinit();
    const diff = d.lines(old[0..old_len], new[0..new_len], .{ .algorithm = .histogram }) catch return -1;
    var m = d.merge(old[0..old_len], new[0..new_len], old[0..old_len], .{}) catch return -1;
    _ = &m;
    return @intCast(diff.changes.len);
}
