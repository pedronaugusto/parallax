const std = @import("std");
const parallax = @import("parallax");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // --- README:usage ---
    // One workspace for many diffs: once warm it allocates nothing.
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    const diff = try differ.lines("a\nb\nc\n", "a\nB\nc\nd\n", .{ .algorithm = .histogram });
    std.debug.assert(diff.changes.len == 2);
    std.debug.assert(diff.stat().added == 2);
    // The unified body, as `git diff` prints it.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try parallax.writeUnified(&out.writer, diff, .{ .heading = .c_function });
    std.debug.assert(std.mem.eql(u8, out.written(), "@@ -1,3 +1,4 @@\n a\n-b\n+B\n c\n+d\n"));
    // --- README:usage ---
    try merging(gpa);
    try refining(gpa);
}

fn merging(gpa: std.mem.Allocator) !void {
    // --- README:merge ---
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    const m = try differ.merge("one\nbase\nend\n", "one\nours\nend\n", "one\ntheirs\nend\n", .{ .style = .diff3 });
    std.debug.assert(m.conflicts == 1);
    for (m.regions) |region| switch (region.kind) {
        .conflict => std.debug.assert(region.ours.start == 1),
        else => {},
    };
    // The text `git merge-file --diff3` writes.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try parallax.merge.write(&out.writer, m, .{ .labels = .{ .ours = "HEAD", .base = "base", .theirs = "topic" } });
    std.debug.assert(std.mem.startsWith(u8, out.written(), "one\n<<<<<<< HEAD\nours\n||||||| base\nbase\n=======\ntheirs\n>>>>>>> topic\n"));
    // --- README:merge ---
}

fn refining(gpa: std.mem.Allocator) !void {
    // --- README:refine ---
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    const old = "let total = sum(a, b);\n";
    const new = "let total = sum(a, c);\n";
    const diff = try differ.lines(old, new, .{});
    // Which words of a changed line differ, as spans that never cross a line.
    const refined = try differ.refine(diff, diff.changes[0], .{ .tokens = .words });
    for (refined.new) |span| {
        if (span.changed) std.debug.assert(std.mem.eql(u8, new[span.start..][0..span.len], "c"));
    }
    // Any sequence diffs once interned: here, words.
    var interner: parallax.Interner([]const u8, std.hash_map.StringContext) = .init(gpa, .{});
    defer interner.deinit();
    var a: [3]u32 = undefined;
    var b: [3]u32 = undefined;
    try interner.internSlice(&.{ "red", "green", "blue" }, &a);
    try interner.internSlice(&.{ "red", "yellow", "blue" }, &b);
    const changes = try differ.sequences(&a, &b, .{ .classes = interner.classes() });
    std.debug.assert(changes.len == 1);
    std.debug.assert(changes[0].old_start == 1);
    // --- README:refine ---
}
