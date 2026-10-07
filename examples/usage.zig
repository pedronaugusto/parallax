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
}

fn merging(gpa: std.mem.Allocator) !void {
    // --- README:merge ---
    var differ: parallax.Differ = .init(gpa);
    defer differ.deinit();
    const m = try differ.merge("one\nbase\nend\n", "one\nours\nend\n", "one\ntheirs\nend\n", .{ .style = .diff3 });
    std.debug.assert(m.conflicts == 1);
    for (m.regions) |region| switch (region.kind) {
        .conflict => std.debug.assert(region.ours.start == 1 and region.ours.len == 1),
        else => {},
    };
    // The text `git merge-file --diff3` writes.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try parallax.merge.write(&out.writer, m, .{ .labels = .{ .ours = "HEAD", .base = "base", .theirs = "topic" } });
    std.debug.assert(std.mem.startsWith(u8, out.written(), "one\n<<<<<<< HEAD\nours\n||||||| base\nbase\n=======\ntheirs\n>>>>>>> topic\n"));
    // --- README:merge ---
}
