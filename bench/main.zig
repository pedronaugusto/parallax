//! parallax's own workloads, timed: `zig build bench [-- --smoke] [-- --json]
//! [-- --runs N] [-- --only W1,W5] [-- --corpus DIR]`.
//!
//! Each workload runs on parallax with one reused `Differ`, and, as the A/B
//! baseline, on the code parallax replaces (`baseline/`, relic's line diff
//! and blob merge copied verbatim at relic e090bde). The A/B column is the
//! baseline's time over parallax's: above 1 is parallax faster.
//!
//! - W1: 1M lines, ten edits; W2: 1M lines, 10% and 50% edited;
//! - W3a-W3f: the adversarial shapes; W2 and W3b again with a stop flag
//!   that is never raised, for what reading it costs;
//! - W4: every changed file of a real history (`--corpus`, made by
//!   `zig build bench-corpus`), per-file latency and allocations; W4L: the
//!   files of 1 MB and more; W7a: the merges of its merge commits;
//! - W5: 100k small files through one workspace, p50 and p99 per call, and
//!   allocations per call;
//! - W6: W2 at 10% under -w, -b and --ignore-cr-at-eol (CRLF copies);
//! - W7b: a conflict per ten lines, every style, also over interned ids,
//!   and its markers read back; W7c: many insertions at the same places.
//! - W8: every replace of W2 at 10% refined by words and by characters,
//!   plain and with each cleanup.
//! - W9: the W5 pairs written as patches, parsed, and applied to the old side
//!   as it is, shifted by inserted lines, and with context changed (fuzz 2);
//!   then applied to the new side with the reversed hint.
//! - W10: a C-shaped file with one function in ten edited, written as a
//!   unified diff with plain hunks and with whole functions.
//!
//! Timings are wall-clock on this machine; CI only compiles this file.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parallax = @import("parallax");
const gen = @import("gen.zig");
const textdiff = @import("baseline/diff/textdiff.zig");
const blobmerge = @import("baseline/merge/blobmerge.zig");

const Report = struct {
    w: *Io.Writer,
    json: bool,
    io: Io,

    fn line(r: Report, workload: []const u8, name: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
        if (r.json) {
            try r.w.print("{{\"workload\":\"{s}\",\"name\":\"{s}\",\"metric\":\"{s}\",\"value\":{d:.3},\"unit\":\"{s}\"}}\n", .{ workload, name, metric, value, unit });
        } else {
            try r.w.print("{s:<10} {s:<28} {s:<14} {d:>14.2} {s}\n", .{ workload, name, metric, value, unit });
        }
        try r.w.flush();
    }

    fn now(r: Report) Io.Timestamp {
        return Io.Clock.awake.now(r.io);
    }
};

fn ns(start: Io.Timestamp, end: Io.Timestamp) f64 {
    return @floatFromInt(start.durationTo(end).nanoseconds);
}

const Config = struct {
    smoke: bool = false,
    runs: usize = 5,
    only: ?[]const u8 = null,
    /// A directory `zig build bench-corpus` wrote.
    corpus: ?[]const u8 = null,

    fn wants(c: Config, name: []const u8) bool {
        const only = c.only orelse return true;
        var it = std.mem.splitScalar(u8, only, ',');
        while (it.next()) |w| if (std.mem.eql(u8, w, name)) return true;
        return false;
    }

    fn scale(c: Config, full: usize) usize {
        return if (c.smoke) @max(full / 1000, 10) else full;
    }
};

/// Counts the calls into an allocator.
const Counting = struct {
    inner: Allocator,
    calls: usize = 0,
    bytes: usize = 0,

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx)); // safe: ctx is the Counting this allocator was made from
        c.calls += 1;
        c.bytes += len;
        return c.inner.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx)); // safe: ctx is the Counting this allocator was made from
        c.calls += 1;
        return c.inner.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx)); // safe: ctx is the Counting this allocator was made from
        c.calls += 1;
        return c.inner.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx)); // safe: ctx is the Counting this allocator was made from
        c.inner.rawFree(m, a, ra);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    var config: Config = .{};
    var json = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--smoke")) {
            config.smoke = true;
            config.runs = 1;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--runs") and i + 1 < args.len) {
            i += 1;
            config.runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--only") and i + 1 < args.len) {
            i += 1;
            config.only = args[i];
        } else if (std.mem.eql(u8, arg, "--corpus") and i + 1 < args.len) {
            i += 1;
            config.corpus = args[i];
        } else return error.UnknownArgument;
    }
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    const r: Report = .{ .w = &stdout.interface, .json = json, .io = init.io };

    var d: parallax.Differ = .init(gpa);
    defer d.deinit();

    const large = config.scale(1_000_000);
    if (config.wants("W1")) {
        const p = try gen.w1(gpa, large);
        defer p.deinit(gpa);
        try pair(r, gpa, &d, config, "W1", p, &.{ .myers, .histogram, .patience });
    }
    if (config.wants("W2")) {
        for ([_]f64{ 0.1, 0.5 }, [_][]const u8{ "W2 10%", "W2 50%" }) |fraction, name| {
            const p = try gen.w2(gpa, large, fraction);
            defer p.deinit(gpa);
            try pair(r, gpa, &d, config, name, p, &.{ .myers, .histogram, .patience });
        }
    }
    if (config.wants("W3")) {
        const shapes = [_]struct { name: []const u8, pair: gen.Pair }{
            .{ .name = "W3a", .pair = try gen.w3a(gpa, large) },
            .{ .name = "W3b", .pair = try gen.w3b(gpa, config.scale(200_000)) },
            .{ .name = "W3c", .pair = try gen.w3c(gpa, config.scale(100_000)) },
            .{ .name = "W3d", .pair = try gen.w3d(gpa, large) },
            .{ .name = "W3e", .pair = try gen.w3e(gpa, config.scale(64 << 20)) },
            .{ .name = "W3f", .pair = try gen.w3f(gpa, config.scale(10_000_000)) },
        };
        defer for (shapes) |s| s.pair.deinit(gpa);
        for (shapes) |s| try pair(r, gpa, &d, config, s.name, s.pair, &.{ .myers, .histogram });
        try stopRows(r, gpa, &d, config, large, shapes[1].pair);
    }
    if (config.corpus) |dir| {
        if (config.wants("W4")) try real(r, gpa, init.io, config, dir);
        if (config.wants("W7a")) try realMerges(r, gpa, init.io, config, dir);
    }
    if (config.wants("W5")) try small(r, gpa, config);
    if (config.wants("W6")) try whitespace(r, gpa, &d, config, large);
    if (config.wants("W7")) try merges(r, gpa, &d, config);
    if (config.wants("W8")) try refineInline(r, gpa, &d, config, large);
    if (config.wants("W9")) try patches(r, gpa, config);
    if (config.wants("W10")) try functions(r, gpa, &d, config);
}

/// W2 at 10% and W3b again with a stop flag that is never raised: what
/// reading it once per work unit costs.
fn stopRows(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config, lines: usize, w3b: gen.Pair) !void {
    const w2 = try gen.w2(gpa, lines, 0.1);
    defer w2.deinit(gpa);
    const flag: std.atomic.Value(bool) = .init(false);
    for ([_]struct { []const u8, gen.Pair }{ .{ "W2 10%", w2 }, .{ "W3b", w3b } }) |case| {
        const plain = try timeLines(r, d, config, case[1], .{});
        const watched = try timeLines(r, d, config, case[1], .{ .stop = &flag });
        try r.line(case[0], "myers", "no flag", plain / 1e6, "ms");
        try r.line(case[0], "myers", "stop flag", watched / 1e6, "ms");
        try r.line(case[0], "myers", "flag cost", (watched - plain) / plain * 100, "%");
    }
}

/// W10: whole-function hunks against plain ones, on a C-shaped file.
fn functions(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config) !void {
    const p = try gen.w10(gpa, if (config.smoke) 50 else 20_000);
    defer p.deinit(gpa);
    const diff = try d.lines(p.old, p.new, .{});
    for ([_]struct { []const u8, ?parallax.Heading }{ .{ "plain", null }, .{ "-W", .c_function } }) |case| {
        var best: f64 = std.math.inf(f64);
        var written: usize = 0;
        for (0..config.runs + 1) |run| {
            var discard_buffer: [4096]u8 = undefined;
            var discard: Io.Writer.Discarding = .init(&discard_buffer);
            const t0 = r.now();
            try parallax.writeUnified(&discard.writer, diff, .{ .heading = .c_function, .hunks = .{ .function_context = case[1] } });
            try discard.writer.flush();
            const t1 = r.now();
            written = @intCast(discard.fullCount());
            if (run != 0) best = @min(best, ns(t0, t1));
        }
        try r.line("W10", case[0], "unified", best / 1e6, "ms");
        try r.line("W10", case[0], "written", @as(f64, @floatFromInt(written)) / 1e6, "MB");
    }
}

/// One pair under each algorithm, parallax then the baseline.
fn pair(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config, name: []const u8, p: gen.Pair, algorithms: []const parallax.Algorithm) !void {
    const mb = @as(f64, @floatFromInt(p.old.len + p.new.len)) / 1e6;
    for (algorithms) |algorithm| {
        const ours = try timeLines(r, d, config, p, .{ .algorithm = algorithm });
        const base = try timeBaseline(r, gpa, config, p, .{ .algorithm = baselineAlgorithm(algorithm) });
        var label_buf: [64]u8 = undefined;
        const label = try std.mem.print(&label_buf, "{t}", .{algorithm});
        try r.line(name, label, "parallax", ours / 1e6, "ms");
        try r.line(name, label, "baseline", base / 1e6, "ms");
        try r.line(name, label, "throughput", mb / (ours / 1e9), "MB/s");
        try r.line(name, label, "A/B", base / ours, "x");
        try r.line(name, label, "work", @floatFromInt(d.work), "units");
    }
}

fn baselineAlgorithm(a: parallax.Algorithm) textdiff.Algorithm {
    return switch (a) {
        .myers => .myers,
        .histogram => .histogram,
        .patience => .patience,
    };
}

fn timeLines(r: Report, d: *parallax.Differ, config: Config, p: gen.Pair, options: parallax.Options) !f64 {
    var best: f64 = std.math.inf(f64);
    for (0..config.runs + 1) |run| {
        const t0 = r.now();
        const diff = try d.lines(p.old, p.new, options);
        std.mem.doNotOptimizeAway(diff.changes.len);
        const t1 = r.now();
        if (run != 0) best = @min(best, ns(t0, t1));
    }
    return best;
}

fn timeBaseline(r: Report, gpa: Allocator, config: Config, p: gen.Pair, options: textdiff.Options) !f64 {
    var best: f64 = std.math.inf(f64);
    for (0..config.runs + 1) |run| {
        const t0 = r.now();
        const old = try textdiff.splitLines(gpa, p.old);
        defer gpa.free(old);
        const new = try textdiff.splitLines(gpa, p.new);
        defer gpa.free(new);
        const changes = try textdiff.diffLines(gpa, old, new, options);
        defer gpa.free(changes);
        std.mem.doNotOptimizeAway(changes.len);
        const t1 = r.now();
        if (run != 0) best = @min(best, ns(t0, t1));
    }
    return best;
}

fn percentile(sorted: []const f64, p: f64) f64 {
    const at: usize = @intFromFloat(@as(f64, @floatFromInt(sorted.len - 1)) * p);
    return sorted[at];
}

/// W5: many small diffs through one workspace, as blame makes them.
fn small(r: Report, gpa: Allocator, config: Config) !void {
    const pairs = try gen.w5(gpa, if (config.smoke) 100 else 100_000);
    defer {
        for (pairs) |p| p.deinit(gpa);
        gpa.free(pairs);
    }
    const times = try gpa.alloc(f64, pairs.len);
    defer gpa.free(times);
    var counting: Counting = .{ .inner = gpa };
    var d: parallax.Differ = .init(counting.allocator());
    defer d.deinit();
    for (pairs) |p| _ = try d.lines(p.old, p.new, .{});
    const warm = counting.calls;
    for (pairs, times) |p, *t| {
        const t0 = r.now();
        const diff = try d.lines(p.old, p.new, .{});
        std.mem.doNotOptimizeAway(diff.changes.len);
        t.* = ns(t0, r.now());
    }
    const calls = counting.calls - warm;
    std.mem.sort(f64, times, {}, std.sort.asc(f64));
    try r.line("W5", "parallax", "p50", percentile(times, 0.5) / 1e3, "us");
    try r.line("W5", "parallax", "p99", percentile(times, 0.99) / 1e3, "us");
    try r.line("W5", "parallax", "allocations", @as(f64, @floatFromInt(calls)) / @as(f64, @floatFromInt(pairs.len)), "per call");

    var base_counting: Counting = .{ .inner = gpa };
    const b = base_counting.allocator();
    for (pairs, times) |p, *t| {
        const t0 = r.now();
        const old = try textdiff.splitLines(b, p.old);
        defer b.free(old);
        const new = try textdiff.splitLines(b, p.new);
        defer b.free(new);
        const changes = try textdiff.diffLines(b, old, new, .{});
        defer b.free(changes);
        t.* = ns(t0, r.now());
    }
    std.mem.sort(f64, times, {}, std.sort.asc(f64));
    try r.line("W5", "baseline", "p50", percentile(times, 0.5) / 1e3, "us");
    try r.line("W5", "baseline", "p99", percentile(times, 0.99) / 1e3, "us");
    try r.line("W5", "baseline", "allocations", @as(f64, @floatFromInt(base_counting.calls)) / @as(f64, @floatFromInt(pairs.len)), "per call");
}

/// W6: the normalising hash path.
fn whitespace(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config, lines: usize) !void {
    const p = try gen.w2(gpa, lines, 0.1);
    defer p.deinit(gpa);
    // The CRLF copies, for --ignore-cr-at-eol.
    const crlf_old = try crlf(gpa, p.old);
    defer gpa.free(crlf_old);
    const crlf_new = try crlf(gpa, p.new);
    defer gpa.free(crlf_new);
    const cases = [_]struct { name: []const u8, ws: parallax.Whitespace, old: []const u8, new: []const u8 }{
        .{ .name = "-w", .ws = .{ .all = true }, .old = p.old, .new = p.new },
        .{ .name = "-b", .ws = .{ .change = true }, .old = p.old, .new = p.new },
        .{ .name = "--ignore-cr-at-eol", .ws = .{ .cr_at_eol = true }, .old = crlf_old, .new = p.new },
    };
    for (cases) |c| {
        const q: gen.Pair = .{ .old = c.old, .new = c.new };
        const ours = try timeLines(r, d, config, q, .{ .compare = .{ .whitespace = c.ws } });
        const base = try timeBaseline(r, gpa, config, q, .{
            .ignore_all_whitespace = c.ws.all,
            .ignore_whitespace_change = c.ws.change,
            .ignore_cr_at_eol = c.ws.cr_at_eol,
        });
        try r.line("W6", c.name, "parallax", ours / 1e6, "ms");
        try r.line("W6", c.name, "baseline", base / 1e6, "ms");
        try r.line("W6", c.name, "A/B", base / ours, "x");
    }
}

fn crlf(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (text) |c| {
        if (c == '\n') try out.append(gpa, '\r');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// W8: every replace of W2 at 10% refined by words and by characters.
fn refineInline(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config, lines: usize) !void {
    const p = try gen.w2(gpa, lines, 0.1);
    defer p.deinit(gpa);
    var e: parallax.Differ = .init(gpa);
    defer e.deinit();
    const diff = try e.lines(p.old, p.new, .{});
    var replaces: usize = 0;
    var bytes: usize = 0;
    for (diff.changes) |c| if (c.old_len != 0 and c.new_len != 0) {
        replaces += 1;
        bytes += diff.old.span(c.old_start, c.old_len).len + diff.new.span(c.new_start, c.new_len).len;
    };
    for ([_]parallax.Tokens{ .words, .chars }) |tokens| for ([_]parallax.Cleanup{ .none, .semantic, .efficiency }) |cleanup| {
        var best: f64 = std.math.inf(f64);
        for (0..config.runs + 1) |run| {
            const t0 = r.now();
            for (diff.changes) |c| if (c.old_len != 0 and c.new_len != 0) {
                const refined = try d.refine(diff, c, .{ .tokens = tokens, .cleanup = cleanup });
                std.mem.doNotOptimizeAway(refined.old.len);
            };
            const t1 = r.now();
            if (run != 0) best = @min(best, ns(t0, t1));
        }
        var label_buf: [32]u8 = undefined;
        const label = if (cleanup == .none)
            try std.mem.print(&label_buf, "{t}", .{tokens})
        else
            try std.mem.print(&label_buf, "{t} {t}", .{ tokens, cleanup });
        try r.line("W8", label, "per change", best / @as(f64, @floatFromInt(@max(replaces, 1))) / 1e3, "us");
        try r.line("W8", label, "throughput", @as(f64, @floatFromInt(bytes)) / 1e6 / (best / 1e9), "MB/s");
    };
}

/// W7: merges, parallax writing into a discarding writer, against the
/// baseline's blob merge.
fn merges(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config) !void {
    const triples = [_]struct { name: []const u8, t: gen.Triple }{
        .{ .name = "W7b", .t = try gen.w7b(gpa, config.scale(100_000)) },
        .{ .name = "W7c", .t = try gen.w7c(gpa, config.scale(100_000), if (config.smoke) 10 else 1000) },
    };
    defer for (triples) |t| t.t.deinit(gpa);
    for (triples) |case| {
        const t = case.t;
        for ([_]parallax.merge.Style{ .merge, .diff3, .zdiff3 }) |style| {
            var best: f64 = std.math.inf(f64);
            var discard_buffer: [4096]u8 = undefined;
            for (0..config.runs + 1) |run| {
                var discard: Io.Writer.Discarding = .init(&discard_buffer);
                const t0 = r.now();
                const m = try d.merge(t.base, t.ours, t.theirs, .{ .algorithm = .histogram, .style = style, .level = .zealous });
                try parallax.merge.write(&discard.writer, m, .{});
                try discard.writer.flush();
                const t1 = r.now();
                if (run != 0) best = @min(best, ns(t0, t1));
            }
            var base_best: f64 = std.math.inf(f64);
            for (0..config.runs + 1) |run| {
                const t0 = r.now();
                var result = try blobmerge.blobs(gpa, t.base, t.ours, t.theirs, .{
                    .conflict_style = switch (style) {
                        .merge => .merge,
                        .diff3 => .diff3,
                        .zdiff3 => .zdiff3,
                    },
                    .algorithm = .histogram,
                });
                result.deinit();
                const t1 = r.now();
                if (run != 0) base_best = @min(base_best, ns(t0, t1));
            }
            var label_buf: [32]u8 = undefined;
            const label = try std.mem.print(&label_buf, "{t}", .{style});
            try r.line(case.name, label, "parallax", best / 1e6, "ms");
            try r.line(case.name, label, "baseline", base_best / 1e6, "ms");
            try r.line(case.name, label, "A/B", base_best / best, "x");
        }
    }
    try mergeExtras(r, gpa, d, config, triples[0].t);
}

/// W7b over interned line ids, against the line merge, and its markers read
/// back.
fn mergeExtras(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config, t: gen.Triple) !void {
    var interner: parallax.Interner([]const u8, std.hash_map.StringContext) = .init(gpa, .{});
    defer interner.deinit();
    var ids: [3][]parallax.ClassId = undefined;
    var made: usize = 0;
    defer for (ids[0..made]) |side| gpa.free(side);
    for (&ids, [_][]const u8{ t.base, t.ours, t.theirs }) |*side, text| {
        var list: std.ArrayList(parallax.ClassId) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (it.peek() == null and line.len == 0) break;
            try list.append(gpa, try interner.intern(line));
        }
        side.* = try list.toOwnedSlice(gpa);
        made += 1;
    }
    var lines_best: f64 = std.math.inf(f64);
    var ids_best: f64 = std.math.inf(f64);
    for (0..config.runs + 1) |run| {
        const t0 = r.now();
        const m = try d.merge(t.base, t.ours, t.theirs, .{ .algorithm = .histogram, .level = .zealous });
        std.mem.doNotOptimizeAway(m.regions.len);
        const t1 = r.now();
        const s = try d.mergeSequences(ids[0], ids[1], ids[2], .{ .algorithm = .histogram, .level = .zealous, .classes = interner.classes() });
        std.mem.doNotOptimizeAway(s.regions.len);
        const t2 = r.now();
        if (run != 0) {
            lines_best = @min(lines_best, ns(t0, t1));
            ids_best = @min(ids_best, ns(t1, t2));
        }
    }
    try r.line("W7b", "lines", "merge", lines_best / 1e6, "ms");
    try r.line("W7b", "interned ids", "merge", ids_best / 1e6, "ms");

    // The merged text with every conflict marked, read back.
    const m = try d.merge(t.base, t.ours, t.theirs, .{ .algorithm = .histogram, .level = .zealous, .style = .diff3 });
    var marked: Io.Writer.Allocating = .init(gpa);
    defer marked.deinit();
    try parallax.merge.write(&marked.writer, m, .{});
    var best: f64 = std.math.inf(f64);
    var conflicts: usize = 0;
    for (0..config.runs + 1) |run| {
        conflicts = 0;
        const t0 = r.now();
        var it = parallax.merge.parseMarkers(marked.written(), .{});
        while (try it.next()) |part| conflicts += @intFromBool(part == .conflict);
        const t1 = r.now();
        if (run != 0) best = @min(best, ns(t0, t1));
    }
    try r.line("W7b", "markers", "read back", best / 1e6, "ms");
    try r.line("W7b", "markers", "throughput", @as(f64, @floatFromInt(marked.written().len)) / 1e6 / (best / 1e9), "MB/s");
    try r.line("W7b", "markers", "conflicts", @floatFromInt(conflicts), "");
}

/// W9: patches parsed and applied, GNU patch's way.
fn patches(r: Report, gpa: Allocator, config: Config) !void {
    const pairs = try gen.w5(gpa, if (config.smoke) 50 else 5_000);
    defer {
        for (pairs) |p| p.deinit(gpa);
        gpa.free(pairs);
    }
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    // Each pair's patch, and its old side three ways.
    const Case = struct { patch: []u8, bases: [3][]u8 };
    const cases = try gpa.alloc(Case, pairs.len);
    defer {
        for (cases) |c| {
            gpa.free(c.patch);
            for (c.bases) |b| gpa.free(b);
        }
        gpa.free(cases);
    }
    var bytes: usize = 0;
    for (pairs, cases) |p, *c| {
        const diff = try d.lines(p.old, p.new, .{});
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try parallax.writeUnified(&out.writer, diff, .{ .files = .{ .old = "a/f", .new = "b/f" } });
        c.patch = try out.toOwnedSlice();
        c.bases[0] = try gpa.dupe(u8, p.old);
        c.bases[1] = try std.mem.concat(gpa, u8, &.{ "one\ntwo\nthree\n", p.old });
        // The first line of every 40 changed: context the hunks may lean on.
        c.bases[2] = try gpa.dupe(u8, p.old);
        var line: usize = 0;
        for (c.bases[2], 0..) |*ch, i| {
            if (ch.* == '\n') line += 1 else if (line % 40 == 0 and (i == 0 or c.bases[2][i - 1] == '\n')) ch.* = '#';
        }
        bytes += c.patch.len + p.old.len;
    }
    var results: std.ArrayList(parallax.patch.HunkResult) = .empty;
    defer results.deinit(gpa);
    for ([_][]const u8{ "exact", "offset", "fuzz 2" }, 0..) |name, which| {
        var best: f64 = std.math.inf(f64);
        var failed: usize = 0;
        for (0..config.runs + 1) |run| {
            var discard_buffer: [4096]u8 = undefined;
            var discard: Io.Writer.Discarding = .init(&discard_buffer);
            failed = 0;
            const t0 = r.now();
            for (cases) |c| {
                var p = try parallax.patch.parse(gpa, c.patch, .{});
                defer p.deinit();
                for (p.files) |file| {
                    try results.resize(gpa, file.hunks.len);
                    try parallax.patch.apply(gpa, &discard.writer, c.bases[which], file, .{ .fuzz = 2, .rejects = .skip }, results.items);
                    for (results.items) |h| failed += @intFromBool(h == .rejected);
                }
            }
            const t1 = r.now();
            if (run != 0) best = @min(best, ns(t0, t1));
        }
        try r.line("W9", name, "per patch", best / @as(f64, @floatFromInt(cases.len)) / 1e3, "us");
        try r.line("W9", name, "throughput", @as(f64, @floatFromInt(bytes)) / 1e6 / (best / 1e9), "MB/s");
        try r.line("W9", name, "rejected", @floatFromInt(failed), "hunks");
    }
    // Applied to the side it already made, with the reversed hint: the
    // first hunk is looked for both ways, at every fuzz.
    for ([_]bool{ false, true }) |hinted| {
        var best: f64 = std.math.inf(f64);
        var reversed: usize = 0;
        for (0..config.runs + 1) |run| {
            var discard_buffer: [4096]u8 = undefined;
            var discard: Io.Writer.Discarding = .init(&discard_buffer);
            reversed = 0;
            const t0 = r.now();
            for (cases, pairs) |c, p| {
                var parsed = try parallax.patch.parse(gpa, c.patch, .{});
                defer parsed.deinit();
                for (parsed.files) |file| {
                    try results.resize(gpa, file.hunks.len);
                    var hint = false;
                    try parallax.patch.apply(gpa, &discard.writer, p.new, file, .{ .fuzz = 2, .rejects = .skip, .reversed_hint = if (hinted) &hint else null }, results.items);
                    reversed += @intFromBool(hint);
                }
            }
            const t1 = r.now();
            if (run != 0) best = @min(best, ns(t0, t1));
        }
        const label = if (hinted) "applied, hint" else "applied";
        try r.line("W9", label, "per patch", best / @as(f64, @floatFromInt(cases.len)) / 1e3, "us");
        try r.line("W9", label, "reversed", @floatFromInt(reversed), "patches");
    }
}

/// The corpus `zig build bench-corpus` wrote, read a record at a time.
const Records = struct {
    file: Io.File,
    reader: Io.File.Reader,
    buffer: [1 << 20]u8,

    fn open(rec: *Records, io: Io, dir: []const u8, name: []const u8) !void {
        var path_buffer: [4096]u8 = undefined;
        const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ dir, name });
        rec.file = try Io.Dir.cwd().openFile(io, path, .{});
        rec.reader = rec.file.readerStreaming(io, &rec.buffer);
    }

    fn close(rec: *Records, io: Io) void {
        rec.file.close(io);
    }

    /// The next record into `fields`, or false at the end.
    fn next(rec: *Records, gpa: Allocator, fields: []std.ArrayList(u8)) !bool {
        for (fields, 0..) |*field, k| {
            var len: [4]u8 = undefined;
            rec.reader.interface.readSliceAll(&len) catch |err| switch (err) {
                error.EndOfStream => return if (k == 0) false else error.TruncatedCorpus,
                else => |e| return e,
            };
            try field.resize(gpa, std.mem.readInt(u32, &len, .little));
            try rec.reader.interface.readSliceAll(field.items);
        }
        return true;
    }
};

/// The corpus in `dir` is the one the committed manifest names.
fn checkCorpus(gpa: Allocator, io: Io, dir: []const u8) !void {
    var path_buffer: [4096]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/manifest", .{dir});
    const manifest = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(manifest);
    if (!std.mem.eql(u8, manifest, @embedFile("linux-v6.11-v6.12.manifest"))) return error.CorpusMismatch;
}

/// Files of this size or more are W4L's.
const large_file = 1 << 20;

/// W4 and W4L: every changed file of the real history, diffed by parallax
/// (one workspace) and by the baseline, per-file latency from the best of
/// the runs, and allocations per call once warm.
fn real(r: Report, gpa: Allocator, io: Io, config: Config, dir: []const u8) !void {
    try checkCorpus(gpa, io, dir);
    var fields: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&fields) |*f| f.deinit(gpa);
    var times: std.ArrayList(f64) = .empty;
    defer times.deinit(gpa);
    const records = try gpa.create(Records);
    defer gpa.destroy(records);
    for ([_]parallax.Algorithm{ .myers, .histogram }) |algorithm| {
        var counting: Counting = .{ .inner = gpa };
        var d: parallax.Differ = .init(counting.allocator());
        defer d.deinit();
        var best: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
        var base_best: [2]f64 = .{ std.math.inf(f64), std.math.inf(f64) };
        var bytes: [2]u64 = .{ 0, 0 };
        var calls_warm: usize = 0;
        var count: usize = 0;
        for (0..config.runs + 1) |run| {
            try records.open(io, dir, "pairs");
            defer records.close(io);
            var total: [2]f64 = .{ 0, 0 };
            var base_total: [2]f64 = .{ 0, 0 };
            const calls_before = counting.calls;
            var at: usize = 0;
            while (try records.next(gpa, &fields)) : (at += 1) {
                const old = fields[0].items;
                const new = fields[1].items;
                const big = @max(old.len, new.len) >= large_file;
                if (run == 0) {
                    try times.append(gpa, std.math.inf(f64));
                    bytes[0] += old.len + new.len;
                    if (big) bytes[1] += old.len + new.len;
                }
                const t0 = r.now();
                const diff = try d.lines(old, new, .{ .algorithm = algorithm });
                std.mem.doNotOptimizeAway(diff.changes.len);
                const t1 = r.now();
                const old_lines = try textdiff.splitLines(gpa, old);
                defer gpa.free(old_lines);
                const new_lines = try textdiff.splitLines(gpa, new);
                defer gpa.free(new_lines);
                const changes = try textdiff.diffLines(gpa, old_lines, new_lines, .{ .algorithm = baselineAlgorithm(algorithm) });
                gpa.free(changes);
                const t2 = r.now();
                times.items[at] = @min(times.items[at], ns(t0, t1));
                total[0] += ns(t0, t1);
                base_total[0] += ns(t1, t2);
                if (big) {
                    total[1] += ns(t0, t1);
                    base_total[1] += ns(t1, t2);
                }
            }
            count = at;
            if (run == 0) continue;
            if (run == 1) calls_warm = counting.calls - calls_before;
            for (0..2) |k| {
                best[k] = @min(best[k], total[k]);
                base_best[k] = @min(base_best[k], base_total[k]);
            }
        }
        var label_buf: [32]u8 = undefined;
        const label = try std.mem.print(&label_buf, "{t}", .{algorithm});
        for ([_][]const u8{ "W4", "W4L" }, 0..) |name, k| {
            try r.line(name, label, "parallax", best[k] / 1e6, "ms");
            try r.line(name, label, "baseline", base_best[k] / 1e6, "ms");
            try r.line(name, label, "A/B", base_best[k] / best[k], "x");
            try r.line(name, label, "throughput", @as(f64, @floatFromInt(bytes[k])) / 1e6 / (best[k] / 1e9), "MB/s");
        }
        try r.line("W4", label, "files", @floatFromInt(count), "");
        try r.line("W4", label, "allocations", @as(f64, @floatFromInt(calls_warm)) / @as(f64, @floatFromInt(@max(count, 1))), "per call");
        std.mem.sort(f64, times.items, {}, std.sort.asc(f64));
        try r.line("W4", label, "p50", percentile(times.items, 0.5) / 1e3, "us");
        try r.line("W4", label, "p99", percentile(times.items, 0.99) / 1e3, "us");
        try r.line("W4", label, "p999", percentile(times.items, 0.999) / 1e3, "us");
        times.clearRetainingCapacity();
    }
}

/// W7a: the merges of the real history's merge commits, as git's merge
/// machinery takes them (histogram, zealous) and as `git merge-file` does
/// (Myers, zealous-alnum), each written, against the baseline.
fn realMerges(r: Report, gpa: Allocator, io: Io, config: Config, dir: []const u8) !void {
    try checkCorpus(gpa, io, dir);
    var fields: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    defer for (&fields) |*f| f.deinit(gpa);
    const records = try gpa.create(Records);
    defer gpa.destroy(records);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const cases = [_]struct { []const u8, parallax.merge.Options, textdiff.Algorithm }{
        .{ "histogram zealous", .{ .algorithm = .histogram, .level = .zealous }, .histogram },
        .{ "myers zealous-alnum", .{}, .myers },
    };
    for (cases) |case| {
        var best: f64 = std.math.inf(f64);
        var base_best: f64 = std.math.inf(f64);
        var conflicts: usize = 0;
        var count: usize = 0;
        for (0..config.runs + 1) |run| {
            try records.open(io, dir, "merges");
            defer records.close(io);
            var total: f64 = 0;
            var base_total: f64 = 0;
            conflicts = 0;
            count = 0;
            var discard_buffer: [1 << 14]u8 = undefined;
            var discard: Io.Writer.Discarding = .init(&discard_buffer);
            while (try records.next(gpa, &fields)) : (count += 1) {
                const t0 = r.now();
                const m = try d.merge(fields[0].items, fields[1].items, fields[2].items, case[1]);
                try parallax.merge.write(&discard.writer, m, .{});
                const t1 = r.now();
                var result = try blobmerge.blobs(gpa, fields[0].items, fields[1].items, fields[2].items, .{
                    .algorithm = case[2],
                    .join_without_alnum = case[1].level == .zealous_alnum,
                });
                result.deinit();
                const t2 = r.now();
                total += ns(t0, t1);
                base_total += ns(t1, t2);
                conflicts += m.conflicts;
            }
            if (run == 0) continue;
            best = @min(best, total);
            base_best = @min(base_best, base_total);
        }
        try r.line("W7a", case[0], "parallax", best / 1e6, "ms");
        try r.line("W7a", case[0], "baseline", base_best / 1e6, "ms");
        try r.line("W7a", case[0], "A/B", base_best / best, "x");
        try r.line("W7a", case[0], "merges", @floatFromInt(count), "files");
        try r.line("W7a", case[0], "conflicts", @floatFromInt(conflicts), "");
    }
}
