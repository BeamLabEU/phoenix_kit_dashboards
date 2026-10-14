# PR #12 — Actor and activity logging through core

- **Author:** mdon
- **Merged as:** `0cab060`
- **Reviewer:** Claude (post-merge, reviewed 2026-10-14)
- **Files:** `dashboards.ex`, `web/helpers.ex`, `web/{builder,dashboard_form,places,slot}_live.ex`,
  `mix.exs`, `test/core_pin_conformance_test.exs`, gettext catalogs, `AGENTS.md`.

## Summary

Replaces the hand-rolled, `Code.ensure_loaded?`-guarded activity logging and
actor lookups with core's `PhoenixKit.Activity.log/3` and `PhoenixKitWeb.Actor`,
raises the core floor to `>= 2.38.0 and < 3.0.0`, and sets the admin header
trail (`page_section`, `page_section_path`, `page_crumbs`) on every page.

## Verified against core (2.62.2, the locked version)

- `Activity.log/3` exists, defaults `mode: "manual"` (what the old map set
  explicitly), and cannot raise: it rescues and catches `:exit`/`:throw`, and
  answers `{:error, :invalid_arguments}` for bad arguments. Dropping the local
  `rescue`/`catch` is therefore safe.
- `PhoenixKitWeb.Actor.uuid/1` accepts a socket, an assigns map, a `%Scope{}`
  or `nil`; `opts/1` returns `[actor_uuid: uuid]` or `[]`. The `defdelegate`s
  keep every existing call site (`Helpers.actor_uuid/1`, `scope_actor_uuid/1`,
  `actor_opts/1`) source-compatible.
- Behaviour change worth knowing, not a bug: the scope now wins over
  `:phoenix_kit_current_user`; before, `actor_uuid/1` read only the user assign.
  Core documents this as the canonical order.
- Trail assigns are set in `mount` (static parts) and `handle_params`/`load_slot`
  (title, crumbs), so no query was moved into `mount`.

## Findings

### IMPROVEMENT - MEDIUM — suite red on `main` after the lock moved to core 2.62.2

13 tests failed on a clean tree; none touch this PR's logic. Two causes, both
test brittleness against newer core:

1. 12 tests hard-coded `"/en/admin/dashboards…"` as the expected redirect/link
   target. Current core omits the primary locale from generated URLs, so
   `Paths.index/0` returns `/admin/dashboards`.
2. The builder settings test saved `module_key => "jobs"` into a select whose
   options come from the live module registry; `jobs` is not registered in the
   test environment on this core, so LiveViewTest rejected the value.

**Fixed:** the tests now derive expectations from `Paths` (new `uuid_from/1`
helper in `dashboards_live_test.exs`) and pick `"dashboards"` — this module's
own key, always in the registry — for the select. Result: 402 tests, 0
failures. The requests themselves still go to the router's `/en/…` scope,
which is unchanged.

### NITPICK — pin test failure message described the wrong core

The `refute Version.match?("2.37.5", …)` assertion's message still said
"core 2.14.9 lacks `Settings.update_setting_with_module/4`" (copy of the
previous floor's reason). A failure would have sent the reader to the wrong
cause. **Fixed:** the message now names `PhoenixKitWeb.Actor` and
`Activity.log/3`, the reason 2.38.0 is the floor.

### Not verified

That `Actor` and `Activity.log/3` first shipped in exactly 2.38.0: the vendored
core in `deps/` ships no changelog covering it. The pin test enforces whatever
floor is declared, but the number itself is the author's claim.
