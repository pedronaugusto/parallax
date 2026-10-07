# parallax

parallax is a line diff and a three-way line merge in Zig. Its output is git's,
byte for byte: the same edit scripts under Myers, minimal, patience, anchored and
histogram, the same hunks and unified body, and the same merged text in the
merge, diff3 and zdiff3 styles. It has no Io: every call is pure computation, and
a reusable workspace makes no allocation once it is warm.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/parallax`, then obtain the `parallax` module
through `b.dependency` and add it to your executable's imports. parallax has no
dependencies and makes no OS calls; it builds for every target,
wasm32-freestanding included.

## Usage

A `Differ` is the workspace every diff goes through; a diff borrows it until the
next call:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const parallax = @import("parallax");

// One workspace for many diffs: once warm it allocates nothing.
var differ: parallax.Differ = .init(gpa);
defer differ.deinit();
const diff = try differ.lines("a\nb\nc\n", "a\nB\nc\nd\n", .{ .algorithm = .histogram });
std.debug.assert(diff.changes.len == 2);
std.debug.assert(diff.stat().added == 2);
// The unified body, as `git diff` prints it.
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try parallax.writeUnified(&out.writer, diff, .{ .heading = .c_function });
std.debug.assert(std.mem.eql(u8, out.written(), "@@ -1,3 +1,4 @@\n a\n-b\n+B\n c\n+d\n"));
```
<!-- END GENERATED -->

A merge gives regions in the order of our side, and `merge.write` renders them as
`git merge-file` does:

<!-- BEGIN GENERATED zig build docs -- merge -->
```zig
const parallax = @import("parallax");

var differ: parallax.Differ = .init(gpa);
defer differ.deinit();
const m = try differ.merge("one\nbase\nend\n", "one\nours\nend\n", "one\ntheirs\nend\n", .{ .style = .diff3 });
std.debug.assert(m.conflicts == 1);
for (m.regions) |region| switch (region.kind) {
    .conflict => std.debug.assert(region.ours.start == 1 and region.ours.len == 1),
    else => {},
};
// The text `git merge-file --diff3` writes.
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try parallax.merge.write(&out.writer, m, .{ .labels = .{ .ours = "HEAD", .base = "base", .theirs = "topic" } });
std.debug.assert(std.mem.startsWith(u8, out.written(), "one\n<<<<<<< HEAD\nours\n||||||| base\nbase\n=======\ntheirs\n>>>>>>> topic\n"));
```
<!-- END GENERATED -->

## Design

Every line becomes a dense `u32` id. The texts are split at `\n` without copying
them; each line is hashed once while it is scanned, the comparison form under the
whitespace flags streamed into the hash with no copy, and bytes are compared only
when two hashes meet. The algorithms then work on ids alone: arrays indexed by
id, with a generation stamp, replace every hash map, and the counts the prune
step needs cost the size of the region, not of the file.

Myers has git's shape: the common ends trimmed, lines with no counterpart and
lines too common to matter set aside, the linear-space middle-snake split, and
git's give-up rules, which change the answer on large or noisy input and so are
kept exactly. Patience and histogram are git's decision for decision, including
the regions they hand to Myers. Every run of changes is then slid where git puts
it, by the indentation heuristic or to line up with a change on the other side.
Every recursion in git is an explicit work stack here, taken in the same order,
so stack use is constant: the deep inputs diff on a 64 KiB stack.

`Options.max_work` caps the work a diff may do, in Myers sweeps; past it the rest
is described as one deletion and one insertion. The cap is a count, not a clock,
so the answer is the same on every machine.

A merge interns its three texts into one table, diffs both sides against the
base, and walks the two scripts as git does. The style and level decide whether a
conflict is narrowed to the lines that really differ, joined with a close
neighbour, or (zdiff3) trimmed of the lines both sides share at its ends. The
result is regions; labels, marker size and how a conflict resolves are the
writer's.

### Comparison

| `Compare` field | git | Lines that are the same |
|---|---|---|
| `whitespace.all` | `-w` | ignoring every whitespace byte |
| `whitespace.change` | `-b` | ignoring how much whitespace, not whether |
| `whitespace.at_eol` | `--ignore-space-at-eol` | ignoring whitespace at the end |
| `whitespace.cr_at_eol` | `--ignore-cr-at-eol` | ignoring a carriage return before the newline |
| `ignore_case` | none | ignoring ASCII case |

Whitespace is git's class: space, tab, newline and carriage return. Vertical tab
and form feed are ordinary bytes. With no flag a final line without a newline
never equals the same text with one; under any whitespace flag the newline is
whitespace and the two can match.

### Hunks and the unified body

`HunkOptions` has git's `-U`, `--inter-hunk-context`, `--ignore-blank-lines` and
`-I` (a caller's predicate on each line, given with its newline). `writeUnified`
writes the `@@` lines, the heading a `Heading` finds (`Heading.c_function` is
git's default rule), context taken from the new side as git prints it, and
`\ No newline at end of file`.

### Merge styles and levels

| `Level` | git | |
|---|---|---|
| `minimal` | `XDL_MERGE_MINIMAL` | the same change on both sides is still a conflict |
| `eager` | `XDL_MERGE_EAGER` | the same change on both sides is taken once |
| `zealous` | the merge machinery | conflicts narrowed; three lines or fewer apart joined |
| `zealous_alnum` | `git merge-file`, the default | and joined across lines with no letter or digit |

diff3 is capped at eager, as in git. `Resolve` is `markers`, `ours`, `theirs` or
`both` (git's union).

## API

| Call | Does |
|---|---|
| `Differ.init(gpa)`, `deinit`, `shrink(keep)` | The workspace; `shrink` releases its scratch when it holds more than `keep` bytes |
| `differ.lines(old, new, options)` | The line diff of two texts, as a `Diff` borrowing the inputs and the workspace |
| `differ.sequences(old, new, options)` | The diff of two sequences of ids below `options.classes` |
| `differ.merge(base, ours, theirs, options)` | The three-way merge, as regions |
| `diffLines(gpa, old, new, options)` | A one-shot diff that owns its memory |
| `diff.stat()`, `diff.ratio()` | Lines added and removed; the matched share of both sides |
| `diff.ops()`, `diff.hunks(options)` | The script as steps, and as hunks; neither allocates |
| `writeUnified(w, diff, options)` | The unified body, optionally with `---`/`+++` lines |
| `merge.write(w, merge, options)` | The merged text with labels, marker size and resolution |
| `merge.mergeAlloc(gpa, base, ours, theirs, options, write_options)` | Merge and write in one call |

Every input is under 4 GiB, and the inputs of one call hold fewer than 2^32 lines
between them; anything larger is `error.InputTooLarge`. The only other error is
`error.OutOfMemory`.

## Scope

- No git headers (`diff --git`, `index`), funcname drivers, colour or
  `--word-diff`: those are git's policy, built on top.
- No binary rule: any bytes diff and merge, NUL included. Deciding that a file is
  binary is the caller's.
- No rename or copy similarity, no directory diff and no binary deltas.
- No wall-clock deadline: `max_work` is the reproducible cap.
- No structural (syntax-tree) diff or merge.

## Platforms

Every target Zig supports, wasm32-freestanding included. parallax uses only
`std.mem`, `std.hash`, `std.Io.Writer` and an `Allocator`. Nothing is serialised,
so byte order never matters; the byte scans that use vectors have a scalar twin,
and a test holds the two to the same answer.

## Testing

`zig build test` runs the suite and the usage example. git's own output is the
reference: a corpus captured once from git 2.55 and committed as data
(`testdata/git-2.55/`, under 2 MB) holds edit scripts for 600 pairs under every
algorithm, 1,483 unified bodies across context, inter-hunk context, headings, the
whitespace flags, `--ignore-blank-lines` and `-I`, and 3,015 merges in every style,
algorithm, label, marker size and resolution, with `merge-tree`'s blobs for the
merge machinery's level and whitespace options. parallax must reproduce every
byte.

Properties run on seeded inputs in every `zig build test`, and under the fuzzer
with `zig build test --fuzz`: every script applies, under every algorithm,
comparison and work cap; a minimal script is never longer; lines of one form
always match; a merge's regions cover our side in order, an unchanged side gives
the other, and the markers read back give each side's resolution. A warm
workspace is counted to make no allocation, every allocation failure is survived
without a leak, the adversarial workloads are held to recorded work units and
scripts, and the deep inputs run on a 64 KiB stack.

`zig build bench -- [--smoke] [--json] [--runs N] [--only W1,W5]` times parallax's
own workloads in ReleaseFast: large files with few and many edits, the
adversarial shapes, many small diffs through one workspace with their latency and
allocations, the whitespace flags, and merges with many conflicts, each beside
the code parallax replaces. CI compiles the benchmarks and never times them.

## Licence

MIT. See [LICENSE](LICENSE).
