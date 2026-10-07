//! Determinism and bounds, with no clock involved: a warm workspace makes no
//! allocation, the adversarial workloads cost the work units recorded here
//! and give the scripts recorded here, every allocation failure is survived,
//! and the deep inputs diff on a 64 KiB stack.

const std = @import("std");
const parallax = @import("../parallax.zig");
const gen = @import("gen");
const support = @import("support.zig");
const builtin = @import("builtin");

const Counts = struct { allocations: usize, resizes: usize, frees: usize };

fn counts(a: *const std.testing.FailingAllocator) Counts {
    return .{ .allocations = a.allocations, .resizes = a.resize_index, .frees = a.deallocations };
}

test "a warm Differ allocates nothing, for any algorithm or a merge" {
    const gpa = std.testing.allocator;
    const big = try gen.w2(gpa, 3000, 0.1);
    defer big.deinit(gpa);
    const small = try gen.w2(gpa, 500, 0.3);
    defer small.deinit(gpa);
    const triple = try gen.w7b(gpa, 1000);
    defer triple.deinit(gpa);
    var counting: std.testing.FailingAllocator = .init(gpa, .{});
    var d: parallax.Differ = .init(counting.allocator());
    defer d.deinit();
    for ([_]parallax.Algorithm{ .myers, .patience, .histogram }) |algorithm| {
        for ([_]parallax.Compare{ .{}, .{ .whitespace = .{ .change = true } } }) |compare| {
            const options: parallax.Options = .{ .algorithm = algorithm, .compare = compare };
            _ = try d.lines(big.old, big.new, options);
            const warm = counts(&counting);
            _ = try d.lines(big.old, big.new, options);
            _ = try d.lines(small.old, small.new, options);
            try std.testing.expectEqual(warm, counts(&counting));
        }
    }
    for ([_]parallax.Tokens{ .words, .chars, .bytes }) |tokens| {
        const diff = try d.lines(small.old, small.new, .{});
        for (diff.changes) |c| _ = try d.refine(diff, c, .{ .tokens = tokens });
        const warm = counts(&counting);
        for (diff.changes) |c| _ = try d.refine(diff, c, .{ .tokens = tokens });
        try std.testing.expectEqual(warm, counts(&counting));
    }
    for ([_]parallax.merge.Style{ .merge, .diff3, .zdiff3 }) |style| {
        const options: parallax.merge.Options = .{ .algorithm = .histogram, .style = style };
        _ = try d.merge(triple.base, triple.ours, triple.theirs, options);
        const warm = counts(&counting);
        _ = try d.merge(triple.base, triple.ours, triple.theirs, options);
        try std.testing.expectEqual(warm, counts(&counting));
    }
}

/// The script's numbers, little-endian, hashed: the same on every target.
fn scriptHash(changes: []const parallax.Change) u64 {
    var h: std.hash.Wyhash = .init(0);
    for (changes) |c| {
        for ([_]u32{ c.old_start, c.old_len, c.new_start, c.new_len }) |n| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, n, .little);
            h.update(&b);
        }
    }
    return h.final();
}

const Guard = struct {
    name: []const u8,
    algorithm: parallax.Algorithm = .myers,
    minimal: bool = false,
    work: u64,
    changes: usize,
    hash: u64,
};

fn workload(gpa: std.mem.Allocator, name: []const u8) !gen.Pair {
    if (std.mem.eql(u8, name, "W1")) return gen.w1(gpa, 10_000);
    if (std.mem.eql(u8, name, "W2 10%")) return gen.w2(gpa, 10_000, 0.1);
    if (std.mem.eql(u8, name, "W2 50%")) return gen.w2(gpa, 10_000, 0.5);
    if (std.mem.eql(u8, name, "W3a")) return gen.w3a(gpa, 10_000);
    if (std.mem.eql(u8, name, "W3b")) return gen.w3b(gpa, 2_000);
    if (std.mem.eql(u8, name, "W3c")) return gen.w3c(gpa, 1_000);
    if (std.mem.eql(u8, name, "W3d")) return gen.w3d(gpa, 10_000);
    if (std.mem.eql(u8, name, "W3e")) return gen.w3e(gpa, 640 * 1024);
    if (std.mem.eql(u8, name, "W3f")) return gen.w3f(gpa, 100_000);
    unreachable;
}

/// The workloads at 1/100 scale. A change to an algorithm that moves one of
/// these numbers changes output or cost, and has to say why.
const guards = [_]Guard{
    .{ .name = "W1", .work = 0, .changes = 13, .hash = 0x9e8a3c98bee1b6d4 },
    .{ .name = "W2 10%", .work = 0, .changes = 956, .hash = 0x6ed0afab64039df9 },
    .{ .name = "W2 50%", .work = 0, .changes = 3334, .hash = 0xf604d66d7111afd0 },
    .{ .name = "W3a", .work = 0, .changes = 1, .hash = 0xd8ef771d08ba36be },
    .{ .name = "W3b", .work = 3477, .changes = 434, .hash = 0x7b101a1681a4ead8 },
    .{ .name = "W3b", .minimal = true, .work = 3722, .changes = 438, .hash = 0x9e082b1338b391d0 },
    .{ .name = "W3c", .work = 1279, .changes = 2, .hash = 0x9233d77aca153216 },
    .{ .name = "W3d", .work = 311, .changes = 111, .hash = 0xbe624f7249bfa74e },
    .{ .name = "W3d", .algorithm = .histogram, .work = 14, .changes = 111, .hash = 0xbe624f7249bfa74e },
    .{ .name = "W3d", .algorithm = .patience, .work = 46, .changes = 111, .hash = 0xbe624f7249bfa74e },
    .{ .name = "W3e", .work = 0, .changes = 1, .hash = 0x53739d1851fce549 },
    .{ .name = "W3f", .work = 0, .changes = 1, .hash = 0x239ac3de28561a3f },
};

test "the workloads cost the work units and give the scripts recorded for them" {
    const gpa = std.testing.allocator;
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    var failed = false;
    for (guards) |g| {
        const pair = try workload(gpa, g.name);
        defer pair.deinit(gpa);
        const diff = try d.lines(pair.old, pair.new, .{ .algorithm = g.algorithm, .minimal = g.minimal });
        const hash = scriptHash(diff.changes);
        if (d.work != g.work or diff.changes.len != g.changes or hash != g.hash) {
            std.debug.print(".{{ .name = \"{s}\", .algorithm = .{t}, .minimal = {}, .work = {d}, .changes = {d}, .hash = 0x{x} }},\n", .{ g.name, g.algorithm, g.minimal, d.work, diff.changes.len, hash });
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}

fn deepDiffs(pairs: []const gen.Pair) !void {
    var d: parallax.Differ = .init(std.heap.page_allocator);
    defer d.deinit();
    for (pairs) |pair| {
        for ([_]parallax.Algorithm{ .myers, .patience, .histogram }) |algorithm| {
            for ([_]bool{ false, true }) |minimal| {
                _ = try d.lines(pair.old, pair.new, .{ .algorithm = algorithm, .minimal = minimal });
            }
        }
    }
}

test "the deep inputs diff on a 64 KiB stack" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pairs: [3]gen.Pair = undefined;
    for (&pairs, [_][]const u8{ "W3b", "W3c", "W3d" }) |*p, name| p.* = try workload(gpa, name);
    defer for (pairs) |p| p.deinit(gpa);
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
        fn run(r: *anyerror!void, p: []const gen.Pair) void {
            r.* = deepDiffs(p);
        }
    }.run, .{ &result, &pairs });
    thread.join();
    try result;
}

fn diffAll(gpa: std.mem.Allocator, old: []const u8, new: []const u8) !void {
    var d = try parallax.diffLines(gpa, old, new, .{ .algorithm = .histogram });
    defer d.deinit();
    var e: parallax.Differ = .init(gpa);
    defer e.deinit();
    _ = try e.lines(old, new, .{ .algorithm = .patience, .compare = .{ .whitespace = .{ .all = true } } });
    _ = try e.lines(old, new, .{ .minimal = true });
}

fn refineAll(gpa: std.mem.Allocator, old: []const u8, new: []const u8) !void {
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    const diff = try d.lines(old, new, .{});
    for (diff.changes) |c| _ = try d.refine(diff, c, .{ .tokens = .chars });
}

fn mergeAll(gpa: std.mem.Allocator, base: []const u8, ours: []const u8, theirs: []const u8) !void {
    var m = try parallax.merge.mergeAlloc(gpa, base, ours, theirs, .{ .style = .zdiff3 }, .{});
    defer m.deinit();
    var n = try parallax.merge.mergeAlloc(gpa, base, ours, theirs, .{ .algorithm = .histogram }, .{});
    defer n.deinit();
}

test "every allocation failure is survived without a leak" {
    var fixed: support.NoResize = .{ .inner = std.testing.allocator };
    const gpa = fixed.allocator();
    const pair = try gen.w2(gpa, 120, 0.2);
    defer pair.deinit(gpa);
    try std.testing.checkAllAllocationFailures(gpa, diffAll, .{ pair.old, pair.new });
    try std.testing.checkAllAllocationFailures(gpa, refineAll, .{ pair.old, pair.new });
    const triple = try gen.w7b(gpa, 60);
    defer triple.deinit(gpa);
    try std.testing.checkAllAllocationFailures(gpa, mergeAll, .{ triple.base, triple.ours, triple.theirs });
}

test "an input a u32 cannot index is refused" {
    if (@sizeOf(usize) < 8) return error.SkipZigTest;
    // A slice that claims 4 GiB is never read: the length alone is refused.
    const len: usize = if (@sizeOf(usize) >= 8) @as(usize, std.math.maxInt(u32)) + 1 else 0;
    const huge: []const u8 = @as([*]const u8, @ptrFromInt(0x1000))[0..len];
    var d: parallax.Differ = .init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expectError(error.InputTooLarge, d.lines(huge, "", .{}));
}
