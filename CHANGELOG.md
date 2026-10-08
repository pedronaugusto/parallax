# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Property tests use shakedown generators and checks with the same seeds, assertions and case counts, with shrinking and tape replay; allocation failure sweeps use its NoResize allocator and repeated fixtures use its corpus helpers.
- Consume shakedown unchanged from its upstream module, including its 32-bit generator fixes.
- Regenerate the pinned workflow and every tier matrix with preflight's canonical `zig build plan -- --workflow .github/workflows/ci.yml`.
- Pin preflight b28046c and shakedown 9357a9a, keep test dependencies lazy, ship only the library sources and package documents, and smoke-run each benchmark program through preflight.

### Added

- `Differ`: a reusable workspace that makes no allocation once warm, with `lines`, `sequences`, `merge` and `shrink`.
- Line diffs with git's output: Myers with git's prune and give-up rules, minimal, patience, anchored and histogram; the slide and the indentation heuristic; `max_work`, a deterministic cap.
- `Compare`: git's whitespace flags (`all`, `change`, `at_eol`, `cr_at_eol`) with git's whitespace class, and ASCII `ignore_case`.
- `Diff` with `stat`, `ratio`, `ops` and `hunks`; `HunkOptions` with context, inter-hunk context, `ignore_blank_lines` and an `ignore` predicate.
- `writeUnified`, with `Heading` (`Heading.c_function` is git's default rule) and optional `---`/`+++` lines.
- `merge`: the three-way merge as regions, in the `merge`, `diff3` and `zdiff3` styles at git's four levels; `merge.write` with labels, marker size and `Resolve`; `merge.mergeAlloc`.
- `diffLines`, a one-shot diff that owns its memory.
- `Interner(T, Context)` and `Differ.sequences`: any sequence diffs once interned, with the caller's anchors and indentation.
- `Differ.refine`: the spans inside one change that differ, by `Tokens` (`words`, `chars`, `bytes`), under a `Compare`.
- `patch.parse`: unified patches with any number of files, header lines kept verbatim, and `Diagnostics` for a malformed hunk.
- `patch.apply`: one file's hunks applied with GNU patch's offset, fuzz, reverse and reject rules, and a result per hunk.
- `stop` on `Options`, `SequenceOptions`, `merge.Options`, `merge.SequenceOptions` and `RefineOptions`: a flag the caller raises, from any thread, to have a diff, merge or refinement finish early with a coarse result that is still correct.
- `HunkOptions.function_context`: hunks widened to the whole function around their changes, as `git diff -W` widens them, by a `Heading`'s rule for where a function starts.
- `RefineOptions.cleanup` (`Cleanup.semantic`, `Cleanup.efficiency`) and `RefineOptions.edit_cost`: diff-match-patch's cleanups over the token script before it becomes spans.
- `merge.parseMarkers`: the text and conflicts of marked text, read back as git's rerere reads them, with each side, the base when there is one, and the labels.
- `Differ.mergeSequences`, with `merge.SequenceOptions` and `merge.SequenceMerge`: the three-way merge of any interned sequences, as regions, in every style and level.
- `ApplyOptions.reversed_hint`: whether a patch looks reversed or already applied, where GNU patch would say so.
- `zig build bench-corpus`, which collects the changed files of a range of a git history (Linux v6.11..v6.12 by default) for the benchmarks on real files, and `bench/cli`, a small command that diffs, merges and applies.

[Unreleased]: https://github.com/pedronaugusto/parallax/commits/main
