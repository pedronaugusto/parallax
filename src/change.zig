//! The edit script's unit, and reading it off the two flag arrays.

const std = @import("std");
const Allocator = std.mem.Allocator;
/// Change flags shared by the algorithm entry points.
pub const Flags = @import("flags.zig").Flags;

/// Which algorithm produces the edit script.
pub const Algorithm = enum { myers, patience, histogram };

/// One run that differs: `old_len` lines from `old_start` replaced by
/// `new_len` lines from `new_start`. Runs ascend strictly on both sides and
/// never touch.
// aegis: measured-boundary: docs/design.md#numeric-boundaries; script ranges are produced from bounded line/sequence flags and stay compact in script iteration.
pub const Change = struct {
    old_start: u32,
    old_len: u32,
    new_start: u32,
    new_len: u32,
};

/// Read the two flag arrays as changes, appended to `out`. Unchanged lines
/// match one for one, so both sides advance together over them and each
/// change is a run where either side is flagged.
pub fn build(gpa: Allocator, out: *std.ArrayList(Change), fa: Flags, fb: Flags) Allocator.Error!void {
    var at_a: u32 = 0;
    var at_b: u32 = 0;
    while (at_a < fa.len or at_b < fb.len) {
        const flagged_a = at_a < fa.len and fa.get(at_a);
        const flagged_b = at_b < fb.len and fb.get(at_b);
        if (flagged_a or flagged_b) {
            const from_a = at_a;
            const from_b = at_b;
            while (at_a < fa.len and fa.get(at_a)) at_a += 1;
            while (at_b < fb.len and fb.get(at_b)) at_b += 1;
            try out.append(gpa, .{ .old_start = from_a, .old_len = at_a - from_a, .new_start = from_b, .new_len = at_b - from_b });
        } else {
            at_a += 1;
            at_b += 1;
        }
    }
}
