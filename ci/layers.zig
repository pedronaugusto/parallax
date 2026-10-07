//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "comparison, lines and flags", .patterns = &.{
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
    .{ .name = "writers", .patterns = &.{
        "src/unified.zig",
        "src/merge.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/parallax.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "diff.corpus",
        "unified.corpus",
        "merge.corpus",
        "gen",
        "builtin",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
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
    "src/refine.zig",
    "src/hunks.zig",
    "src/script.zig",
    "src/threeway.zig",
    "src/Differ.zig",
    "src/unified.zig",
    "src/merge.zig",
    "src/parallax.zig",
    "src/tests.zig",
};
