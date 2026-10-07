//! The properties, on seeded inputs, in every `zig build test`.

const std = @import("std");
const shakedown = @import("shakedown");
const support = @import("support.zig");

test "every algorithm, comparison and cap gives a script that applies" {
    try shakedown.check(std.testing.allocator, {}, support.diffOne, .{ .seed = 0x64696666, .cases = 3000 });
}

test "lines of one form match, symmetrically" {
    try shakedown.check(std.testing.allocator, {}, support.sameLineOne, .{ .seed = 0x6c696e65, .cases = 3000 });
}

test "merges cover ours, read back, and keep an unchanged side's other" {
    try shakedown.check(std.testing.allocator, {}, support.mergeOne, .{ .seed = 0x6d657267, .cases = 3000 });
}

test "marked text reads back as parts that tile it" {
    try shakedown.check(std.testing.allocator, {}, support.markersOne, .{ .seed = 0x6d61726b, .cases = 3000 });
}

test "fuzz: marked text reads back as parts that tile it" {
    try shakedown.check(std.testing.allocator, {}, support.markersOne, .{ .seed = 0x6d61726b, .cases = 1 });
}
