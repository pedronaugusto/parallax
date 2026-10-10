# Architecture

parallax computes line and sequence differences, three-way merges, inline
refinement and unified-patch parsing and application. Production code depends
on published aegis and std. Computation takes borrowed input and never waits on an Io or calls
an OS; writers use the caller's `std.Io.Writer`. Binary classification,
filesystem operations, syntax trees and application policy belong to callers.

This describes the implementation in this repository. Change it with the code
whenever an owner, invariant or decision changes. Development and validation
continue; this document does not declare a release or a performance target met.

## Layers and owners

[ci/layers.zig](../ci/layers.zig) checks the production import graph. Its layers
are ordered from lowest to highest; imports stay in their layer or go downward.
The public facade exports supported types without becoming their state owner.

| Layer | Files and responsibility |
|---|---|
| Comparison, lines and flags | `fit.zig` sizes retained arrays; `compare.zig` owns comparison forms, hashing and equality; `lines.zig` owns borrowed line views and splitting; `flags.zig` owns change flags; `interner.zig` owns generic value-to-id mapping. |
| Changes | `change.zig` builds ordered replacement runs from the two flag sets. |
| Line table | `table.zig` assigns dense ids to equal line forms across all inputs. |
| Myers | `myers.zig` owns pruning, the middle-snake search, work accounting and its explicit box stack. |
| Histogram | `histogram.zig` owns occurrence chains and region splitting, falling back to Myers. |
| Patience and slide | `patience.zig` owns unique anchors and their ordered backbone; `slide.zig` compacts flagged changes and scores indentation. |
| One diff | `core.zig` selects an algorithm, slides both sides and builds the script. Lines and generic sequences share this path. |
| Token cleanup | `cleanup.zig` transforms token scripts for semantic or efficiency cleanup. |
| Refinement | `refine.zig` owns tokenization, token interning and mapping changes to byte spans. |
| Hunks | `hunks.zig` groups changes, filters ignorable changes and widens function context. |
| Script | `script.zig` owns the borrowed `Diff` view, statistics and operation iteration. |
| Three-way regions | `threeway.zig` solves overlapping side changes and refines or joins conflicts. |
| Workspace | `Differ.zig` owns the allocator and retained buffers for all diff, merge and refinement calls. |
| Unified writer | `unified.zig` renders hunks. |
| Diff facade | `diff.zig` exports diff/refinement and workspace merge types and owns the one-shot diff convenience owner. |
| Patch types | `patch/types.zig` owns parsed patch records, options, diagnostics and results. |
| Patch parse and apply | `patch/parse.zig` owns syntax validation and arena-backed records; `patch/apply.zig` owns offset/fuzz search and writes applied text. |
| Merge writer | `merge.zig` renders regions and iterates marked text. |
| Patches and root facade | `patch.zig` exports patch contracts; `parallax.zig` reexports the supported concern modules. |

Paths in the table are under [src](../src). Tests and fixture readers are
separate from the production graph; aegis owns scalar safety types, while shakedown and preflight are lazy test/build
dependencies, not dependencies of a consumer's computation.

## Representation and lifetime

`Lines` borrows the original text and locates lines with `u32` end offsets. A
line includes its terminating newline; a final unterminated line is still a
line. A lone carriage return and NUL are ordinary bytes. Each text must be under
4 GiB and the total line count across one call must fit `u32`; oversized inputs
return `InputTooLarge`. The sequence calls likewise bound their combined length
and require every supplied id to be below `classes`. This keeps offsets and
four-field `Change` records compact without copying input text.

`Differ` owns line ends, ids, scripts, the line table, algorithm scratch, merge
regions and refinement buffers. Results borrow inputs and workspace storage and
are valid until the next workspace call, with one useful exception:
`refine` preserves the line diff it reads, keeping its spans in separate
buffers. Keep inputs alive and use separate workspaces for simultaneous
operations. `deinit` releases the buffers. Capacity
is retained for reuse: warm calls fitting the retained capacities avoid new
allocations. `shrink(keep)` releases all scratch if its total capacity exceeds
`keep`, so the next call may allocate again; it is not a partial trim to a
fixed-size budget.

`diffLines` makes a temporary workspace and copies ends and changes into an
`OwnedDiff`; it still borrows input text. `mergeAlloc` owns rendered output.
`Interner(T, Context)` owns its lookup storage and stored values, using the
caller's hash/equality contract; values containing slices still require those
slices to remain valid. These convenience owners each store their allocator
and have a non-failing `deinit`.

## Comparison and the diff pipeline

Comparison has one owner: the line table's hash and collision check both use
`compare.zig`. Flags support ignoring all whitespace, changes in whitespace,
end-of-line whitespace or a carriage return at line end, plus ASCII case.
Whitespace means space, tab, newline and carriage return; vertical tab and form
feed stay ordinary. With no whitespace flag, an unterminated final line differs
from the same text with a newline. Hash equality alone never establishes line
equality: the comparison form is checked on collisions.

The splitter has vector and scalar paths. The open-addressed line table packs a
hash tag and id into a `u64` slot, with a separate first-line index for collision
checks. It hashes comparison forms without a normalized copy, prefetches slots
for batches of lines and reuses the preceding id for consecutive identical
lines. For a two-sided call, whole lines in the common byte prefix and suffix
reuse old-side ids on the new side. Every old-side line is still interned: this
optimization does not change the whole-file counts used by pruning.

Myers counts both whole inputs before trimming common ends. Its per-id `u32`
count packs two saturating 16-bit counts; touched ids are cleared on each run.
Pruning sets aside unmatched and excessively common lines, while minimal mode
keeps lines with a counterpart and disables the give-up shortcuts. The linear
space search uses `i32` diagonals when their range fits, and `i64` otherwise.
Its explicit stack preserves traversal order without recursive stack growth.

Histogram uses occurrence chains with a 64-entry limit and generation-stamped
arrays. Patience uses unique matching lines, optionally constrained by anchors,
and an ordered backbone; its slots are cleared per region. Unanchorable regions
fall back to Myers using that region's counts. These are distinct buffer
strategies, not a shared promise that every algorithm uses stamped arrays.

`core.diff` runs the selected algorithm, compacts both sets of flags and builds
ordered `Change` runs. Sliding chooses placement using indentation when enabled;
histogram can re-diff a region during compaction. Generic sequences use this
same machinery with caller-provided anchors and indentation rather than text
callbacks. Minimal and anchored behavior are options on these algorithms, not
additional public algorithm variants.

`max_work` on line and sequence diffs counts Myers forward/backward sweeps;
zero adds no cap. Remaining work becomes a coarse deletion/insertion when the
cap is exhausted, preserving a valid script. This bounds search reproducibly
without a wall-clock deadline; it is not a count of every scanning or rendering
operation. A caller-raised atomic `stop` is read at work units and regions and
also produces a coarse valid answer. Its timing is caller-controlled, so it
does not promise a reproducible stopping point. Merge and refinement accept
`stop`; their public options do not expose `max_work`.

## Views, hunks and rendering

`Diff.ops`, statistics and hunk iteration read the script without allocating.
Algorithm options decide equality and edit placement. `HunkOptions` separately
decides context, inter-hunk context, ignorable lines and function context:
presentation does not change the script.

Changes join across at most `2 * context + inter_hunk_context` common lines.
An all-ignorable change does not open or extend a hunk by itself but can print
inside another hunk. Context is clamped at file boundaries. Function context
uses the caller's `Heading` to include whole functions and preceding comment
lines; its resulting hunks may overlap. The unified writer owns range syntax,
heading search/truncation, context from the new side and missing-newline
markers. Optional file names produce plain unified headers. Application-specific
header formats and function-name rules stay outside the solver.

## Refinement and three-way merge

Refinement tokenizes the whole old and new runs of a change, so matches can move
across line breaks. Words group letters, digits, underscore and bytes at least
0x80, or runs of space/tab/carriage return; newlines are separate tokens.
Characters are UTF-8 scalars with each invalid byte a separate token; bytes are
individual bytes. Token comparison uses the chosen comparison form. Cleanup
runs in tokens before spans are emitted: semantic cleanup favors readable
boundaries and common overlaps; efficiency cleanup removes short equalities
according to `edit_cost`. Spans tile each side's changed lines and never cross
a line end. Grapheme segmentation and domain tokenizers belong to callers,
which can supply their own interned sequences.

A merge interns all three texts in one table, diffs each side against base and
passes both scripts to the region solver. Equal sides or an unchanged side have
whole-side shortcuts. Refinement compares existing ids, avoiding repeated
splitting and hashing. Regions cover our side in order and distinguish
unchanged, ours, theirs, same and conflict. Generic three-way merge uses the
same solver; its `content` callback determines which tokens count as content
when joining conflicts.

Style and level affect regions and belong to merge options. The default level
is `zealous_alnum`: conflicts are narrowed and joined across short gaps or gaps
without letters/digits. `zealous` joins short gaps, `eager` accepts identical
side changes, and `minimal` can conflict on identical changes. `diff3` caps the
level at eager; `zdiff3` moves shared conflict ends into surrounding regions.
Labels, `u32` marker size and resolution (`markers`, `ours`, `theirs`, `both`)
belong to the writer because they change rendered text rather than the solver's
answer. Marker size zero means seven, empty labels add no space, and markers
follow the implementation's CRLF rule. Marker parsing borrows text and allocates
nothing; nested conflicts remain part of the containing side's bytes.

## Unified patches

Parsing owns arena-backed file, hunk and line records and borrows their text
from the caller. It retains extended headers verbatim for callers to interpret,
including header-only sections. Hunk counts are checked, omitted counts mean
one, and missing-newline markers annotate the preceding line. Diagnostics name
the failing input line, which for a patch that ends inside a hunk is the one that
should have followed; malformed syntax returns a named parse error.

The grammar of one hunk, `patch/hunk.zig`, is the owner of every hunk read here and
of any a caller reads with `scanHunk` and `HunkLines`: the header's ranges, the
lines the counts bound, and the markers. A scan walks the hunk once, allocating
nothing, and measures it; the lines are read back on demand, so a caller that keeps
a large patch's text pays nothing per line. Two dialects share it. GNU patch's is
lenient where mail and editors damage a patch (a line led by a tab or a newline is
context, any `\` line marks the line before it, a hunk may be context alone). git's
is `git apply`'s rule for rule: every line of a hunk ends in a newline, the counts
decide where it ends, a marker is the one line right after a line, a hunk that
changes nothing is refused, and `recount` takes the counts from the lines. The
two differ at those points only; the ranges, counts and markers are read once.

Application owns temporary line/hash/search storage and streams to the caller's
writer. Hunks apply in order without overlap. Search starts at the stated line
plus the accumulated offset, then alternates after and before; `max_offset`
bounds that search. If needed, increasing fuzz ignores context at the ends.
Asymmetric context constrains a hunk to the appropriate file boundary. Kept
context comes from the base, preserving the text ignored by fuzz. Reverse swaps
added and removed lines; per-hunk results report position, offset, fuzz or
rejection. A reversed hint probes the first failed hunk without silently
changing the requested direction. Fail mode can leave partial writer output;
skip mode continues after rejected hunks. Filesystem edits, binary patch rules
and application-specific three-way patch policy stay with the caller.

## Validation contract

Committed fixture corpora check scripts, unified output, merge text, marker
parsing, patch application and cleanup. Seeded shakedown properties check script
application, span/region coverage, round trips and failure handling. Allocation
failure tests and warm-workspace allocation counts protect ownership; recorded
work-unit bounds and the 64 KiB deep-stack test protect algorithm behavior.
CI compiles and smoke-runs the own benchmarks; timings are measured separately
and never used as correctness thresholds. Architecture records owners and
invariants here, while benchmark results remain in their dedicated evidence.

## Numeric boundaries

The public equivalence-class vocabulary is `ClassId` and `ClassCount` from
published aegis id/units. It is shared across line, token and caller interning,
so equal classes deliberately compare across both inputs; the type separates
classes from positions, byte offsets and counts, not one interner instance
from another. Callers still supply one shared interning domain and IDs below
`classes`; `fromRaw` establishes representation, not membership. Runtime-safety
builds check this existing sequence precondition before kernel entry.

`Work` counts Myers sweeps; zero retains the unlimited policy. Core extracts
the cap once and keeps the validated one-unit search loop raw. The internal
cap widens in the same domain to u64, preserving the original run layout. `Bytes` counts
retained storage, and `shrink` compares byte counts. Array capacity converts
at the storage owner by actual element width. The allocator checks each
extent before publishing capacity; disjoint live allocations cannot exceed
the address space. Byte-only accounting therefore retains raw multiplication
and addition inside this owner, wrapped at its declarations. Patch header
numbers use checked multiply/add and retain the existing malformed-header
outcome at u32 overflow. Arena cleanup and borrowed text remain with the parser.

Raw forms retained at their sites have these reasons:

- Measured boundary: algorithm class arrays, positions, change ranges, packed
  counts, byte/token ends and work counters operate on inputs bounded by the
  workspace/splitter and the sequence contract. Typed class slices are viewed
  as u32 without copying; size/alignment are checked at compile time. The line
  table and interner probe kernels deliberately use the same class domain.
- No danger: `fit.resize` receives the element count of one array only. Single
  workspace owners need no lock or secret guard; atomics only read the caller's
  cancellation flag, whose lifetime remains the caller's contract.
- Design removes the bug class: Reader offsets come from bounded slices and
  patch decimal parsing uses checked arithmetic. Allocated extents and their
  disjoint storage totals cannot overflow the address space; redundant
  arithmetic checks in byte accounting would slow retention without adding
  protection. Public patch ranges retain
  their specified u32 textual representation; signed application offsets and
  counts are widened to i64 before offset/fuzz arithmetic.

No secrets, shared lock/data owners, OS boundaries or protocol state machines
exist in the current computation package. This batch uses the
A3 scalar contracts after their cloak adoption; it introduces no later-wave
lifecycle/input API or future functionality.

## Build modules

Consumers may take `parallax.diff`, `parallax.merge`, `parallax.patch`,
`parallax.interner`, `parallax.lines` or `parallax.compare` alone. `parallax`
reexports these shared declarations. Merge rendering depends on the diff
workspace and its region types; patch parsing/application depends only on
lines, comparison and aegis. Diff depends on lines, comparison, interning,
aegis and its existing algorithm layers. Internal storage, flags, changes and
cleanup have one module owner and are not separately registered consumer
modules. The source layer graph maps every named import and permits no upward
edge; `check-consumer` proves shared identities while fetching only aegis.

The package preflight configuration selects glint A004 as a gate for adopted
IDs, units and checked integers. Its paths include production, test support,
benchmarks, examples, CI drivers and the build script; no test or benchmark
exemption applies. The pinned published preflight still executes ziglint, and
the published glint aegis pack currently rejects gate selections. This
configuration awaits the G4 runner/admission integration; current validation
uses the published pack in report mode. The storage-sum site uses the pack
comment syntax with its design proof rather than an exception ledger.
