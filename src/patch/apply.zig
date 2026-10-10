//! Applying one file's hunks to a text, as GNU patch does: each hunk is
//! looked for at its stated line plus the offset the hunks before it found,
//! then further away one line at a time, alternating after and before, never
//! before the end of the previous hunk; when that fails, again with up to
//! `fuzz` context lines ignored at each end. A hunk with less context at one
//! end than the other is held to the start or the end of the file, as GNU
//! patch holds it. The base's lines are kept wherever the hunk has context,
//! so ignored context is never rewritten.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const compare = @import("../compare.zig");
const lines_mod = @import("../lines.zig");
const Lines = lines_mod.Lines;
const types = @import("types.zig");
const Line = types.Line;
const Hunk = types.Hunk;

/// One line of the text a hunk looks for, with its hash.
const Pattern = struct { text: []const u8, hash: u64 };

const State = struct {
    gpa: Allocator,
    w: *Io.Writer,
    base: Lines,
    hashes: []const u64,
    options: types.ApplyOptions,
    /// Base lines, 1-based, already written or deleted.
    frozen: u32 = 0,
    /// How far the hunks so far were from where they said they were.
    offset: i64 = 0,
    /// Whether the output so far ends with a newline.
    after_newline: bool = true,
    pattern: std.ArrayList(Pattern) = .empty,
    /// The first hunk's lines the other way round, for the reversed probe.
    pattern_back: std.ArrayList(Pattern) = .empty,

    fn inputLines(s: *const State) i64 {
        return s.base.len();
    }

    /// Whether the pattern matches the base with its line `pline` (1-based)
    /// at base line `pline - 1 + at`, for the lines `prefix_fuzz` and
    /// `suffix_fuzz` leave.
    fn matches(s: *const State, pat: []const Pattern, at: i64, prefix_fuzz: i64, suffix_fuzz: i64) bool {
        var pline: i64 = 1 + prefix_fuzz;
        const last: i64 = @as(i64, @intCast(pat.len)) - suffix_fuzz;
        while (pline <= last) : (pline += 1) {
            const line = pline - 1 + at;
            if (line < 1 or line > s.inputLines()) return false;
            const i: u32 = @intCast(line - 1);
            const p = pat[@intCast(pline - 1)];
            if (s.hashes[i] != p.hash) return false;
            if (!compare.sameForm(s.base.get(i), p.text, s.options.compare)) return false;
        }
        return true;
    }

    /// GNU patch's `locate_hunk`: the 1-based base line the pattern's first
    /// line goes on, or 0.
    fn locate(s: *State, pat: []const Pattern, shape: Shape, fuzz: i64) i64 {
        const first = shape.first;
        const prefix_context = shape.prefix_context;
        const suffix_context = shape.suffix_context;
        const first_guess = first + s.offset;
        const pat_lines: i64 = @intCast(pat.len);
        const context = @max(prefix_context, suffix_context);
        var prefix_fuzz = fuzz + prefix_context - context;
        const suffix_fuzz = fuzz + suffix_context - context;
        const max_where = s.inputLines() - (pat_lines - suffix_fuzz) + 1;
        const min_where: i64 = @as(i64, s.frozen) + 1;
        const max_pos_offset = max_where - first_guess;
        var max_neg_offset = first_guess - min_where;
        var max_offset = @max(max_pos_offset, max_neg_offset);
        if (s.options.max_offset) |cap| max_offset = @min(max_offset, @as(i64, cap));

        if (pat_lines == 0) return first_guess;
        // No line 0 or before.
        if (first_guess <= max_neg_offset) max_neg_offset = first_guess - 1;

        if (prefix_fuzz < 0 and first <= 1) {
            // Less context before than after: only the start of the file.
            const shift = 1 - first_guess;
            if (s.frozen <= prefix_context and shift <= max_pos_offset and s.allowed(shift) and s.matches(pat, first_guess + shift, 0, suffix_fuzz)) {
                s.offset += shift;
                return first_guess + shift;
            }
            return 0;
        } else if (prefix_fuzz < 0) prefix_fuzz = 0;

        if (suffix_fuzz < 0) {
            // Less context after than before: only the end of the file.
            const shift = first_guess - (s.inputLines() - pat_lines + 1);
            if (shift <= max_neg_offset and s.allowed(shift) and s.matches(pat, first_guess - shift, prefix_fuzz, 0)) {
                s.offset -= shift;
                return first_guess - shift;
            }
            return 0;
        }

        const min_offset: i64 = if (max_pos_offset < 0) first_guess - max_where else if (max_neg_offset < 0) first_guess - min_where else 0;
        var shift = min_offset;
        while (shift <= max_offset) : (shift += 1) {
            if (shift <= max_pos_offset and s.matches(pat, first_guess + shift, prefix_fuzz, suffix_fuzz)) {
                s.offset += shift;
                return first_guess + shift;
            }
            if (shift <= max_neg_offset and s.matches(pat, first_guess - shift, prefix_fuzz, suffix_fuzz)) {
                s.offset -= shift;
                return first_guess - shift;
            }
        }
        return 0;
    }

    /// Whether `max_offset` lets a hunk move `shift` lines.
    fn allowed(s: *const State, shift: i64) bool {
        const cap = s.options.max_offset orelse return true;
        return @abs(shift) <= cap;
    }

    fn write(s: *State, text: []const u8) Io.Writer.Error!void {
        if (text.len == 0) return;
        if (!s.after_newline) try s.w.writeByte('\n');
        try s.w.writeAll(text);
        s.after_newline = text[text.len - 1] == '\n';
    }

    /// Write the base's lines up to and including 1-based line `last`.
    fn copyTill(s: *State, last: i64) Io.Writer.Error!void {
        while (s.frozen < last) {
            s.frozen += 1;
            if (s.frozen <= s.base.len()) try s.write(s.base.get(s.frozen - 1));
        }
    }
};

fn removes(kind: Line.Kind, reverse: bool) bool {
    return kind == if (reverse) Line.Kind.added else Line.Kind.removed;
}

fn adds(kind: Line.Kind, reverse: bool) bool {
    return kind == if (reverse) Line.Kind.removed else Line.Kind.added;
}

/// Where a hunk says it goes, and how much context it has at each end.
const Shape = struct { first: i64, prefix_context: i64, suffix_context: i64 };

/// The lines a hunk looks for when applied forwards or `reverse`, into
/// `pattern`, and where it says they are.
fn prepare(s: *State, pattern: *std.ArrayList(Pattern), h: Hunk, reverse: bool) Allocator.Error!Shape {
    pattern.clearRetainingCapacity();
    var prefix_context: i64 = -1;
    var context: i64 = 0;
    for (h.lines) |line| {
        if (!adds(line.kind, reverse)) try pattern.append(s.gpa, .{ .text = line.text, .hash = compare.hash(line.text, s.options.compare) });
        if (line.kind == .context) {
            context += 1;
        } else {
            if (prefix_context < 0) prefix_context = context;
            context = 0;
        }
    }
    // A hunk of context only, as GNU patch takes it: no change at all.
    if (prefix_context < 0) prefix_context = context;
    const stated_start: i64 = if (reverse) h.new_start else h.old_start;
    return .{
        .first = if (pattern.items.len == 0) stated_start + 1 else stated_start,
        .prefix_context = prefix_context,
        .suffix_context = context,
    };
}

/// Apply one hunk, or say it does not apply. With `hint`, a hunk that does
/// not apply at some fuzz is looked for at that fuzz the other way round
/// too, as GNU patch does for a file's first hunk, and finding it there
/// sets `hint`. The probe moves nothing: the hunk goes on as given.
fn hunk(s: *State, h: Hunk, nonexistent: bool, hint: ?*bool) Allocator.Error!?types.HunkResult {
    const reverse = s.options.reverse;
    const shape = try prepare(s, &s.pattern, h, reverse);
    // The other way round, read only when there is a hint to give.
    const back: Shape = if (hint != null) try prepare(s, &s.pattern_back, h, !reverse) else undefined;
    const max_fuzz = @min(@as(i64, s.options.fuzz), @max(shape.prefix_context, shape.suffix_context));

    var fuzz: i64 = 0;
    var where: i64 = 0;
    while (fuzz <= max_fuzz) : (fuzz += 1) {
        where = s.locate(s.pattern.items, shape, fuzz);
        if (where != 0) break;
        const flag = hint orelse continue;
        if (flag.*) continue;
        const offset = s.offset;
        flag.* = s.locate(s.pattern_back.items, back, fuzz) != 0;
        s.offset = offset;
    }
    if (where == 0) return null;
    if (where == 1 and nonexistent and s.base.text.len != 0) return null;
    // Hunks apply in order; one before the previous one's end garbles.
    if (where - 1 < s.frozen) return null;
    return .{ .applied = .{ .at = @intCast(where - 1), .offset = @intCast(s.offset), .fuzz = @intCast(fuzz) } };
}

/// Write the hunk found at 1-based base line `where`.
fn emit(s: *State, h: Hunk, where: i64) Io.Writer.Error!void {
    const reverse = s.options.reverse;
    var old: i64 = 1;
    for (h.lines) |line| {
        if (removes(line.kind, reverse)) {
            try s.copyTill(where + old - 2);
            s.frozen += 1;
            old += 1;
        } else if (adds(line.kind, reverse)) {
            try s.copyTill(where + old - 2);
            try s.write(line.text);
        } else old += 1;
    }
}

/// Write `base` with `file`'s hunks applied. `results`, one per hunk, is
/// filled when given. With `.fail`, the first hunk that does not apply ends
/// the call with `error.HunkFailed`, its result `.rejected`, and nothing is
/// promised about what `w` holds. A `results` with other than one slot per
/// hunk is `error.InvalidResults`, before anything is written.
pub fn apply(
    gpa: Allocator,
    w: *Io.Writer,
    base: []const u8,
    file: types.File,
    options: types.ApplyOptions,
    results: ?[]types.HunkResult,
) types.ApplyError!void {
    if (results) |r| if (r.len != file.hunks.len) return error.InvalidResults;
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    try lines_mod.split(gpa, &ends, base);
    const lines: Lines = .{ .text = base, .ends = ends.items };
    const hashes = try gpa.alloc(u64, ends.items.len);
    defer gpa.free(hashes);
    for (hashes, 0..) |*h, i| h.* = compare.hash(lines.get(@intCast(i)), options.compare);
    var s: State = .{ .gpa = gpa, .w = w, .base = lines, .hashes = hashes, .options = options };
    defer s.pattern.deinit(gpa);
    defer s.pattern_back.deinit(gpa);
    if (options.reversed_hint) |hint| hint.* = false;

    const old_name = if (options.reverse) file.new_name else file.old_name;
    const nonexistent = if (old_name) |n| std.mem.eql(u8, n, "/dev/null") else false;
    for (file.hunks, 0..) |h, i| {
        const result = try hunk(&s, h, nonexistent, if (i == 0) options.reversed_hint else null) orelse {
            if (results) |r| r[i] = .rejected;
            if (options.rejects == .fail) return error.HunkFailed;
            continue;
        };
        if (results) |r| r[i] = result;
        try emit(&s, h, @as(i64, result.applied.at) + 1);
    }
    try s.copyTill(s.base.len());
}
