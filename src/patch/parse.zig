//! Reading a unified patch: one or more files, each with the header lines
//! before its `---`, its names, and its hunks. The text is borrowed, never
//! copied; the parse is one pass, linear in the text.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Line = types.Line;
const Hunk = types.Hunk;
const File = types.File;
const hunk_mod = @import("hunk.zig");

/// The lines of the patch, each with its newline.
// aegis: design: docs/design.md#numeric-boundaries; Reader offsets advance only through bounded slices, while header arithmetic is checked separately.
const Reader = struct {
    text: []const u8,
    at: usize = 0,
    number: u32 = 0,

    fn peek(r: *const Reader) ?[]const u8 {
        if (r.at >= r.text.len) return null;
        const end = if (std.mem.findScalarPos(u8, r.text, r.at, '\n')) |nl| nl + 1 else r.text.len;
        return r.text[r.at..end];
    }

    fn next(r: *Reader) ?[]const u8 {
        const line = r.peek() orelse return null;
        r.at += line.len;
        r.number += 1;
        return line;
    }

    /// The line after the next one.
    fn peekSecond(r: *const Reader) ?[]const u8 {
        var copy = r.*;
        _ = copy.next() orelse return null;
        return copy.peek();
    }
};

fn chomp(line: []const u8) []const u8 {
    return if (line.len != 0 and line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
}

/// A file name: the text after the marker up to a tab, without a carriage
/// return.
fn fileName(line: []const u8) []const u8 {
    var name = chomp(line)[4..];
    if (std.mem.findScalar(u8, name, '\t')) |tab| name = name[0..tab];
    if (name.len != 0 and name[name.len - 1] == '\r') name = name[0 .. name.len - 1];
    return name;
}

const Parser = struct {
    arena: Allocator,
    reader: Reader,
    diagnostics: ?*types.Diagnostics,
    files: std.ArrayList(File) = .empty,
    header: std.ArrayList([]const u8) = .empty,
    header_has_diff: bool = false,

    fn fail(p: *Parser, err: types.ParseError, message: []const u8) types.ParseError {
        if (p.diagnostics) |d| d.* = .{ .line = p.reader.number, .message = message };
        return err;
    }

    fn flushHeaderOnly(p: *Parser) Allocator.Error!void {
        try p.files.append(p.arena, .{ .header = try p.header.toOwnedSlice(p.arena), .old_name = null, .new_name = null, .hunks = &.{} });
        p.header_has_diff = false;
    }

    fn run(p: *Parser) types.ParseError!void {
        while (p.reader.peek()) |line| {
            if (std.mem.startsWith(u8, line, "--- ")) {
                if (p.reader.peekSecond()) |second| if (std.mem.startsWith(u8, second, "+++ ")) {
                    _ = p.reader.next();
                    _ = p.reader.next();
                    try p.section(fileName(line), fileName(second));
                    continue;
                };
            }
            if (std.mem.startsWith(u8, line, "@@ -")) {
                try p.section(null, null);
                continue;
            }
            if (std.mem.startsWith(u8, line, "diff ")) {
                if (p.header_has_diff) try p.flushHeaderOnly();
                p.header_has_diff = true;
            }
            try p.header.append(p.arena, chomp(line));
            _ = p.reader.next();
        }
        // A section that never reached `---` is a file only when git's
        // header started it; anything else after the last hunk is not a
        // file at all.
        if (p.header_has_diff) try p.flushHeaderOnly();
    }

    /// The hunks of one file, after its names.
    fn section(p: *Parser, old_name: ?[]const u8, new_name: ?[]const u8) types.ParseError!void {
        var hunks: std.ArrayList(Hunk) = .empty;
        while (p.reader.peek()) |line| {
            if (!std.mem.startsWith(u8, line, "@@ -")) break;
            try hunks.append(p.arena, try p.hunk());
        }
        try p.files.append(p.arena, .{
            .header = try p.header.toOwnedSlice(p.arena),
            .old_name = old_name,
            .new_name = new_name,
            .hunks = try hunks.toOwnedSlice(p.arena),
        });
        p.header_has_diff = false;
    }

    fn hunk(p: *Parser) types.ParseError!Hunk {
        const rest = p.reader.text[p.reader.at..];
        var diagnostics: types.Diagnostics = .{};
        const scanned = hunk_mod.scan(rest, .{ .dialect = .gnu, .diagnostics = &diagnostics }) catch |err| {
            p.reader.number += diagnostics.line;
            return p.fail(switch (err) {
                error.HunkWithoutChange => unreachable, // unreachable: only the git reading refuses a hunk for changing nothing
                error.InvalidHunkHeader, error.HunkLengthMismatch, error.UnexpectedLine => |e| e,
            }, diagnostics.message);
        };
        var h: Hunk = .{
            .old_start = narrow(scanned.header.old_start),
            .old_len = narrow(scanned.header.old_len),
            .new_start = narrow(scanned.header.new_start),
            .new_len = narrow(scanned.header.new_len),
            .heading = scanned.header.heading,
            .lines = &.{},
        };
        var lines: std.ArrayList(Line) = .empty;
        var it: hunk_mod.HunkLines = .init(rest[hunk_mod.lineLength(rest)..scanned.consumed], .gnu);
        while (it.next()) |line| try lines.append(p.arena, line);
        h.lines = try lines.toOwnedSlice(p.arena);
        p.reader.at += scanned.consumed;
        p.reader.number += aegis.int.cast(u32, scanned.lines) catch return p.fail(error.HunkLengthMismatch, "a hunk too long to number its lines");
        return h;
    }
};

/// A header number the gnu reading has already held under 2^32.
fn narrow(value: u64) u32 {
    return @intCast(value); // safe: the gnu reading refuses a header number above u32's maximum
}

/// Read a unified patch. The result borrows `text`.
pub fn parse(gpa: Allocator, text: []const u8, options: types.ParseOptions) types.ParseError!types.Patch {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var p: Parser = .{ .arena = arena.allocator(), .reader = .{ .text = text }, .diagnostics = options.diagnostics };
    try p.run();
    return .{ .files = p.files.items, .arena = arena };
}

test "a git patch: header lines, names, hunks, headings and the no-newline marker" {
    const text = "diff --git a/x.c b/x.c\n" ++
        "index 1234567..89abcde 100644\n" ++
        "--- a/x.c\t2026-10-07\n" ++
        \\+++ b/x.c
        \\@@ -1,3 +1,3 @@ int main(void)
        \\ a
        \\-b
        \\+B
        \\ c
        \\@@ -10 +10,0 @@
        \\-gone
        \\diff --git a/mode b/mode
        \\old mode 100644
        \\new mode 100755
        \\diff --git a/y b/y
        \\--- a/y
        \\+++ b/y
        \\@@ -1 +1 @@
        \\-old
        \\\ No newline at end of file
        \\+new
        \\\ No newline at end of file
        \\
    ;
    var patch = try parse(std.testing.allocator, text, .{});
    defer patch.deinit();
    try std.testing.expectEqual(@as(usize, 3), patch.files.len);
    const x = patch.files[0];
    try std.testing.expectEqual(@as(usize, 2), x.header.len);
    try std.testing.expectEqualStrings("index 1234567..89abcde 100644", x.header[1]);
    try std.testing.expectEqualStrings("a/x.c", x.old_name.?);
    try std.testing.expectEqualStrings("b/x.c", x.new_name.?);
    try std.testing.expectEqual(@as(usize, 2), x.hunks.len);
    try std.testing.expectEqualStrings("int main(void)", x.hunks[0].heading);
    try std.testing.expectEqual(@as(usize, 4), x.hunks[0].lines.len);
    try std.testing.expectEqual(Line.Kind.added, x.hunks[0].lines[2].kind);
    try std.testing.expectEqualStrings("B\n", x.hunks[0].lines[2].text);
    try std.testing.expectEqual([4]u32{ 10, 1, 10, 0 }, [4]u32{ x.hunks[1].old_start, x.hunks[1].old_len, x.hunks[1].new_start, x.hunks[1].new_len });
    try std.testing.expectEqualStrings("", x.hunks[1].heading);
    const mode = patch.files[1];
    try std.testing.expect(mode.old_name == null);
    try std.testing.expectEqual(@as(usize, 3), mode.header.len);
    const y = patch.files[2];
    try std.testing.expectEqualStrings("old", y.hunks[0].lines[0].text);
    try std.testing.expect(y.hunks[0].lines[0].no_newline);
    try std.testing.expectEqualStrings("new", y.hunks[0].lines[1].text);
    try std.testing.expect(y.hunks[0].lines[1].no_newline);
}

test "a malformed hunk says what and where" {
    var diagnostics: types.Diagnostics = .{};
    try std.testing.expectError(error.HunkLengthMismatch, parse(std.testing.allocator, "--- a\n+++ b\n@@ -1,3 +1,2 @@\n a\n-b\n+c\n", .{ .diagnostics = &diagnostics }));
    // The line after the last, where the hunk wanted another.
    try std.testing.expectEqual(@as(u32, 7), diagnostics.line);
    try std.testing.expectError(error.InvalidHunkHeader, parse(std.testing.allocator, "--- a\n+++ b\n@@ -x +1 @@\n", .{ .diagnostics = &diagnostics }));
    try std.testing.expectEqual(@as(u32, 3), diagnostics.line);
    try std.testing.expectError(error.UnexpectedLine, parse(std.testing.allocator, "--- a\n+++ b\n@@ -1 +1 @@\n*a\n", .{ .diagnostics = &diagnostics }));
    try std.testing.expectError(error.HunkLengthMismatch, parse(std.testing.allocator, "--- a\n+++ b\n@@ -1 +1 @@\n-a\n-b\n", .{}));
}
