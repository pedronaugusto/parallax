# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- A caller's stop flag is `parallax.Stop`, an aegis `Atomic` of `parallax.Raised` (`no`, `yes`), where it was a `std.atomic.Value(bool)`: `Options.stop`, `SequenceOptions.stop` and the merge's options take `?*const parallax.Stop`. Make one with `.init(.no)` and raise it with `store(.yes, .monotonic)` where `store(true, ...)` was.

- The declarations the two context and stop-flag changes break, by name. The callback interfaces are gone for the context's methods: `Differ.Indent`, `Differ.Indent.context`, `Differ.Indent.new`, `Differ.Indent.old`, `Differ.Predicate`, `Differ.Predicate.at`, `Differ.Predicate.context`, `Differ.SequenceOptions.anchor`, `Differ.SequenceOptions.indent`, `Heading`, `Heading.c_function`, `Heading.context`, `Heading.find`, `Heading.max_len`, `HunkOptions.ignore`, `Indent`, `Indent.context`, `Indent.new`, `Indent.old`, `LinePredicate`, `LinePredicate.at`, `LinePredicate.context`, `Paint`, `Paint.Kind`, `Paint.Kind.context`, `Paint.Kind.hunk`, `Paint.Kind.incomplete`, `Paint.Kind.new`, `Paint.Kind.new_file`, `Paint.Kind.old`, `Paint.Kind.old_file`, `Paint.Line`, `Paint.Line.heading`, `Paint.Line.kind`, `Paint.Line.number`, `Paint.Line.sign`, `Paint.Line.text`, `Paint.context`, `Paint.write`, `Predicate`, `Predicate.at`, `Predicate.context`, `SequenceOptions.anchor`, `SequenceOptions.indent`, `UnifiedOptions.heading`, `UnifiedOptions.paint`, `diff.Differ.Indent`, `diff.Differ.Indent.context`, `diff.Differ.Indent.new`, `diff.Differ.Indent.old`, `diff.Differ.Predicate`, `diff.Differ.Predicate.at`, `diff.Differ.Predicate.context`, `diff.Differ.SequenceOptions.anchor`, `diff.Differ.SequenceOptions.indent`, `diff.Heading`, `diff.Heading.c_function`, `diff.Heading.context`, `diff.Heading.find`, `diff.Heading.max_len`, `diff.HunkOptions.ignore`, `diff.Indent`, `diff.Indent.context`, `diff.Indent.new`, `diff.Indent.old`, `diff.LinePredicate`, `diff.LinePredicate.at`, `diff.LinePredicate.context`, `diff.MergeSequenceOptions.content`, `diff.Paint`, `diff.Paint.Kind`, `diff.Paint.Kind.context`, `diff.Paint.Kind.hunk`, `diff.Paint.Kind.incomplete`, `diff.Paint.Kind.new`, `diff.Paint.Kind.new_file`, `diff.Paint.Kind.old`, `diff.Paint.Kind.old_file`, `diff.Paint.Line`, `diff.Paint.Line.heading`, `diff.Paint.Line.kind`, `diff.Paint.Line.number`, `diff.Paint.Line.sign`, `diff.Paint.Line.text`, `diff.Paint.context`, `diff.Paint.write`, `diff.Predicate`, `diff.Predicate.at`, `diff.Predicate.context`, `diff.SequenceOptions.anchor`, `diff.SequenceOptions.indent`, `diff.UnifiedOptions.heading`, `diff.UnifiedOptions.paint`, `merge.SequenceOptions.content`. A function given a context takes it after its options: `Differ.mergeSequences`, `Differ.sequences`, `HunkIterator.next`, `diff.Differ.mergeSequences`, `diff.Differ.sequences`, `diff.HunkIterator.next`; `HunkOptions.function_context`, `diff.HunkOptions.function_context` says whether the context's `heading` is asked. A stop flag is a `?*const parallax.Stop`: `Differ.Options.stop`, `Differ.SequenceOptions.stop`, `RefineOptions.stop`, `diff.Differ.Options.stop`, `diff.Differ.SequenceOptions.stop`, `diff.MergeOptions.stop`, `diff.MergeSequenceOptions.stop`, `diff.Options.stop`, `diff.RefineOptions.stop`, `diff.SequenceOptions.stop`, `merge.Options.stop`, `merge.SequenceOptions.stop`.

- `compare.Form.Mode` is public (`verbatim`, `all`, `change`), so `compare.Form.mode` has a type a caller can name. Code that compiled before compiles unchanged.

### Added

- A property for the minimal search: under minimal Myers and any comparison, a diff adds and removes exactly the lines a longest common subsequence leaves, checked against the textbook table over the same comparison on short texts that repeat their lines. It fails when the minimal search sets common lines aside as the heuristic one does.

### Changed

- The merge property states git's rule for a side whose only edits are whitespace the comparison ignores: that side has no change, so a merge with an unchanged theirs gives ours only where ours changes something the comparison sees, else theirs whole (`git merge -Xignore-space-change` writes the same). A test holds git's text for both shapes, and the fuzz job's case is kept as a regression. Development on shakedown 08468e0, whose fuzzer names a leak as one.
- Development on preflight's ci-standard 158c176, shakedown c29751d (its simulation builds for 32-bit targets, which x86-linux-musl's cross compile reads) and reactor 2d72792. The line split property keeps each case's lists to that case, as the fuzzer checks the allocator after every input.
- Pins aegis f52eabe, still 0.2.4, the one aegis the family builds on: the kernels read the interned ids as their `u32`s through `ClassId.raws`, where parallax cast the slice itself. Development on preflight's ci-standard f991816 and shakedown 327bc61, with reactor 60e8f45 for the tests.
- Pins aegis c8982a8, still 0.2.4: six additive commits after 3c0b13e (the role declarations a linter reads, `lint_rules`), the aegis the development build's preflight selects. Nothing parallax calls changed.
- On aegis 0.2.3 (the aegis 0.2 line), developed with preflight 0.18.4. The interner's slot holds an optional class where it held the class plus one, zero for empty.
- Pins aegis breaking-0.3 (a34e694), the 0.3.0 line the family is on, where it pinned aegis 0.1.12; shakedown main (4979fa9) and reactor main (c6921bd) for the tests. parallax builds on them unchanged.
- **Breaking:** a caller's rules come as a context, as std's sort takes its `lessThan`, where they were a context pointer beside loose functions: each method the context has is called, inlined, and `.{}` is none. `writeUnified(w, diff, options, context)` asks its `heading`, `ignore` and `paint`, and a painter's errors pass through it (`WriteError(Context)`); `HunkIterator.next(context)` its `heading` and `ignore`; `Differ.sequences(…, options, context)` its `anchor`, `indentOld` and `indentNew`; `Differ.mergeSequences(…, options, context)` its `content`. `Heading`, `Paint`, `LinePredicate`, `Predicate` and `Indent` are gone, with `HunkOptions.ignore`, `UnifiedOptions.heading` and `.paint`, `SequenceOptions.anchor` and `.indent`, and `SequenceMerge` options' `content`. `UnifiedOptions.function_names` writes the function lines, `HunkOptions.function_context` is a flag, and either reads the context's `heading` or else `cFunction`, git's default rule (`Heading.c_function` before). `Paint.Line` is `UnifiedLine`; `writeLine` writes one line plainly, as a painter does the lines it leaves uncoloured. A function line is cut at git's 80 bytes (`Heading.max_len` before).

- Development: the cancellation tests build for 32-bit targets (x86-linux-musl): their evented half, on reactor, runs only where reactor builds (64-bit), and the check counter is a `usize`.

## [0.3.0] - 2026-10-24

### Added

- `Options.io`, `SequenceOptions.io`, `MergeOptions.io`, `MergeSequenceOptions.io` and `RefineOptions.io`: the caller's `Io`, asked once per work unit and once per histogram or patience region whether the calling task is canceled. Once it is, the call returns `error.Canceled` and is abandoned, where `stop` still returns a result, correct but coarse. Tested on `std.Io.Threaded` and on reactor's evented runtime.

### Changed

- **Breaking:** `Differ.Error` gains `Canceled`, and `Differ.refine` returns `RefineError` (`OutOfMemory`, `Canceled`). Neither is returned when no `io` is given.
- Pins aegis 0.1.12; the tests' shakedown is 0.4.16, and reactor 0.8.1 joins it as a development dependency.

## [0.2.6] - 2026-10-18

### Added

- `UnifiedOptions.paint`: a `Paint` that is handed each line of the unified diff, what it is (the file names, the `@@` ranges and heading, context, removed and added lines, `\ No newline at end of file`), its sign and its number on its side, and writes it in place of the plain writer: how a caller colours a diff, as git's `--color` does.

## [0.2.5] - 2026-10-17

### Added

- `UnifiedOptions.suppress_blank_empty`: a context line that is a line ending alone is written without its space, as git writes it under `diff.suppressBlankEmpty`.

## [0.2.4] - 2026-10-14

### Added

- A fuzz property for `patch.hunk.parseHeader`, the one parser of untrusted input preflight reported without one: a header GNU's reading accepts, git's reads with the same numbers, and a heading lies inside its line.

## [0.2.3] - 2026-10-14

### Changed

- Pins aegis 0.1.6.

## [0.2.2] - 2026-10-13

### Changed

- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.2.1] - 2026-10-12

### Changed

- Pins preflight 0.3.4 and shakedown 0.2.5.

## [0.2.0] - 2026-10-12

### Breaking

- parallax is developed with [bay](https://github.com/pedronaugusto/bay): preflight and shakedown are dev dependencies, and the tests, example, benchmarks and checks are the development build's (`bay test`, `bay bench`). What a project that depends on parallax builds is unchanged: the `parallax` module over aegis.
- `parallax.diff`, `parallax.merge`, `parallax.patch`, `parallax.interner`, `parallax.lines` and `parallax.compare` are no longer separate build modules, so `b.dependency("parallax", ...).module("parallax.patch")` no longer exists. Take `module("parallax")` and use `parallax.patch` and the others as namespaces of it. Code that already wrote `@import("parallax").patch` is unchanged, and a program that names only `parallax.patch` still compiles only what that reaches.
- `Options.max_work` and `SequenceOptions.max_work` take `Work` (Myers sweeps): construct a cap with `Work.fromRaw(n)`. `Differ.shrink` takes `Bytes`, constructed with `Bytes.fromRaw(n)`.
- Class IDs and counts are aegis types:
  - `Interner.intern` returns `ClassId`, `get` takes `ClassId`, and `internSlice` writes `[]ClassId`;
  - `classes` returns `ClassCount`;
  - `Differ.sequences` and `mergeSequences` take `[]const ClassId`, and their options take `ClassCount` for `classes`.

  Bring raw external IDs and counts in with `fromRaw`.
- `patch.apply` returns `error.InvalidResults` for a `results` slice that is not one slot per hunk. Before, it asserted, which was undefined behaviour in ReleaseFast.

### Added

- `Differ`: a reusable workspace that makes no allocation once warm, with `lines`, `sequences`, `merge` and `shrink`.
- Line diffs with git's output:
  - Myers with git's prune and give-up rules, minimal, patience, anchored and histogram;
  - the slide and the indentation heuristic;
  - `max_work`, a deterministic cap.
- `Compare`: git's whitespace flags (`all`, `change`, `at_eol`, `cr_at_eol`) with git's whitespace class, and ASCII `ignore_case`.
- `Diff` with `stat`, `ratio`, `ops` and `hunks`; `HunkOptions` with context, inter-hunk context, `ignore_blank_lines` and an `ignore` predicate.
- `HunkOptions.function_context`: hunks widened to the whole function around their changes, as `git diff -W` widens them, by a `Heading`'s rule for where a function starts.
- `writeUnified`, with `Heading` (`Heading.c_function` is git's default rule) and optional `---`/`+++` lines.
- `merge`: the three-way merge as regions, in the `merge`, `diff3` and `zdiff3` styles at git's four levels; `merge.write` with labels, marker size and `Resolve`; `merge.mergeAlloc`.
- `merge.parseMarkers`: the text and conflicts of marked text, read back as git's rerere reads them, with each side, the base when there is one, and the labels.
- `diffLines`, a one-shot diff that owns its memory.
- `Interner(T, Context)` and `Differ.sequences`: any sequence diffs once interned, with the caller's anchors and indentation. `Differ.mergeSequences`, with `merge.SequenceOptions` and `merge.SequenceMerge`, merges them three ways in every style and level.
- `Differ.refine`: the spans inside one change that differ, by `Tokens` (`words`, `chars`, `bytes`), under a `Compare`. `RefineOptions.cleanup` (`Cleanup.semantic`, `Cleanup.efficiency`) and `RefineOptions.edit_cost` clean up the token script before it becomes spans.
- `stop` on `Options`, `SequenceOptions`, `merge.Options`, `merge.SequenceOptions` and `RefineOptions`: a flag the caller raises, from any thread, to have a diff, merge or refinement finish early with a coarse result that is still correct.
- `patch.parse`: unified patches with any number of files, header lines kept verbatim, and `Diagnostics` for a malformed hunk.
- `patch.apply`: one file's hunks applied with GNU patch's offset, fuzz, reverse and reject rules, and a result per hunk. `ApplyOptions.reversed_hint` says whether a patch looks reversed or already applied, where GNU patch would say so.
- `patch.scanHunk`, `patch.HunkLines`, `patch.parseHunkHeader` and `patch.Dialect`: the grammar of one hunk on its own, for a caller that keeps the patch text and reads its own file headers.
  - `scanHunk` checks a hunk and measures it without allocating: counts, bytes, leading and trailing context, lines added and removed, and which kinds of line end in CR LF.
  - `HunkLines` reads its lines back.
  - `.gnu` is the reading `parse` has always had; `.git` is `git apply`'s, with `recount` for `--recount`.
- `zig build bench-corpus` collects the changed files of a range of a git history (Linux v6.11..v6.12 by default) for the benchmarks on real files. `bench/cli` is a small command that diffs, merges and applies.

### Changed

- `parse` is built on the one-hunk grammar. A patch that ends inside a hunk reports the line that should have come next, where it reported the last one.
- `Differ` orders sizes and class IDs through aegis's `compare`, and checks its sequence bound in every build with runtime safety.
- Property tests use shakedown's generators and checks with the same seeds, assertions and case counts, with shrinking and tape replay; the fuzz tests are shakedown `check` properties.
- Pins aegis 0.1.0.

[Unreleased]: https://github.com/pedronaugusto/parallax/commits/main
