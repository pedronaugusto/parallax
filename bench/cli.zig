//! A small command over parallax, for timing it end to end against other
//! tools: `cli diff [--histogram|--patience|--minimal] [-U N] OLD NEW`
//! writes a unified diff, `cli merge [--diff3|--zdiff3] OURS BASE THEIRS`
//! the merged text (exit 1 when it has conflicts), and `cli apply [-F N]
//! [-R] FILE PATCH` the file with the patch applied (exit 1 when a hunk is
//! rejected). Output goes to stdout.
const std = @import("std");
const parallax = @import("parallax");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--smoke")) return smoke(gpa);
    if (args.len < 2) return error.Usage;
    var files: std.ArrayList([]const u8) = .empty;
    var options: parallax.Options = .{};
    var context: u32 = 3;
    var style: parallax.merge.Style = .merge;
    var apply: parallax.patch.ApplyOptions = .{ .rejects = .skip };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--histogram")) {
            options.algorithm = .histogram;
        } else if (std.mem.eql(u8, a, "--patience")) {
            options.algorithm = .patience;
        } else if (std.mem.eql(u8, a, "--minimal")) {
            options.minimal = true;
        } else if (std.mem.eql(u8, a, "--diff3")) {
            style = .diff3;
        } else if (std.mem.eql(u8, a, "--zdiff3")) {
            style = .zdiff3;
        } else if (std.mem.eql(u8, a, "-R")) {
            apply.reverse = true;
        } else if (std.mem.eql(u8, a, "-U") or std.mem.eql(u8, a, "-F")) {
            i += 1;
            const n = try std.fmt.parseInt(u8, args[i], 10);
            if (a[1] == 'U') context = n else apply.fuzz = n;
        } else try files.append(arena, try std.Io.Dir.cwd().readFileAlloc(io, a, arena, .unlimited));
    }
    var buffer: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const w = &stdout.interface;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    var status: u8 = 0;
    const command = args[1];
    if (std.mem.eql(u8, command, "diff") and files.items.len == 2) {
        const diff = try d.lines(files.items[0], files.items[1], options);
        try parallax.writeUnified(w, diff, .{ .hunks = .{ .context = context }, .heading = .c_function, .files = .{ .old = args[args.len - 2], .new = args[args.len - 1] } });
        status = @intFromBool(diff.changes.len != 0);
    } else if (std.mem.eql(u8, command, "merge") and files.items.len == 3) {
        const m = try d.merge(files.items[1], files.items[0], files.items[2], .{ .style = style });
        try parallax.merge.write(w, m, .{ .labels = .{ .ours = args[args.len - 3], .base = args[args.len - 2], .theirs = args[args.len - 1] } });
        status = @intFromBool(m.conflicts != 0);
    } else if (std.mem.eql(u8, command, "apply") and files.items.len == 2) {
        var p = try parallax.patch.parse(gpa, files.items[1], .{});
        defer p.deinit();
        for (p.files) |file| {
            const results = try arena.alloc(parallax.patch.HunkResult, file.hunks.len);
            try parallax.patch.apply(gpa, w, files.items[0], file, apply, results);
            for (results) |r| status |= @intFromBool(r == .rejected);
        }
    } else return error.Usage;
    try w.flush();
    return status;
}

fn smoke(gpa: std.mem.Allocator) !u8 {
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const diff = try d.lines("a\nb\n", "a\nc\n", .{});
    try parallax.writeUnified(&out.writer, diff, .{ .files = .{ .old = "a/f", .new = "b/f" } });
    var patch = try parallax.patch.parse(gpa, out.written(), .{});
    defer patch.deinit();
    if (patch.files.len != 1) return error.SmokeFailed;
    out.clearRetainingCapacity();
    try parallax.patch.apply(gpa, &out.writer, "a\nb\n", patch.files[0], .{}, null);
    if (!std.mem.eql(u8, out.written(), "a\nc\n")) return error.SmokeFailed;
    const merged = try d.merge("a\nb\n", "a\nc\n", "a\nb\n", .{});
    out.clearRetainingCapacity();
    try parallax.merge.write(&out.writer, merged, .{});
    if (!std.mem.eql(u8, out.written(), "a\nc\n") or merged.conflicts != 0) return error.SmokeFailed;
    return 0;
}
