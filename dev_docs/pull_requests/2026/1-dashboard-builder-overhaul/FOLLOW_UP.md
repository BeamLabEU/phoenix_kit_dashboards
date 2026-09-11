# FOLLOW_UP — PR #1: Dashboard builder overhaul

Triaged 2026-09-11 against current `main`. Reviewer: Claude
(`CLAUDE_REVIEW.md`).

## Fixed (pre-existing)

- ~~**NITPICK — `builder_live.ex` moduledoc described the removed
  `config["mode"]` model.**~~ Fixed in `32a6343` during the PR itself.
- ~~**NITPICK — `grid.ex` moduledoc referenced `fit_size/7`.**~~ Fixed in
  `32a6343`; the function is `fit_size/8` (`grid.ex:188`).
- ~~**IMPROVEMENT-MEDIUM — `set_layout_mode/2` was a legacy no-op.**~~ Retired
  since. `set_layout_mode`, `layout_modes/0` and `@layout_modes` have no
  matches anywhere in `lib/` or `test/`. The legacy `config["mode"]` → type
  mapping survives as a read-side fallback only
  (`schemas/dashboard.ex:128-129`), which is the intended end state.
- ~~**IMPROVEMENT-MEDIUM — `Grid.fit_size/8` right-edge overflow.**~~ Fixed.
  The fitting floor is now clamped to the available space when that is smaller
  than the type minimum (`grid.ex:192-193`,
  `floor_w = min(min(min_size.w, cols), max(cols - x, 1))`), so a widget parked
  at the edge via `min_override` can no longer grow one column past the grid.
  Pinned by `test/grid_test.exs:99` ("the grid edge caps even the type minimum
  (min_override corner)").

## Skipped (with rationale)

- **NITPICK — `DashboardsLive.mount/3` runs a DB query in `mount`.** Unchanged
  and still correct: the page has no `handle_params`, so mount is the only load
  point, and a `connected?/1` guard would blank the first paint. The review
  reached the same conclusion.
- **NITPICK — `Jason.encode!` rather than the built-in `JSON`.** Unchanged.
  Jason is present transitively via Phoenix; switching is cosmetic.

## Files touched

None — every actionable finding was already resolved before this triage.

## Verification

`mix precommit` clean; 362 tests, 0 failures (2026-09-11).

## Open

None.
