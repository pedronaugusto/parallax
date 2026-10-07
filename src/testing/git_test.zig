//! parallax against git's own output, captured once as data
//! (`testdata/git-2.55/`): edit scripts under every algorithm, unified
//! bodies under every flag, and merges in every style, level and writer
//! option.

const std = @import("std");
const parallax = @import("../parallax.zig");
const corpus = @import("corpus.zig");

const diff_corpus = @embedFile("diff.corpus");
const unified_corpus = @embedFile("unified.corpus");
const merge_corpus = @embedFile("merge.corpus");

fn startsWithPredicate(context: ?*const anyopaque, line: []const u8) bool {
    const prefix: *const []const u8 = @ptrCast(@alignCast(context.?));
    return std.mem.startsWith(u8, line, prefix.*);
}

/// git's diff flags as parallax options.
const DiffFlags = struct {
    options: parallax.Options = .{},
    unified: parallax.UnifiedOptions = .{ .heading = .c_function },
    anchors: [4][]const u8 = undefined,
    anchor_count: usize = 0,
    ignore_prefix: []const u8 = "",

    fn parse(f: *DiffFlags, field: []const u8) !void {
        var it = corpus.flags(field);
        while (it.next()) |flag| {
            if (flag.len == 0) continue;
            if (std.mem.startsWith(u8, flag, "-U")) {
                f.unified.hunks.context = try std.fmt.parseInt(u32, flag[2..], 10);
            } else if (std.mem.startsWith(u8, flag, "--inter-hunk-context=")) {
                f.unified.hunks.inter_hunk_context = try std.fmt.parseInt(u32, flag["--inter-hunk-context=".len..], 10);
            } else if (std.mem.eql(u8, flag, "-w")) {
                f.options.compare.whitespace.all = true;
            } else if (std.mem.eql(u8, flag, "-b")) {
                f.options.compare.whitespace.change = true;
            } else if (std.mem.eql(u8, flag, "--ignore-space-at-eol")) {
                f.options.compare.whitespace.at_eol = true;
            } else if (std.mem.eql(u8, flag, "--ignore-cr-at-eol")) {
                f.options.compare.whitespace.cr_at_eol = true;
            } else if (std.mem.eql(u8, flag, "--ignore-blank-lines")) {
                f.unified.hunks.ignore_blank_lines = true;
            } else if (std.mem.startsWith(u8, flag, "-I^")) {
                f.ignore_prefix = flag[3..];
            } else if (std.mem.eql(u8, flag, "--patience")) {
                f.options.algorithm = .patience;
            } else if (std.mem.eql(u8, flag, "--histogram")) {
                f.options.algorithm = .histogram;
            } else if (std.mem.eql(u8, flag, "--minimal")) {
                f.options.minimal = true;
            } else if (std.mem.eql(u8, flag, "--no-indent-heuristic")) {
                f.options.indent_heuristic = false;
            } else if (std.mem.startsWith(u8, flag, "--anchored=")) {
                f.options.algorithm = .patience;
                f.anchors[f.anchor_count] = flag["--anchored=".len..];
                f.anchor_count += 1;
            } else {
                std.debug.print("unknown flag {s}\n", .{flag});
                return error.UnknownFlag;
            }
        }
    }

    /// Point the options at this value's own storage; call after it stops
    /// moving.
    fn bind(f: *DiffFlags) void {
        f.options.anchors = f.anchors[0..f.anchor_count];
        if (f.ignore_prefix.len != 0) f.unified.hunks.ignore = .{ .context = @ptrCast(&f.ignore_prefix), .at = startsWithPredicate };
    }
};

fn expectBody(d: *parallax.Differ, flags: *DiffFlags, old: []const u8, new: []const u8, expected: []const u8) !void {
    const diff = try d.lines(old, new, flags.options);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try parallax.writeUnified(&out.writer, diff, flags.unified);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "edit scripts land on the lines git's do, under every algorithm" {
    const c = try corpus.Corpus.parse(diff_corpus);
    try std.testing.expectEqualStrings("git version 2.55.0", c.git_version);
    const variants = [_][]const u8{ "-U0", "-U0\n--minimal", "-U0\n--patience", "-U0\n--histogram", "-U0\n--no-indent-heuristic" };
    try std.testing.expectEqual(@as(usize, 2 + variants.len), c.fields);
    var d: parallax.Differ = .init(std.testing.allocator);
    defer d.deinit();
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        for (variants, 0..) |v, i| {
            var flags: DiffFlags = .{};
            try flags.parse(v);
            flags.bind();
            expectBody(&d, &flags, r.fields[0], r.fields[1], r.fields[2 + i]) catch |err| {
                std.debug.print("diff.corpus record {d}, variant {s}\n", .{ r.index, v });
                return err;
            };
        }
    }
    try std.testing.expectEqual(@as(usize, 600), count);
}

test "unified bodies are byte for byte what git prints, under every flag" {
    const c = try corpus.Corpus.parse(unified_corpus);
    var d: parallax.Differ = .init(std.testing.allocator);
    defer d.deinit();
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        var flags: DiffFlags = .{};
        try flags.parse(r.fields[0]);
        flags.bind();
        expectBody(&d, &flags, r.fields[1], r.fields[2], r.fields[3]) catch |err| {
            std.debug.print("unified.corpus record {d}, flags {s}\n", .{ r.index, r.fields[0] });
            return err;
        };
    }
    try std.testing.expectEqual(@as(usize, 1483), count);
}

/// git merge-file's (or merge-tree's) flags as parallax options.
const MergeFlags = struct {
    options: parallax.merge.Options = .{},
    write: parallax.merge.WriteOptions = .{},
    tree: bool = false,

    fn parse(f: *MergeFlags, field: []const u8) !void {
        var it = corpus.flags(field);
        var label: usize = 0;
        while (it.next()) |flag| {
            if (flag.len == 0) continue;
            if (std.mem.eql(u8, flag, "--diff3")) {
                f.options.style = .diff3;
            } else if (std.mem.eql(u8, flag, "--zdiff3")) {
                f.options.style = .zdiff3;
            } else if (std.mem.eql(u8, flag, "--diff-algorithm=minimal")) {
                f.options.minimal = true;
            } else if (std.mem.eql(u8, flag, "--diff-algorithm=patience")) {
                f.options.algorithm = .patience;
            } else if (std.mem.eql(u8, flag, "--diff-algorithm=histogram")) {
                f.options.algorithm = .histogram;
            } else if (std.mem.startsWith(u8, flag, "--marker-size=")) {
                f.write.marker_size = try std.fmt.parseInt(u32, flag["--marker-size=".len..], 10);
            } else if (std.mem.eql(u8, flag, "--ours")) {
                f.write.resolve = .ours;
            } else if (std.mem.eql(u8, flag, "--theirs")) {
                f.write.resolve = .theirs;
            } else if (std.mem.eql(u8, flag, "--union")) {
                f.write.resolve = .both;
            } else if (std.mem.eql(u8, flag, "-L")) {
                const text = it.next().?;
                switch (label) {
                    0 => f.write.labels.ours = text,
                    1 => f.write.labels.base = text,
                    else => f.write.labels.theirs = text,
                }
                label += 1;
            } else if (std.mem.eql(u8, flag, "merge-tree")) {
                // The merge machinery: histogram at the zealous level.
                f.tree = true;
                f.options.algorithm = .histogram;
                f.options.level = .zealous;
                f.write.labels = .{ .ours = "ours", .theirs = "theirs" };
            } else if (std.mem.startsWith(u8, flag, "-X")) {
                const ws = &f.options.compare.whitespace;
                const x = flag[2..];
                if (std.mem.eql(u8, x, "ignore-space-change")) ws.change = true else if (std.mem.eql(u8, x, "ignore-all-space")) ws.all = true else if (std.mem.eql(u8, x, "ignore-space-at-eol")) ws.at_eol = true else if (std.mem.eql(u8, x, "ignore-cr-at-eol")) ws.cr_at_eol = true else return error.UnknownFlag;
            } else {
                std.debug.print("unknown flag {s}\n", .{flag});
                return error.UnknownFlag;
            }
        }
    }
};

test "merges are what git merge-file and merge-tree write, in every style, level and option" {
    const gpa = std.testing.allocator;
    const c = try corpus.Corpus.parse(merge_corpus);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        var flags: MergeFlags = .{};
        try flags.parse(r.fields[0]);
        const m = try d.merge(r.fields[1], r.fields[2], r.fields[3], flags.options);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try parallax.merge.write(&out.writer, m, flags.write);
        const status = try std.fmt.parseInt(u32, r.fields[5], 10);
        const conflicts = if (flags.write.resolve == .markers) m.conflicts else 0;
        errdefer std.debug.print("merge.corpus record {d}, flags {s}\n", .{ r.index, r.fields[0] });
        try std.testing.expectEqualStrings(r.fields[4], out.written());
        if (flags.tree) {
            try std.testing.expectEqual(status == 1, conflicts != 0);
        } else {
            try std.testing.expectEqual(status, conflicts);
        }
    }
    try std.testing.expectEqual(@as(usize, 3015), count);
}
