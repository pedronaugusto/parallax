# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `patch.scanHunk`, `patch.HunkLines`, `patch.parseHunkHeader` and `patch.Dialect`: the grammar of one hunk on its own, for a caller that keeps the patch text and reads its own file headers. `scanHunk` checks a hunk and measures it (counts, bytes, leading and trailing context, lines added and removed, which kinds of line end in CR LF) without allocating, and `HunkLines` reads its lines back. `.gnu` is the reading `parse` has always had; `.git` is `git apply`'s, with `recount` for `--recount`.

### Changed

- `parse` is built on the same grammar. A patch that ends inside a hunk reports the line that should have come next, where it reported the last one.

### Breaking

- `parallax.diff`, `parallax.merge`, `parallax.patch`, `parallax.interner`, `parallax.lines` and `parallax.compare` are no longer separate build modules: `b.dependency("parallax", ...).module("parallax.patch")` no longer exists. Take `module("parallax")` and use `parallax.patch` and the others as namespaces of it; code that already wrote `@import("parallax").patch` is unchanged. No part had a dependency or a link of its own, so a module of its own bought nothing Zig's lazy analysis does not already give: a program that names only `parallax.patch` still compiles only what that reaches.
- `Options.max_work` and `SequenceOptions.max_work` take `Work` (Myers sweeps); construct a cap with `Work.fromRaw(n)`. `Differ.shrink` takes `Bytes`, constructed with `Bytes.fromRaw(n)`.
- `Interner.intern` returns `ClassId`, `get` takes `ClassId`, and `internSlice` writes `[]ClassId`. `classes` returns `ClassCount`. `Differ.sequences` and `mergeSequences` take `[]const ClassId`; their options take `ClassCount` for `classes`. Import raw external IDs/counts explicitly with `fromRaw`.


### Changed

- Use published aegis for equivalence-class IDs/counts, work caps, typed scratch byte accounting and patch header integers; retain compact raw kernels behind explicit boundaries.
- Expose the diff, merge, patch, interner, lines and comparison concerns as namespaces of the one module (`parallax.diff`, `.merge`, `.patch`, `.interner`, `.lines`, `.compare`), each declaration with one owner; the root reexports the types most callers want.
- Pin green published aegis a5d17d0, preflight c04e49d and shakedown 99418ac; regenerate CI from the pinned preflight.

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
