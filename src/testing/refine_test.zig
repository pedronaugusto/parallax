//! Generic sequences, the interner, and inline refinement.

const std = @import("std");
const parallax = @import("../parallax.zig");
const support = @import("support.zig");

const Span = parallax.Span;

test "a sequence of any type diffs through the interner as lines do" {
    const gpa = std.testing.allocator;
    var interner: parallax.Interner([]const u8, std.hash_map.StringContext) = .init(gpa, .{});
    defer interner.deinit();
    const old = [_][]const u8{ "the", "quick", "brown", "fox", "jumps" };
    const new = [_][]const u8{ "the", "slow", "brown", "fox", "jumps", "high" };
    var old_ids: [old.len]u32 = undefined;
    var new_ids: [new.len]u32 = undefined;
    try interner.internSlice(&old, &old_ids);
    try interner.internSlice(&new, &new_ids);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    for ([_]parallax.Algorithm{ .myers, .patience, .histogram }) |algorithm| {
        const changes = try d.sequences(&old_ids, &new_ids, .{ .classes = interner.classes(), .algorithm = algorithm });
        try std.testing.expectEqualSlices(parallax.Change, &.{
            .{ .old_start = 1, .old_len = 1, .new_start = 1, .new_len = 1 },
            .{ .old_start = 5, .old_len = 0, .new_start = 5, .new_len = 1 },
        }, changes);
    }
}

test "sequences take a caller's anchors and indentation" {
    const gpa = std.testing.allocator;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    // The lines of the indentation-heuristic fixture, as ids: 0 "a {", 1
    // "  b", 2 "}", 3 "  c", 4 "  x".
    const old = [_]u32{ 0, 1, 2, 0, 3, 2 };
    const new = [_]u32{ 0, 1, 2, 0, 4, 2, 0, 3, 2 };
    const indents = [_]i32{ 0, 2, 0, 2, 2 };
    const Ctx = struct {
        fn of(ids: []const u32, i: u32) i32 {
            return indents[ids[i]];
        }
        fn oldIndent(_: ?*const anyopaque, i: u32) i32 {
            return of(&old, i);
        }
        fn newIndent(_: ?*const anyopaque, i: u32) i32 {
            return of(&new, i);
        }
    };
    const heuristic = try d.sequences(&old, &new, .{ .classes = 5, .indent = .{ .old = Ctx.oldIndent, .new = Ctx.newIndent } });
    try std.testing.expectEqualSlices(parallax.Change, &.{.{ .old_start = 3, .old_len = 0, .new_start = 3, .new_len = 3 }}, heuristic);
    const plain = try d.sequences(&old, &new, .{ .classes = 5 });
    try std.testing.expectEqualSlices(parallax.Change, &.{.{ .old_start = 4, .old_len = 0, .new_start = 4, .new_len = 3 }}, plain);
}

fn expectSpans(text: []const u8, spans: []const Span, want: []const struct { []const u8, bool }) !void {
    try std.testing.expectEqual(want.len, spans.len);
    for (spans, want) |s, w| {
        try std.testing.expectEqualStrings(w[0], text[s.start..][0..s.len]);
        try std.testing.expectEqual(w[1], s.changed);
    }
}

test "refinement marks the words that changed, line by line" {
    const gpa = std.testing.allocator;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const old = "keep\nlet x = compute(a, b);\nreturn x;\nkeep\n";
    const new = "keep\nlet y = compute(a, c);\nreturn y;\nkeep\n";
    const diff = try d.lines(old, new, .{});
    try std.testing.expectEqual(@as(usize, 1), diff.changes.len);
    const r = try d.refine(diff, diff.changes[0], .{});
    try expectSpans(old, r.old, &.{
        .{ "let ", false },    .{ "x", true }, .{ " = compute(a, ", false }, .{ "b", true }, .{ ");\n", false },
        .{ "return ", false }, .{ "x", true }, .{ ";\n", false },
    });
    try expectSpans(new, r.new, &.{
        .{ "let ", false },    .{ "y", true }, .{ " = compute(a, ", false }, .{ "c", true }, .{ ");\n", false },
        .{ "return ", false }, .{ "y", true }, .{ ";\n", false },
    });
    // The diff the refinement came from is undisturbed.
    try std.testing.expectEqual(@as(u32, 1), diff.changes[0].old_start);
}

test "refinement by characters, under a comparison, and of a pure insertion" {
    const gpa = std.testing.allocator;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines("colour\n", "color\n", .{});
    const chars = try d.refine(diff, diff.changes[0], .{ .tokens = .chars });
    try expectSpans("colour\n", chars.old, &.{ .{ "colo", false }, .{ "u", true }, .{ "r\n", false } });
    try expectSpans("color\n", chars.new, &.{.{ "color\n", false }});

    const loose = try d.lines("Hello  World\n", "hello world!\n", .{});
    const folded = try d.refine(loose, loose.changes[0], .{ .compare = .{ .ignore_case = true, .whitespace = .{ .change = true } } });
    try expectSpans("hello world!\n", folded.new, &.{ .{ "hello world", false }, .{ "!", true }, .{ "\n", false } });

    const added = try d.lines("a\n", "a\nb\nc", .{});
    const r = try d.refine(added, added.changes[0], .{});
    try std.testing.expectEqual(@as(usize, 0), r.old.len);
    try expectSpans("a\nb\nc", r.new, &.{ .{ "b\n", true }, .{ "c", true } });
}

test "refined spans tile each line and change only where the tokens differ" {
    try support.seeded(support.refineOne, 0x72656669, 2000);
}

test "fuzz: refinement tiles every change" {
    try std.testing.fuzz({}, support.fuzzed(support.refineOne), .{});
}

test "sequences under every algorithm apply" {
    try support.seeded(support.sequenceOne, 0x73657175, 2000);
}

test "the semantic cleanup puts an edit on a word, and the efficiency cleanup joins close edits" {
    const gpa = std.testing.allocator;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    // diff-match-patch's own example: The c<ins>at c</ins>ame.
    const new = "The cat cat came.\n";
    const diff = try d.lines("The cat came.\n", new, .{});
    const plain = try d.refine(diff, diff.changes[0], .{ .tokens = .chars });
    try expectSpans(new, plain.new, &.{ .{ "The cat ca", false }, .{ "t ca", true }, .{ "me.\n", false } });
    const semantic = try d.refine(diff, diff.changes[0], .{ .tokens = .chars, .cleanup = .semantic });
    try expectSpans(new, semantic.new, &.{ .{ "The cat ", false }, .{ "cat ", true }, .{ "came.\n", false } });
    // Two one-letter edits four letters apart: kept apart at an edit cost
    // of 4, one edit at 8.
    const close = try d.lines("The quick fox.\n", "The quack fix.\n", .{});
    const apart = try d.refine(close, close.changes[0], .{ .tokens = .chars, .cleanup = .efficiency });
    try expectSpans("The quack fix.\n", apart.new, &.{ .{ "The qu", false }, .{ "a", true }, .{ "ck f", false }, .{ "i", true }, .{ "x.\n", false } });
    const joined = try d.refine(close, close.changes[0], .{ .tokens = .chars, .cleanup = .efficiency, .edit_cost = 8 });
    try expectSpans("The quick fox.\n", joined.old, &.{ .{ "The qu", false }, .{ "ick fo", true }, .{ "x.\n", false } });
    try expectSpans("The quack fix.\n", joined.new, &.{ .{ "The qu", false }, .{ "ack fi", true }, .{ "x.\n", false } });
}
