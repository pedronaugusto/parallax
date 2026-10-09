//! The unified diff body, byte for byte what git prints after its headers:
//! `@@` lines with the enclosing heading, context, `-` and `+` lines, and
//! "\ No newline at end of file".

const std = @import("std");
const Io = std.Io;
const Diff = @import("script.zig").Diff;
const hunks_mod = @import("hunks.zig");
const compare = @import("parallax.compare");
const Lines = @import("parallax.lines").Lines;

/// The text after a hunk's second `@@`.
pub const Heading = hunks_mod.Heading;

pub const UnifiedOptions = struct {
    hunks: hunks_mod.HunkOptions = .{},
    heading: ?Heading = null,
    /// Written as "--- {old}\n+++ {new}\n" before the first hunk; null is the
    /// body only.
    files: ?struct { old: []const u8, new: []const u8 } = null,
};

/// Write `diff` as a unified diff. Context lines come from the new side, as
/// git prints them, which shows under a whitespace flag.
pub fn writeUnified(w: *Io.Writer, diff: Diff, options: UnifiedOptions) Io.Writer.Error!void {
    var it = diff.hunks(options.hunks);
    // git looks backwards from each hunk for its heading, stopping where the
    // previous hunk's search began, and keeps the last one found when it
    // finds none.
    var previous_start: i64 = -1;
    var last_found: ?[]const u8 = null;
    var first = true;
    while (it.next()) |hunk| {
        if (first) {
            if (options.files) |files| try w.print("--- {s}\n+++ {s}\n", .{ files.old, files.new });
            first = false;
        }
        try w.writeAll("@@ -");
        try writeRange(w, hunk.old_start, hunk.old_len);
        try w.writeAll(" +");
        try writeRange(w, hunk.new_start, hunk.new_len);
        try w.writeAll(" @@");
        if (options.heading) |heading| {
            const from: i64 = @as(i64, hunk.old_start) - 1;
            if (findHeading(diff.old, from, previous_start, heading)) |text| last_found = text;
            previous_start = from;
            if (last_found) |text| {
                if (text.len != 0) {
                    try w.writeByte(' ');
                    try w.writeAll(text);
                }
            }
        }
        try w.writeByte('\n');

        // The context before the first change is the new side's, counted
        // there, as git prints it; between changes both sides step.
        var new_at = hunk.new_start;
        while (new_at < hunk.changes[0].new_start) : (new_at += 1) try writeLine(w, ' ', diff.new.get(new_at));
        var old_at = hunk.changes[0].old_start;
        for (hunk.changes) |c| {
            while (old_at < c.old_start and new_at < c.new_start) {
                try writeLine(w, ' ', diff.new.get(new_at));
                old_at += 1;
                new_at += 1;
            }
            for (c.old_start..c.old_start + c.old_len) |i| try writeLine(w, '-', diff.old.get(@intCast(i)));
            for (c.new_start..c.new_start + c.new_len) |i| try writeLine(w, '+', diff.new.get(@intCast(i)));
            old_at = c.old_start + c.old_len;
            new_at = c.new_start + c.new_len;
        }
        while (new_at < hunk.new_start + hunk.new_len) {
            try writeLine(w, ' ', diff.new.get(new_at));
            new_at += 1;
        }
    }
}

/// An empty range is printed at the line before it, and with no count when
/// the count is one.
fn writeRange(w: *Io.Writer, start: u32, count: u32) Io.Writer.Error!void {
    if (count == 0) return w.print("{d},0", .{start});
    if (count == 1) return w.print("{d}", .{@as(u64, start) + 1});
    try w.print("{d},{d}", .{ @as(u64, start) + 1, count });
}

fn writeLine(w: *Io.Writer, prefix: u8, line: []const u8) Io.Writer.Error!void {
    try w.writeByte(prefix);
    try w.writeAll(line);
    if (line.len == 0 or line[line.len - 1] != '\n') try w.writeAll("\n\\ No newline at end of file\n");
}

/// The nearest line at or before `from` and after `limit` that `heading`
/// finds, cut at its `max_len` with git's trailing whitespace dropped.
fn findHeading(lines: Lines, from: i64, limit: i64, heading: Heading) ?[]const u8 {
    var at = from;
    while (at > limit and at >= 0 and at < lines.len()) : (at -= 1) {
        var line = lines.get(@intCast(at));
        if (line.len != 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        var text = heading.find(heading.context, line) orelse continue;
        if (text.len > heading.max_len) text = text[0..heading.max_len];
        var end = text.len;
        while (end > 0 and compare.isSpace(text[end - 1])) end -= 1;
        return text[0..end];
    }
    return null;
}
