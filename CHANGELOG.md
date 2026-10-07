# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Differ`: a reusable workspace that makes no allocation once warm, with `lines`, `sequences`, `merge` and `shrink`.
- Line diffs with git's output: Myers with git's prune and give-up rules, minimal, patience, anchored and histogram; the slide and the indentation heuristic; `max_work`, a deterministic cap.
- `Compare`: git's whitespace flags (`all`, `change`, `at_eol`, `cr_at_eol`) with git's whitespace class, and ASCII `ignore_case`.
- `Diff` with `stat`, `ratio`, `ops` and `hunks`; `HunkOptions` with context, inter-hunk context, `ignore_blank_lines` and an `ignore` predicate.
- `writeUnified`, with `Heading` (`Heading.c_function` is git's default rule) and optional `---`/`+++` lines.
- `merge`: the three-way merge as regions, in the `merge`, `diff3` and `zdiff3` styles at git's four levels; `merge.write` with labels, marker size and `Resolve`; `merge.mergeAlloc`.
- `diffLines`, a one-shot diff that owns its memory.

[Unreleased]: https://github.com/pedronaugusto/parallax/commits/main
