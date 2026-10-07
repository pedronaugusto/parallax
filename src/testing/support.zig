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
    var o = options(s);
    // A stop flag raised before the call: the script is coarse, and still
    // applies.
    const raised: std.atomic.Value(bool) = .init(true);
    if (s.oneIn(6)) o.stop = &raised;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines(old, new, o);
    try expectApplies(diff);
    const hunk_options: parallax.HunkOptions = .{
        .context = @intCast(s.index(4)),
        .inter_hunk_context = @intCast(s.index(3)),
        .ignore_blank_lines = s.oneIn(4),
    };
    try expectHunks(diff, hunk_options);
    // Whole functions: the same, except that a hunk may overlap the one
    // before, as git's do.
    var whole = hunk_options;
    whole.function_context = .c_function;
    try expectHunks(diff, whole);
    if (o.stop != null) return;
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

/// The hunks of `diff` are in bounds, ascend, hold their changes, and cover
/// every change at most once (with no ignorable change, exactly once);
/// without whole functions they never overlap.
fn expectHunks(diff: parallax.Diff, hunk_options: parallax.HunkOptions) !void {
    var it = diff.hunks(hunk_options);
    var covered: usize = 0;
    var old_end: u32 = 0;
    var new_end: u32 = 0;
    var next_change: usize = 0;
    while (it.next()) |h| {
        try std.testing.expect(h.old_start + h.old_len <= diff.old.len());
        try std.testing.expect(h.new_start + h.new_len <= diff.new.len());
        // Whole functions may overlap the hunk before, as git's do.
        if (hunk_options.function_context == null) try std.testing.expect(h.old_start >= old_end and h.new_start >= new_end);
        try std.testing.expect(h.changes.len != 0);
        var first = next_change;
        while (diff.changes[first].old_start != h.changes[0].old_start) first += 1;
        next_change = first + h.changes.len;
        for (h.changes) |c| {
            try std.testing.expect(c.old_start >= h.old_start and c.old_start + c.old_len <= h.old_start + h.old_len);
            try std.testing.expect(c.new_start >= h.new_start and c.new_start + c.new_len <= h.new_start + h.new_len);
        }
        old_end = h.old_start + h.old_len;
        new_end = h.new_start + h.new_len;
        covered += h.changes.len;
    }
    if (!hunk_options.ignore_blank_lines) try std.testing.expectEqual(diff.changes.len, covered);
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
    // resolution, outside text and their part the theirs one, and each
    // conflict's parts are its regions' lines.
    var read_ours: std.ArrayList(u8) = .empty;
    defer read_ours.deinit(gpa);
    var read_theirs: std.ArrayList(u8) = .empty;
    defer read_theirs.deinit(gpa);
    var conflicts: u32 = 0;
    var marked = parallax.merge.parseMarkers(markers.written(), .{});
    var region_at: usize = 0;
    while (try marked.next()) |part| switch (part) {
        .text => |t| {
            try read_ours.appendSlice(gpa, t);
            try read_theirs.appendSlice(gpa, t);
        },
        .conflict => |c| {
            conflicts += 1;
            while (m.regions[region_at].kind != .conflict) region_at += 1;
            const r = m.regions[region_at];
            region_at += 1;
            try expectSide(c.ours, m.ours.span(r.ours.start, r.ours.len));
            try expectSide(c.theirs, m.theirs.span(r.theirs.start, r.theirs.len));
            if (m.style == .merge) {
                try std.testing.expect(c.base == null);
            } else try expectSide(c.base.?, m.base.span(r.base.start, r.base.len));
            try std.testing.expectEqualStrings("ours", c.labels.ours);
            try std.testing.expectEqualStrings("theirs", c.labels.theirs);
            try read_ours.appendSlice(gpa, c.ours);
            try read_theirs.appendSlice(gpa, c.theirs);
        },
    };
    try std.testing.expectEqual(m.conflicts, conflicts);
    try std.testing.expectEqualStrings(as_ours.written(), read_ours.items);
    try std.testing.expectEqualStrings(as_theirs.written(), read_theirs.items);

    // The same merge over interned lines gives the same regions.
    if (o.compare.exact()) try expectSequenceMerge(&d, m, o);

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

/// A side read back from markers is its region's lines, a newline added
/// to a last line without one.
fn expectSide(read: []const u8, lines: []const u8) !void {
    if (lines.len != 0 and lines[lines.len - 1] != '\n') {
        try std.testing.expectEqualStrings(lines, read[0..lines.len]);
        try std.testing.expect(std.mem.eql(u8, read[lines.len..], "\n") or std.mem.eql(u8, read[lines.len..], "\r\n"));
    } else try std.testing.expectEqualStrings(lines, read);
}

fn hasContent(context: ?*const anyopaque, i: u32) bool {
    const lines: *const parallax.Lines = @ptrCast(@alignCast(context.?)); // safe: the caller passes its Lines
    for (lines.get(i)) |c| if (std.ascii.isAlphanumeric(c)) return true;
    return false;
}

/// `m`, merged again over interned lines, gives the same regions.
fn expectSequenceMerge(d: *parallax.Differ, m: parallax.merge.Merge, o: parallax.merge.Options) !void {
    const gpa = std.testing.allocator;
    var interner: parallax.Interner([]const u8, std.hash_map.StringContext) = .init(gpa, .{});
    defer interner.deinit();
    var ids: [3][]u32 = undefined;
    var made: usize = 0;
    defer for (ids[0..made]) |side| gpa.free(side);
    for (&ids, [_]parallax.Lines{ m.base, m.ours, m.theirs }) |*side, lines| {
        side.* = try gpa.alloc(u32, lines.len());
        made += 1;
        for (side.*, 0..) |*id, i| id.* = try interner.intern(lines.get(@intCast(i)));
    }
    const regions = try gpa.dupe(parallax.merge.Region, m.regions);
    defer gpa.free(regions);
    const ours = m.ours;
    const sequence = try d.mergeSequences(ids[0], ids[1], ids[2], .{
        .algorithm = o.algorithm,
        .minimal = o.minimal,
        .classes = interner.classes(),
        .style = o.style,
        .level = o.level,
        .content = .{ .context = @ptrCast(&ours), .at = hasContent }, // safe: hasContent reads it back as Lines
    });
    try std.testing.expectEqual(m.conflicts, sequence.conflicts);
    try std.testing.expectEqualSlices(parallax.merge.Region, regions, sequence.regions);
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

/// One random diff, every change refined: the spans tile the change's
/// lines on each side, none crosses a line end, the unchanged spans read the
/// same on both sides, and a change with an empty side gives one changed
/// span per line.
pub fn refineOne(s: Source) !void {
    const gpa = std.testing.allocator;
    var a_buf: [256]u8 = undefined;
    var b_buf: [320]u8 = undefined;
    const old = text(s, &a_buf);
    const new = edit(s, old, &b_buf);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines(old, new, .{});
    const tokens: parallax.Tokens = @fromBackingInt(@intCast(s.index(3)));
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    const ignore = s.oneIn(3);
    for (diff.changes) |c| {
        const r = try d.refine(diff, c, .{
            .tokens = tokens,
            .algorithm = algorithms[s.index(3)],
            .compare = if (ignore) .{ .ignore_case = true } else .{},
            .cleanup = @fromBackingInt(@intCast(s.index(3))),
            .edit_cost = @intCast(1 + s.index(6)),
        });
        try expectTiles(diff.old, c.old_start, c.old_len, r.old, c.new_len == 0);
        try expectTiles(diff.new, c.new_start, c.new_len, r.new, c.old_len == 0);
        if (ignore or c.old_len == 0 or c.new_len == 0) continue;
        var kept_old: std.ArrayList(u8) = .empty;
        defer kept_old.deinit(gpa);
        var kept_new: std.ArrayList(u8) = .empty;
        defer kept_new.deinit(gpa);
        for (r.old) |span| if (!span.changed) try kept_old.appendSlice(gpa, diff.old.text[span.start..][0..span.len]);
        for (r.new) |span| if (!span.changed) try kept_new.appendSlice(gpa, diff.new.text[span.start..][0..span.len]);
        try std.testing.expectEqualStrings(kept_old.items, kept_new.items);
    }
}

fn expectTiles(lines: parallax.Lines, start: u32, len: u32, spans: []const parallax.Span, one_per_line: bool) !void {
    if (len == 0) return std.testing.expectEqual(@as(usize, 0), spans.len);
    var at = lines.start(start);
    for (spans) |span| {
        try std.testing.expectEqual(at, span.start);
        try std.testing.expect(span.len != 0);
        const bytes = lines.text[span.start..][0..span.len];
        if (std.mem.findScalar(u8, bytes, '\n')) |nl| try std.testing.expectEqual(bytes.len - 1, nl);
        if (one_per_line) try std.testing.expect(span.changed);
        at += span.len;
    }
    try std.testing.expectEqual(lines.ends[start + len - 1], at);
    if (one_per_line) try std.testing.expectEqual(@as(usize, len), spans.len);
}

/// Random id sequences under every algorithm: the script applies.
pub fn sequenceOne(s: Source) !void {
    const gpa = std.testing.allocator;
    var old: [64]u32 = undefined;
    var new: [64]u32 = undefined;
    const classes: u32 = @intCast(1 + s.index(8));
    const n_old = s.index(old.len);
    const n_new = s.index(new.len);
    for (old[0..n_old]) |*id| id.* = @intCast(s.index(classes));
    for (new[0..n_new], 0..) |*id, i| id.* = if (i < n_old and !s.oneIn(3)) old[i] else @intCast(s.index(classes));
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    const changes = try d.sequences(old[0..n_old], new[0..n_new], .{
        .classes = classes,
        .algorithm = algorithms[s.index(3)],
        .minimal = s.boolean(),
        .max_work = if (s.oneIn(4)) 2 else 0,
    });
    var at_old: u32 = 0;
    var at_new: u32 = 0;
    for (changes) |c| {
        try std.testing.expectEqualSlices(u32, old[at_old..c.old_start], new[at_new..c.new_start]);
        at_old = c.old_start + c.old_len;
        at_new = c.new_start + c.new_len;
    }
    try std.testing.expectEqualSlices(u32, old[at_old..n_old], new[at_new..n_new]);
}

/// An allocator that never grows or moves memory in place, so the number
/// of allocations a call makes is the same on every run: the backing for
/// `std.testing.checkAllAllocationFailures`.
pub const NoResize = struct {
    inner: std.mem.Allocator,

    pub fn allocator(n: *NoResize) std.mem.Allocator {
        return .{ .ptr = n, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const n: *NoResize = @ptrCast(@alignCast(ctx)); // safe: ctx is the NoResize this allocator was made from
        return n.inner.rawAlloc(len, a, ra);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const n: *NoResize = @ptrCast(@alignCast(ctx)); // safe: ctx is the NoResize this allocator was made from
        n.inner.rawFree(m, a, ra);
    }
};

/// A random diff written as a patch: it parses back to its own hunks and
/// applies to the old side to give the new, and backwards.
pub fn patchOne(s: Source) !void {
    const gpa = std.testing.allocator;
    var a_buf: [256]u8 = undefined;
    var b_buf: [320]u8 = undefined;
    const old = text(s, &a_buf);
    const new = if (s.oneIn(4)) text(s, &b_buf) else edit(s, old, &b_buf);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    const diff = try d.lines(old, new, .{ .algorithm = algorithms[s.index(3)] });
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try parallax.writeUnified(&written.writer, diff, .{
        .hunks = .{ .context = @intCast(s.index(6)), .inter_hunk_context = @intCast(s.index(3)) },
        .heading = if (s.boolean()) .c_function else null,
        .files = .{ .old = "a/f", .new = "b/f" },
    });
    var p = try parallax.patch.parse(gpa, written.written(), .{});
    defer p.deinit();
    if (diff.changes.len == 0) return std.testing.expectEqual(@as(usize, 0), p.files.len);
    try std.testing.expectEqual(@as(usize, 1), p.files.len);
    const file = p.files[0];
    try std.testing.expectEqualStrings("a/f", file.old_name.?);
    for (file.hunks) |h| {
        var old_lines: u32 = 0;
        var new_lines: u32 = 0;
        for (h.lines) |line| {
            old_lines += @intFromBool(line.kind != .added);
            new_lines += @intFromBool(line.kind != .removed);
        }
        try std.testing.expectEqual(h.old_len, old_lines);
        try std.testing.expectEqual(h.new_len, new_lines);
    }
    for ([_]bool{ false, true }) |reverse| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        // A patch that applies as given is never taken for a reversed one.
        var hint = true;
        try parallax.patch.apply(gpa, &out.writer, if (reverse) new else old, file, .{ .reverse = reverse, .reversed_hint = &hint }, null);
        try std.testing.expectEqualStrings(if (reverse) old else new, out.written());
        try std.testing.expect(!hint);
    }
}

/// Patch-shaped bytes: the parse returns a patch or one of its own errors,
/// and every hunk it returns holds the lines its header counts.
pub fn parseOne(s: Source) !void {
    const pieces = [_][]const u8{
        "--- a/f\n", "+++ b/f\n",                      "@@ -1,2 +1 @@\n",      "@@ -0,0 +1 @@ h\n", "@@ -1 +1,2 @@\n", " a\n", "-b\n",
        "+c\n",      "\\ No newline at end of file\n", "diff --git a/f b/f\n", "\n",                "x\n",             "@@ -", "+++ ",
        "--- ",
    };
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    while (!s.oneIn(40)) {
        const p = pieces[s.index(pieces.len)];
        if (len + p.len > buf.len) break;
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    var diagnostics: parallax.patch.Diagnostics = .{};
    var p = parallax.patch.parse(std.testing.allocator, buf[0..len], .{ .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.InvalidHunkHeader, error.HunkLengthMismatch, error.UnexpectedLine => {
            try std.testing.expect(diagnostics.line != 0);
            return;
        },
        error.OutOfMemory => return err,
    };
    defer p.deinit();
    for (p.files) |f| for (f.hunks) |h| {
        var old_lines: u32 = 0;
        var new_lines: u32 = 0;
        for (h.lines) |line| {
            old_lines += @intFromBool(line.kind != .added);
            new_lines += @intFromBool(line.kind != .removed);
        }
        try std.testing.expectEqual(h.old_len, old_lines);
        try std.testing.expectEqual(h.new_len, new_lines);
    };
}

/// Marker-shaped bytes: the parts tile the text, a conflict's pieces lie
/// inside it in order, and only the iterator's own errors come back.
pub fn markersOne(s: Source) !void {
    const pieces = [_][]const u8{
        "<<<<<<< a\n", "<<<<<<<\n", "|||||||\n", "||||||| b\n", "=======\n", "=======\r\n",  ">>>>>>> c\n",
        ">>>>>>>\n",   "<<<\n",     "x\n",       "y",           "\n",        "<<<<<<<< z\n", "=",
    };
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    while (!s.oneIn(30)) {
        const p = pieces[s.index(pieces.len)];
        if (len + p.len > buf.len) break;
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    const marked = buf[0..len];
    var it = parallax.merge.parseMarkers(marked, .{ .marker_size = if (s.oneIn(4)) 3 else 7 });
    var at: usize = 0;
    while (true) {
        const part = it.next() catch |err| switch (err) {
            error.UnterminatedConflict, error.MisplacedMarker, error.TooDeep => {
                try std.testing.expect(it.line != 0);
                return;
            },
        } orelse break;
        const bytes = switch (part) {
            .text => |t| t,
            .conflict => |c| blk: {
                for ([_]?[]const u8{ c.ours, c.base, c.theirs }) |piece| {
                    const p = piece orelse continue;
                    try std.testing.expect(std.mem.find(u8, c.whole, p) != null);
                }
                break :blk c.whole;
            },
        };
        try std.testing.expectEqualStrings(marked[at..][0..bytes.len], bytes);
        try std.testing.expect(bytes.len != 0);
        at += bytes.len;
    }
    try std.testing.expectEqual(marked.len, at);
}
