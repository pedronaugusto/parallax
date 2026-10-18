//! The unified diff body, byte for byte what git prints after its headers:
//! `@@` lines with the enclosing heading, context, `-` and `+` lines, and
//! "\ No newline at end of file".

const std = @import("std");
const Io = std.Io;
const Diff = @import("script.zig").Diff;
const hunks_mod = @import("hunks.zig");
const compare = @import("compare.zig");
const Lines = @import("lines.zig").Lines;

/// The text after a hunk's second `@@`.
pub const Heading = hunks_mod.Heading;

pub const UnifiedOptions = struct {
    hunks: hunks_mod.HunkOptions = .{},
    heading: ?Heading = null,
    /// Written as "--- {old}\n+++ {new}\n" before the first hunk; null is the
    /// body only.
    files: ?struct { old: []const u8, new: []const u8 } = null,
    /// A context line that is a line ending alone is written without its
    /// space, as git writes it under `diff.suppressBlankEmpty`.
    suppress_blank_empty: bool = false,
    /// Who writes each line, in place of the plain writer: a caller that
    /// colours. null writes the lines as they are.
    paint: ?Paint = null,
};

/// A caller that writes every line of the diff itself, given what the line
/// is: how git's diff colours its output, line by line.
pub const Paint = struct {
    context: ?*const anyopaque = null,
    write: *const fn (context: ?*const anyopaque, w: *Io.Writer, line: Line) Io.Writer.Error!void,

    /// One line of a unified diff, as the plain writer would write it.
    pub const Line = struct {
        kind: Kind,
        /// For `old_file` and `new_file` the name, with no newline. For
        /// `hunk` the two ranges between their `@@`s, `@@` included, with
        /// no newline. For a content line the text after its sign, with
        /// its ending where it has one: a painter ends a line that has
        /// none with a newline, as git does, and an `incomplete` line
        /// follows it. For `incomplete` the line `\ No newline at end of
        /// file` with its newline.
        text: []const u8,
        /// For `hunk` the enclosing line the heading found, cut and
        /// trimmed, empty for none: written after a space.
        heading: []const u8 = "",
        /// The sign before a content line: ' ', '-' or '+', and 0 for a
        /// blank context line under `suppress_blank_empty`. For
        /// `incomplete` the sign of the line it follows.
        sign: u8 = 0,
        /// A content line's number on its own side, from zero: the new
        /// side's for context.
        number: u32 = 0,
    };

    pub const Kind = enum { old_file, new_file, hunk, context, old, new, incomplete };
};

const no_newline = "\\ No newline at end of file\n";

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
            if (options.files) |files| {
                if (options.paint) |paint| {
                    try paint.write(paint.context, w, .{ .kind = .old_file, .text = files.old });
                    try paint.write(paint.context, w, .{ .kind = .new_file, .text = files.new });
                } else try w.print("--- {s}\n+++ {s}\n", .{ files.old, files.new });
            }
            first = false;
        }
        var heading_text: []const u8 = "";
        if (options.heading) |heading| {
            const from: i64 = @as(i64, hunk.old_start) - 1;
            if (findHeading(diff.old, from, previous_start, heading)) |text| last_found = text;
            previous_start = from;
            if (last_found) |text| heading_text = text;
        }
        if (options.paint) |paint| {
            // Two ranges of two 32-bit numbers and their punctuation.
            var buf: [64]u8 = undefined;
            var header: Io.Writer = .fixed(&buf);
            // unreachable: the buffer holds the widest ranges
            writeRanges(&header, hunk.old_start, hunk.old_len, hunk.new_start, hunk.new_len) catch unreachable;
            try paint.write(paint.context, w, .{ .kind = .hunk, .text = header.buffered(), .heading = heading_text });
        } else {
            try writeRanges(w, hunk.old_start, hunk.old_len, hunk.new_start, hunk.new_len);
            if (heading_text.len != 0) {
                try w.writeByte(' ');
                try w.writeAll(heading_text);
            }
            try w.writeByte('\n');
        }

        // The context before the first change is the new side's, counted
        // there, as git prints it; between changes both sides step.
        var new_at = hunk.new_start;
        while (new_at < hunk.changes[0].new_start) : (new_at += 1) try writeContext(w, options, diff.new.get(new_at), new_at);
        var old_at = hunk.changes[0].old_start;
        for (hunk.changes) |c| {
            while (old_at < c.old_start and new_at < c.new_start) {
                try writeContext(w, options, diff.new.get(new_at), new_at);
                old_at += 1;
                new_at += 1;
            }
            for (c.old_start..c.old_start + c.old_len) |i| try writeLine(w, options, .old, '-', diff.old.get(@intCast(i)), @intCast(i));
            for (c.new_start..c.new_start + c.new_len) |i| try writeLine(w, options, .new, '+', diff.new.get(@intCast(i)), @intCast(i));
            old_at = c.old_start + c.old_len;
            new_at = c.new_start + c.new_len;
        }
        while (new_at < hunk.new_start + hunk.new_len) {
            try writeContext(w, options, diff.new.get(new_at), new_at);
            new_at += 1;
        }
    }
}

/// `@@ -<old> +<new> @@`.
fn writeRanges(w: *Io.Writer, old_start: u32, old_len: u32, new_start: u32, new_len: u32) Io.Writer.Error!void {
    try w.writeAll("@@ -");
    try writeRange(w, old_start, old_len);
    try w.writeAll(" +");
    try writeRange(w, new_start, new_len);
    try w.writeAll(" @@");
}

/// An empty range is printed at the line before it, and with no count when
/// the count is one.
fn writeRange(w: *Io.Writer, start: u32, count: u32) Io.Writer.Error!void {
    if (count == 0) return w.print("{d},0", .{start});
    if (count == 1) return w.print("{d}", .{@as(u64, start) + 1});
    try w.print("{d},{d}", .{ @as(u64, start) + 1, count });
}

fn writeContext(w: *Io.Writer, options: UnifiedOptions, line: []const u8, number: u32) Io.Writer.Error!void {
    const sign: u8 = if (options.suppress_blank_empty and std.mem.eql(u8, line, "\n")) 0 else ' ';
    try writeLine(w, options, .context, sign, line, number);
}

fn writeLine(w: *Io.Writer, options: UnifiedOptions, kind: Paint.Kind, sign: u8, line: []const u8, number: u32) Io.Writer.Error!void {
    const complete = line.len != 0 and line[line.len - 1] == '\n';
    if (options.paint) |paint| {
        try paint.write(paint.context, w, .{ .kind = kind, .text = line, .sign = sign, .number = number });
        if (!complete) try paint.write(paint.context, w, .{ .kind = .incomplete, .text = no_newline, .sign = sign });
        return;
    }
    if (sign != 0) try w.writeByte(sign);
    try w.writeAll(line);
    if (!complete) try w.writeAll("\n" ++ no_newline);
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
