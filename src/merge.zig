//! The three-way line merge: `Differ.merge` gives the regions, `write`
//! renders them as `git merge-file` writes them, and `mergeAlloc` does both
//! in one call. `parseMarkers` reads conflict markers back out of text.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const diff = @import("parallax.diff");
const Lines = @import("parallax.lines").Lines;
const Differ = diff.Differ;
const compare_mod = @import("parallax.compare");

pub const Style = diff.MergeStyle;
pub const Level = diff.MergeLevel;
pub const Options = diff.MergeOptions;
pub const Range = diff.Range;
pub const Region = diff.Region;
pub const Merge = diff.Merge;
pub const SequenceOptions = diff.MergeSequenceOptions;
pub const SequenceMerge = diff.SequenceMerge;

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

/// How `parseMarkers` reads.
pub const MarkerOptions = struct {
    /// Characters per marker; 0 means 7, as in git. A longer run of the
    /// character is not a marker.
    marker_size: u32 = 7,
};

/// One conflict read back from marked text. Every slice borrows the text.
pub const Conflict = struct {
    /// Our side's lines as they stand between the markers. A conflict
    /// nested inside a side stays in its bytes.
    ours: []const u8,
    /// The base's lines, when the conflict has them (the diff3 and zdiff3
    /// styles); null otherwise.
    base: ?[]const u8,
    theirs: []const u8,
    /// The text after each marker, without the space before it or the line
    /// end; empty for a marker with none.
    labels: Labels,
    /// The whole conflict, markers included.
    whole: []const u8,
};

/// A stretch of marked text: plain text, or one conflict.
pub const Part = union(enum) {
    text: []const u8,
    conflict: Conflict,
};

pub const MarkerError = error{
    /// The text ends inside a conflict.
    UnterminatedConflict,
    /// A marker out of order inside a conflict: a base or `=======` marker
    /// after the `=======`, or a closing marker before it.
    MisplacedMarker,
    /// Conflicts nested more than 64 deep.
    TooDeep,
};

/// The parts of `text`, in order: what `write` produced, read back. A
/// conflict opens at a line of `marker_size` `<` and closes at one of `>`,
/// each alone on its line or followed by a space and a label; between them
/// an optional `|` line (followed by whitespace or the line end) starts the
/// base and an `=` line their side. Marker lines outside a conflict are
/// text, and a conflict inside a side is part of that side, as git's rerere
/// reads them. Allocates nothing.
pub fn parseMarkers(text: []const u8, options: MarkerOptions) MarkerIterator {
    return .{ .text = text, .size = if (options.marker_size == 0) 7 else options.marker_size };
}

pub const MarkerIterator = struct {
    /// Private: the text and the marker size.
    text: []const u8,
    size: u32,
    /// Private: where the next part starts.
    at: usize = 0,
    /// Lines read so far; after an error, the 1-based line it is on.
    line: u32 = 0,

    const Side = enum(u2) { ours, base, theirs };

    /// The next part, or null at the end of the text.
    pub fn next(it: *MarkerIterator) MarkerError!?Part {
        if (it.at >= it.text.len) return null;
        const from = it.at;
        if (markerLine(it.peek(), '<', it.size)) |label| return .{ .conflict = try it.conflict(label) };
        while (it.at < it.text.len) {
            const line = it.peek();
            if (markerLine(line, '<', it.size) != null) break;
            it.pass(line);
        }
        return .{ .text = it.text[from..it.at] };
    }

    /// The line at the cursor, with its newline.
    fn peek(it: *const MarkerIterator) []const u8 {
        const end = if (std.mem.findScalarPos(u8, it.text, it.at, '\n')) |nl| nl + 1 else it.text.len;
        return it.text[it.at..end];
    }

    /// Step over `line`, the one at the cursor.
    fn pass(it: *MarkerIterator, line: []const u8) void {
        it.at += line.len;
        it.line += 1;
    }

    /// One conflict, its opening marker at the cursor. Each open conflict,
    /// the outermost first, keeps the side it is in as two bits of `sides`.
    fn conflict(it: *MarkerIterator, label: []const u8) MarkerError!Conflict {
        const start = it.at;
        it.pass(it.peek());
        var c: Conflict = .{ .ours = "", .base = null, .theirs = "", .labels = .{ .ours = label, .base = "", .theirs = "" }, .whole = "" };
        var section = it.at;
        var sides: u128 = 0;
        var depth: u7 = 1;
        while (it.at < it.text.len) {
            const at = it.at;
            const line = it.peek();
            it.pass(line);
            const shift: u7 = 2 * (depth - 1);
            const side: Side = @fromBackingInt(@intCast(@as(u2, @truncate(sides >> shift))));
            if (markerLine(line, '<', it.size) != null) {
                if (depth == 64) return error.TooDeep;
                depth += 1;
                sides &= ~(@as(u128, 3) << (shift + 2));
            } else if (markerLine(line, '|', it.size)) |base_label| {
                if (side != .ours) return error.MisplacedMarker;
                sides = (sides & ~(@as(u128, 3) << shift)) | (@as(u128, @backingInt(Side.base)) << shift);
                if (depth == 1) {
                    c.ours = it.text[section..at];
                    c.labels.base = base_label;
                    section = it.at;
                }
            } else if (markerLine(line, '=', it.size) != null) {
                if (side == .theirs) return error.MisplacedMarker;
                sides = (sides & ~(@as(u128, 3) << shift)) | (@as(u128, @backingInt(Side.theirs)) << shift);
                if (depth == 1) {
                    if (side == .ours) c.ours = it.text[section..at] else c.base = it.text[section..at];
                    section = it.at;
                }
            } else if (markerLine(line, '>', it.size)) |theirs_label| {
                if (side != .theirs) return error.MisplacedMarker;
                depth -= 1;
                if (depth == 0) {
                    c.theirs = it.text[section..at];
                    c.labels.theirs = theirs_label;
                    c.whole = it.text[start..it.at];
                    return c;
                }
            }
        }
        return error.UnterminatedConflict;
    }
};

/// The label of `line` when it is a marker of `size` `char`s, as git's
/// `is_cmarker` reads one: whitespace after the run, and a space before the
/// label of an opening or closing marker. A marker alone on its line is one
/// too, as `write` writes it for an empty label.
fn markerLine(line: []const u8, char: u8, size: u32) ?[]const u8 {
    if (line.len <= size) return null;
    for (line[0..size]) |c| if (c != char) return null;
    const rest = line[size..];
    if (rest[0] == '\n' or std.mem.eql(u8, rest, "\r\n")) return "";
    if (char == '<' or char == '>') {
        if (rest[0] != ' ') return null;
    } else if (!compare_mod.isSpace(rest[0])) return null;
    var label = rest[1..];
    if (label.len != 0 and label[label.len - 1] == '\n') label = label[0 .. label.len - 1];
    if (label.len != 0 and label[label.len - 1] == '\r') label = label[0 .. label.len - 1];
    return label;
}
