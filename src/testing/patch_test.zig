//! Patches: parse and apply against GNU patch's own results, captured once
//! as data (`testdata/gnu-patch-2.8/`), and the round trip through the
//! unified writer.

const std = @import("std");
const parallax = @import("../parallax.zig");
const corpus = @import("corpus.zig");
const support = @import("support.zig");

const patch_corpus = @embedFile("patch.corpus");

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
        var options: parallax.patch.ApplyOptions = .{ .rejects = .skip };
        var flags = corpus.flags(r.fields[0]);
        while (flags.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "-F")) {
                options.fuzz = try std.fmt.parseInt(u8, flag[2..], 10);
            } else if (std.mem.eql(u8, flag, "-R")) {
                options.reverse = true;
            } else return error.UnknownFlag;
        }
        var p = try parallax.patch.parse(gpa, r.fields[2], .{});
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 1), p.files.len);
        const file = p.files[0];
        const results = try gpa.alloc(parallax.patch.HunkResult, file.hunks.len);
        defer gpa.free(results);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try parallax.patch.apply(gpa, &out.writer, r.fields[1], file, options, results);
        try std.testing.expectEqualStrings(r.fields[3], out.written());

        // Each hunk's fate, as GNU patch reported it.
        var all_applied = true;
        var lines = std.mem.splitScalar(u8, r.fields[5], '\n');
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
                rejected += 1;
                continue;
            }
            const fuzz = try std.fmt.parseInt(u8, words.next().?, 10);
            const offset = try std.fmt.parseInt(i32, words.next().?, 10);
            const applied = results[n].applied;
            try std.testing.expectEqual(fuzz, applied.fuzz);
            try std.testing.expectEqual(offset, applied.offset);
            fuzzed += @intFromBool(fuzz != 0);
            shifted += @intFromBool(offset != 0);
        }
        try std.testing.expectEqual(file.hunks.len, n);
        try std.testing.expectEqual(@as(u32, if (all_applied) 0 else 1), try std.fmt.parseInt(u32, r.fields[4], 10));
    }
    try std.testing.expectEqual(@as(usize, 488), count);
    // The corpus exercises what it is for.
    try std.testing.expect(fuzzed > 20 and shifted > 50 and rejected > 20);
}

test "a written patch parses and applies back, forwards and in reverse" {
    try support.seeded(support.patchOne, 0x726f756e, 1500);
}

test "fuzz: parse takes any bytes, failing only with its own errors" {
    try std.testing.fuzz({}, support.fuzzed(support.parseOne), .{});
}

test "fuzz: a written patch round-trips" {
    try std.testing.fuzz({}, support.fuzzed(support.patchOne), .{});
}

test "parse takes any bytes, on seeded inputs" {
    try support.seeded(support.parseOne, 0x70617273, 3000);
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
