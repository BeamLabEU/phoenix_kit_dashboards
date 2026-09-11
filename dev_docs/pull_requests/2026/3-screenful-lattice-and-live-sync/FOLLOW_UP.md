# FOLLOW_UP — PR #3: Screenful lattice and live sync

Triaged 2026-09-11 against current `main`. Reviewer: Claude
(`CLAUDE_REVIEW.md`, three rounds including a post-merge audit).

Everything under the review's own "Fixed in this PR" and "Round 3 —
post-merge follow-up audit" headings landed at the time and is not repeated
here. What follows is the state of the items the review left open.

## Fixed (pre-existing)

- ~~**NITPICK — unused export `Lattice.stretch_tolerance/0`.**~~ No longer
  unused: pinned by `test/lattice_test.exs:11`.

## Still live (surfaced, not changed in this triage)

- **IMPROVEMENT-MEDIUM — mid-session permission revocation is not live.** A
  viewer who loses a module's permission keeps seeing that module's widgets
  until they navigate. `Registry.visible_for_scope?/2` is re-checked on every
  render, so the stale window closes on the next mount or patch, not on the
  revocation itself. Closing it properly needs a permissions PubSub topic in
  core, which is a core change, not a module one.
- **IMPROVEMENT-MEDIUM — `hide_widget/4` has no UI.** Still host-facing only
  (`dashboards.ex:613`, and its `show_widget` counterpart at `:903`). A widget
  can be hidden per layout through the context but nothing in the builder
  offers it.
- **IMPROVEMENT-HIGH (test) — the activity-log rescue path is untested.** The
  guarded/rescued logging in `dashboards.ex` (`:1292`, `:1354`) still has no
  test that drives a logging failure and asserts the mutation succeeds anyway.
  The tests that mention `rescue` cover `enabled?/0`, not this path.
- **NITPICK — default names are not translated.** `"My Dashboard"`
  (`dashboards.ex:121`) and `"Layout #{n}"` (`layouts.ex:108`) are stored in
  English whatever the creator's locale. These are persisted DATA, not chrome,
  so translating at render would be wrong; translating at creation time is the
  real option and is a product decision about what a stored title means.
- **NITPICK — activity-log asymmetry.** Geometry edits made through the
  settings modal are logged; drag and resize are not, because `save_layout/2`
  is the hot path and is deliberately excluded (documented in `AGENTS.md`).
  Listed here so the asymmetry is a recorded decision rather than an omission.
- **IMPROVEMENT-MEDIUM (Round 3) — a full layout has no "no room" UX.** When
  `Grid.first_free/5` returns `nil` the caller stacks the widget below the
  screenful; the user is told nothing.
- **NITPICK — `Grid.max_rows/0` has no callers.** Verified: the only match in
  `lib/` is its own `@spec`/`def` (`grid.ex:33-34`); `first_free/5`'s default
  argument uses the `@max_rows` attribute directly, not the function. Public
  API of a published package, so deleting it is a (small) breaking change.

## Skipped (with rationale)

- **LiveView `:stale` → resync.** The review verified this as correct, not as a
  gap: the context-level compare-and-swap is the real guard and the LiveView
  path is a tight-race safety net on top of it.

## Files touched

None in this triage.

## Verification

`mix precommit` clean; 362 tests, 0 failures (2026-09-11).

## Open

The seven "Still live" items above. None is a correctness bug; each is either a
product decision (default-name translation, no-room UX), a core-side
prerequisite (permission revocation), a deliberate exclusion (drag logging), or
a small test/API cleanup (rescue-path test, `max_rows/0`).
