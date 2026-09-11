# Claude Review — PR #10

**Reviewed**: 2026-09-11
**Range**: `ce69c0c..d72f6aa` (merge `8213ecc`)
**Author**: @mdon
**Verdict**: the placement-slots feature (slots, placements, binds, the
Places/Slot/AdminHome LiveViews) is sound. This PR shipped with its own
internal `QUALITY_SWEEP.md`, which already found and fixed 7 real bugs
(core version floor, role-dashboard re-ownership, unvalidated `role_uuid`,
a placement-write permission bypass, a cross-re-point subscription leak, a
missing off-router locale, one wording nitpick) before merge. This review
re-checked the diff against the Iron Law, PubSub scoping, sticky-LiveView
staleness, catalog/gettext drift, the personal-tier reuse claim, and the
bind "never a fallback record" invariant — the sweep holds up. No
CRITICAL/HIGH/MEDIUM findings survived.

---

## NITPICK — `put/3`'s docstring invents a "wall surface" restriction that doesn't exist

`lib/phoenix_kit_dashboards/placements.ex`

The doc said a pixel dashboard is refused "in a slot that is not a wall
surface." `Slot.surface/0` has exactly three values (`:module_tab`,
`:record_tab`, `:admin_home`) — there is no wall/TV concept in the type —
and `validate_type/2` only actually rejects a pixel dashboard for
`:admin_home`. A pixel canvas can be placed in an ordinary sidebar or
record-tab slot today; the `DashboardFreeFit` hook auto-scales it to fit,
so nothing is broken, but the docstring overclaims an enforcement the code
doesn't have.

**Fixed**: reworded to name `:admin_home` specifically and note the other
surfaces accept and auto-scale a pixel dashboard.

---

## IMPROVEMENT - LOW — `load_all/1` is N+1 (not fixed; already priced in)

`lib/phoenix_kit_dashboards/placements.ex:209`

`Placements.resolve/3` calls `Dashboards.get/1` once per placement inside
`load_all/1` rather than a single `WHERE uuid IN (...)`. This is a fresh
pattern this PR introduces (not raised by the sweep), but the module's own
docstring (line 20) already scopes placements to "as many as an
administrator types by hand: tens, not thousands" — the same
priced-tradeoff shape as the sweep's other deferred items. Not fixed here;
recording it so it doesn't need rediscovering if that scale assumption
ever changes.

---

## Reviewed and found correct

- **Iron Law** — `SlotLive` loads in `handle_params/3`. `AdminHomeLive`
  queries in `mount/3`, but it's mounted off-router via `live_render`
  (`handle_params/3` never fires there), the same forced tradeoff already
  accepted for `ProjectDashboardLive` in the PR #5 review — a second
  instance of a known, priced cost, not a new bug.
- **PubSub scoping** — `Placements.topic/0` is a single unscoped topic,
  correctly so: placements are admin-wide config, and every handler
  re-derives visibility from `Slots.visible_for_scope?/2` +
  `Placements.resolve/3` on receipt rather than trusting the broadcast
  payload.
- **Sticky nested LiveView** — `SlotLive`/`AdminHomeLive` re-resolve
  everything live off `{:placements_changed, _}` / `{:dashboard_updated,
  _}`; neither has the PR #5 class of stale-session-read bug.
- **Catalog/gettext sync** — the only new catalog literal this PR
  introduces (the "Admin home" slot's name/description,
  `phoenix_kit_dashboards.ex:307-308`) is anchored via `gettext_noop`.
  Verified by grep against `default.pot`.
- **Personal-tier reuse** — `Web.Personal.fork/2` / `reset/2` /
  `assign_flags/1` are genuinely shared by `SlotLive` and `AdminHomeLive`,
  not reimplemented, matching the AGENTS.md claim that every surface
  rendering a place goes through one fork/reset path.
- **Bind resolution** — `Binds.resolve/3` is called from exactly three
  render paths (`refresh.ex`, `project_dashboard_live.ex`,
  `builder_components.ex`), and `slot_components.ex`'s board rendering
  reuses `builder_components`'s `grid_mode`/`free_mode` rather than
  reimplementing widget rendering, so Places/AdminHome inherit the same
  "unresolvable bind renders an explanatory card, never a fallback record"
  guarantee for free. `refresh.ex` correctly skips `send_update` when a
  widget's binds are unresolved (would otherwise target state the render
  never mounted).

---

## Gate

`mix test` — **368 tests, 0 failures** (against a local `phoenix_kit_dashboards_test`
database with `PGDATABASE` set explicitly — `mix test.setup`'s own `storage_up`
step fails on this role because it lacks `CONNECT` on the `postgres`
maintenance database, but the target test database already existed and
needed no creation).

`mix precommit` — clean (`compile --warnings-as-errors`, format, credo
`--strict`: 898 mods/funs, no issues; dialyzer: 0 errors).
