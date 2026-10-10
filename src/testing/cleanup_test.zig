//! The cleanups against the reference's own, captured once as data
//! (`testdata/cleanup-20241021/`): its diff of each pair, cleaned
//! up by parallax's passes over a character script, must come out as
//! the reference semantic and efficiency cleanups
//! leave it.

const std = @import("std");
const parallax = @import("../parallax.zig");
const cleanup = @import("../cleanup.zig");
const corpus = @import("corpus.zig");

const cleanup_corpus = @embedFile("cleanup.corpus");

const Change = parallax.Change;

/// One side cut into UTF-8 characters, interned.
const Chars = struct {
    ends: std.ArrayList(u32) = .empty,
    ids: std.ArrayList(u32) = .empty,

    fn deinit(c: *Chars, gpa: std.mem.Allocator) void {
        c.ends.deinit(gpa);
        c.ids.deinit(gpa);
        c.* = undefined;
    }

    fn load(c: *Chars, gpa: std.mem.Allocator, interner: anytype, text: []const u8) !cleanup.Side {
        c.ends.clearRetainingCapacity();
        c.ids.clearRetainingCapacity();
        var at: usize = 0;
        while (at < text.len) {
            const end = at + (std.unicode.utf8ByteSequenceLength(text[at]) catch 1);
            try c.ends.append(gpa, @intCast(end));
            try c.ids.append(gpa, (try interner.intern(text[at..end])).raw());
            at = end;
        }
        return .{ .ids = c.ids.items, .text = text, .from = 0, .ends = c.ends.items };
    }
};

/// the reference's operations ("=3", "-2", "+4", one a line) as a
/// script.
fn script(gpa: std.mem.Allocator, out: *std.ArrayList(Change), ops: []const u8) !void {
    out.clearRetainingCapacity();
    var old: u32 = 0;
    var new: u32 = 0;
    var open: ?Change = null;
    var lines = std.mem.splitScalar(u8, ops, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const n = try std.fmt.parseInt(u32, line[1..], 10);
        if (n == 0) continue;
        switch (line[0]) {
            '=' => {
                if (open) |c| try out.append(gpa, c);
                open = null;
                old += n;
                new += n;
            },
            '-', '+' => {
                var c = open orelse Change{ .old_start = old, .old_len = 0, .new_start = new, .new_len = 0 };
                if (line[0] == '-') {
                    c.old_len += n;
                    old += n;
                } else {
                    c.new_len += n;
                    new += n;
                }
                open = c;
            },
            else => return error.BadOperation,
        }
    }
    if (open) |c| try out.append(gpa, c);
}

test "the cleanups leave the reference's diffs as the reference does" {
    const gpa = std.testing.allocator;
    const c = try corpus.Corpus.parse(cleanup_corpus);
    try std.testing.expectEqualStrings("reference cleanups 20241021", c.git_version);
    var interner: parallax.Interner([]const u8, std.hash_map.StringContext) = .init(gpa, .{});
    defer interner.deinit();
    var old: Chars = .{};
    defer old.deinit(gpa);
    var new: Chars = .{};
    defer new.deinit(gpa);
    var buffers: cleanup.Buffers = .{};
    defer buffers.deinit(gpa);
    var got: std.ArrayList(Change) = .empty;
    defer got.deinit(gpa);
    var want: std.ArrayList(Change) = .empty;
    defer want.deinit(gpa);
    var it = c.records();
    var count: usize = 0;
    var changed: usize = 0;
    while (it.next()) |r| : (count += 1) {
        interner.clear();
        const old_side = try old.load(gpa, &interner, r.fields[0]);
        const new_side = try new.load(gpa, &interner, r.fields[1]);
        for ([_]struct { cleanup.Cleanup, u32, usize }{ .{ .semantic, 4, 3 }, .{ .efficiency, 4, 4 }, .{ .efficiency, 6, 5 } }) |pass| {
            errdefer std.debug.print("cleanup.corpus record {d}, {t} {d}\n", .{ r.index, pass[0], pass[1] });
            try script(gpa, &got, r.fields[2]);
            try script(gpa, &want, r.fields[pass[2]]);
            if (!std.mem.eql(u8, std.mem.sliceAsBytes(got.items), std.mem.sliceAsBytes(want.items))) changed += 1;
            try cleanup.run(.{ .gpa = gpa, .buffers = &buffers, .old = old_side, .new = new_side, .edit_cost = pass[1] }, pass[0], &got);
            try std.testing.expectEqualSlices(Change, want.items, got.items);
        }
    }
    try std.testing.expectEqual(@as(usize, 609), count);
    // The corpus exercises what it is for.
    try std.testing.expect(changed > 300);
}
