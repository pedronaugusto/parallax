//! The grammar of one hunk: its `@@` line, the lines its counts bound, and
//! the markers after them. `scan` checks a hunk and measures it without
//! allocating, and `HunkLines` reads its lines back, so a caller that keeps
//! the patch text pays nothing per line. `parse` is built on both.
//!
//! Two dialects read the same shape. `.gnu` is GNU patch's: a line that
//! begins with a tab or a newline is a context line whose space was lost,
//! any `\` line after a line marks it as the last one without a newline, and
//! a hunk may hold nothing but context. `.git` is `git apply`'s, rule for
//! rule: every line of a hunk ends in a newline, the counts decide where it
//! ends, a hunk with no change is refused (unless the counts are taken from
//! its lines), a `\ No newline at end of file` marker is the one line right
//! after a line, and anything else is refused.

const std = @import("std");
const aegis = @import("aegis");
const types = @import("types.zig");
const Line = types.Line;

/// Which program's reading of a hunk.
pub const Dialect = enum { gnu, git };

/// An `@@ -a[,b] +c[,d] @@[ heading]` line, its ranges as written: 1-based,
/// and for an empty range the line before it. The `.git` reading takes
/// 64-bit numbers, as `git apply` does on a 64-bit machine; `.gnu`'s are
/// under 2^32.
pub const Header = struct {
    old_start: u64,
    old_len: u64,
    new_start: u64,
    new_len: u64,
    /// The text after the second `@@ ` without its line ending; empty when
    /// there is none.
    heading: []const u8,
};

/// The end of the line that begins `text`, past its newline when it has one.
pub fn lineLength(text: []const u8) usize {
    return if (std.mem.findScalar(u8, text, '\n')) |nl| nl + 1 else text.len;
}

/// A hunk's header line, or null when `line` is none. The `.git` reading
/// takes whatever follows the second `@@`; `.gnu` takes a heading after a
/// space, or nothing.
pub fn parseHeader(line: []const u8, dialect: Dialect) ?Header {
    return (headerAt(line, dialect) orelse return null).header;
}

const Parsed = struct { header: Header, end: usize };

fn headerAt(head: []const u8, dialect: Dialect) ?Parsed {
    if (!std.mem.startsWith(u8, head, "@@ -")) return null;
    var at: usize = "@@ -".len;
    const limit: u64 = if (dialect == .gnu) std.math.maxInt(u32) else std.math.maxInt(u64);
    const old = range(head, &at, limit) orelse return null;
    if (!std.mem.startsWith(u8, head[at..], " +")) return null;
    at += 2;
    const new = range(head, &at, limit) orelse return null;
    if (!std.mem.startsWith(u8, head[at..], " @@")) return null;
    at += 3;
    var heading = head[at..];
    if (heading.len != 0 and heading[heading.len - 1] == '\n') heading = heading[0 .. heading.len - 1];
    if (heading.len != 0 and heading[heading.len - 1] == '\r') heading = heading[0 .. heading.len - 1];
    if (heading.len != 0 and heading[0] == ' ') {
        heading = heading[1..];
    } else if (heading.len != 0 and dialect == .gnu) return null;
    return .{
        .header = .{ .old_start = old[0], .old_len = old[1], .new_start = new[0], .new_len = new[1], .heading = heading },
        .end = at,
    };
}

fn range(head: []const u8, at: *usize, limit: u64) ?[2]u64 {
    const start = number(head, at, limit) orelse return null;
    if (at.* < head.len and head[at.*] == ',') {
        at.* += 1;
        return .{ start, number(head, at, limit) orelse return null };
    }
    return .{ start, 1 };
}

fn number(head: []const u8, at: *usize, limit: u64) ?u64 {
    var value: aegis.int.Checked(u64) = .init(0);
    const from = at.*;
    while (at.* < head.len and std.ascii.isDigit(head[at.*])) : (at.* += 1) {
        value = (value.mul(10) catch return null).add(head[at.*] - '0') catch return null;
        if (value.raw() > limit) return null;
    }
    if (at.* == from) return null;
    return value.raw();
}

pub const ScanOptions = struct {
    dialect: Dialect = .git,
    /// Take the counts from the lines that follow the header, not from the
    /// header: `git apply --recount`. Only the `.git` reading has it.
    recount: bool = false,
    /// Where a refusal stopped: the 1-based line of the scanned text it is
    /// about, which is the line after the last one when the text ends first.
    diagnostics: ?*types.Diagnostics = null,
};

/// Which kinds of line some line of ends in CR LF.
pub const Endings = struct { context: bool = false, removed: bool = false, added: bool = false };

/// What `scan` measured.
pub const Scan = struct {
    /// The header, its counts those of the lines when they were recounted.
    header: Header,
    /// Bytes of the hunk: the header line and everything it holds.
    consumed: usize,
    /// Lines of the hunk: the header, every line and every marker.
    lines: u64,
    /// Context lines before the first change and after the last; a hunk of
    /// context alone has them all in both.
    leading: u64,
    trailing: u64,
    added: u64,
    removed: u64,
    /// The kinds of line that end in CR LF, a line a marker follows not
    /// ending in a newline at all.
    crlf: Endings,
};

pub const ScanError = types.ScanError;

/// Check the hunk that begins `text` and measure it. Nothing is allocated and
/// the text is not kept.
pub fn scan(text: []const u8, options: ScanOptions) ScanError!Scan {
    var s: Scanner = .{ .text = text, .options = options };
    return s.run();
}

const Scanner = struct {
    text: []const u8,
    options: ScanOptions,
    at: usize = 0,
    read: u64 = 0,

    fn fail(s: *const Scanner, err: ScanError, offending: bool, message: []const u8) ScanError {
        if (s.options.diagnostics) |d| d.* = .{ .line = std.math.lossyCast(u32, s.read + @intFromBool(!offending)), .message = message };
        return err;
    }

    fn run(s: *Scanner) ScanError!Scan {
        const dialect = s.options.dialect;
        const head_len = lineLength(s.text);
        s.read = 1;
        const head = s.text[0..head_len];
        if (dialect == .git and (head.len == 0 or head[head.len - 1] != '\n')) return s.fail(error.InvalidHunkHeader, true, "a hunk header has no line ending");
        const parsed = headerAt(head, dialect) orelse return s.fail(error.InvalidHunkHeader, true, "a hunk header is not @@ -a,b +c,d @@");
        var header = parsed.header;
        if (s.options.recount and dialect == .git) recount(s.text[parsed.end..], &header);
        s.at = head_len;
        var old_left: u64 = header.old_len;
        var new_left: u64 = header.new_len;
        var out: Scan = .{ .header = header, .consumed = 0, .lines = 0, .leading = 0, .trailing = 0, .added = 0, .removed = 0, .crlf = .{} };
        var last_is_line = false;
        while (old_left != 0 or new_left != 0) {
            const rest = s.text[s.at..];
            if (rest.len == 0) return s.fail(error.HunkLengthMismatch, false, "the patch ends inside a hunk");
            const len = lineLength(rest);
            s.read += 1;
            if (dialect == .git and rest[len - 1] != '\n') return s.fail(error.HunkLengthMismatch, true, "the patch ends inside a hunk");
            // The marker a line is followed by takes the line's newline.
            const marker = if (dialect == .git) gitMarker(rest, len) else 0;
            const crlf = marker == 0 and len >= 2 and rest[len - 1] == '\n' and rest[len - 2] == '\r';
            switch (rest[0]) {
                ' ', '\n', '\t' => {
                    if (rest[0] == '\t' and dialect != .gnu) return s.fail(error.UnexpectedLine, true, "a line in a hunk starts with none of ' ', '-', '+' or '\\'");
                    if (old_left == 0 or new_left == 0) return s.fail(error.HunkLengthMismatch, true, "a hunk holds more lines than its header says");
                    old_left -= 1;
                    new_left -= 1;
                    if (out.added == 0 and out.removed == 0) out.leading += 1;
                    out.trailing += 1;
                    out.crlf.context = out.crlf.context or crlf;
                },
                '-' => {
                    if (old_left == 0) return s.fail(error.HunkLengthMismatch, true, "a hunk holds more lines than its header says");
                    old_left -= 1;
                    out.removed += 1;
                    out.trailing = 0;
                    out.crlf.removed = out.crlf.removed or crlf;
                },
                '+' => {
                    if (new_left == 0) return s.fail(error.HunkLengthMismatch, true, "a hunk holds more lines than its header says");
                    new_left -= 1;
                    out.added += 1;
                    out.trailing = 0;
                    out.crlf.added = out.crlf.added or crlf;
                },
                '\\' => {
                    if (dialect != .gnu) return s.fail(error.UnexpectedLine, true, "a line in a hunk starts with none of ' ', '-', '+' or '\\'");
                    if (!last_is_line) return s.fail(error.UnexpectedLine, true, "a no-newline marker with no line before it");
                    s.at += len;
                    continue;
                },
                else => return s.fail(error.UnexpectedLine, true, "a line in a hunk starts with none of ' ', '-', '+' or '\\'"),
            }
            last_is_line = true;
            s.at += len;
            if (marker != 0) {
                s.at += marker;
                s.read += 1;
            }
        }
        // A marker after the last line is part of the hunk too.
        s.consumeTrailingMarkers(last_is_line);
        if (dialect == .git and !s.options.recount and out.added == 0 and out.removed == 0) return s.fail(error.HunkWithoutChange, true, "a hunk changes nothing");
        out.consumed = s.at;
        out.lines = s.read;
        return out;
    }

    /// GNU patch takes `\` lines after the last counted line; git's reading
    /// took its one marker with the line before.
    fn consumeTrailingMarkers(s: *Scanner, last_is_line: bool) void {
        if (s.options.dialect != .gnu or !last_is_line) return;
        while (s.at < s.text.len and s.text[s.at] == '\\') {
            s.at += lineLength(s.text[s.at..]);
            s.read += 1;
        }
    }
};

/// The length of the `\ No newline` line `rest[len..]` begins, when `rest`'s
/// first line, `len` long, is one it can follow: git's `adjust_incomplete`.
fn gitMarker(rest: []const u8, len: usize) usize {
    const first = rest[0];
    if (first != '\n' and first != ' ' and first != '+' and first != '-') return 0;
    if (rest.len - len < 12 or !std.mem.startsWith(u8, rest[len..], "\\ ")) return 0;
    const next = lineLength(rest[len..]);
    if (next < 12) return 0;
    return next;
}

/// `git apply --recount`: the counts the lines after the header give. `rest`
/// begins after the header's second `@@`; the counts stay the header's when
/// a line is none a hunk holds.
fn recount(rest: []const u8, header: *Header) void {
    var old_lines: u64 = 0;
    var new_lines: u64 = 0;
    var body = rest;
    if (body.len == 0) return;
    while (true) {
        const len = lineLength(body);
        body = body[len..];
        if (body.len == 0) break;
        switch (body[0]) {
            ' ', '\n' => {
                new_lines +|= 1;
                old_lines +|= 1;
                continue;
            },
            '-' => {
                old_lines +|= 1;
                continue;
            },
            '+' => {
                new_lines +|= 1;
                continue;
            },
            '\\' => continue,
            '@' => if (body.len < 3 or !std.mem.startsWith(u8, body, "@@ ")) return,
            'd' => if (body.len < 5 or !std.mem.startsWith(u8, body, "diff ")) return,
            else => return,
        }
        break;
    }
    header.old_len = old_lines;
    header.new_len = new_lines;
}

/// The lines of a hunk already checked by `scan`, one at a time and without
/// allocating. `body` is the hunk after its header line.
pub const HunkLines = struct {
    body: []const u8,
    dialect: Dialect,
    /// Lines of `body` read so far, markers included: with the header's own,
    /// the offset of the next from the hunk's first line.
    read: u64 = 0,
    /// The last line returned had no prefix: an empty context line whose
    /// space was lost.
    bare: bool = false,

    pub fn init(body: []const u8, dialect: Dialect) HunkLines {
        return .{ .body = body, .dialect = dialect };
    }

    /// The next line, or null at the end of the body or at a line no hunk
    /// holds.
    pub fn next(it: *HunkLines) ?Line {
        while (true) {
            if (it.body.len == 0) return null;
            const len = lineLength(it.body);
            const line = it.body[0..len];
            const first = line[0];
            if (first == '\\') {
                // A marker with no line before it: only the `.gnu` reading
                // lets one pass, as it did in `scan`.
                if (it.dialect != .gnu) return null;
                it.body = it.body[len..];
                it.read += 1;
                continue;
            }
            const kind: Line.Kind, var text: []const u8 = switch (first) {
                ' ' => .{ .context, line[1..] },
                '-' => .{ .removed, line[1..] },
                '+' => .{ .added, line[1..] },
                '\n' => .{ .context, line },
                '\t' => if (it.dialect == .gnu) .{ .context, line } else return null,
                else => return null,
            };
            it.bare = first == '\n' or first == '\t';
            var taken = len;
            var marked = false;
            switch (it.dialect) {
                .git => {
                    const marker = gitMarker(it.body, len);
                    if (marker != 0) {
                        marked = true;
                        taken += marker;
                        it.read += 1;
                    }
                },
                .gnu => while (taken < it.body.len and it.body[taken] == '\\') {
                    marked = true;
                    taken += lineLength(it.body[taken..]);
                    it.read += 1;
                },
            }
            if (marked and text.len != 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
            it.body = it.body[taken..];
            it.read += 1;
            return .{ .kind = kind, .text = text, .no_newline = text.len == 0 or text[text.len - 1] != '\n' };
        }
    }
};

test "header numbers accept the u32 maximum and refuse decimal overflow" {
    const largest = parseHeader("@@ -4294967295,0 +4294967295,0 @@", .gnu).?;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), largest.old_start);
    try std.testing.expect(parseHeader("@@ -4294967296,0 +1,0 @@", .gnu) == null);
    try std.testing.expect(parseHeader("@@ -1,0 +99999999999999999999999,0 @@", .gnu) == null);
    try std.testing.expect(parseHeader("@@ -1,4294967296 +1,0 @@", .gnu) == null);
    // git's numbers are 64 bits, and past them it refuses too.
    try std.testing.expectEqual(@as(u64, 4294967296), parseHeader("@@ -4294967296,0 +1,0 @@", .git).?.old_start);
    try std.testing.expectEqual(std.math.maxInt(u64), parseHeader("@@ -1,0 +18446744073709551615,0 @@", .git).?.new_start);
    try std.testing.expect(parseHeader("@@ -1,0 +18446744073709551616,0 @@", .git) == null);
}

test "the readings differ at the end of a header and in what a hunk may hold" {
    // git takes anything after the second @@; GNU patch a heading after a space.
    try std.testing.expect(parseHeader("@@ -1 +1 @@x\n", .git) != null);
    try std.testing.expect(parseHeader("@@ -1 +1 @@x\n", .gnu) == null);
    try std.testing.expectEqualStrings("int f(void)", parseHeader("@@ -1 +1 @@ int f(void)\n", .git).?.heading);
    // GNU patch takes a tab-led line as context and a hunk of context alone;
    // git does neither.
    const context_only = "@@ -1,2 +1,2 @@\n a\n b\n";
    _ = try scan(context_only, .{ .dialect = .gnu });
    try std.testing.expectError(error.HunkWithoutChange, scan(context_only, .{ .dialect = .git }));
    const recounted = try scan(context_only, .{ .dialect = .git, .recount = true });
    try std.testing.expectEqual(@as(u64, 2), recounted.leading);
    try std.testing.expectEqual(@as(u64, 2), recounted.trailing);
    try std.testing.expectEqual(@as(usize, context_only.len), recounted.consumed);
    const tab = "@@ -2,2 +2,2 @@\n-a\n+b\n\tc\n";
    _ = try scan(tab, .{ .dialect = .gnu });
    try std.testing.expectError(error.UnexpectedLine, scan(tab, .{ .dialect = .git }));
}

test "scan measures a hunk and stops where its counts do" {
    const text = "@@ -1,4 +1,4 @@ fn\n a\n-b\n+B\n c\n d\n@@ -9 +9 @@\n";
    const s = try scan(text, .{});
    try std.testing.expectEqual(@as(u64, 1), s.leading);
    try std.testing.expectEqual(@as(u64, 2), s.trailing);
    try std.testing.expectEqual(@as(u64, 1), s.added);
    try std.testing.expectEqual(@as(u64, 1), s.removed);
    try std.testing.expectEqual(@as(u64, 6), s.lines);
    try std.testing.expectEqualStrings("fn", s.header.heading);
    try std.testing.expectEqualStrings("@@ -9 +9 @@\n", text[s.consumed..]);
}

test "a no-newline marker is one line after a line, and the hunk takes it" {
    const text = "@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\nrest\n";
    const s = try scan(text, .{});
    try std.testing.expectEqual(@as(u64, 5), s.lines);
    try std.testing.expectEqualStrings("rest\n", text[s.consumed..]);
    var it: HunkLines = .init(text["@@ -1 +1 @@\n".len..s.consumed], .git);
    const removed = it.next().?;
    try std.testing.expectEqual(Line.Kind.removed, removed.kind);
    try std.testing.expectEqualStrings("a", removed.text);
    try std.testing.expect(removed.no_newline);
    const added = it.next().?;
    try std.testing.expectEqualStrings("b", added.text);
    try std.testing.expect(added.no_newline);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(@as(u64, 4), it.read);
    // Git reads a short marker as no marker, and then as a line it refuses.
    try std.testing.expectError(error.UnexpectedLine, scan("@@ -1 +1 @@\n-a\n\\ No\n+b\n", .{}));
    _ = try scan("@@ -1 +1 @@\n-a\n\\ No\n+b\n", .{ .dialect = .gnu });
}

test "the failing line is the one refused, or the one that never came" {
    var d: types.Diagnostics = .{};
    try std.testing.expectError(error.UnexpectedLine, scan("@@ -1,2 +1,2 @@\n a\n*b\n", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(u32, 3), d.line);
    try std.testing.expectError(error.HunkLengthMismatch, scan("@@ -1,2 +1,2 @@\n a\n", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(u32, 3), d.line);
    try std.testing.expectError(error.HunkLengthMismatch, scan("@@ -1 +1 @@\n a", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(u32, 2), d.line);
    try std.testing.expectError(error.InvalidHunkHeader, scan("@@ -1 +1 @@", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(u32, 1), d.line);
}

test "fuzz: any text scans or is refused by name, and what scans reads back" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: *std.testing.Smith) anyerror!void {
            var buffer: [256]u8 = undefined;
            const len = input.slice(&buffer);
            const text = buffer[0..len];
            inline for (.{ Dialect.gnu, Dialect.git }) |dialect| {
                for ([_]bool{ false, true }) |recounted| {
                    const s = scan(text, .{ .dialect = dialect, .recount = recounted }) catch continue;
                    try std.testing.expect(s.consumed <= text.len);
                    var it: HunkLines = .init(text[lineLength(text)..s.consumed], dialect);
                    var old: u64 = 0;
                    var new: u64 = 0;
                    while (it.next()) |line| {
                        if (line.kind != .added) old += 1;
                        if (line.kind != .removed) new += 1;
                    }
                    try std.testing.expectEqual(s.header.old_len, old);
                    try std.testing.expectEqual(s.header.new_len, new);
                }
            }
        }
    }.run, .{});
}

test "a scan says which kinds of line end in CR LF, and a marker takes a line's newline" {
    const s = try scan("@@ -1,2 +1,2 @@\n a\r\n-b\n+c\r\n d\n", .{});
    try std.testing.expect(s.crlf.context);
    try std.testing.expect(!s.crlf.removed);
    try std.testing.expect(s.crlf.added);
    // The newline of the last line is the marker's to take, so no CR LF is left.
    const marked = try scan("@@ -1 +1 @@\n-a\r\n\\ No newline at end of file\n+b\n", .{});
    try std.testing.expect(!marked.crlf.removed);
    try std.testing.expect(!marked.crlf.added);
    const bare = try scan("@@ -1,2 +1,2 @@\n\n-b\r\n+c\n", .{});
    try std.testing.expect(!bare.crlf.context);
    try std.testing.expect(bare.crlf.removed);
}
