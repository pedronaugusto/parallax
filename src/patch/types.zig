//! What a parsed unified patch holds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Compare = @import("../compare.zig").Compare;

/// One line of a hunk.
pub const Line = struct {
    kind: Kind,
    /// The line without its prefix, newline included unless `no_newline`.
    /// A carriage return before the newline stays.
    text: []const u8,
    /// A "\ No newline at end of file" followed the line.
    no_newline: bool,

    pub const Kind = enum { context, removed, added };
};

/// One `@@` hunk, with its ranges as written: 1-based, and for an empty
/// range the line before it.
pub const Hunk = struct {
    old_start: u32,
    old_len: u32,
    new_start: u32,
    new_len: u32,
    /// The text after the second `@@ `, without its newline; empty when
    /// there is none.
    heading: []const u8,
    lines: []const Line,
};

/// One file's section of a patch.
pub const File = struct {
    /// The lines before `---`, verbatim and without their newlines
    /// ("diff --git ...", "index ...", "rename from ..."): the caller's to
    /// read.
    header: []const []const u8,
    /// The text after `--- ` and `+++ ` up to a tab; null for a section
    /// with a header and no `---`, such as a mode change.
    old_name: ?[]const u8,
    new_name: ?[]const u8,
    hunks: []const Hunk,
};

/// A parsed patch. It borrows the text it was parsed from.
pub const Patch = struct {
    files: []const File,
    /// Private: where the files, headers, hunks and lines live.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(p: *Patch) void {
        p.arena.deinit();
        p.* = undefined;
    }
};

/// Where a parse stopped, and why.
pub const Diagnostics = struct {
    /// 1-based line of the patch.
    line: u32 = 0,
    message: []const u8 = "",
};

pub const ParseOptions = struct {
    diagnostics: ?*Diagnostics = null,
};

pub const ParseError = error{ OutOfMemory, InvalidHunkHeader, HunkLengthMismatch, UnexpectedLine };

pub const Rejects = enum {
    /// Stop at the first hunk that does not apply.
    fail,
    /// Leave it out and go on, as GNU patch does.
    skip,
};

pub const ApplyOptions = struct {
    /// GNU patch's fuzz factor: how many leading and trailing context lines
    /// a hunk may ignore when it does not match as it stands (0 is exact).
    fuzz: u8 = 0,
    /// The furthest a hunk may move from where the hunks before it put it;
    /// null is anywhere after the previous hunk.
    max_offset: ?u32 = null,
    /// Lines match when their comparison forms are the same.
    compare: Compare = .{},
    /// Apply the patch backwards: added lines are removed and removed lines
    /// added.
    reverse: bool = false,
    rejects: Rejects = .fail,
};

/// What became of one hunk.
pub const HunkResult = union(enum) {
    applied: struct {
        /// 0-based line of the base where the hunk's old lines start.
        at: u32,
        /// Lines from where the hunk said it was, counting what the hunks
        /// before it moved, as GNU patch reports it.
        offset: i32,
        /// Context lines ignored at each end.
        fuzz: u8,
    },
    rejected,
};

pub const ApplyError = error{ OutOfMemory, WriteFailed, HunkFailed, InputTooLarge };
