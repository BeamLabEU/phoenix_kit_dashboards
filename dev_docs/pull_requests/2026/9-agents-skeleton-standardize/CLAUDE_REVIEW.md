# PR #9 — Standardize AGENTS.md onto the shared module skeleton

- **Author:** mdon
- **Merged as:** `ce69c0c`
- **Reviewer:** Claude (post-merge, reviewed 2026-10-14)
- **Files:** `AGENTS.md` (rewrite), `CLAUDE.md` (symlink), `dev_docs/guides/layout-model.md` (new),
  `test/test_helper.exs`.

## Summary

Rewrites AGENTS.md onto the shared skeleton, splits the layout/drag detail out
into a guide, and swaps the `psql -lqt` database probe in `test_helper.exs` for
core's `PostgresPreflight` (one classified connection attempt with the repo's
own credentials), keeping the old unclassified path when core lacks it.

## Findings

No bugs. Spot-checks: the lattice cap (160), widget size defaults, the hook
names listed in AGENTS.md and the guide, and the `Code.ensure_loaded?` guard in
`test_helper.exs` (suite runs and preflight is exercised) all match the code.

### NITPICK — stale comment in `test_helper.exs`

The comment justified the `Code.ensure_loaded?` guard by "this module's core
floor (`~> 2.0`) predates it". The floor is `>= 2.38.0` since #12, so the claim
is false. The guard is harmless and kept; **fixed** the comment to say only what
the guard does.
