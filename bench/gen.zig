//! parallax's workloads, generated from fixed seeds: the timed benchmarks,
//! the tests' work and output guards at 1/100 scale, and any comparison
//! that wants the same inputs.
//!
//! Text is lines of 5 to 15 words from a fixed vocabulary of 4,096 words.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pair = struct {
    old: []const u8,
    new: []const u8,

    pub fn deinit(p: Pair, gpa: Allocator) void {
        gpa.free(p.old);
        gpa.free(p.new);
    }
};

pub const Triple = struct {
    base: []u8,
    ours: []u8,
    theirs: []u8,

    pub fn deinit(t: Triple, gpa: Allocator) void {
        gpa.free(t.base);
        gpa.free(t.ours);
        gpa.free(t.theirs);
    }
};

pub const vocabulary_size = 4096;

/// The fixed vocabulary: 4,096 lowercase words of 2 to 9 letters.
pub const Vocabulary = struct {
    bytes: [vocabulary_size * 9]u8,
    lens: [vocabulary_size]u8,

    pub fn init() Vocabulary {
        var v: Vocabulary = undefined;
        var prng: std.Random.DefaultPrng = .init(0x766f6361);
        const r = prng.random();
        for (0..vocabulary_size) |i| {
            const len = 2 + r.uintLessThan(u8, 8);
            v.lens[i] = len;
            for (v.bytes[i * 9 ..][0..len]) |*c| c.* = 'a' + r.uintLessThan(u8, 26);
        }
        return v;
    }

    pub fn word(v: *const Vocabulary, i: usize) []const u8 {
        return v.bytes[i * 9 ..][0..v.lens[i]];
    }
};

/// One line of 5 to 15 words.
pub fn line(gpa: Allocator, out: *std.ArrayList(u8), v: *const Vocabulary, r: std.Random) Allocator.Error!void {
    const n = 5 + r.uintLessThan(usize, 11);
    for (0..n) |i| {
        if (i != 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, v.word(r.uintLessThan(usize, vocabulary_size)));
    }
    try out.append(gpa, '\n');
}

/// `lines` generated lines.
pub fn file(gpa: Allocator, v: *const Vocabulary, r: std.Random, lines: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..lines) |_| try line(gpa, &out, v, r);
    return out.toOwnedSlice(gpa);
}

/// `old` with `edits` random edits, each a replaced, inserted or deleted
/// line, or with `fraction` of its lines edited when `edits` is null.
pub fn edited(gpa: Allocator, v: *const Vocabulary, r: std.Random, old: []const u8, edits: ?usize, fraction: f64) Allocator.Error![]u8 {
    var count: usize = 0;
    for (old) |c| count += @intFromBool(c == '\n');
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const p: f64 = if (edits) |e| @as(f64, @floatFromInt(e)) / @as(f64, @floatFromInt(@max(count, 1))) else fraction;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        if (r.float(f64) < p) switch (r.uintLessThan(u8, 3)) {
            0 => try line(gpa, &out, v, r),
            1 => {
                try line(gpa, &out, v, r);
                try out.print(gpa, "{s}\n", .{l});
            },
            else => {},
        } else try out.print(gpa, "{s}\n", .{l});
    }
    return out.toOwnedSlice(gpa);
}

fn repeated(gpa: Allocator, l: []const u8, n: usize) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, l.len * n);
    for (0..n) |i| @memcpy(out[i * l.len ..][0..l.len], l);
    return out;
}

/// W1: a large file with ten random edits.
pub fn w1(gpa: Allocator, lines: usize) Allocator.Error!Pair {
    const v: Vocabulary = .init();
    var prng: std.Random.DefaultPrng = .init(0x7731);
    const old = try file(gpa, &v, prng.random(), lines);
    errdefer gpa.free(old);
    return .{ .old = old, .new = try edited(gpa, &v, prng.random(), old, 10, 0) };
}

/// W2: a large file with `fraction` of its lines edited at random.
pub fn w2(gpa: Allocator, lines: usize, fraction: f64) Allocator.Error!Pair {
    const v: Vocabulary = .init();
    var prng: std.Random.DefaultPrng = .init(0x7732);
    const old = try file(gpa, &v, prng.random(), lines);
    errdefer gpa.free(old);
    return .{ .old = old, .new = try edited(gpa, &v, prng.random(), old, null, fraction) };
}

/// W3a: identical lines `x`, one line inserted in the middle.
pub fn w3a(gpa: Allocator, lines: usize) Allocator.Error!Pair {
    const old = try repeated(gpa, "x\n", lines);
    errdefer gpa.free(old);
    const new = try gpa.alloc(u8, old.len + 2);
    const mid = (lines / 2) * 2;
    @memcpy(new[0..mid], old[0..mid]);
    @memcpy(new[mid..][0..2], "y\n");
    @memcpy(new[mid + 2 ..], old[mid..]);
    return .{ .old = old, .new = new };
}

fn binaryText(gpa: Allocator, r: std.Random, lines: usize) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, lines * 2);
    for (0..lines) |i| {
        out[2 * i] = if (r.boolean()) 'a' else 'b';
        out[2 * i + 1] = '\n';
    }
    return out;
}

/// W3b: two independent random texts over a two-line alphabet: the edit
/// distance is close to the size, which is what git's give-up rules are
/// for.
pub fn w3b(gpa: Allocator, lines: usize) Allocator.Error!Pair {
    var prng: std.Random.DefaultPrng = .init(0x773362);
    const old = try binaryText(gpa, prng.random(), lines);
    errdefer gpa.free(old);
    return .{ .old = old, .new = try binaryText(gpa, prng.random(), lines) };
}

/// W3c: unique lines against their reverse: the edit distance is twice
/// the size.
pub fn w3c(gpa: Allocator, lines: usize) Allocator.Error!Pair {
    var old: std.ArrayList(u8) = .empty;
    errdefer old.deinit(gpa);
    var new: std.ArrayList(u8) = .empty;
    errdefer new.deinit(gpa);
    for (0..lines) |i| try old.print(gpa, "line {d}\n", .{i});
    for (0..lines) |i| try new.print(gpa, "line {d}\n", .{lines - 1 - i});
    return .{ .old = try old.toOwnedSlice(gpa), .new = try new.toOwnedSlice(gpa) };
}

/// W3d: lines of `}` and blank with 1% unique ones, edited: the histogram's
/// chain limit and its fallbacks.
pub fn w3d(gpa: Allocator, lines: usize) Allocator.Error!Pair {
    var prng: std.Random.DefaultPrng = .init(0x773364);
    const r = prng.random();
    var old: std.ArrayList(u8) = .empty;
    errdefer old.deinit(gpa);
    for (0..lines) |i| {
        if (r.uintLessThan(u8, 100) == 0) {
            try old.print(gpa, "unique {d}\n", .{i});
        } else try old.appendSlice(gpa, if (r.boolean()) "}\n" else "\n");
    }
    const v: Vocabulary = .init();
    const new = try edited(gpa, &v, r, old.items, null, 0.01);
    errdefer gpa.free(new);
    return .{ .old = try old.toOwnedSlice(gpa), .new = new };
}

/// W3e: one line of `bytes` bytes and no newline, one byte changed.
pub fn w3e(gpa: Allocator, bytes: usize) Allocator.Error!Pair {
    const old = try gpa.alloc(u8, bytes);
    errdefer gpa.free(old);
    for (old, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    const new = try gpa.dupe(u8, old);
    new[bytes / 2] = '#';
    return .{ .old = old, .new = new };
}

/// W3f: `lines` lines `a` against one more.
pub fn w3f(gpa: Allocator, lines: usize) Allocator.Error!Pair {
    const old = try repeated(gpa, "a\n", lines);
    errdefer gpa.free(old);
    return .{ .old = old, .new = try repeated(gpa, "a\n", lines + 1) };
}

/// W5: small files, 50 to 500 lines, with a few edits each, as blame
/// diffs them.
pub fn w5(gpa: Allocator, count: usize) Allocator.Error![]Pair {
    const v: Vocabulary = .init();
    var prng: std.Random.DefaultPrng = .init(0x7735);
    const r = prng.random();
    const out = try gpa.alloc(Pair, count);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |p| p.deinit(gpa);
        gpa.free(out);
    }
    for (out) |*p| {
        const old = try file(gpa, &v, r, 50 + r.uintLessThan(usize, 451));
        errdefer gpa.free(old);
        p.* = .{ .old = old, .new = try edited(gpa, &v, r, old, 1 + r.uintLessThan(usize, 8), 0) };
        made += 1;
    }
    return out;
}

/// W7b: every tenth line edited differently on each side: a conflict per
/// ten lines.
pub fn w7b(gpa: Allocator, lines: usize) Allocator.Error!Triple {
    const v: Vocabulary = .init();
    var prng: std.Random.DefaultPrng = .init(0x773762);
    const r = prng.random();
    var sides: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    errdefer for (&sides) |*s| s.deinit(gpa);
    for (0..lines) |i| {
        const start = sides[0].items.len;
        try line(gpa, &sides[0], &v, r);
        const l = sides[0].items[start..];
        if (i % 10 == 5) {
            try line(gpa, &sides[1], &v, r);
            try line(gpa, &sides[2], &v, r);
        } else {
            try sides[1].appendSlice(gpa, l);
            try sides[2].appendSlice(gpa, l);
        }
    }
    const base = try sides[0].toOwnedSlice(gpa);
    errdefer gpa.free(base);
    const ours = try sides[1].toOwnedSlice(gpa);
    errdefer gpa.free(ours);
    return .{ .base = base, .ours = ours, .theirs = try sides[2].toOwnedSlice(gpa) };
}

/// W7c: a base of identical lines; both sides insert different text at
/// `points` places.
pub fn w7c(gpa: Allocator, lines: usize, points: usize) Allocator.Error!Triple {
    var sides: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    errdefer for (&sides) |*s| s.deinit(gpa);
    const every = @max(lines / @max(points, 1), 1);
    for (0..lines) |i| {
        for (&sides) |*s| try s.appendSlice(gpa, "x\n");
        if (i % every == every / 2) {
            try sides[1].print(gpa, "ours {d}\n", .{i});
            try sides[2].print(gpa, "theirs {d}\n", .{i});
        }
    }
    const base = try sides[0].toOwnedSlice(gpa);
    errdefer gpa.free(base);
    const ours = try sides[1].toOwnedSlice(gpa);
    errdefer gpa.free(ours);
    return .{ .base = base, .ours = ours, .theirs = try sides[2].toOwnedSlice(gpa) };
}

/// W10: a C-shaped file of `functions` functions, comments above some,
/// blank lines between, and an edit of it touching about one function in
/// ten: what whole-function hunks are for.
pub fn w10(gpa: Allocator, functions: usize) Allocator.Error!Pair {
    const v: Vocabulary = .init();
    var prng: std.Random.DefaultPrng = .init(0x773130);
    const r = prng.random();
    var old: std.ArrayList(u8) = .empty;
    errdefer old.deinit(gpa);
    var new: std.ArrayList(u8) = .empty;
    errdefer new.deinit(gpa);
    for (0..functions) |f| {
        const touched = r.uintLessThan(u8, 10) == 0;
        for ([_]*std.ArrayList(u8){ &old, &new }) |side| {
            if (f % 3 == 0) try side.print(gpa, "/* {s} */\n", .{v.word(f % vocabulary_size)});
            try side.print(gpa, "static int {s}_{d}(int n)\n{{\n", .{ v.word(f % vocabulary_size), f });
        }
        const body = 5 + r.uintLessThan(usize, 30);
        for (0..body) |b| {
            const word = v.word(r.uintLessThan(usize, vocabulary_size));
            try old.print(gpa, "    n += {s}({d});\n", .{ word, b });
            if (touched and r.uintLessThan(u8, 8) == 0) {
                try new.print(gpa, "    n -= {s}({d});\n", .{ word, b });
            } else try new.print(gpa, "    n += {s}({d});\n", .{ word, b });
        }
        for ([_]*std.ArrayList(u8){ &old, &new }) |side| try side.appendSlice(gpa, "    return n;\n}\n\n");
    }
    const old_bytes = try old.toOwnedSlice(gpa);
    errdefer gpa.free(old_bytes);
    return .{ .old = old_bytes, .new = try new.toOwnedSlice(gpa) };
}
