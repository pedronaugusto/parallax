//! `zig build bench-corpus -- --repo <git repository> --out <directory>
//! [--range A..B] [--write-manifest]`: the real-history corpus for the
//! benchmarks, made from a git repository by git itself.
//!
//! - `pairs`: every modified regular file of every non-merge commit in the
//!   range, the blob before and the blob after.
//! - `merges`: for every two-parent merge commit in the range, every regular
//!   file both parents changed from their merge base: the base's blob,
//!   the first parent's and the second's.
//!
//! Each is a file of records, each field a little-endian u32 length and the
//! bytes. A `manifest` beside them names the range, its two ends, the counts
//! and a SHA-256 of each file; it must match the committed
//! `bench/linux-v6.11-v6.12.manifest` (unless `--write-manifest`, which
//! writes it there instead), so a run proves it measured the same corpus.
//! git runs with no system or global configuration.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Git = struct {
    gpa: Allocator,
    io: Io,
    repo: []const u8,
    env: *const std.process.Environ.Map,

    /// git's output, which the caller owns.
    fn run(g: Git, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(g.gpa);
        try argv.appendSlice(g.gpa, &.{ "git", "-C", g.repo });
        try argv.appendSlice(g.gpa, args);
        const result = try std.process.run(g.gpa, g.io, .{ .argv = argv.items, .environ_map = g.env });
        defer g.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        g.gpa.free(result.stdout);
        say(g.io, "git {s}: {s}\n", .{ args[0], result.stderr });
        return error.GitFailed;
    }
};

/// `git cat-file --batch`, one blob at a time.
const Blobs = struct {
    child: std.process.Child,
    in: Io.File.Writer,
    out: Io.File.Reader,
    in_buffer: [4096]u8 = undefined,
    out_buffer: [1 << 16]u8 = undefined,

    fn start(b: *Blobs, g: Git) !void {
        b.child = try std.process.spawn(g.io, .{
            .argv = &.{ "git", "-C", g.repo, "cat-file", "--batch" },
            .environ_map = g.env,
            .stdin = .pipe,
            .stdout = .pipe,
        });
        b.in = b.child.stdin.?.writerStreaming(g.io, &b.in_buffer);
        b.out = b.child.stdout.?.readerStreaming(g.io, &b.out_buffer);
    }

    fn stop(b: *Blobs, io: Io) void {
        b.child.stdin.?.close(io);
        b.child.stdin = null;
        _ = b.child.wait(io) catch {};
    }

    /// The blob `oid`, into `out`.
    fn get(b: *Blobs, gpa: Allocator, oid: []const u8, out: *std.ArrayList(u8)) !void {
        try b.in.interface.print("{s}\n", .{oid});
        try b.in.interface.flush();
        const head = try b.out.interface.takeDelimiterExclusive('\n');
        b.out.interface.toss(1);
        var words = std.mem.splitScalar(u8, head, ' ');
        _ = words.next();
        if (!std.mem.eql(u8, words.next() orelse "", "blob")) return error.NotABlob;
        const size = try std.fmt.parseInt(usize, words.next() orelse "", 10);
        try out.resize(gpa, size);
        try b.out.interface.readSliceAll(out.items);
        try b.out.interface.discardAll(1);
    }
};

/// A records file being written, and the hash of every byte of it.
const Records = struct {
    file: Io.File,
    writer: Io.File.Writer,
    buffer: [1 << 16]u8 = undefined,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    count: usize = 0,
    bytes: u64 = 0,

    fn open(r: *Records, io: Io, dir: Io.Dir, name: []const u8) !void {
        r.* = .{ .file = try dir.createFile(io, name, .{}), .writer = undefined };
        r.writer = r.file.writer(io, &r.buffer);
    }

    fn field(r: *Records, bytes: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(bytes.len), .little);
        r.hash.update(&len);
        r.hash.update(bytes);
        try r.writer.interface.writeAll(&len);
        try r.writer.interface.writeAll(bytes);
        r.bytes += bytes.len;
    }

    fn close(r: *Records, io: Io) ![64]u8 {
        try r.writer.interface.flush();
        r.file.close(io);
        return std.fmt.bytesToHex(r.hash.finalResult(), .lower);
    }
};

/// One line of `--raw` output: a modification of a regular file, or null.
const Raw = struct { old: []const u8, new: []const u8, path: []const u8 };

fn raw(line: []const u8) ?Raw {
    if (line.len == 0 or line[0] != ':') return null;
    const tab = std.mem.findScalar(u8, line, '\t') orelse return null;
    var words = std.mem.splitScalar(u8, line[1..tab], ' ');
    const mode_old = words.next() orelse return null;
    const mode_new = words.next() orelse return null;
    const old = words.next() orelse return null;
    const new = words.next() orelse return null;
    const status = words.next() orelse return null;
    const regular = struct {
        fn f(mode: []const u8) bool {
            return std.mem.eql(u8, mode, "100644") or std.mem.eql(u8, mode, "100755");
        }
    }.f;
    if (!std.mem.eql(u8, status, "M") or !regular(mode_old) or !regular(mode_new)) return null;
    return .{ .old = old, .new = new, .path = line[tab + 1 ..] };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var repo: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var range: []const u8 = "v6.11..v6.12";
    var write_manifest = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--write-manifest")) {
            write_manifest = true;
            continue;
        }
        if (i + 1 == args.len) return error.MissingValue;
        if (std.mem.eql(u8, args[i], "--repo")) {
            repo = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--out")) {
            out_path = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--manifest")) {
            manifest_path = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--range")) {
            range = args[i + 1];
        } else return error.UnknownArgument;
        i += 1;
    }

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", init.environ_map.get("PATH") orelse "/usr/bin:/bin");
    try env.put("HOME", init.environ_map.get("HOME") orelse "/");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("LC_ALL", "C");
    const git: Git = .{ .gpa = gpa, .io = io, .repo = repo orelse return error.MissingRepo, .env = &env };

    const dots = std.mem.find(u8, range, "..") orelse return error.BadRange;
    var ends: [2][]const u8 = undefined;
    for (&ends, [_][]const u8{ range[0..dots], range[dots + 2 ..] }) |*end, name| {
        const spec = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{name});
        const out = try git.run(&.{ "rev-parse", spec });
        end.* = try arena.dupe(u8, std.mem.trimEnd(u8, out, "\n"));
        gpa.free(out);
    }

    var out_dir = try Io.Dir.cwd().createDirPathOpen(io, out_path orelse return error.MissingOut, .{});
    defer out_dir.close(io);
    var blobs: Blobs = undefined;
    try blobs.start(git);
    defer blobs.stop(io);
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    var c: std.ArrayList(u8) = .empty;
    defer c.deinit(gpa);

    // The pairs: every modified regular file of every non-merge commit,
    // oldest commit first.
    const log = try git.run(&.{ "log", "--no-merges", "--reverse", "--format=", "-r", "--raw", "--no-renames", "--no-abbrev", range });
    defer gpa.free(log);
    var commits: usize = 0;
    {
        const counted = try git.run(&.{ "rev-list", "--count", "--no-merges", range });
        defer gpa.free(counted);
        commits = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, counted, "\n"), 10);
    }
    var pairs: Records = undefined;
    try pairs.open(io, out_dir, "pairs");
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const r = raw(line) orelse continue;
        try blobs.get(gpa, r.old, &a);
        try blobs.get(gpa, r.new, &b);
        try pairs.field(a.items);
        try pairs.field(b.items);
        pairs.count += 1;
    }
    const pairs_hash = try pairs.close(io);
    say(io, "{d} pairs from {d} commits, {d} MB\n", .{ pairs.count, commits, pairs.bytes / 1_000_000 });

    // The merges: files both parents changed from their merge base.
    const merges_list = try git.run(&.{ "rev-list", "--merges", "--reverse", "--parents", range });
    defer gpa.free(merges_list);
    var merges: Records = undefined;
    try merges.open(io, out_dir, "merges");
    var merge_commits: usize = 0;
    var merge_lines = std.mem.splitScalar(u8, merges_list, '\n');
    while (merge_lines.next()) |line| {
        var words = std.mem.splitScalar(u8, line, ' ');
        _ = words.next() orelse continue;
        const p1 = words.next() orelse continue;
        const p2 = words.next() orelse continue;
        if (words.next() != null) continue;
        merge_commits += 1;
        const base_out = try git.run(&.{ "merge-base", p1, p2 });
        defer gpa.free(base_out);
        const base = std.mem.trimEnd(u8, base_out, "\n");
        const ours = try git.run(&.{ "diff-tree", "-r", "--no-renames", "--no-abbrev", base, p1 });
        defer gpa.free(ours);
        const theirs = try git.run(&.{ "diff-tree", "-r", "--no-renames", "--no-abbrev", base, p2 });
        defer gpa.free(theirs);
        // Both lists come sorted by path: walk them together.
        var it_o = std.mem.splitScalar(u8, ours, '\n');
        var it_t = std.mem.splitScalar(u8, theirs, '\n');
        var o = nextRaw(&it_o);
        var t = nextRaw(&it_t);
        while (o != null and t != null) {
            switch (std.mem.order(u8, o.?.path, t.?.path)) {
                .lt => o = nextRaw(&it_o),
                .gt => t = nextRaw(&it_t),
                .eq => {
                    try blobs.get(gpa, o.?.old, &a);
                    try blobs.get(gpa, o.?.new, &b);
                    try blobs.get(gpa, t.?.new, &c);
                    try merges.field(a.items);
                    try merges.field(b.items);
                    try merges.field(c.items);
                    merges.count += 1;
                    o = nextRaw(&it_o);
                    t = nextRaw(&it_t);
                },
            }
        }
    }
    const merges_hash = try merges.close(io);
    say(io, "{d} triples from {d} merges, {d} MB\n", .{ merges.count, merge_commits, merges.bytes / 1_000_000 });

    const manifest = try std.fmt.allocPrint(arena,
        \\parallax bench corpus 1
        \\range: {s}
        \\from: {s}
        \\to: {s}
        \\commits: {d}
        \\pairs: {d}
        \\pairs bytes: {d}
        \\pairs sha256: {s}
        \\merges: {d}
        \\triples: {d}
        \\triples bytes: {d}
        \\triples sha256: {s}
        \\
    , .{ range, ends[0], ends[1], commits, pairs.count, pairs.bytes, pairs_hash, merge_commits, merges.count, merges.bytes, merges_hash });
    try out_dir.writeFile(io, .{ .sub_path = "manifest", .data = manifest });
    const committed = manifest_path orelse return;
    if (write_manifest) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = committed, .data = manifest });
        return;
    }
    const expected = try Io.Dir.cwd().readFileAlloc(io, committed, arena, .unlimited);
    if (!std.mem.eql(u8, expected, manifest)) {
        say(io, "the corpus differs from {s}:\n{s}", .{ committed, manifest });
        return error.ManifestMismatch;
    }
}

/// A line on stderr.
fn say(io: Io, comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buffer);
    stderr.interface.print(format, args) catch return;
    stderr.interface.flush() catch return;
}

fn nextRaw(it: *std.mem.SplitIterator(u8, .scalar)) ?Raw {
    while (it.next()) |line| if (raw(line)) |r| return r;
    return null;
}
