//! The properties, on seeded inputs, in every `zig build test`.

const std = @import("std");
const support = @import("support.zig");

test "every algorithm, comparison and cap gives a script that applies" {
    try support.seeded(support.diffOne, 0x64696666, 3000);
}

test "lines of one form match, symmetrically" {
    try support.seeded(support.sameLineOne, 0x6c696e65, 3000);
}

test "merges cover ours, read back, and keep an unchanged side's other" {
    try support.seeded(support.mergeOne, 0x6d657267, 3000);
}

test "marked text reads back as parts that tile it" {
    try support.seeded(support.markersOne, 0x6d61726b, 3000);
}

test "fuzz: marked text reads back as parts that tile it" {
    try std.testing.fuzz({}, support.fuzzed(support.markersOne), .{});
}
