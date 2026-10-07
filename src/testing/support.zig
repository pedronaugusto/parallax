//! Helpers the tests share: where random choices come from, input
//! generators, and the properties every diff and merge must have. The
//! properties run on seeded inputs in every `zig build test` and under the
//! fuzzer with `zig build test --fuzz`.

const std = @import("std");
const parallax = @import("../parallax.zig");
const compare = @import("../compare.zig");

const Smith = std.testing.Smith;
const Change = parallax.Change;

/// Where choices come from.
pub const Source = union(enum) {
    smith: *Smith,
    random: std.Random,

    /// A number below `n`, which must not be zero.
    pub fn index(s: Source, n: usize) usize {
        return switch (s) {
            .smith => |smith| smith.index(n),
            .random => |r| r.uintLessThan(usize, n),
        };
    }

    /// True about once in `n`.
    pub fn oneIn(s: Source, n: u64) bool {
        return switch (s) {
            .smith => |smith| smith.eosWeightedSimple(n - 1, 1),
            .random => |r| r.uintLessThan(u64, n) == 0,
        };
    }

    pub fn boolean(s: Source) bool {
        return s.index(2) == 1;
    }
};

/// Adapts a property over a `Source` to `std.testing.fuzz`.
pub fn fuzzed(comptime one: fn (Source) anyerror!void) fn (void, *Smith) anyerror!void {
    return struct {
        fn run(_: void, smith: *Smith) anyerror!void {
            return one(.{ .smith = smith });
        }
    }.run;
}

/// Runs `one` on `count` inputs from a seeded generator.
pub fn seeded(comptime one: fn (Source) anyerror!void, seed: u64, count: usize) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    for (0..count) |_| try one(.{ .random = prng.random() });
}

/// Lines from a few pieces, so that equal lines are common; whitespace and
/// carriage returns in the mix, and sometimes no final newline.
pub fn text(s: Source, buf: []u8) []u8 {
    const pieces = [_][]const u8{ "a", "b", "c", " ", "\t", "\r", "{", "}", "  x", "A" };
    var len: usize = 0;
    while (!s.oneIn(24)) {
        const n = s.index(4);
        if (len + n * 3 + 1 > buf.len) break;
        for (0..n) |_| {
            const p = pieces[s.index(pieces.len)];
            @memcpy(buf[len..][0..p.len], p);
            len += p.len;
        }
        buf[len] = '\n';
        len += 1;
    }
    if (len != 0 and s.oneIn(4)) len -= 1;
    return buf[0..len];
}

/// An edit of `base`: lines dropped, replaced, inserted or kept.
pub fn edit(s: Source, base: []const u8, buf: []u8) []u8 {
    const others = [_][]const u8{ "x\n", "y\n", "a\n", "{\n", "}\n", "a \n" };
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, base, '\n');
    while (it.next()) |line| {
        const last = it.peek() == null;
        if (last and line.len == 0) break;
        const choice = s.index(8);
        if (choice == 0) continue;
        if (choice == 1 or choice == 2) {
            const o = others[s.index(others.len)];
            if (len + o.len > buf.len) break;
            @memcpy(buf[len..][0..o.len], o);
            len += o.len;
            if (choice == 1) continue;
        }
        if (len + line.len + 1 > buf.len) break;
        @memcpy(buf[len..][0..line.len], line);
        len += line.len;
        if (!last or base.len == 0 or base[base.len - 1] == '\n') {
            buf[len] = '\n';
            len += 1;
        }
    }
    return buf[0..len];
}

pub fn options(s: Source) parallax.Options {
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    const caps = [_]u32{ 0, 0, 0, 1, 3, 20 };
    return .{
        .algorithm = algorithms[s.index(algorithms.len)],
        .minimal = s.oneIn(3),
        .indent_heuristic = !s.oneIn(3),
        .compare = .{
            .whitespace = .{ .all = s.oneIn(5), .change = s.oneIn(5), .at_eol = s.oneIn(5), .cr_at_eol = s.oneIn(5) },
            .ignore_case = s.oneIn(5),
        },
        .max_work = caps[s.index(caps.len)],
        .anchors = if (s.oneIn(4)) &.{ "a", "{" } else &.{},
    };
}

/// The script, applied to the old side, gives the new side: every run is in
/// bounds, ascends, and never touches the next, and the lines between runs
/// are the same line under the diff's comparison.
pub fn expectApplies(d: parallax.Diff) !void {
    var at_old: u32 = 0;
    var at_new: u32 = 0;
    for (d.changes, 0..) |c, i| {
        try std.testing.expect(c.old_len != 0 or c.new_len != 0);
        try std.testing.expect(c.old_start + c.old_len <= d.old.len());
        try std.testing.expect(c.new_start + c.new_len <= d.new.len());
        if (i > 0) {
            try std.testing.expect(c.old_start > at_old);
            try std.testing.expect(c.new_start > at_new);
        }
        try std.testing.expectEqual(c.old_start - at_old, c.new_start - at_new);
        try expectSameRun(d, at_old, at_new, c.old_start - at_old);
        at_old = c.old_start + c.old_len;
        at_new = c.new_start + c.new_len;
    }
    try std.testing.expectEqual(d.old.len() - at_old, d.new.len() - at_new);
    try expectSameRun(d, at_old, at_new, d.old.len() - at_old);
}

fn expectSameRun(d: parallax.Diff, old: u32, new: u32, n: u32) !void {
    for (0..n) |k| {
        const a = d.old.get(old + @as(u32, @intCast(k)));
        const b = d.new.get(new + @as(u32, @intCast(k)));
        try std.testing.expect(compare.sameForm(a, b, d.compare));
    }
}

/// One random pair under random options: the script applies, the hunks
/// cover every change once, and a minimal script is never longer.
pub fn diffOne(s: Source) !void {
    const gpa = std.testing.allocator;
    var a_buf: [256]u8 = undefined;
    var b_buf: [320]u8 = undefined;
    const old = text(s, &a_buf);
    const new = if (s.oneIn(3)) text(s, &b_buf) else edit(s, old, &b_buf);
    const o = options(s);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines(old, new, o);
    try expectApplies(diff);
    var it = diff.hunks(.{ .context = @intCast(s.index(4)), .inter_hunk_context = @intCast(s.index(3)) });
    var covered: usize = 0;
    while (it.next()) |h| {
        try std.testing.expect(h.old_start + h.old_len <= diff.old.len());
        try std.testing.expect(h.new_start + h.new_len <= diff.new.len());
        covered += h.changes.len;
    }
    try std.testing.expectEqual(diff.changes.len, covered);
    if (o.max_work == 0 and !o.minimal) {
        const plain = diff.stat();
        var exact = o;
        exact.minimal = true;
        exact.algorithm = .myers;
        const m = try d.lines(old, new, exact);
        const st = m.stat();
        try std.testing.expect(st.added + st.removed <= plain.added + plain.removed or o.algorithm != .myers);
    }
}

/// Two random lines under every comparison: one form means a match, and
/// matching is symmetric and reflexive.
pub fn sameLineOne(s: Source) !void {
    var buf: [64]u8 = undefined;
    const t = text(s, &buf);
    var lines = std.mem.splitScalar(u8, t, '\n');
    const first = lines.next() orelse "";
    const second = lines.next() orelse "";
    var pair: [2][]const u8 = .{ first, second };
    // Some with their newline, some without.
    var withnl: [2][80]u8 = undefined;
    for (&pair, 0..) |*l, i| {
        if (s.boolean() and l.len < 79) {
            @memcpy(withnl[i][0..l.len], l.*);
            withnl[i][l.len] = '\n';
            l.* = withnl[i][0 .. l.len + 1];
        }
    }
    for ([_]parallax.Compare{
        .{},
        .{ .whitespace = .{ .all = true } },
        .{ .whitespace = .{ .change = true } },
        .{ .whitespace = .{ .at_eol = true } },
        .{ .whitespace = .{ .cr_at_eol = true } },
        .{ .whitespace = .{ .change = true, .cr_at_eol = true } },
        .{ .ignore_case = true },
        .{ .ignore_case = true, .whitespace = .{ .change = true } },
    }) |c| {
        const same = compare.sameLine(pair[0], pair[1], c);
        try std.testing.expectEqual(same, compare.sameLine(pair[1], pair[0], c));
        if (compare.sameForm(pair[0], pair[1], c)) {
            try std.testing.expect(same);
            try std.testing.expectEqual(compare.hash(pair[0], c), compare.hash(pair[1], c));
        }
        try std.testing.expect(compare.sameLine(pair[0], pair[0], c));
    }
}

pub fn mergeOptions(s: Source) parallax.merge.Options {
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    return .{
        .algorithm = algorithms[s.index(algorithms.len)],
        .minimal = s.oneIn(3),
        .compare = .{ .whitespace = .{ .change = s.oneIn(5), .cr_at_eol = s.oneIn(5) } },
        .style = @fromBackingInt(@intCast(s.index(3))),
        .level = @fromBackingInt(@intCast(s.index(4))),
    };
}

/// Three random texts: the merge runs, its regions cover ours in order, an
/// unchanged side yields the other, resolving to one side leaves no marker,
/// and the markers read back give each side's resolution.
pub fn mergeOne(s: Source) !void {
    const gpa = std.testing.allocator;
    var bufs: [3][256]u8 = undefined;
    var base = text(s, &bufs[0]);
    // Whole lines only, so markers sit on lines of their own.
    if (base.len != 0 and base[base.len - 1] != '\n') {
        bufs[0][base.len] = '\n';
        base = bufs[0][0 .. base.len + 1];
    }
    const ours = edit(s, base, &bufs[1]);
    const theirs = edit(s, base, &bufs[2]);
    const o = mergeOptions(s);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();

    const m = try d.merge(base, ours, theirs, o);
    var at: u32 = 0;
    for (m.regions) |r| {
        try std.testing.expectEqual(at, r.ours.start);
        at += r.ours.len;
        try std.testing.expect(r.base.start + r.base.len <= m.base.len());
        try std.testing.expect(r.theirs.start + r.theirs.len <= m.theirs.len());
    }
    try std.testing.expectEqual(m.ours.len(), at);

    var markers: std.Io.Writer.Allocating = .init(gpa);
    defer markers.deinit();
    try parallax.merge.write(&markers.writer, m, .{});
    var as_ours: std.Io.Writer.Allocating = .init(gpa);
    defer as_ours.deinit();
    try parallax.merge.write(&as_ours.writer, m, .{ .resolve = .ours });
    var as_theirs: std.Io.Writer.Allocating = .init(gpa);
    defer as_theirs.deinit();
    try parallax.merge.write(&as_theirs.writer, m, .{ .resolve = .theirs });
    try std.testing.expect(std.mem.find(u8, as_ours.written(), "<<<<<<<") == null);

    // Read the markers back: outside text and our part is the ours
    // resolution, outside text and their part the theirs one.
    var read_ours: std.ArrayList(u8) = .empty;
    defer read_ours.deinit(gpa);
    var read_theirs: std.ArrayList(u8) = .empty;
    defer read_theirs.deinit(gpa);
    var state: enum { out, ours, base, theirs } = .out;
    var conflicts: u32 = 0;
    var lines = std.mem.splitScalar(u8, markers.written(), '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        if (std.mem.startsWith(u8, line, "<<<<<<< ")) {
            state = .ours;
            conflicts += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "||||||| ")) {
            state = .base;
            continue;
        }
        if (std.mem.eql(u8, line, "=======") or std.mem.eql(u8, line, "=======\r")) {
            state = .theirs;
            continue;
        }
        if (std.mem.startsWith(u8, line, ">>>>>>> ")) {
            state = .out;
            continue;
        }
        if (state == .out or state == .ours) try read_ours.print(gpa, "{s}\n", .{line});
        if (state == .out or state == .theirs) try read_theirs.print(gpa, "{s}\n", .{line});
    }
    try std.testing.expectEqual(m.conflicts, conflicts);
    try std.testing.expectEqualStrings(as_ours.written(), read_ours.items);
    try std.testing.expectEqualStrings(as_theirs.written(), read_theirs.items);

    // A side with no change gives the other side.
    const kept = try d.merge(base, ours, base, o);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try parallax.merge.write(&out.writer, kept, .{});
    try std.testing.expectEqualStrings(ours, out.written());
    try std.testing.expectEqual(@as(u32, 0), kept.conflicts);
    const taken = try d.merge(base, base, theirs, o);
    out.clearRetainingCapacity();
    try parallax.merge.write(&out.writer, taken, .{});
    try std.testing.expectEqualStrings(theirs, out.written());
}

/// `text` written `times` times, at compile time.
pub inline fn repeat(comptime bytes: []const u8, comptime times: usize) *const [bytes.len * times]u8 {
    comptime {
        @setEvalBranchQuota(4 * bytes.len * times + 1000);
        var out: [bytes.len * times]u8 = undefined;
        for (0..times) |i| @memcpy(out[i * bytes.len ..][0..bytes.len], bytes);
        const final = out;
        return &final;
    }
}
