//! Unified patches: `parse` reads one, with any number of files, and
//! `apply` applies one file's hunks to a text with GNU patch's rules for
//! offset and fuzz. git's own apply rules (extended headers, three-way
//! fallback, whitespace fixing) are not here: the header lines are kept
//! verbatim for a caller that layers them.

const types = @import("patch/types.zig");
const hunk = @import("patch/hunk.zig");

/// One line of a hunk: context, removed or added.
pub const Line = types.Line;
/// One `@@` hunk.
pub const Hunk = types.Hunk;
/// One file's section: header lines, names and hunks.
pub const File = types.File;
/// A parsed patch, borrowing its text.
pub const Patch = types.Patch;
/// Where a parse stopped, and why.
pub const Diagnostics = types.Diagnostics;
/// How `parse` reads.
pub const ParseOptions = types.ParseOptions;
/// Why `parse` stopped.
pub const ParseError = types.ParseError;
/// How `apply` applies.
pub const ApplyOptions = types.ApplyOptions;
/// What `apply` does with a hunk that does not apply.
pub const Rejects = types.Rejects;
/// What became of one hunk.
pub const HunkResult = types.HunkResult;
/// Why `apply` stopped.
pub const ApplyError = types.ApplyError;
/// Whose reading of a hunk: GNU patch's or `git apply`'s.
pub const Dialect = hunk.Dialect;
/// An `@@` line's ranges and heading.
pub const HunkHeader = hunk.Header;
/// A hunk's header line, or null when it is none.
pub const parseHunkHeader = hunk.parseHeader;
/// How `scanHunk` reads: the dialect, `--recount`, where a refusal stopped.
pub const HunkScanOptions = hunk.ScanOptions;
/// What `scanHunk` measured: the header, the extent, the context around the changes.
pub const HunkScan = hunk.Scan;
/// Why a hunk is refused.
pub const HunkScanError = types.ScanError;
/// Check the hunk at the start of a text and measure it, allocating nothing.
pub const scanHunk = hunk.scan;
/// The lines of a scanned hunk, one at a time, allocating nothing.
pub const HunkLines = hunk.HunkLines;
/// Read a unified patch. The result borrows the text.
pub const parse = @import("patch/parse.zig").parse;
/// Write a text with one file's hunks applied.
pub const apply = @import("patch/apply.zig").apply;

test {
    _ = @import("patch/hunk.zig");
    _ = @import("patch/parse.zig");
}
