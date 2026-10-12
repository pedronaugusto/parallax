# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
