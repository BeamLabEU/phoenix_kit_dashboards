# PR #5: Add the read-only project-tab viewer and projects-hub provider, and move slug generation onto core

**Author**: @mdon (Max Don)
**Reviewer**: Claude
**Status**: Merged
**Commit**: `b4d4dcc..feb4614` (merge `46cc04f`)
**Date**: 2026-08-09

## Goal

Two independent changes shipped together:

1. **A read-only Dashboard tab for the `phoenix_kit_projects` hub.** This module
   becomes a *project-extension provider* the same duck-typed way it is already a
   *widget provider* — `phoenix_kit_project_extensions/0` returns a plain-map
   descriptor, so neither package depends on the other. A project can link ONE
   shared dashboard and render it, live and read-only, as a project tab.
2. **Stop hand-rolling slug generation.** `Dashboard.slugify/1` had a local
   ASCII-only pipeline that deleted every non-ASCII character, so a Cyrillic
   title produced an EMPTY slug — and an empty slug is worse than a wrong one,
   because `maybe_put_slug/1` reads `nil`/`""` as "no slug yet" and regenerates
   on every save. The fix routes it through core's `PhoenixKit.Utils.Slug`.

Two pre-existing bugs were also fixed in passing (the suite was red at HEAD):
cold-VM widget discovery, and string geometry leaking out of `resolve_items/3`.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_dashboards.ex` | New `phoenix_kit_project_extensions/0` descriptor + `project_dashboard_options/0` (the shared-dashboard picker source) |
| `lib/phoenix_kit_dashboards/web/project_dashboard_live.ex` | **New.** The embedded read-only viewer: embed-session identity, state machine, PubSub live sync, re-hosted refresh loop |
| `lib/phoenix_kit_dashboards/web/builder_components.ex` | `readonly` + `id_prefix` attrs on `grid_mode`/`free_mode`/`widget_card` — same board, no edit affordances, unique DOM ids |
| `lib/phoenix_kit_dashboards/dashboards.ex` | `list_system/0`; `normalize_span/1` in `resolve_designed/2` |
| `lib/phoenix_kit_dashboards/registry.ex` | `Code.ensure_loaded?/1` before `function_exported?/3` in provider discovery |
| `lib/phoenix_kit_dashboards/schemas/dashboard.ex` | `slugify/1` delegates to `PhoenixKit.Utils.Slug` |
| `test/web/project_dashboard_live_test.exs` | **New.** State machine, shared-only rule, absence of edit affordances, live downgrade, provider contract |
| `test/slug_generation_test.exs` | **New.** Pins the slug behaviour |

## Implementation Details

- **The arrow still points one way.** The project-extension descriptor is a plain
  map (`key`, `tabs`, `config_schema`, `permission_actions`) with no `@impl` and
  no compile-time reference to `phoenix_kit_projects` — the same contract shape
  as `phoenix_kit_widgets/0`.
- **Only `scope == "system"` renders.** A project tab is a project-wide surface;
  personal and role dashboards carry per-user visibility a shared pane must not
  blur. Both the picker (`project_dashboard_options/0`) and the render path
  (`state_for/1`) enforce it, and the render path re-checks on every
  `{:dashboard_updated, _}` so a re-scope downgrades the pane live.
- **Per-viewer gating is unchanged.** Widget bodies still run
  `Registry.visible_for_scope?/2`, so a viewer without a module's permission gets
  that widget's placeholder — exactly like the builder.
- **Off-router mount.** `use Phoenix.LiveView` (not `PhoenixKitWeb, :live_view`)
  so the admin layout is not pulled into a project page; identity is
  reconstructed from the embed session because the `on_mount` hook never runs
  under `live_render`.
- **`readonly` reuses the board rather than forking it.** One render path for the
  builder and the viewer; `id_prefix` keeps the fit/drag DOM ids unique when the
  board renders inside another page.

## Testing

- [x] Unit tests added (slug generation)
- [x] Integration tests added (`:integration`, need PostgreSQL + core `>= 1.7.179`)
- [x] `mix precommit` green after review fixes
- [x] Backward compatibility verified (slug change affects new/blank slugs only)

## Known Limitations (v1, by design)

- Grid dashboards show their **first** layout — no layout switcher in the tab.
- Changing `dashboard_uuid` in the project's Modules panel is picked up when the
  tab LiveView next mounts; if the hub embeds the tab as a **sticky** nested
  LiveView, that mount does not happen on `push_navigate` and the pane keeps the
  previously linked dashboard until a full page load. Live sync (`Dashboards.subscribe/1`)
  covers edits to the *linked* dashboard, not a change of *which* dashboard is linked.

## Related

- Review: [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md)
- Previous PR: [#4](/dev_docs/pull_requests/2026/4-code-review-resolution-and-c14-sweep)
- Core slug rule: `deps/phoenix_kit/lib/phoenix_kit/utils/slug.ex`
