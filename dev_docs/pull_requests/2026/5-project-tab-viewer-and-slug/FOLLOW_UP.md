# FOLLOW_UP — PR #5: Project-tab viewer and slug

Triaged 2026-09-11 against current `main`. Reviewer: Claude
(`CLAUDE_REVIEW.md`).

## Fixed (pre-existing)

- ~~**BUG-CRITICAL — the slug fix was a no-op; `transliterate` defaults to
  `false`.**~~ Fixed. `schemas/dashboard.ex:181` now carries the explicit
  `transliterate: true` and states why it is required.
- ~~**BUG-HIGH — the new test asserted a romanization core cannot produce.**~~
  Fixed. `test/slug_generation_test.exs:13,36-41` asserts against core's
  current behaviour and documents the contract change that made the old
  assertion wrong (core made romanization unconditional and now accepts
  `:transliterate` as ignored, for source compatibility).
- ~~**BUG-MEDIUM — `assign_embed_identity/2` repeated the cold-VM trap this
  same PR fixed elsewhere.**~~ Fixed:
  `web/project_dashboard_live.ex:339-344` calls `Code.ensure_loaded?/1` before
  `function_exported?/3`, with the reason in a comment. On a cold VM
  `function_exported?/3` answers `false` without loading the module, which
  silently took the legacy fallback against a core that does export the
  canonical helper.
- ~~**BUG-MEDIUM — the read-only board told viewers to use a panel that isn't
  there.**~~ Fixed 2026-09-11. The empty state said "pick a shared dashboard in
  the Modules panel" while no such panel appears anywhere on a project page. It
  now links to the Places screen and spells the per-project path out as
  `⋮ → Edit → Modules → Dashboard` (`web/project_dashboard_live.ex:266-283`).

## Fixed (Batch 1 — 2026-09-11)

- ~~**NITPICK — the `readonly` docstring overstated what is dropped.**~~ The
  comment claimed readonly widgets "render frameless"; the card keeps its
  border, shadow, background and margin — only the chrome bar and resize grip
  go. Reworded at `web/builder_components.ex:509-512`.

## Partially fixed

- **IMPROVEMENT-MEDIUM — a config change is invisible to a sticky embed.** Half
  of this is now closed: the tab subscribes to `Placements` and reloads on
  `{:placements_changed, _}` (`web/project_dashboard_live.ex:135-136`), so
  changing which dashboard is placed reaches an open project page live. The
  other half is unchanged — the per-project `config["dashboard_uuid"]` is still
  captured once at mount (`:89`), so re-pinning a project's own board still
  needs a remount. Closing it needs the hub to broadcast an
  extension-config-changed message, which is a contract `phoenix_kit_projects`
  owns.

## Skipped (with rationale)

- **IMPROVEMENT-MEDIUM — DB query in `mount/3`.** Unchanged, and the review's
  reasoning still holds: the view is mounted off-router via `live_render`, so
  `handle_params/3` never fires and there is nowhere correct to move it.
  Gating on `connected?/1` would throw away the server-rendered first paint;
  `assign_async/3` adds a loading state for one indexed primary-key lookup.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_dashboards/web/builder_components.ex` | Reword the readonly chrome comment — "frameless" was wrong for a card that keeps its frame |

## Verification

`mix precommit` clean; 362 tests, 0 failures (2026-09-11).

## Open

The sticky-embed half above, which needs a change in `phoenix_kit_projects`.
