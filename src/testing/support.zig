//! Diff and merge assertions, with domain inputs composed from shakedown.gen.
//! shakedown.check runs, shrinks and replays these properties and feeds the fuzzer.

const std = @import("std");
const parallax = @import("../parallax.zig");
const compare = @import("parallax.compare");

const shakedown = @import("shakedown");
const gen = shakedown.gen;
const Change = parallax.Change;

const pieces = [_][]const u8{ "a", "b", "c", " ", "\t", "\r", "{", "}", "  x", "A" };
const Line = struct { count: u2, parts: [3][]const u8 };

fn drawLine(s: *shakedown.Source) Line {
    return .{ .count = gen.intRange(s, u2, 0, 3), .parts = .{
        gen.oneOf(s, []const u8, &pieces),
        gen.oneOf(s, []const u8, &pieces),
        gen.oneOf(s, []const u8, &pieces),
    } };
}

// Domain syntax assembled from shakedown's bounded, shrinkable list draws.
fn drawText(case: *shakedown.Case, buf: []u8) ![]u8 {
    const lines = try gen.slice(case.source, Line, drawLine, case.gpa, .{ .average = 23, .max_len = buf.len });
    var len: usize = 0;
    for (lines) |line| {
        if (len + @as(usize, line.count) * 3 + 1 > buf.len) break;
        for (line.parts[0..line.count]) |part| {
            @memcpy(buf[len..][0..part.len], part);
            len += part.len;
        }
        buf[len] = '\n';
        len += 1;
    }
    if (len != 0 and gen.weighted(case.source, &.{ 3, 1 }) == 1) len -= 1;
    return buf[0..len];
}

fn drawEdit(case: *shakedown.Case, base: []const u8, buf: []u8) []u8 {
    const others = [_][]const u8{ "x\n", "y\n", "a\n", "{\n", "}\n", "a \n" };
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, base, '\n');
    while (it.next()) |line| {
        const last = it.peek() == null;
        if (last and line.len == 0) break;
        const mark = case.source.begin();
        defer case.source.end(mark);
        const choice = gen.weighted(case.source, &.{ 5, 1, 1, 1 });
        if (choice == 1) continue;
        if (choice == 2 or choice == 3) {
            const o = gen.oneOf(case.source, []const u8, &others);
            if (len + o.len > buf.len) break;
            @memcpy(buf[len..][0..o.len], o);
            len += o.len;
            if (choice == 2) continue;
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

fn options(s: *shakedown.Source) parallax.Options {
    return .{
        .algorithm = gen.enumValue(s, parallax.Algorithm),
        .minimal = gen.weighted(s, &.{ 2, 1 }) == 1,
        .indent_heuristic = gen.weighted(s, &.{ 1, 2 }) == 1,
        .compare = .{
            .whitespace = .{ .all = gen.weighted(s, &.{ 4, 1 }) == 1, .change = gen.weighted(s, &.{ 4, 1 }) == 1, .at_eol = gen.weighted(s, &.{ 4, 1 }) == 1, .cr_at_eol = gen.weighted(s, &.{ 4, 1 }) == 1 },
            .ignore_case = gen.weighted(s, &.{ 4, 1 }) == 1,
        },
        .max_work = .fromRaw(gen.oneOf(s, u32, &.{ 0, 0, 0, 1, 3, 20 })),
        .anchors = if (gen.weighted(s, &.{ 3, 1 }) == 1) &.{ "a", "{" } else &.{},
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
pub fn diffOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = std.testing.allocator;
    var a_buf: [256]u8 = undefined;
    var b_buf: [320]u8 = undefined;
    const old = try drawText(case, &a_buf);
    const new = if (gen.weighted(s, &.{ 2, 1 }) == 1) try drawText(case, &b_buf) else drawEdit(case, old, &b_buf);
    var o = options(s);
    // A stop flag raised before the call: the script is coarse, and still
    // applies.
    const raised: std.atomic.Value(bool) = .init(true);
    if (gen.weighted(s, &.{ 5, 1 }) == 1) o.stop = &raised;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines(old, new, o);
    try expectApplies(diff);
    const hunk_options: parallax.HunkOptions = .{
        .context = @intCast(gen.intRange(s, usize, 0, 3)),
        .inter_hunk_context = @intCast(gen.intRange(s, usize, 0, 2)),
        .ignore_blank_lines = gen.weighted(s, &.{ 3, 1 }) == 1,
    };
    try expectHunks(diff, hunk_options);
    // Whole functions: the same, except that a hunk may overlap the one
    // before, as git's do.
    var whole = hunk_options;
    whole.function_context = .c_function;
    try expectHunks(diff, whole);
    if (o.stop != null) return;
    if (o.max_work.raw() == 0 and !o.minimal) {
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
pub fn sameLineOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var buf: [64]u8 = undefined;
    const t = try drawText(case, &buf);
    var lines = std.mem.splitScalar(u8, t, '\n');
    const first = lines.next() orelse "";
    const second = lines.next() orelse "";
    var pair: [2][]const u8 = .{ first, second };
    // Some with their newline, some without.
    var withnl: [2][80]u8 = undefined;
    for (&pair, 0..) |*l, i| {
        if (gen.boolean(s) and l.len < 79) {
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

fn mergeOptions(s: *shakedown.Source) parallax.merge.Options {
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    return .{
        .algorithm = algorithms[gen.intRange(s, usize, 0, algorithms.len - 1)],
        .minimal = gen.weighted(s, &.{ 2, 1 }) == 1,
        .compare = .{ .whitespace = .{ .change = gen.weighted(s, &.{ 4, 1 }) == 1, .cr_at_eol = gen.weighted(s, &.{ 4, 1 }) == 1 } },
        .style = @fromBackingInt(@intCast(gen.intRange(s, usize, 0, 2))),
        .level = @fromBackingInt(@intCast(gen.intRange(s, usize, 0, 3))),
    };
}

/// Three random texts: the merge runs, its regions cover ours in order, an
/// unchanged side yields the other, resolving to one side leaves no marker,
/// and the markers read back give each side's resolution.
pub fn mergeOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = std.testing.allocator;
    var bufs: [3][256]u8 = undefined;
    var base = try drawText(case, &bufs[0]);
    // Whole lines only, so markers sit on lines of their own.
    if (base.len != 0 and base[base.len - 1] != '\n') {
        bufs[0][base.len] = '\n';
        base = bufs[0][0 .. base.len + 1];
    }
    const ours = drawEdit(case, base, &bufs[1]);
    const theirs = drawEdit(case, base, &bufs[2]);
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
    var ids: [3][]parallax.ClassId = undefined;
    var made: usize = 0;
    defer for (ids[0..made]) |side| gpa.free(side);
    for (&ids, [_]parallax.Lines{ m.base, m.ours, m.theirs }) |*side, lines| {
        side.* = try gpa.alloc(parallax.ClassId, lines.len());
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

/// One random diff, every change refined: the spans tile the change's
/// lines on each side, none crosses a line end, the unchanged spans read the
/// same on both sides, and a change with an empty side gives one changed
/// span per line.
pub fn refineOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = std.testing.allocator;
    var a_buf: [256]u8 = undefined;
    var b_buf: [320]u8 = undefined;
    const old = try drawText(case, &a_buf);
    const new = drawEdit(case, old, &b_buf);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines(old, new, .{});
    const tokens: parallax.Tokens = @fromBackingInt(@intCast(gen.intRange(s, usize, 0, 2)));
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    const ignore = gen.weighted(s, &.{ 2, 1 }) == 1;
    for (diff.changes) |c| {
        const r = try d.refine(diff, c, .{
            .tokens = tokens,
            .algorithm = algorithms[gen.intRange(s, usize, 0, 2)],
            .compare = if (ignore) .{ .ignore_case = true } else .{},
            .cleanup = @fromBackingInt(@intCast(gen.intRange(s, usize, 0, 2))),
            .edit_cost = @intCast(1 + gen.intRange(s, usize, 0, 5)),
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
pub fn sequenceOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = std.testing.allocator;
    var old: [64]parallax.ClassId = undefined;
    var new: [64]parallax.ClassId = undefined;
    const classes: u32 = @intCast(1 + gen.intRange(s, usize, 0, 7));
    const n_old = gen.intRange(s, usize, 0, old.len - 1);
    const n_new = gen.intRange(s, usize, 0, new.len - 1);
    for (old[0..n_old]) |*id| id.* = .fromRaw(@intCast(gen.intRange(s, usize, 0, classes - 1)));
    for (new[0..n_new], 0..) |*id, i| id.* = if (i < n_old and !(gen.weighted(s, &.{ 2, 1 }) == 1)) old[i] else .fromRaw(@intCast(gen.intRange(s, usize, 0, classes - 1)));
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    const changes = try d.sequences(old[0..n_old], new[0..n_new], .{
        .classes = .fromRaw(classes),
        .algorithm = algorithms[gen.intRange(s, usize, 0, 2)],
        .minimal = gen.boolean(s),
        .max_work = .fromRaw(if (gen.weighted(s, &.{ 3, 1 }) == 1) 2 else 0),
    });
    var at_old: u32 = 0;
    var at_new: u32 = 0;
    for (changes) |c| {
        try std.testing.expectEqualSlices(parallax.ClassId, old[at_old..c.old_start], new[at_new..c.new_start]);
        at_old = c.old_start + c.old_len;
        at_new = c.new_start + c.new_len;
    }
    try std.testing.expectEqualSlices(parallax.ClassId, old[at_old..n_old], new[at_new..n_new]);
}

/// A random diff written as a patch: it parses back to its own hunks and
/// applies to the old side to give the new, and backwards.
pub fn patchOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = std.testing.allocator;
    var a_buf: [256]u8 = undefined;
    var b_buf: [320]u8 = undefined;
    const old = try drawText(case, &a_buf);
    const new = if (gen.weighted(s, &.{ 3, 1 }) == 1) try drawText(case, &b_buf) else drawEdit(case, old, &b_buf);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const algorithms = [_]parallax.Algorithm{ .myers, .patience, .histogram };
    const diff = try d.lines(old, new, .{ .algorithm = algorithms[gen.intRange(s, usize, 0, 2)] });
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try parallax.writeUnified(&written.writer, diff, .{
        .hunks = .{ .context = @intCast(gen.intRange(s, usize, 0, 5)), .inter_hunk_context = @intCast(gen.intRange(s, usize, 0, 2)) },
        .heading = if (gen.boolean(s)) .c_function else null,
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
pub fn parseOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const syntax = [_][]const u8{
        "--- a/f\n", "+++ b/f\n",                      "@@ -1,2 +1 @@\n",      "@@ -0,0 +1 @@ h\n", "@@ -1 +1,2 @@\n", " a\n", "-b\n",
        "+c\n",      "\\ No newline at end of file\n", "diff --git a/f b/f\n", "\n",                "x\n",             "@@ -", "+++ ",
        "--- ",
    };
    const fragments = try gen.slice(s, []const u8, struct {
        fn draw(source: *shakedown.Source) []const u8 {
            return gen.oneOf(source, []const u8, &syntax);
        }
    }.draw, case.gpa, .{ .average = 39, .max_len = 512 });
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    for (fragments) |p| {
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
pub fn markersOne(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const syntax = [_][]const u8{
        "<<<<<<< a\n", "<<<<<<<\n", "|||||||\n", "||||||| b\n", "=======\n", "=======\r\n",  ">>>>>>> c\n",
        ">>>>>>>\n",   "<<<\n",     "x\n",       "y",           "\n",        "<<<<<<<< z\n", "=",
    };
    const fragments = try gen.slice(s, []const u8, struct {
        fn draw(source: *shakedown.Source) []const u8 {
            return gen.oneOf(source, []const u8, &syntax);
        }
    }.draw, case.gpa, .{ .average = 29, .max_len = 512 });
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    for (fragments) |p| {
        if (len + p.len > buf.len) break;
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    const marked = buf[0..len];
    var it = parallax.merge.parseMarkers(marked, .{ .marker_size = if (gen.weighted(s, &.{ 3, 1 }) == 1) 3 else 7 });
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
