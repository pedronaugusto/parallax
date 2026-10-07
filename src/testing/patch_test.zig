//! Patches: parse and apply against GNU patch's own results, captured once
//! as data (`testdata/gnu-patch-2.8/`), and the round trip through the
//! unified writer.

const std = @import("std");
const shakedown = @import("shakedown");
const parallax = @import("../parallax.zig");
const corpus = @import("corpus.zig");
const support = @import("support.zig");

const patch_corpus = @embedFile("patch.corpus");
const reversed_corpus = @embedFile("reversed.corpus");

/// The flags of a GNU patch run as apply options.
fn applyOptions(field: []const u8) !parallax.patch.ApplyOptions {
    var options: parallax.patch.ApplyOptions = .{ .rejects = .skip };
    var flags = corpus.flags(field);
    while (flags.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-F")) {
            options.fuzz = try std.fmt.parseInt(u8, flag[2..], 10);
        } else if (std.mem.eql(u8, flag, "-R")) {
            options.reverse = true;
        } else return error.UnknownFlag;
    }
    return options;
}

/// Each hunk's fate as GNU patch reported it, against `results`. True when
/// every hunk applied.
fn expectFates(fates: []const u8, results: []const parallax.patch.HunkResult) !bool {
    var all_applied = true;
    var lines = std.mem.splitScalar(u8, fates, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (line.len == 0) break;
        var words = std.mem.splitScalar(u8, line, ' ');
        const number = try std.fmt.parseInt(usize, words.next().?, 10);
        try std.testing.expectEqual(n + 1, number);
        const fate = words.next().?;
        if (std.mem.eql(u8, fate, "rejected")) {
            try std.testing.expectEqual(parallax.patch.HunkResult.rejected, results[n]);
            all_applied = false;
            continue;
        }
        const fuzz = try std.fmt.parseInt(u8, words.next().?, 10);
        const offset = try std.fmt.parseInt(i32, words.next().?, 10);
        try std.testing.expectEqual(fuzz, results[n].applied.fuzz);
        try std.testing.expectEqual(offset, results[n].applied.offset);
    }
    try std.testing.expectEqual(results.len, n);
    return all_applied;
}

test "apply does what GNU patch does: offsets, fuzz, reverse and rejects" {
    const gpa = std.testing.allocator;
    const c = try corpus.Corpus.parse(patch_corpus);
    try std.testing.expectEqualStrings("GNU patch 2.8", c.git_version);
    var it = c.records();
    var count: usize = 0;
    var fuzzed: usize = 0;
    var shifted: usize = 0;
    var rejected: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("patch.corpus record {d}, flags {s}\n", .{ r.index, r.fields[0] });
        var p = try parallax.patch.parse(gpa, r.fields[2], .{});
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 1), p.files.len);
        const file = p.files[0];
        const results = try gpa.alloc(parallax.patch.HunkResult, file.hunks.len);
        defer gpa.free(results);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try parallax.patch.apply(gpa, &out.writer, r.fields[1], file, try applyOptions(r.fields[0]), results);
        try std.testing.expectEqualStrings(r.fields[3], out.written());
        const all_applied = try expectFates(r.fields[5], results);
        try std.testing.expectEqual(@as(u32, if (all_applied) 0 else 1), try std.fmt.parseInt(u32, r.fields[4], 10));
        for (results) |h| switch (h) {
            .rejected => rejected += 1,
            .applied => |a| {
                fuzzed += @intFromBool(a.fuzz != 0);
                shifted += @intFromBool(a.offset != 0);
            },
        };
    }
    try std.testing.expectEqual(@as(usize, 488), count);
    // The corpus exercises what it is for.
    try std.testing.expect(fuzzed > 20 and shifted > 50 and rejected > 20);
}

test "a written patch parses and applies back, forwards and in reverse" {
    try shakedown.check(std.testing.allocator, {}, support.patchOne, .{ .seed = 0x726f756e, .cases = 1500 });
}

test "fuzz: parse takes any bytes, failing only with its own errors" {
    try shakedown.check(std.testing.allocator, {}, support.parseOne, .{ .seed = 0x70617273, .cases = 1 });
}

test "fuzz: a written patch round-trips" {
    try shakedown.check(std.testing.allocator, {}, support.patchOne, .{ .seed = 0x726f756e, .cases = 1 });
}

test "parse takes any bytes, on seeded inputs" {
    try shakedown.check(std.testing.allocator, {}, support.parseOne, .{ .seed = 0x70617273, .cases = 3000 });
}

test "a base shifted by inserted lines applies with that offset" {
    const gpa = std.testing.allocator;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const old = "a\nb\nc\nd\ne\nf\ng\n";
    const new = "a\nb\nc\nD\ne\nf\ng\n";
    const diff = try d.lines(old, new, .{});
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try parallax.writeUnified(&text.writer, diff, .{ .files = .{ .old = "a/f", .new = "b/f" } });
    var p = try parallax.patch.parse(gpa, text.written(), .{});
    defer p.deinit();
    var results: [1]parallax.patch.HunkResult = undefined;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try parallax.patch.apply(gpa, &out.writer, "x\ny\nz\n" ++ old, p.files[0], .{}, &results);
    try std.testing.expectEqualStrings("x\ny\nz\n" ++ new, out.written());
    try std.testing.expectEqual(@as(i32, 3), results[0].applied.offset);
    // Too far for a cap of two.
    out.clearRetainingCapacity();
    try std.testing.expectError(error.HunkFailed, parallax.patch.apply(gpa, &out.writer, "x\ny\nz\n" ++ old, p.files[0], .{ .max_offset = 2 }, &results));
    try std.testing.expectEqual(parallax.patch.HunkResult.rejected, results[0]);
}

test "a reversed or already applied patch is noticed where GNU patch notices it" {
    const gpa = std.testing.allocator;
    const c = try corpus.Corpus.parse(reversed_corpus);
    try std.testing.expectEqualStrings("GNU patch 2.8", c.git_version);
    var it = c.records();
    var count: usize = 0;
    var detected: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("reversed.corpus record {d}, flags {s}\n", .{ r.index, r.fields[0] });
        var options = try applyOptions(r.fields[0]);
        var p = try parallax.patch.parse(gpa, r.fields[2], .{});
        defer p.deinit();
        const file = p.files[0];
        const results = try gpa.alloc(parallax.patch.HunkResult, file.hunks.len);
        defer gpa.free(results);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var hint = false;
        options.reversed_hint = &hint;
        try parallax.patch.apply(gpa, &out.writer, r.fields[1], file, options, results);
        try std.testing.expectEqual(std.mem.eql(u8, r.fields[6], "1"), hint);
        if (hint) {
            // GNU patch's -t: the other way round.
            detected += 1;
            options.reverse = !options.reverse;
            options.reversed_hint = null;
            out.clearRetainingCapacity();
            try parallax.patch.apply(gpa, &out.writer, r.fields[1], file, options, results);
        }
        try std.testing.expectEqualStrings(r.fields[3], out.written());
        const all = try expectFates(r.fields[5], results);
        try std.testing.expectEqual(@as(u32, if (all) 0 else 1), try std.fmt.parseInt(u32, r.fields[4], 10));
    }
    try std.testing.expectEqual(@as(usize, 400), count);
    try std.testing.expect(detected > 100);
}
