//! Cancellation: a diff or a merge given the caller's `Io` ends with
//! `error.Canceled` once its task is canceled, at the next work unit or
//! region, on the threaded backend and on the host's evented one; given an
//! `Io` and never canceled, it gives the script it gives without one.

const std = @import("std");
const shakedown = @import("shakedown");
const parallax = @import("../parallax.zig");
const reactor = @import("reactor");

/// The cancellation checks a call makes, and an event set at the first:
/// the call is under way.
const Checks = struct {
    count: std.atomic.Value(u64) = .init(0),
    started: std.Io.Event = .unset,

    fn checkCancel(userdata: ?*anyopaque) std.Io.Cancelable!void {
        const layer = Counted.of(userdata);
        if (layer.state.count.fetchAdd(1, .monotonic) == 0) layer.state.started.set(layer.base);
        return layer.base.checkCancel();
    }
};
const Counted = shakedown.Layer(Checks, .{ .checkCancel = Checks.checkCancel });

/// `lines` lines of four kinds in a seeded order. No line is unique and
/// every line is common, so patience and histogram fall back to Myers on
/// the whole, and a minimal Myers keeps every line: two of these at 100k
/// lines take seconds, at 2k lines a fraction of one.
fn fourKinds(gpa: std.mem.Allocator, lines: usize, seed: u64) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const text = try gpa.alloc(u8, 2 * lines);
    for (0..lines) |i| {
        text[2 * i] = 'a' + random.uintLessThan(u8, 4);
        text[2 * i + 1] = '\n';
    }
    return text;
}

const Inputs = struct {
    old: []u8,
    new: []u8,
    fn init(gpa: std.mem.Allocator, lines: usize) !Inputs {
        const old = try fourKinds(gpa, lines, 1);
        errdefer gpa.free(old);
        return .{ .old = old, .new = try fourKinds(gpa, lines, 2) };
    }
    fn deinit(in: Inputs, gpa: std.mem.Allocator) void {
        gpa.free(in.old);
        gpa.free(in.new);
    }
};

const Call = union(enum) { lines: parallax.Algorithm, merge };

/// The call, under `io`; the number of changes or of regions it gives.
fn run(d: *parallax.Differ, io: std.Io, in: Inputs, call: Call) parallax.Differ.Error!usize {
    switch (call) {
        .lines => |algorithm| {
            const diff = try d.lines(in.old, in.new, .{ .algorithm = algorithm, .minimal = true, .io = io });
            return diff.changes.len;
        },
        .merge => {
            const m = try d.merge(in.old, in.new, in.old[in.old.len / 2 ..], .{ .minimal = true, .io = io });
            return m.regions.len;
        },
    }
}

const calls = [_]Call{ .{ .lines = .myers }, .{ .lines = .patience }, .{ .lines = .histogram }, .merge };

fn cancelEach(io: std.Io) !void {
    const gpa = std.testing.allocator;
    const in: Inputs = try .init(gpa, 100_000);
    defer in.deinit(gpa);
    for (calls) |call| {
        var d: parallax.Differ = .init(gpa);
        defer d.deinit();
        var counted: Counted = .init(io, .{});
        var task = try counted.io().concurrent(run, .{ &d, counted.io(), in, call });
        try counted.state.started.wait(io);
        try std.testing.expectError(error.Canceled, task.cancel(io));
    }
}

fn unchanged(io: std.Io) !void {
    const gpa = std.testing.allocator;
    const in: Inputs = try .init(gpa, 2_000);
    defer in.deinit(gpa);
    var d: parallax.Differ = .init(gpa);
    defer d.deinit();
    for (calls) |call| {
        const expected = switch (call) {
            .lines => |algorithm| (try d.lines(in.old, in.new, .{ .algorithm = algorithm, .minimal = true })).changes.len,
            .merge => (try d.merge(in.old, in.new, in.old[in.old.len / 2 ..], .{ .minimal = true })).regions.len,
        };
        const expected_work = d.work;
        var counted: Counted = .init(io, .{});
        try std.testing.expectEqual(expected, try run(&d, counted.io(), in, call));
        try std.testing.expectEqual(expected_work, d.work);
        try std.testing.expect(counted.state.count.load(.monotonic) > 0);
    }
}

test "a diff or merge canceled while it runs ends with Canceled, on the threaded backend" {
    try cancelEach(std.testing.io);
}

/// reactor's runtime, the evented `Io`: kqueue on macOS and the BSDs,
/// io_uring on Linux. Null where the system has no evented backend.
fn evented(runtime: *reactor.Runtime) !?std.Io {
    runtime.init(std.testing.allocator, .{}) catch |err| switch (err) {
        error.BackendUnavailable => return null,
        else => |e| return e,
    };
    errdefer runtime.deinit();
    try runtime.start();
    return runtime.io();
}

test "a diff or merge canceled while it runs ends with Canceled, on the evented backend" {
    var runtime: reactor.Runtime = undefined;
    const io = try evented(&runtime) orelse return error.SkipZigTest;
    defer runtime.deinit();
    try cancelEach(io);
}

test "a diff or merge given an Io and never canceled gives the same script and work" {
    try unchanged(std.testing.io);
    var runtime: reactor.Runtime = undefined;
    const io = try evented(&runtime) orelse return;
    defer runtime.deinit();
    try unchanged(io);
}
