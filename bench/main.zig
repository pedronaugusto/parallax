//! parallax's own workloads, timed: `zig build bench [-- --smoke] [-- --json]
//! [-- --runs N] [-- --only W1,W5]`.
//!
//! Each workload runs on parallax with one reused `Differ`, and, as the A/B
//! baseline, on the code parallax replaces (`baseline/`, relic's line diff
//! and blob merge copied verbatim at relic e090bde). The A/B column is the
//! baseline's time over parallax's: above 1 is parallax faster.
//!
//! - W1: 1M lines, ten edits; W2: 1M lines, 10% and 50% edited;
//! - W3a-W3f: the adversarial shapes;
//! - W5: 100k small files through one workspace, p50 and p99 per call, and
//!   allocations per call;
//! - W6: W2 at 10% under -w, -b and --ignore-cr-at-eol (CRLF copies);
//! - W7b: a conflict per ten lines, every style; W7c: many insertions at
//!   the same places.
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
    }
    if (config.wants("W5")) try small(r, gpa, config);
    if (config.wants("W6")) try whitespace(r, gpa, &d, config, large);
    if (config.wants("W7")) try merges(r, gpa, &d, config);
}

/// One pair under each algorithm, parallax then the baseline.
fn pair(r: Report, gpa: Allocator, d: *parallax.Differ, config: Config, name: []const u8, p: gen.Pair, algorithms: []const parallax.Algorithm) !void {
    const mb = @as(f64, @floatFromInt(p.old.len + p.new.len)) / 1e6;
    for (algorithms) |algorithm| {
        const ours = try timeLines(r, d, config, p, .{ .algorithm = algorithm });
        const base = try timeBaseline(r, gpa, config, p, .{ .algorithm = baselineAlgorithm(algorithm) });
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "{t}", .{algorithm});
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
            const label = try std.fmt.bufPrint(&label_buf, "{t}", .{style});
            try r.line(case.name, label, "parallax", best / 1e6, "ms");
            try r.line(case.name, label, "baseline", base_best / 1e6, "ms");
            try r.line(case.name, label, "A/B", base_best / best, "x");
        }
    }
}
