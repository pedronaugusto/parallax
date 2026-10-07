//! What counts as the same line: git's whitespace flags, ASCII case, and the
//! comparison form two lines share exactly when they are the same line.
//!
//! The form is never built. It is streamed into the hash while the lines are
//! scanned, and compared byte against byte when two hashes meet.

const std = @import("std");

/// Which whitespace differences two lines may have and still be the same
/// line: git's `XDF_WHITESPACE_FLAGS`. Each takes in what the ones after it
/// do.
pub const Whitespace = struct {
    /// git -w, GNU -w: every whitespace byte.
    all: bool = false,
    /// git -b, GNU -b: how much whitespace, not whether.
    change: bool = false,
    /// git --ignore-space-at-eol, GNU -Z: whitespace at the end of the line.
    at_eol: bool = false,
    /// git --ignore-cr-at-eol, GNU --strip-trailing-cr: a carriage return
    /// before the newline.
    cr_at_eol: bool = false,

    /// Whether any whitespace is ignored at all.
    pub fn any(ws: Whitespace) bool {
        return ws.all or ws.change or ws.at_eol or ws.cr_at_eol;
    }
};

/// What counts as the same line.
pub const Compare = struct {
    whitespace: Whitespace = .{},
    /// ASCII letters only, as GNU -i. git has no such flag.
    ignore_case: bool = false,

    /// Whether two lines are equal only when their bytes are.
    pub fn exact(c: Compare) bool {
        return !c.whitespace.any() and !c.ignore_case;
    }
};

/// git's whitespace class, which is git's `isspace`: space, tab, newline and
/// carriage return. Vertical tab and form feed are not in it.
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn fold(c: u8, on: bool) u8 {
    return if (on) std.ascii.toLower(c) else c;
}

/// The comparison form of one line, produced in chunks.
///
/// With no flag the form is the line, newline and all, so a final line that
/// lacks one never equals a line that has one: the distinction git prints as
/// "\ No newline at end of file". Under any whitespace flag the newline is
/// whitespace like the rest, as in git. Two lines have the same form exactly
/// when git puts them in one class: the same hash, and `xdl_recmatch`.
pub const Form = struct {
    line: []const u8,
    at: usize,
    end: usize,
    mode: Mode,
    lower: bool,

    const Mode = enum { verbatim, all, change };

    pub fn init(line: []const u8, compare: Compare) Form {
        const ws = compare.whitespace;
        var f: Form = .{ .line = line, .at = 0, .end = line.len, .mode = .verbatim, .lower = compare.ignore_case };
        if (ws.all) {
            f.mode = .all;
        } else if (ws.change or ws.at_eol) {
            while (f.end > 0 and isSpace(line[f.end - 1])) f.end -= 1;
            if (ws.change) f.mode = .change;
        } else if (ws.cr_at_eol) {
            // A newline goes, and a carriage return before it; a line with
            // no newline keeps its carriage return.
            if (f.end > 0 and line[f.end - 1] == '\n') {
                f.end -= 1;
                if (f.end > 0 and line[f.end - 1] == '\r') f.end -= 1;
            }
        }
        return f;
    }

    /// Up to `buf.len` more bytes of the form; empty at the end.
    pub fn fill(f: *Form, buf: []u8) []u8 {
        var n: usize = 0;
        switch (f.mode) {
            .verbatim => {
                n = @min(buf.len, f.end - f.at);
                @memcpy(buf[0..n], f.line[f.at..][0..n]);
                f.at += n;
            },
            .all => while (n < buf.len and f.at < f.end) : (f.at += 1) {
                const c = f.line[f.at];
                buf[n] = c;
                n += @intFromBool(!space[c]);
            },
            .change => while (n < buf.len and f.at < f.end) : (n += 1) {
                const c = f.line[f.at];
                if (space[c]) {
                    // The end is trimmed, so a run inside always ends
                    // before it.
                    while (space[f.line[f.at]]) f.at += 1;
                    buf[n] = ' ';
                } else {
                    buf[n] = c;
                    f.at += 1;
                }
            },
        }
        if (f.lower) for (buf[0..n]) |*c| {
            c.* = std.ascii.toLower(c.*);
        };
        return buf[0..n];
    }
};

/// git's whitespace class as a table.
const space: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for (" \t\n\r") |c| t[c] = true;
    break :blk t;
};

/// The hash of a line's comparison form.
pub fn hash(line: []const u8, compare: Compare) u64 {
    if (compare.exact()) return std.hash.Wyhash.hash(0, line);
    var form: Form = .init(line, compare);
    var buf: [256]u8 = undefined;
    const first = form.fill(&buf);
    // A form that fits is hashed in one call; the streaming hash gives the
    // same value for a longer one.
    if (form.at == form.end) return std.hash.Wyhash.hash(0, first);
    var h: std.hash.Wyhash = .init(0);
    h.update(first);
    while (true) {
        const chunk = form.fill(&buf);
        if (chunk.len == 0) break;
        h.update(chunk);
    }
    return h.final();
}

/// Whether two lines have the same comparison form.
pub fn sameForm(a: []const u8, b: []const u8, compare: Compare) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (compare.exact()) return false;
    var fa: Form = .init(a, compare);
    var fb: Form = .init(b, compare);
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    var ca: []u8 = &.{};
    var cb: []u8 = &.{};
    while (true) {
        if (ca.len == 0) ca = fa.fill(&buf_a);
        if (cb.len == 0) cb = fb.fill(&buf_b);
        if (ca.len == 0 or cb.len == 0) return ca.len == 0 and cb.len == 0;
        const n = @min(ca.len, cb.len);
        if (!std.mem.eql(u8, ca[0..n], cb[0..n])) return false;
        ca = ca[n..];
        cb = cb[n..];
    }
}

/// Whether two lines are the same once what `compare` ignores is
/// overlooked: git's `xdl_recmatch`, plus ASCII case. Lines of one form
/// always match; the converse fails only for git's one quirk, a carriage
/// return ending a line with no newline under `cr_at_eol` alone.
pub fn sameLine(a: []const u8, b: []const u8, compare: Compare) bool {
    const lower = compare.ignore_case;
    if (std.mem.eql(u8, a, b)) return true;
    const ws = compare.whitespace;
    if (!ws.any()) return lower and std.ascii.eqlIgnoreCase(a, b);
    var i: usize = 0;
    var j: usize = 0;
    if (ws.all) {
        while (true) {
            while (i < a.len and isSpace(a[i])) i += 1;
            while (j < b.len and isSpace(b[j])) j += 1;
            if (i == a.len or j == b.len) break;
            if (fold(a[i], lower) != fold(b[j], lower)) return false;
            i += 1;
            j += 1;
        }
    } else if (ws.change) {
        while (i < a.len and j < b.len) {
            if (isSpace(a[i]) and isSpace(b[j])) {
                while (i < a.len and isSpace(a[i])) i += 1;
                while (j < b.len and isSpace(b[j])) j += 1;
                continue;
            }
            if (fold(a[i], lower) != fold(b[j], lower)) return false;
            i += 1;
            j += 1;
        }
    } else if (ws.at_eol) {
        while (i < a.len and j < b.len and fold(a[i], lower) == fold(b[j], lower)) {
            i += 1;
            j += 1;
        }
    } else {
        while (i < a.len and j < b.len and fold(a[i], lower) == fold(b[j], lower)) {
            i += 1;
            j += 1;
        }
        return (i == a.len or endsWithOptionalCr(a, i)) and (j == b.len or endsWithOptionalCr(b, j));
    }
    // One side has run out: what is left of the other has to be whitespace.
    while (i < a.len and isSpace(a[i])) i += 1;
    while (j < b.len and isSpace(b[j])) j += 1;
    return i == a.len and j == b.len;
}

/// Whether `line` from `at` on is its newline, perhaps after a carriage
/// return. A line with no newline keeps its carriage return.
fn endsWithOptionalCr(line: []const u8, at: usize) bool {
    const complete = line.len != 0 and line[line.len - 1] == '\n';
    const end = if (complete) line.len - 1 else line.len;
    if (end == at) return true;
    return complete and end == at + 1 and line[at] == '\r';
}

/// git's `xdl_blankline`: with no whitespace flag a line of at most one byte
/// (git's quirk: a one-byte last line without a newline counts), otherwise a
/// line of whitespace only.
pub fn isBlank(line: []const u8, ws: Whitespace) bool {
    if (!ws.any()) return line.len <= 1;
    for (line) |c| if (!isSpace(c)) return false;
    return true;
}

test "lines match under each flag as git's xdl_recmatch matches them" {
    const change: Compare = .{ .whitespace = .{ .change = true } };
    try std.testing.expect(sameLine("a  b\n", "a\tb\n", change));
    try std.testing.expect(sameLine("a b \n", "a b", change));
    try std.testing.expect(!sameLine(" a\n", "a\n", change));
    try std.testing.expect(!sameLine("ab\n", "a b\n", change));
    try std.testing.expect(sameLine("ab\n", "a b\n", .{ .whitespace = .{ .all = true } }));
    try std.testing.expect(sameLine("a \t\n", "a", .{ .whitespace = .{ .at_eol = true } }));
    try std.testing.expect(!sameLine("a  b\n", "a b\n", .{ .whitespace = .{ .at_eol = true } }));
    const cr: Compare = .{ .whitespace = .{ .cr_at_eol = true } };
    try std.testing.expect(sameLine("a\r\n", "a\n", cr));
    try std.testing.expect(sameLine("a\r\n", "a", cr));
    try std.testing.expect(!sameLine("a\r", "a\n", cr));
    try std.testing.expect(!sameLine("a \n", "a\n", cr));
    // The quirk: the comparison matches these, their forms part them.
    try std.testing.expect(sameLine("a\r", "a\r\n", cr));
    try std.testing.expect(!sameForm("a\r", "a\r\n", cr));
    try std.testing.expect(!sameLine("a\n", "a \n", .{}));
    try std.testing.expect(sameLine("A b\n", "a B\n", .{ .ignore_case = true }));
    try std.testing.expect(sameLine("A  b\n", "a B\n", .{ .ignore_case = true, .whitespace = .{ .change = true } }));
}

test "vertical tab and form feed are not whitespace, as in git" {
    try std.testing.expect(!sameLine("a\x0bb\n", "a b\n", .{ .whitespace = .{ .change = true } }));
    try std.testing.expect(!sameLine("a\x0c\n", "a\n", .{ .whitespace = .{ .at_eol = true } }));
    try std.testing.expect(!sameForm("a\x0c\n", "a\n", .{ .whitespace = .{ .all = true } }));
    try std.testing.expect(!isBlank("\x0c\n", .{ .all = true }));
}
