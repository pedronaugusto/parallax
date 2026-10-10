//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "comparison, lines and flags", .patterns = &.{
        "src/fit.zig",
        "src/compare.zig",
        "src/lines.zig",
        "src/flags.zig",
        "src/interner.zig",
    } },
    .{ .name = "changes", .patterns = &.{
        "src/change.zig",
    } },
    .{ .name = "line table", .patterns = &.{
        "src/table.zig",
    } },
    .{ .name = "myers", .patterns = &.{
        "src/myers.zig",
    } },
    .{ .name = "histogram", .patterns = &.{
        "src/histogram.zig",
    } },
    .{ .name = "patience and the slide", .patterns = &.{
        "src/patience.zig",
        "src/slide.zig",
    } },
    .{ .name = "one diff", .patterns = &.{
        "src/core.zig",
    } },
    .{ .name = "token cleanup", .patterns = &.{
        "src/cleanup.zig",
    } },
    .{ .name = "refinement", .patterns = &.{
        "src/refine.zig",
    } },
    .{ .name = "hunks", .patterns = &.{
        "src/hunks.zig",
    } },
    .{ .name = "script", .patterns = &.{
        "src/script.zig",
    } },
    .{ .name = "three-way regions", .patterns = &.{
        "src/threeway.zig",
    } },
    .{ .name = "workspace", .patterns = &.{
        "src/Differ.zig",
    } },
    .{ .name = "unified writer", .patterns = &.{"src/unified.zig"} },
    .{ .name = "diff facade", .patterns = &.{"src/diff.zig"} },
    .{ .name = "patch types", .patterns = &.{
        "src/patch/types.zig",
    } },
    .{ .name = "patch hunks", .patterns = &.{
        "src/patch/hunk.zig",
    } },
    .{ .name = "patch parse and apply", .patterns = &.{
        "src/patch/parse.zig",
        "src/patch/apply.zig",
    } },
    .{ .name = "merge writer", .patterns = &.{
        "src/merge.zig",
    } },
    .{ .name = "patches", .patterns = &.{
        "src/patch.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/parallax.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "fit", .path = "src/fit.zig" },
    .{ .name = "cleanup", .path = "src/cleanup.zig" },
    .{ .name = "change", .path = "src/change.zig" },
    .{ .name = "flags", .path = "src/flags.zig" },
    .{ .name = "parallax.diff", .path = "src/diff.zig" },
    .{ .name = "parallax.merge", .path = "src/merge.zig" },
    .{ .name = "parallax.patch", .path = "src/patch.zig" },
    .{ .name = "parallax.interner", .path = "src/interner.zig" },
    .{ .name = "parallax.lines", .path = "src/lines.zig" },
    .{ .name = "parallax.compare", .path = "src/compare.zig" },
};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "aegis",
        "diff.corpus",
        "unified.corpus",
        "merge.corpus",
        "patch.corpus",
        "function.corpus",
        "markers.corpus",
        "reversed.corpus",
        "cleanup.corpus",
        "gen",
        "shakedown",
        "builtin",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/fit.zig",
    "src/compare.zig",
    "src/lines.zig",
    "src/flags.zig",
    "src/interner.zig",
    "src/change.zig",
    "src/table.zig",
    "src/myers.zig",
    "src/histogram.zig",
    "src/patience.zig",
    "src/slide.zig",
    "src/core.zig",
    "src/cleanup.zig",
    "src/refine.zig",
    "src/hunks.zig",
    "src/script.zig",
    "src/threeway.zig",
    "src/Differ.zig",
    "src/unified.zig",
    "src/merge.zig",
    "src/patch/types.zig",
    "src/patch/parse.zig",
    "src/patch/apply.zig",
    "src/patch.zig",
    "src/diff.zig",
    "src/parallax.zig",
    "src/tests.zig",
};
