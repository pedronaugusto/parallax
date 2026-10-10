//! Workspace arrays sized to what one call needs. They are kept between
//! calls, so the half again that a growing list adds by default would be
//! held for good.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;

/// Retained storage in bytes, distinct from element and work counts.
pub const Bytes = aegis.units.Bytes(usize);

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

/// Bytes occupied by one retained array. The allocator has already checked
/// its extent before publishing the capacity.
pub fn bytes(list: anytype) Bytes {
    // aegis: design: docs/design.md#numeric-boundaries; a live array's allocated extent proves this multiplication fits, and the output is only bytes.
    return .fromRaw(list.capacity * @sizeOf(@TypeOf(list.items[0])));
}

/// Sum of disjoint live storage, already bounded by the address space.
pub fn add(a: Bytes, b: Bytes) Bytes {
    // glint-ignore: A004 -- design: docs/design.md#numeric-boundaries; disjoint live allocations cannot exceed the address space; both operands are byte counts.
    return .fromRaw(a.raw() + b.raw());
}
