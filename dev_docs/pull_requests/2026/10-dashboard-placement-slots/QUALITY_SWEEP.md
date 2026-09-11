# Quality sweep — PR #10 (placement slots)

Run 2026-09-11 against the playbook in
`Elixir/dev_docs/quality_sweep.md`. Phase 1 (PR catch-up) and Phase 2
(triage + fixes + C14) both complete.

## Phase 1 — PR catch-up

Five PR folders had no `FOLLOW_UP.md`; all five now do.

| PR | Verdict |
|---|---|
| #1 dashboard-builder-overhaul | All four findings already resolved. `set_layout_mode/2` retired; the `fit_size/8` right-edge overflow fixed and pinned by `grid_test.exs:99` |
| #3 screenful-lattice-and-live-sync | 1 resolved; **7 still live**, all product decisions, core-side prerequisites or small test/API cleanups — listed, none silently deferred |
| #4 code-review-resolution | **2 still live**, both test-quality |
| #5 project-tab-viewer-and-slug | 4 BUGs resolved (2 during the PR, 1 earlier, 1 today); 1 NITPICK fixed in this sweep; 1 IMPROVEMENT half-closed by this PR's own work |
| #7 per-module-gettext-i18n | No findings; re-verified |

## Phase 2 — triage

Four `Explore` agents over `lib/` + `test/`, per the playbook's four
categories. **Two of their headline findings did not survive verification** and
are recorded here so they are not re-raised:

- *"`slug: "projects"` collides with `projects/:id` and lights up the list
  tab."* No. A slot's URL is built by the dashboards package
  (`Slots.slot_path/1` = `dashboards/places/<slug>`), never under the declaring
  module's path. `parent_tab` controls sidebar position only. Verified in the
  code and in a browser at `/admin/dashboards/places/projects`.
- *"The `projects.project` slot is missing a `slug`."* It is a `:record_tab`.
  `slot_path/1` is only reached from `module_tabs/0`, which filters
  `surface: :module_tab`, so a record tab generates no route and needs no slug.

### Fixed

| # | Finding | Fix |
|---|---|---|
| 1 | **The declared core floor was a fiction.** `~> 2.0` resolves core 2.13.5, whose `Settings.update_setting_with_module` is arity **3**; `Placements.write/3` calls arity **4**, first shipped in core 2.15.0. `write/3` rescues, so on an older 2.x every place/unplace/reprioritise failed **silently** behind "That didn't work. Try again." — the whole feature dead on arrival, with no error anywhere | Floor → `~> 2.15`. `core_pin_conformance_test.exs` asserted 2.0.0 *must* be admitted; it was encoding the assumption this disproves, so it now guards the real floor and rejects 2.14.9 by name |
| 2 | **The settings page could re-own a role dashboard.** It gated on `manageable_by?/2`, which only restricts PERSONAL boards — it answers `true` for every role one, for any actor. A holder of the dashboards permission could open a role board they are not a member of and save it as personal, becoming its owner | Pairs `viewable_by?/2` the way the delete path and the builder already do; pinned by a test mirroring the existing blind-delete test |
| 3 | **`role_uuid` written straight from the wire.** Publishes a board to a role the sender picked, or — naming no role — creates a row nobody can ever see, since the changeset only checks presence | Validated against the real role list; pinned both ways |
| 4 | **Placement WRITES never re-checked the slot's own permission**, though the read path does and says why. The slot key is a hidden form input, so the scope-filtered list was display-only | One `with_slot/3` gate on all three write handlers. `set_priority` also discarded its result, so a refused reorder looked like a silent revert — now reported |
| 5 | **The project tab adopted any `{:dashboard_updated, _}`.** It subscribes to whatever it resolves to and never unsubscribes, so after a re-point an edit to the OLD board swapped it back onto a project it is no longer placed on. Found independently by two agents | uuid guard on both the update and delete clauses; three tests |
| 6 | **Neither off-router view applied the `"locale"` it documents receiving.** `live_render` spawns a fresh process and the Gettext locale lives in the process dictionary, so every string they rendered fell back to English inside an otherwise-translated page | `Helpers.put_embed_locale/1`, called from both mounts |
| 7 | NITPICK from PR #5: the readonly comment said widgets "render frameless" for a card that keeps its border, shadow and background | Reworded |

### Surfaced, not changed

Ranked, with the reason each was left:

- **`Placements` logs nothing to `PhoenixKit.Activity`.** Binding a company-wide
  dashboard and unbinding it an hour later leaves only a settings-history diff
  of an opaque JSON blob. Real gap; adding an audit trail is a feature-sized
  change, not a sweep fix.
- **No `test/web/{places,slot,admin_home,dashboard_form}_live_test.exs`**, and
  `admin_home_dashboards/1` — the function deciding whether every install's
  `/admin` keeps its overview — has no test in this repo at all.
- **The compile-time slot-discovery path is not exercised**, and the test that
  claims to cover it passes on both outcomes. This is the guard against the
  regression that already happened once (no slot routes at all).
- **`Registry` caches its catalog unconditionally** while `Slots` learned to
  guard on `complete?` — the same trap, un-fixed on the widget side.
- **`add_layout/3` accepts `opts`, discards the actor and never logs**;
  `delete_layout/2` is destructive and unaudited.
- **Activity metadata carries the dashboard title**, which is free user text.
- Five dead public exports (`Grid.max_rows/0`, `Binds.unsatisfied/2`,
  `Refresh.assign_live_flag/2`, `SlotComponents.many?/1`,
  `Dashboards.update_widget_settings/4`) and a `normalize_positions/1` that is
  an identity function under a comment describing behaviour it does not have.
- **The placement blob is a read-modify-write with no CAS**, unlike the
  dashboard row's `config["rev"]`. Two admins binding different slots at once
  can lose one write.
- **`Slots` memoizes personal slots in the process dictionary**, which survives
  every `push_navigate` for the session.

## C14 — stale-ref sweep

`IO.inspect`/`puts` 0 · `TODO`/`FIXME`/`HACK`/`XXX` 0 · raw `{:error, "..."}` 0
· `String.capitalize` 0 · `Task.start(` 0 · commented-out code 0 (one regex
false positive on prose). One `Gettext.gettext(Backend, …)` — `translate_catalog/1`,
the sanctioned runtime path for catalog *data*, anchored by `gettext_noop`.

**i18n, code-vs-catalogue:** 176 literals in `lib/` diffed against the 200
msgids in `default.pot` — 0 missing, 0 fuzzy, 0 empty `msgstr` in en/et/ru.

## Verification

- 368 tests, 0 failures (6 added by this sweep)
- `mix precommit` clean — compile `--warnings-as-errors`, format, credo
  `--strict`, dialyzer
- `mix deps.get` resolves the raised floor against Hex (core 2.22.16)
