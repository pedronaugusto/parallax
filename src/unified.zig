//! The unified diff body, byte for byte what git prints after its headers:
//! `@@` lines with the enclosing heading, context, `-` and `+` lines, and
//! "\ No newline at end of file".

const std = @import("std");
const Io = std.Io;
const Diff = @import("script.zig").Diff;
const hunks_mod = @import("hunks.zig");
const compare = @import("compare.zig");
const Lines = @import("lines.zig").Lines;

pub const UnifiedOptions = struct {
    hunks: hunks_mod.HunkOptions = .{},
    /// Write after each hunk's second `@@` the line around it that starts a
    /// function, as `hunks.headingOf` finds it, cut at 80 bytes with its
    /// trailing whitespace dropped: git's function names.
    function_names: bool = false,
    /// Written as "--- {old}\n+++ {new}\n" before the first hunk; null is the
    /// body only.
    files: ?struct { old: []const u8, new: []const u8 } = null,
    /// A context line that is a line ending alone is written without its
    /// space, as git writes it under `diff.suppressBlankEmpty`.
    suppress_blank_empty: bool = false,
};

/// One line of a unified diff, as `writeLine` writes it: what a caller's
/// `paint` is handed.
pub const UnifiedLine = struct {
    kind: Kind,
    /// For `old_file` and `new_file` the name, with no newline. For `hunk`
    /// the two ranges between their `@@`s, `@@` included, with no newline.
    /// For a content line the text after its sign, with its ending where it
    /// has one: a painter ends a line that has none with a newline, as git
    /// does, and an `incomplete` line follows it. For `incomplete` the line
    /// `\ No newline at end of file` with its newline.
    text: []const u8,
    /// For `hunk` the function line, cut and trimmed, empty for none:
    /// written after a space.
    heading: []const u8 = "",
    /// The sign before a content line: ' ', '-' or '+', and 0 for a blank
    /// context line under `suppress_blank_empty`. For `incomplete` the sign
    /// of the line it follows.
    sign: u8 = 0,
    /// A content line's number on its own side, from zero: the new side's
    /// for context.
    number: u32 = 0,

    pub const Kind = enum { old_file, new_file, hunk, context, old, new, incomplete };
};

/// What `writeUnified` fails with given a context of type `Context`: the
/// writer's error, and whatever its `paint` returns.
pub fn WriteError(comptime Context: type) type {
    if (!std.meta.hasMethod(Context, "paint")) return Io.Writer.Error;
    const Self = switch (@typeInfo(Context)) {
        .pointer => |p| p.child,
        else => Context,
    };
    const Return = @typeInfo(@TypeOf(Self.paint)).@"fn".return_type.?;
    return Io.Writer.Error || @typeInfo(Return).error_union.error_set;
}

const no_newline = "\\ No newline at end of file\n";

/// git cuts a function line here before it drops trailing whitespace.
const heading_max_len = 80;

/// Write `diff` as a unified diff. Context lines come from the new side, as
/// git prints them, which shows under a whitespace flag. `context` is the
/// caller's, `.{}` for none; each of its methods is optional:
///
/// - `heading(line: []const u8) ?[]const u8` and `ignore(line: []const u8)
///   bool`, as `HunkOptions` reads them;
/// - `paint(w: *Io.Writer, line: UnifiedLine) !void`, handed every line
///   with what it is, its sign and its number, and writing it in place of
///   `writeLine`: how a caller colours a diff, as git's `--color` does.
pub fn writeUnified(w: *Io.Writer, diff: Diff, options: UnifiedOptions, context: anytype) WriteError(@TypeOf(context))!void {
    var it = diff.hunks(options.hunks);
    // git looks backwards from each hunk for its heading, stopping where the
    // previous hunk's search began, and keeps the last one found when it
    // finds none.
    var previous_start: i64 = -1;
    var last_found: ?[]const u8 = null;
    var first = true;
    while (it.next(context)) |hunk| {
        if (first) {
            if (options.files) |files| {
                try emit(context, w, .{ .kind = .old_file, .text = files.old });
                try emit(context, w, .{ .kind = .new_file, .text = files.new });
            }
            first = false;
        }
        var heading_text: []const u8 = "";
        if (options.function_names) {
            const from: i64 = @as(i64, hunk.old_start) - 1;
            if (findHeading(context, diff.old, from, previous_start)) |text| last_found = text;
            previous_start = from;
            if (last_found) |text| heading_text = text;
        }
        // Two ranges of two 32-bit numbers and their punctuation.
        var buf: [64]u8 = undefined;
        var header: Io.Writer = .fixed(&buf);
        // unreachable: the buffer holds the widest ranges
        writeRanges(&header, hunk.old_start, hunk.old_len, hunk.new_start, hunk.new_len) catch unreachable;
        try emit(context, w, .{ .kind = .hunk, .text = header.buffered(), .heading = heading_text });

        // The context before the first change is the new side's, counted
        // there, as git prints it; between changes both sides step.
        var new_at = hunk.new_start;
        while (new_at < hunk.changes[0].new_start) : (new_at += 1) try writeContext(context, w, options, diff.new.get(new_at), new_at);
        var old_at = hunk.changes[0].old_start;
        for (hunk.changes) |c| {
            while (old_at < c.old_start and new_at < c.new_start) {
                try writeContext(context, w, options, diff.new.get(new_at), new_at);
                old_at += 1;
                new_at += 1;
            }
            for (c.old_start..c.old_start + c.old_len) |i| try writeContent(context, w, .old, '-', diff.old.get(@intCast(i)), @intCast(i));
            for (c.new_start..c.new_start + c.new_len) |i| try writeContent(context, w, .new, '+', diff.new.get(@intCast(i)), @intCast(i));
            old_at = c.old_start + c.old_len;
            new_at = c.new_start + c.new_len;
        }
        while (new_at < hunk.new_start + hunk.new_len) {
            try writeContext(context, w, options, diff.new.get(new_at), new_at);
            new_at += 1;
        }
    }
}

/// Write one line of a unified diff plainly, as `writeUnified` does where
/// its context has no `paint`: what a painter writes for the lines it
/// leaves uncoloured.
pub fn writeLine(w: *Io.Writer, line: UnifiedLine) Io.Writer.Error!void {
    switch (line.kind) {
        .old_file => try w.print("--- {s}\n", .{line.text}),
        .new_file => try w.print("+++ {s}\n", .{line.text}),
        .hunk => {
            try w.writeAll(line.text);
            if (line.heading.len != 0) {
                try w.writeByte(' ');
                try w.writeAll(line.heading);
            }
            try w.writeByte('\n');
        },
        .context, .old, .new => {
            if (line.sign != 0) try w.writeByte(line.sign);
            try w.writeAll(line.text);
            if (line.text.len == 0 or line.text[line.text.len - 1] != '\n') try w.writeByte('\n');
        },
        .incomplete => try w.writeAll(line.text),
    }
}

fn emit(context: anytype, w: *Io.Writer, line: UnifiedLine) WriteError(@TypeOf(context))!void {
    if (comptime std.meta.hasMethod(@TypeOf(context), "paint")) return context.paint(w, line);
    return writeLine(w, line);
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

fn writeContext(context: anytype, w: *Io.Writer, options: UnifiedOptions, line: []const u8, number: u32) WriteError(@TypeOf(context))!void {
    const sign: u8 = if (options.suppress_blank_empty and std.mem.eql(u8, line, "\n")) 0 else ' ';
    try writeContent(context, w, .context, sign, line, number);
}

fn writeContent(context: anytype, w: *Io.Writer, kind: UnifiedLine.Kind, sign: u8, line: []const u8, number: u32) WriteError(@TypeOf(context))!void {
    try emit(context, w, .{ .kind = kind, .text = line, .sign = sign, .number = number });
    const complete = line.len != 0 and line[line.len - 1] == '\n';
    if (!complete) try emit(context, w, .{ .kind = .incomplete, .text = no_newline, .sign = sign });
}

/// The nearest line at or before `from` and after `limit` that starts a
/// function, as `hunks.headingOf` finds it, cut with git's trailing
/// whitespace dropped.
fn findHeading(context: anytype, lines: Lines, from: i64, limit: i64) ?[]const u8 {
    var at = from;
    while (at > limit and at >= 0 and at < lines.len()) : (at -= 1) {
        var line = lines.get(@intCast(at));
        if (line.len != 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        var text = hunks_mod.headingOf(context, line) orelse continue;
        if (text.len > heading_max_len) text = text[0..heading_max_len];
        var end = text.len;
        while (end > 0 and compare.isSpace(text[end - 1])) end -= 1;
        return text[0..end];
    }
    return null;
}
