//! The unit tests that came with the code from relic's textdiff, blobmerge
//! and unified writer, on the new API.

const std = @import("std");
const shakedown = @import("shakedown");
const parallax = @import("../parallax.zig");
const support = @import("support.zig");

const Change = parallax.Change;

fn expectDiff(old: []const u8, new: []const u8, want: []const Change) !void {
    var d = try parallax.diffLines(std.testing.allocator, old, new, .{});
    defer d.deinit();
    try std.testing.expectEqualSlices(Change, want, d.diff.changes);
}

test "identical inputs give no changes" {
    try expectDiff("a\nb\nc\n", "a\nb\nc\n", &.{});
    try expectDiff("", "", &.{});
}

test "a pure insertion" {
    try expectDiff("a\nb\n", "a\nx\nb\n", &.{.{ .old_start = 1, .old_len = 0, .new_start = 1, .new_len = 1 }});
}

test "a pure deletion" {
    try expectDiff("a\nx\nb\n", "a\nb\n", &.{.{ .old_start = 1, .old_len = 1, .new_start = 1, .new_len = 0 }});
}

test "a replacement is one change, not a delete and an insert apart" {
    try expectDiff("a\nb\nc\n", "a\nB\nc\n", &.{.{ .old_start = 1, .old_len = 1, .new_start = 1, .new_len = 1 }});
}

test "an empty side is one whole-file change" {
    try expectDiff("a\nb\n", "", &.{.{ .old_start = 0, .old_len = 2, .new_start = 0, .new_len = 0 }});
    try expectDiff("", "a\nb\n", &.{.{ .old_start = 0, .old_len = 0, .new_start = 0, .new_len = 2 }});
}

test "the slide puts a repeated insertion where git puts it" {
    // A naive Myers reports the added "1\n2\n" at the top: the scripts are
    // the same length. The slide moves the run past the equal lines.
    try expectDiff("1\n2\n3\n", "1\n2\n1\n2\n3\n", &.{.{ .old_start = 2, .old_len = 0, .new_start = 2, .new_len = 2 }});
    try expectDiff("a\na\na\nb\n", "a\na\nb\n", &.{.{ .old_start = 2, .old_len = 1, .new_start = 2, .new_len = 0 }});
}

test "the indentation heuristic picks the boundary git picks" {
    const old = "a {\n  b\n}\na {\n  c\n}\n";
    const new = "a {\n  b\n}\na {\n  x\n}\na {\n  c\n}\n";
    try expectDiff(old, new, &.{.{ .old_start = 3, .old_len = 0, .new_start = 3, .new_len = 3 }});
    // With the heuristic off the run slides as far down as it goes, which
    // is `git diff --no-indent-heuristic`.
    var plain = try parallax.diffLines(std.testing.allocator, old, new, .{ .indent_heuristic = false });
    defer plain.deinit();
    try std.testing.expectEqualSlices(Change, &.{.{ .old_start = 4, .old_len = 0, .new_start = 4, .new_len = 3 }}, plain.diff.changes);
}

test "an insertion at either end stays there" {
    try expectDiff("a\nb\n", "a\nb\nc\n", &.{.{ .old_start = 2, .old_len = 0, .new_start = 2, .new_len = 1 }});
    try expectDiff("b\nc\n", "a\nb\nc\n", &.{.{ .old_start = 0, .old_len = 0, .new_start = 0, .new_len = 1 }});
}

test "hunks join when their context touches and split when it does not" {
    const gpa = std.testing.allocator;
    var old: std.Io.Writer.Allocating = .init(gpa);
    defer old.deinit();
    var new: std.Io.Writer.Allocating = .init(gpa);
    defer new.deinit();
    for (0..30) |i| {
        try old.writer.print("{d}\n", .{i});
        // Lines 2 and 8 change: five unchanged lines between, which three
        // lines of context each side cover. Line 25 is a hunk of its own.
        if (i == 2 or i == 8 or i == 25) try new.writer.print("x{d}\n", .{i}) else try new.writer.print("{d}\n", .{i});
    }
    var d = try parallax.diffLines(gpa, old.written(), new.written(), .{});
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.diff.changes.len);
    var it = d.diff.hunks(.{ .context = 3 });
    const first = it.next().?;
    try std.testing.expectEqual(@as(usize, 2), first.changes.len);
    try std.testing.expectEqual(@as(u32, 0), first.old_start);
    try std.testing.expectEqual(@as(u32, 12), first.old_len);
    const second = it.next().?;
    try std.testing.expectEqual(@as(usize, 1), second.changes.len);
    try std.testing.expectEqual(@as(u32, 22), second.old_start);
    try std.testing.expectEqual(@as(u32, 7), second.old_len);
    try std.testing.expect(it.next() == null);
    // One line of context leaves the first two too far apart; inter-hunk
    // context joins them again.
    var narrow = d.diff.hunks(.{ .context = 1 });
    var n: usize = 0;
    while (narrow.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 3), n);
    var joined = d.diff.hunks(.{ .context = 1, .inter_hunk_context = 3 });
    n = 0;
    while (joined.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "hunks clamp their context at both ends of the file" {
    var d = try parallax.diffLines(std.testing.allocator, "a\nb\n", "A\nb\n", .{});
    defer d.deinit();
    var it = d.diff.hunks(.{ .context = 3 });
    const h = it.next().?;
    try std.testing.expectEqual(parallax.Hunk{ .old_start = 0, .old_len = 2, .new_start = 0, .new_len = 2, .changes = h.changes }, h);
    try std.testing.expect(it.next() == null);
}

test "whitespace flags change what counts as equal, and ranges still index the real lines" {
    const gpa = std.testing.allocator;
    var plain = try parallax.diffLines(gpa, "a\nb  \nc\n", "a\nb\nc\n", .{});
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 1), plain.diff.changes.len);
    var relaxed = try parallax.diffLines(gpa, "a\nb  \nc\n", "a\nb\nc\n", .{ .compare = .{ .whitespace = .{ .at_eol = true } } });
    defer relaxed.deinit();
    try std.testing.expectEqual(@as(usize, 0), relaxed.diff.changes.len);
    var inner = try parallax.diffLines(gpa, "a\nx    y\n", "a\nx y\n", .{ .compare = .{ .whitespace = .{ .change = true } } });
    defer inner.deinit();
    try std.testing.expectEqual(@as(usize, 0), inner.diff.changes.len);
    var all = try parallax.diffLines(gpa, "\ta b\n", "ab\n", .{ .compare = .{ .whitespace = .{ .all = true } } });
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 0), all.diff.changes.len);
    var ranged = try parallax.diffLines(gpa, "a  \nb\nc\n", "a\nB\nc\n", .{ .compare = .{ .whitespace = .{ .at_eol = true } } });
    defer ranged.deinit();
    try std.testing.expectEqualSlices(Change, &.{.{ .old_start = 1, .old_len = 1, .new_start = 1, .new_len = 1 }}, ranged.diff.changes);
    try std.testing.expectEqualStrings("b\n", ranged.diff.old.get(ranged.diff.changes[0].old_start));
}

test "histogram agrees with myers on a plain replacement and falls back where no line is rare" {
    const gpa = std.testing.allocator;
    var h = try parallax.diffLines(gpa, "a\nb\nc\nd\ne\n", "a\nb\nX\nd\ne\n", .{ .algorithm = .histogram });
    defer h.deinit();
    try std.testing.expectEqualSlices(Change, &.{.{ .old_start = 2, .old_len = 1, .new_start = 2, .new_len = 1 }}, h.diff.changes);
    const text = shakedown.corpus.repeat("x\n", 200);
    var f = try parallax.diffLines(gpa, text, text[0 .. text.len - 2], .{ .algorithm = .histogram });
    defer f.deinit();
    try std.testing.expectEqual(parallax.Stat{ .added = 0, .removed = 1 }, f.diff.stat());
}

test "minimal and the give-up heuristics can part company" {
    const gpa = std.testing.allocator;
    var old: std.Io.Writer.Allocating = .init(gpa);
    defer old.deinit();
    var new: std.Io.Writer.Allocating = .init(gpa);
    defer new.deinit();
    // Long and noisy enough that the search passes the cost at which git
    // stops proving the script minimal.
    var seed: u64 = 1;
    for (0..1500) |i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        try old.writer.print("line {d} {d}\n", .{ i, seed >> 60 });
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        try new.writer.print("line {d} {d}\n", .{ i, seed >> 60 });
    }
    var heuristic = try parallax.diffLines(gpa, old.written(), new.written(), .{});
    defer heuristic.deinit();
    var exact = try parallax.diffLines(gpa, old.written(), new.written(), .{ .minimal = true });
    defer exact.deinit();
    try support.expectApplies(heuristic.diff);
    try support.expectApplies(exact.diff);
    try std.testing.expect(exact.diff.stat().added <= heuristic.diff.stat().added);
}

test "a noisy file keeps its shared lines as context" {
    const gpa = std.testing.allocator;
    var old: std.Io.Writer.Allocating = .init(gpa);
    defer old.deinit();
    var new: std.Io.Writer.Allocating = .init(gpa);
    defer new.deinit();
    // Every third line is blank and shared; the rest match nothing on the
    // other side. git reports twenty small changes rather than one block,
    // and does so because the blank lines survive the prune.
    for (0..60) |i| {
        if (i % 3 == 0) {
            try old.writer.writeAll("\n");
            try new.writer.writeAll("\n");
        } else {
            try old.writer.print("{s}\n", .{if (i % 2 == 1) "a" else "b"});
            try new.writer.print("{s}\n", .{if (i % 2 == 1) "x" else "y"});
        }
    }
    var d = try parallax.diffLines(gpa, old.written(), new.written(), .{});
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 20), d.diff.changes.len);
    for (d.diff.changes) |c| {
        try std.testing.expectEqual(@as(u32, 2), c.old_len);
        try std.testing.expectEqual(@as(u32, 2), c.new_len);
    }
}

test "max_work falls back to one delete and one insert" {
    const gpa = std.testing.allocator;
    var old: std.Io.Writer.Allocating = .init(gpa);
    defer old.deinit();
    var new: std.Io.Writer.Allocating = .init(gpa);
    defer new.deinit();
    // Every line is on both sides, so none is set aside before the search;
    // a rotated file is then real work for Myers.
    for (0..200) |i| try old.writer.print("line {d}\n", .{i});
    for (0..200) |i| try new.writer.print("line {d}\n", .{(i + 100) % 200});
    var capped = try parallax.diffLines(gpa, old.written(), new.written(), .{ .max_work = .fromRaw(1) });
    defer capped.deinit();
    try std.testing.expectEqualSlices(Change, &.{.{ .old_start = 0, .old_len = 200, .new_start = 0, .new_len = 200 }}, capped.diff.changes);
    var full = try parallax.diffLines(gpa, old.written(), new.written(), .{});
    defer full.deinit();
    try std.testing.expect(full.diff.changes.len > 1);
    try std.testing.expect(full.diff.stat().added < 200);
    // A cap the search never reaches leaves the script as it was.
    var generous = try parallax.diffLines(gpa, old.written(), new.written(), .{ .max_work = .fromRaw(1_000_000) });
    defer generous.deinit();
    try std.testing.expectEqualSlices(Change, full.diff.changes, generous.diff.changes);
}

test "a capped script still reproduces the new side" {
    var d = try parallax.diffLines(std.testing.allocator, "a\nb\nc\nd\ne\nf\n", "a\nq\nc\nr\ne\ns\n", .{ .max_work = .fromRaw(1) });
    defer d.deinit();
    try support.expectApplies(d.diff);
}

test "stat counts both sides of every run, and ratio the matched share" {
    var d = try parallax.diffLines(std.testing.allocator, "a\nb\nc\n", "a\nx\ny\nc\n", .{});
    defer d.deinit();
    try std.testing.expectEqual(parallax.Stat{ .added = 2, .removed = 1 }, d.diff.stat());
    try std.testing.expectApproxEqAbs(@as(f64, 4.0 / 7.0), d.diff.ratio(), 1e-12);
    var empty = try parallax.diffLines(std.testing.allocator, "", "", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(f64, 1), empty.diff.ratio());
}

test "the op iterator walks the whole script" {
    var d = try parallax.diffLines(std.testing.allocator, "a\nb\nc\nd\n", "a\nB\nc\nd\ne\n", .{});
    defer d.deinit();
    var it = d.diff.ops();
    try std.testing.expectEqual(parallax.Op{ .equal = .{ .old = 0, .new = 0, .len = 1 } }, it.next().?);
    try std.testing.expectEqual(parallax.Op{ .replace = .{ .old_start = 1, .old_len = 1, .new_start = 1, .new_len = 1 } }, it.next().?);
    try std.testing.expectEqual(parallax.Op{ .equal = .{ .old = 2, .new = 2, .len = 2 } }, it.next().?);
    try std.testing.expectEqual(parallax.Op{ .insert = .{ .old = 4, .new = 4, .len = 1 } }, it.next().?);
    try std.testing.expect(it.next() == null);
}

fn expectUnified(old: []const u8, new: []const u8, options: parallax.UnifiedOptions, want: []const u8) !void {
    var d = try parallax.diffLines(std.testing.allocator, old, new, .{});
    defer d.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try parallax.writeUnified(&out.writer, d.diff, options);
    try std.testing.expectEqualStrings(want, out.written());
}

test "a unified body matches the shape git prints" {
    try expectUnified("one\ntwo\nthree\nfour\nfive\n", "one\ntwo\nTHREE\nfour\nfive\n", .{}, "@@ -1,5 +1,5 @@\n one\n two\n-three\n+THREE\n four\n five\n");
    try expectUnified("", "added\n", .{}, "@@ -0,0 +1 @@\n+added\n");
    try expectUnified("gone\n", "", .{}, "@@ -1 +0,0 @@\n-gone\n");
    try expectUnified("one\n", "one", .{ .files = .{ .old = "a/f", .new = "b/f" } }, "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-one\n+one\n\\ No newline at end of file\n");
    try expectUnified("same\n", "same\n", .{ .files = .{ .old = "a/f", .new = "b/f" } }, "");
}

test "the heading on a hunk header is cut at eighty bytes" {
    const long = "function_with_a_very_long_name_that_goes_on(int first_argument, int second_argument, int third)";
    var d = try parallax.diffLines(std.testing.allocator, long ++ "\n1\n2\n3\n4\n5\n6\nx\n", long ++ "\n1\n2\n3\n4\n5\n6\ny\n", .{});
    defer d.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try parallax.writeUnified(&out.writer, d.diff, .{ .heading = .c_function });
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "@@ -5,4 +5,4 @@ " ++ long[0..80] ++ "\n"));
}

test "fuzz: any two inputs diff without a crash, and the script reproduces the new side" {
    try shakedown.check(std.testing.allocator, {}, support.diffOne, .{ .seed = 0x64696666, .cases = 1 });
}

test "fuzz: lines of one comparison form always match, and matching is symmetric" {
    try shakedown.check(std.testing.allocator, {}, support.sameLineOne, .{ .seed = 0x6c696e65, .cases = 1 });
}

test "fuzz: three-way merges never crash and an unchanged theirs keeps ours" {
    try shakedown.check(std.testing.allocator, {}, support.mergeOne, .{ .seed = 0x6d657267, .cases = 1 });
}
