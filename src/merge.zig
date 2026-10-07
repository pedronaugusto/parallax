//! The three-way line merge: `Differ.merge` gives the regions, `write`
//! renders them as `git merge-file` writes them, and `mergeAlloc` does both
//! in one call.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const threeway = @import("threeway.zig");
const Lines = @import("lines.zig").Lines;
const Differ = @import("Differ.zig");

pub const Style = threeway.Style;
pub const Level = threeway.Level;
pub const Options = threeway.Options;
pub const Range = threeway.Range;
pub const Region = threeway.Region;
pub const Merge = threeway.Merge;

/// What a conflict becomes in the text.
pub const Resolve = enum {
    /// Conflict markers around each side.
    markers,
    /// Our side's lines: git -X ours, merge-file --ours.
    ours,
    /// Their side's lines.
    theirs,
    /// Ours then theirs: git's union merge.
    both,
};

/// The words after the markers. An empty label writes no trailing space.
pub const Labels = struct {
    ours: []const u8 = "ours",
    base: []const u8 = "base",
    theirs: []const u8 = "theirs",
};

pub const WriteOptions = struct {
    labels: Labels = .{},
    /// Characters per marker; 0 means 7, as in git.
    marker_size: u32 = 7,
    resolve: Resolve = .markers,
};

/// Write the merged text. Labels are written verbatim; a newline in one is
/// the caller's to avoid, as in git.
pub fn write(w: *Io.Writer, m: Merge, options: WriteOptions) Io.Writer.Error!void {
    for (m.regions) |r| switch (r.kind) {
        .unchanged, .ours, .same => try copy(w, m.ours, r.ours, false, false),
        .theirs => try copy(w, m.theirs, r.theirs, false, false),
        .conflict => switch (options.resolve) {
            .markers => try conflict(w, m, r, options),
            .ours => try copy(w, m.ours, r.ours, false, false),
            .theirs => try copy(w, m.theirs, r.theirs, false, false),
            .both => {
                try copy(w, m.ours, r.ours, crNeeded(m, r), true);
                try copy(w, m.theirs, r.theirs, false, false);
            },
        },
    };
}

/// The lines of `range`; with `add_newline`, the last one ended with a
/// newline if it has none, a carriage return first under `crlf`.
fn copy(w: *Io.Writer, lines: Lines, range: Range, crlf: bool, add_newline: bool) Io.Writer.Error!void {
    if (range.len == 0) return;
    const text = lines.span(range.start, range.len);
    try w.writeAll(text);
    if (add_newline and (text.len == 0 or text[text.len - 1] != '\n')) {
        if (crlf) try w.writeByte('\r');
        try w.writeByte('\n');
    }
}

fn conflict(w: *Io.Writer, m: Merge, r: Region, options: WriteOptions) Io.Writer.Error!void {
    const crlf = crNeeded(m, r);
    const size = if (options.marker_size == 0) 7 else options.marker_size;
    try marker(w, '<', size, options.labels.ours, crlf);
    try copy(w, m.ours, r.ours, crlf, true);
    if (m.style != .merge) {
        try marker(w, '|', size, options.labels.base, crlf);
        try copy(w, m.base, r.base, crlf, true);
    }
    try marker(w, '=', size, "", crlf);
    try copy(w, m.theirs, r.theirs, crlf, true);
    try marker(w, '>', size, options.labels.theirs, crlf);
}

fn marker(w: *Io.Writer, c: u8, size: u32, label: []const u8, crlf: bool) Io.Writer.Error!void {
    try w.splatByteAll(c, size);
    if (label.len != 0) {
        try w.writeByte(' ');
        try w.writeAll(label);
    }
    if (crlf) try w.writeByte('\r');
    try w.writeByte('\n');
}

/// git's `is_eol_crlf`: whether line `i` ends in a carriage return and a
/// newline, looking at the line before when the last has no newline. Null
/// when there is nothing to tell by.
fn endsCrlf(lines: Lines, i: u32) ?bool {
    const n = lines.len();
    if (@as(u64, i) + 1 < n) return crlfLine(lines.get(i));
    if (n == 0) return null;
    const line = lines.get(i);
    if (line.len != 0 and line[line.len - 1] == '\n') return crlfLine(line);
    if (i == 0) return null;
    return crlfLine(lines.get(i - 1));
}

fn crlfLine(line: []const u8) bool {
    return line.len > 1 and line[line.len - 2] == '\r';
}

/// git's `is_cr_needed`: markers end in a carriage return when the lines
/// before the conflict on both sides, and the base's first line, do.
fn crNeeded(m: Merge, r: Region) bool {
    var needs = endsCrlf(m.ours, if (r.ours.start > 0) r.ours.start - 1 else 0);
    if (needs != false) needs = endsCrlf(m.theirs, if (r.theirs.start > 0) r.theirs.start - 1 else 0);
    if (needs != false) needs = endsCrlf(m.base, 0);
    return needs orelse false;
}

/// A merged text the caller owns.
pub const Merged = struct {
    bytes: []u8,
    /// Conflicts left in `bytes` as markers.
    conflicts: u32,
    gpa: Allocator,

    pub fn deinit(m: *Merged) void {
        m.gpa.free(m.bytes);
        m.* = undefined;
    }
};

/// Merge and write in one call, into memory the caller owns.
pub fn mergeAlloc(
    gpa: Allocator,
    base: []const u8,
    ours: []const u8,
    theirs: []const u8,
    options: Options,
    write_options: WriteOptions,
) Differ.Error!Merged {
    var d: Differ = .init(gpa);
    defer d.deinit();
    const m = try d.merge(base, ours, theirs, options);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(&out.writer, m, write_options) catch return error.OutOfMemory;
    return .{
        .bytes = try out.toOwnedSlice(),
        .conflicts = if (write_options.resolve == .markers) m.conflicts else 0,
        .gpa = gpa,
    };
}
