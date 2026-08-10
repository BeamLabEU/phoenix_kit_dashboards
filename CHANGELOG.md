# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

## [0.2.3] - 2026-08-09

### Added

- **Read-only project-tab viewer** (`Web.ProjectDashboardLive`): this module is
  now a *project-extension provider* for the `phoenix_kit_projects` hub via the
  duck-typed `phoenix_kit_project_extensions/0` (plain maps — neither package
  depends on the other). A project links ONE shared dashboard and renders it live
  and read-only as a project tab, with an explanatory card for the
  unconfigured / missing / not-shared states.
- `Dashboards.list_system/0` and `PhoenixKitDashboards.project_dashboard_options/0`
  — the shared-dashboard pool behind the project's link picker.
- `readonly` + `id_prefix` attributes on `BuilderComponents.grid_mode/1`,
  `free_mode/1` and `widget_card/1`: the same fitted board with no drag/resize
  hooks and no card chrome, and unique DOM ids when it renders inside another page.

### Changed

- `Schemas.Dashboard.slugify/1` now delegates to core's `PhoenixKit.Utils.Slug`
  **with `transliterate: true`** instead of a local ASCII-only pipeline. A
  Cyrillic title used to strip to an empty slug — which callers read as "no slug
  yet" and regenerate on every save — and Latin diacritics lost their base
  letters. `"Видеопродакшн"` → `"videoprodakshn"`, `"Übung Café"` →
  `"ubung-cafe"`. Scripts core does not romanize (Greek, CJK) still reduce to the
  `"dashboard"` fallback; the slug is a readability aid, not an identifier.

### Fixed

- Provider discovery dropped widgets on a cold VM: `function_exported?/3` returns
  `false` for a module that has not been loaded yet *without loading it*, so a
  discovered provider's widgets were silently missing from the catalogue until
  something else happened to touch the module. `Registry` and the project tab's
  embed-identity resolution now both `Code.ensure_loaded?/1` first.
- `Dashboards.resolve_items/3` could leak string `"w"`/`"h"` spans from a
  legacy/tampered row into the render contract; spans are now floored to
  integers at resolution (`x`/`y` deliberately left uncoerced — their
  integer-ness is the placed-vs-order-only discriminator).
- The empty-board hint told read-only viewers to "Add widgets from the panel on
  the right" — a panel the project tab does not have.

## [0.2.2] - 2026-07-19

### Fixed

- `Dashboards.place_at_cell/5` (a grid drag-to-cell drop) coerced a
  legacy/tampered string `"h"` only for its row-bound clamp but persisted just
  `x`/`y`/`w`, so the string span survived every drag. It now persists the
  coerced `"h"` too (matching `resize_instance/7` / `grow_on_layout/5`), healing
  the stored placement.
- Both regression tests added in 0.2.1 for the legacy-span coercion fixes were
  committed unverified (no PostgreSQL in the review environment) and failed
  against a real DB: the `place_widget_grid/5` one via the persistence gap
  above, the view-switch-growth one via a setup that placed the clock on an
  occupied cell and couldn't trigger growth. The latter was redesigned to
  actually reach the guarded path and pin the `ArithmeticError`.
- `mix.exs` `source_ref` pointed ExDoc source links at non-existent
  `v`-prefixed tags; the repo tags bare version numbers. Corrected, along with
  the stale core-pin floor comments in `mix.exs`/`AGENTS.md` (the floor has
  been `~> 1.7.189` since `PhoenixKit.SchemaPrefix`).

## [0.2.1] - 2026-07-18

### Changed

- Resolved the 15-finding 2026-07-16 code review: touch drag-out pointer-capture
  loss, pixel-canvas resize rubber-band, mixed-type numeric coercion in grid
  math, clock-widget size docs, dead/unwired API removal, permission-check
  consolidation onto `Web.Helpers.viewable_by?`/`manageable_by?`, registry cache
  invalidation on enable, context↔LiveView geometry duplication collapsed into
  `Lattice`/`Sizing`/`Grid`.
- `builder_live.ex` (2028→991 lines): presentational layer extracted to the new
  `Web.BuilderComponents`.
- `dashboards.ex` (1503→1459 lines): pure helpers extracted to `Layouts`; the
  packer consolidated onto `Grid.slot/5` + `Grid.pack/4`, with `Grid.compact/3`
  kept as a distinct size-preserving reflow (a multi-AI re-review caught and
  fixed a regression where the two briefly shared code and `compact` started
  silently rewriting a caller's stored `h`).
- `bp`/"tier" vocabulary renamed to `layout_id`/"layout" throughout (the JSONB
  storage key stays `"bp"` for back-compat).
- JS collision math (`rectsOverlap`/`fitSpan`) deduped, pinned against
  `Grid.fit_size/8` via a Node test harness.
- Converted ~109 call sites from `Gettext.gettext(PhoenixKitWeb.Gettext, "...")`
  to the `gettext/1` macro idiom (compile-time extraction); pure syntax change,
  identical msgids.

### Fixed

- `Dashboards.place_at_cell/5` (a grid drag-to-cell drop) crashed with
  `ArithmeticError` on a widget instance carrying a legacy/tampered string
  span (`"h" => "4"`) — `Layout.placement/2`'s `"w"`/`"h"` were used in
  arithmetic without the `Lattice.to_int/2` coercion every other geometry call
  site applies.
- `Dashboards.grow_on_layout/5` (a widget view switch that raises the view's
  minimum size) had the same gap and could likewise crash with
  `ArithmeticError` on a legacy string `"w"`.
- `Dashboards.resize_instance/7` passed an uncoerced `"h"` into
  `Grid.fit_size/8`, silently discarding a legacy/tampered stored height
  instead of using it.
- A widget-count caption in `DashboardsLive` used the runtime
  `Gettext.ngettext/4` form, left over from the gettext idiom conversion above
  — invisible to `mix gettext.extract`, so it could never gain a translation.
  Converted to the `ngettext/3` macro.

## [0.2.0] - 2026-07-16

### Added

- **Screenful lattice grid model**: replaces fixed device-tier breakpoints
  (TV/Desktop/iPad/Phone) with user-defined named layouts, each a `cols × rows`
  grid on a gapless 25px square-cell lattice representing exactly one
  screenful — nothing scrolls. Layouts are managed as a tab strip
  (add/rename/delete/duplicate) with numeric dimension inputs and a
  "Fit screen" button.
- **Fully live dashboards**: every mutation broadcasts over a per-dashboard
  PubSub topic, so any open session (e.g. a wall-mounted display) re-renders
  instantly on a concurrent edit and navigates away on delete.
- **Optimistic concurrency**: a monotonic `config["rev"]` compare-and-swap
  (no schema migration) refuses stale writes instead of silently clobbering a
  concurrent edit; the builder re-syncs automatically.
- **Display mode**: fullscreen now hides all edit chrome and auto-hides the
  cursor after idle; the refresh loop pauses while the tab is hidden so a
  backgrounded display doesn't fast-forward its clocks on return.
- **Host-app widgets**: any host application can contribute widgets via
  `config :phoenix_kit_dashboards, widget_providers: [...]`, using the same
  `phoenix_kit_widgets/0` contract as a PhoenixKit module.
- **Per-layout widget views**: a widget's render variant (detailed/compact/…)
  is chosen per layout and honored verbatim at any size via container-query
  self-fit sizing.
- Dedicated create/edit page (`DashboardFormLive`) replacing the old create
  modal.

### Changed

- Pixel-canvas dashboards brought up to the lattice-era polish (native fit,
  fill-to-container scaling, restack z-order).
- Manage page trimmed to list/create/clone/delete now that metadata editing
  lives on its own page.

### Fixed

- Hardened the module against a multi-AI security/quality review: re-authorize
  every builder event and form save, scope-gate add-widget paths, validate
  settings/view input to prevent bricking, bound pixel coordinates, gate
  module-stats on module access, and isolate provider discovery from crashes.
- `Grid.first_free/4` ignored a layout's actual row count (scanned to a
  hardcoded 160-row cap), letting a new widget seed below the visible
  screenful on a full small layout instead of triggering the documented
  below-the-fold fallback.
- `DashboardsLive` had no catch-all `handle_event`, unlike its sibling
  LiveViews — an unrecognized event crashed the process.
- `DashboardFormLive` treated a concurrent-edit `{:error, :stale}` as a
  generic save failure instead of resyncing.
- The `DashboardVisibility` JS hook didn't sync the refresh-pause state for a
  dashboard that mounts already in a background tab.

## [0.1.0] - 2026-06-12

### Added

- Initial scaffold of the Dashboards module.
- `PhoenixKit.Module` integration: auto-discovery, admin tab, permission,
  enable/disable.
- Backing `phoenix_kit_dashboards` table added as core PhoenixKit migration V133
  (modules do no DDL of their own).
- Widget provider contract — any module exposes widgets via a plain-map
  `phoenix_kit_widgets/0` (`PhoenixKitDashboards.Widget`).
- `PhoenixKitDashboards.Registry` — runtime discovery and a cached widget
  catalog (built-ins ∪ providers), filtered by module enablement and permissions.
- Built-in widgets: Note, Clock, Module stats.
- `phoenix_kit_dashboards` table + schema + context, with personal and
  system/shared dashboard scopes and a JSONB `layout` of widget instances.
- Manage page (`DashboardsLive`) and a gridstack-style 2D grid builder
  (`BuilderLive`) with add/remove, drag/resize persistence, and a
  schema-generated per-widget settings form.
