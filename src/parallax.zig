//! Line and sequence differences, three-way merges and unified patches.
//! One module; its parts are namespaces, and the types most callers want
//! are also declared here.

/// Line diffs and refinement: the workspace, options, scripts and hunks.
pub const diff = @import("diff.zig");
/// Comparison forms: what counts as the same line.
pub const compare = @import("compare.zig");
/// Dense ids for any type with a hash and an equality.
pub const interner = @import("interner.zig");
/// Borrowed line views of a text.
pub const lines = @import("lines.zig");
/// Three-way merge rendering and marker parsing.
pub const merge = @import("merge.zig");
/// Unified patch parsing and application.
pub const patch = @import("patch.zig");

/// Which whitespace differences two lines may have and still be the same.
pub const Whitespace = diff.Whitespace;
/// What counts as the same line: whitespace and ASCII case.
pub const Compare = diff.Compare;
/// Myers, patience or histogram.
pub const Algorithm = diff.Algorithm;
/// A text split at '\n', by end offsets.
pub const Lines = diff.Lines;
/// One run of the script that differs.
pub const Change = diff.Change;
/// Added and removed line counts.
pub const Stat = diff.Stat;
/// One step of the script: equal, delete, insert or replace.
pub const Op = diff.Op;
/// Steps over a diff's script, allocating nothing.
pub const OpIterator = diff.OpIterator;
/// A finished line diff: the two sides and the script.
pub const Diff = diff.Diff;
/// The reusable workspace every diff and merge goes through.
pub const Differ = diff.Differ;
/// Myers forward/backward sweep count.
pub const Work = diff.Work;
/// Retained storage byte count for `Differ.shrink`.
pub const Bytes = diff.Bytes;
/// How a line diff is taken.
pub const Options = diff.Options;
/// How a diff of two id sequences is taken.
pub const SequenceOptions = diff.SequenceOptions;
/// A caller's test of one position of the old sequence.
pub const Predicate = diff.Predicate;
/// A caller's indentation per token.
pub const Indent = diff.Indent;
/// How changes group into hunks.
pub const HunkOptions = diff.HunkOptions;
/// A caller's test of one line, given with its newline.
pub const LinePredicate = diff.LinePredicate;
/// One hunk and the changes inside it.
pub const Hunk = diff.Hunk;
/// Hunks over a diff, allocating nothing.
pub const HunkIterator = diff.HunkIterator;
/// The text after a hunk's second `@@`.
pub const Heading = diff.Heading;
/// How the unified writer writes.
pub const UnifiedOptions = diff.UnifiedOptions;
/// Write a diff as a unified diff body, as git prints it.
pub const writeUnified = diff.writeUnified;
/// An equivalence class, distinct from a sequence position.
pub const ClassId = diff.ClassId;
/// The number of classes in an interning domain.
pub const ClassCount = diff.ClassCount;
/// Dense ids for any type with a hash and an equality.
pub const Interner = diff.Interner;
/// How `Differ.refine` cuts lines into tokens.
pub const Tokens = diff.Tokens;
/// How `Differ.refine` diffs tokens.
pub const RefineOptions = diff.RefineOptions;
/// diff-match-patch's cleanups, for `RefineOptions.cleanup`.
pub const Cleanup = diff.Cleanup;
/// Bytes of one side, changed or not.
pub const Span = diff.Span;
/// The spans of one change, per side.
pub const Refined = diff.Refined;
/// A one-shot diff that owns its workspace memory.
pub const OwnedDiff = diff.OwnedDiff;
/// One-shot line diff, borrowing the input text.
pub const diffLines = diff.diffLines;

test {
    _ = diff;
    _ = merge;
    _ = patch;
}
