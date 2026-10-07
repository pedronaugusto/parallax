//! Workspace arrays sized to what one call needs. They are kept between
//! calls, so the half again that a growing list adds by default would be
//! held for good.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `list` resized to `n` items, its capacity no more than that when it has
/// to grow.
pub fn resize(gpa: Allocator, list: anytype, n: usize) Allocator.Error!void {
    try list.ensureTotalCapacityPrecise(gpa, n);
    try list.resize(gpa, n);
}

test "a list grows to exactly what is asked and keeps it" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try resize(gpa, &list, 1000);
    try std.testing.expectEqual(@as(usize, 1000), list.capacity);
    try resize(gpa, &list, 10);
    try std.testing.expectEqual(@as(usize, 1000), list.capacity);
    try std.testing.expectEqual(@as(usize, 10), list.items.len);
}
