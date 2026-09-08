# The grid and the layout model

How a dashboard canvas is rendered, placed, fitted and dragged — the grid
lattice, the two dashboard types, and the hooks that enhance them.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Architecture and Conventions.

## The grid (Phoenix-first, no module JS)

The builder grid is **server-rendered HEEx + a CSS grid** — each widget is anchored
at its placement's explicit cells (`grid-column/-row: <x+1> / span <w>`) on the
active layout's lattice. It renders and is readable **without any
JavaScript**, and every mutation (add / remove / move / resize) re-renders
normally — there is **no** `phx-update="ignore"` and no client-owned DOM.

**Drag-to-place** is progressive enhancement via the module's own
**`DashboardGridDrag`** hook (core's SortableJS-based `SortableGrid` is 1D reorder —
it can't do 2D cell placement): the grid container sets
`phx-hook="DashboardGridDrag"` + `data-cols`, each card is a
`.sortable-item[data-id]` carrying `data-x/-y/-w/-h`, dragged by its
`.pk-drag-handle` — the widget's WHOLE top bar (buttons inside it are excluded
by the hook, so settings/remove still click; the grip icon is just the
affordance). A floating clone follows the cursor while the widget itself
jumps cell-to-cell under it as the live preview — the target cell comes from the
clone's top-left against the grid metrics (data-cols + computed gaps/auto-rows +
the fit scale), and the preview only ever moves through FREE cells (occupancy from
the other cards' data attrs), so the shown spot is always legal and **the drop
always matches the preview**. On drop it pushes `move_widget_grid %{id, x, y}`
(0-based cells; `Dashboards.place_widget_grid/5` clamps + collision-rejects
server-side). There is **no viewport/tier detection** — a dashboard opens
instantly on its first layout (no loading state; no-JS reveals via
`<noscript>`). **Catalog drag-out** (`DashboardCatalogDrag` on `#dashboard-catalog`,
entries carry `data-widget-key/-w/-h`): drag an entry past a ~6px threshold and a
ghost + a free-cells-only dashed footprint follow the pointer; dropping pushes
`add_widget_at %{key, x, y}` (grid) or `add_widget_px %{key, fx, fy}` (pixel
canvas) — a plain click still adds at the first free spot, and a completed drag
swallows its trailing click. **Resize** is a bottom-right corner grip (`.pk-resize-handle`) driven
by the per-card `DashboardResize` hook — pixel-smooth while dragging, and on
release it **branches on the card's `data-free` flag**: grid mode snaps to the
nearest whole cell that FITS (grid edge + neighbours, mirroring `Grid.fit_size/8`)
keeping the x/y anchor → `resize_widget_to %{id, w, h}`; free mode keeps the exact
px → `resize_widget_to %{id, fw, fh}` (clamped to `[60, 4000]`). No-JS fallbacks:
the Settings modal's Width/Height + Column/Row inputs (grid) and Width/Height +
X/Y px inputs (pixel). All placement drags **edge auto-scroll** the pane (a shared
rAF scroller; FreeDrag folds the pane-scroll delta into its drag deltas).

The module hooks ship via `js_sources/0` (`priv/static/assets/phoenix_kit_dashboards.js`):
`DashboardGridDrag` (above), `DashboardFreeDrag` (free canvas — drag a
`.pk-free-handle` grip, moves the card via `left/top` and pushes
`move_widget_to %{id, fx, fy}` in exact px), `DashboardResize` (corner resize, both
modes; see above), plus the fit/fullscreen helpers (`DashboardGridFit`,
`DashboardFreeFit`, `DashboardFullscreen`, `DashboardFitScreen` — the Layout
bar's "Fit screen" button, reporting the real `window.screen` px) and
`DashboardVisibility` (reports viewport width so a dashboard mounts fitted, and
pauses the server's refresh loop while the tab is hidden). All are
enhancement only — the non-hook fallbacks are the server-driven modal inputs.
The drag/resize hooks leave the card exactly where dropped and update the
style in the server's format, so the re-render confirms identically with **no
rubber-band / no snap**; they guard concurrent pointers + handle `pointercancel`,
and only the primary button starts a gesture. Do not introduce inline-`<script>`
hooks — they break on LiveView navigation; ship any hook via `js_sources/0`.

## Dashboard type (fixed at creation) & the layout model

A dashboard's **type is chosen at creation** (`config["type"]` = `"grid"` | `"pixel"`)
and is fixed — there is no runtime toggle (`Dashboard.type/1`; legacy `config["mode"]`
`"free"`→`"pixel"` still maps; `Dashboard.layout_mode/1` derives `"free"`/`"grid"` from
type for the builder's internal render switch).

**Geometry is embedded per widget** (`PhoenixKitDashboards.Layout`) so add/remove is
atomic — a widget item is `%{id, widget_key, settings, view, "pixel" => %{fx,fy,fw,fh},
"bp" => %{<layout_id> => %{x,y,w,h,hidden,pos}}}`. The grid-placement JSONB key stays
`"bp"` for back-compat, but it is keyed by **layout id** (`"l1"`, …), not a device
breakpoint — the code accordingly names the argument `layout_id` (only the storage key
keeps the pre-lattice `bp`/"tier" vocabulary).
`Layout.pixel/1` + `placement/2` default and fall back to the legacy flat shape
(`pos` is the legacy-order tiebreaker; items without stored `x`/`y` are packed at
render and pinned on their first edit).

- **`"grid"` — the SCREENFUL LATTICE.** A grid dashboard is an ordered list
  of named layouts in `config["layouts"]`
  (`[%{"id","name","cols","rows"}]`, `Dashboards.layouts/1`; default
  `Layout 1` at 64×36 = 16:9); the builder shows them as a tab strip
  (`[Layout 1] [Wall TV] [+]` + an actions dropdown with Rename/Delete on
  the active tab). "+" instant-creates "Layout N" copying the active
  layout's dims + placements (doubles as duplicate) and drops into inline
  rename. The last layout can't be deleted; deleting one strips its
  per-widget placements (widgets are dashboard-level and live on elsewhere).
  Each layout is `cols × rows` on a **gapless 25px nominal SQUARE cell
  lattice** (`PhoenixKitDashboards.Lattice`: cell 25, dims 4..160, stretch
  tolerance 1.04) representing **exactly ONE SCREENFUL — nothing scrolls,
  ever**. `DashboardGridFit` sizes the canvas
  NATIVELY (no transform — text/SVG render crisp and undistorted): per-axis
  fill when both scales stay within ~4% of 1 and of each other (a fitted
  screen fills exactly; only the cell rectangles go non-square), else the
  intact **artboard** (`bg-base-100 shadow-xl ring-1`, mono caption
  `Layout 1 · 64×36` hidden when no room below) shrinks into a smaller
  pane or floats centered at NATURAL size in a bigger one — standard
  cells, never blown up. The
  Layout bar has numeric Grid `cols × rows` inputs (`set_dims`) and a
  **Fit screen** button (`DashboardFitScreen` pushes real screen px;
  server rounds px/25). `set_grid_dims/4` NEVER refuses: it clamps to
  Lattice bounds and raises to the occupied extent (shrinking can't crop
  widgets). Widget spans are lattice units (note 16×8 default, min 8×4;
  visual gap = the card's own `m-[2px]`, folded into the resize hook's gap
  term; drag/resize hooks are per-axis-zoom aware). **Widget content
  self-fits** via container queries (`[container-type:size]` +
  `cqmin`/`cqh` type) — the view (detailed/dense/…) is user-chosen (hover
  toolbar cycle button, `cycle_view`) and honored verbatim at ANY size —
  never silently switched. On the grid the view is PER LAYOUT (stored on
  that layout's placement as `"view"`, `Layout.view/2` resolves override →
  instance default; `set_layout_view/4` writes it) — designing the phone
  layout means choosing how widgets look ON the phone. The pixel canvas
  has no layouts, so there the view stays instance-level; list widgets take an "items: N" slot budget
  (body divides into N fixed slots + a "+N more" line; see
  `ModuleStatsWidget` for the worked pattern). Widgets never overlap; a
  widget without a stored placement in a layout packs first-fit at render
  (its TYPE default span) and pins on first edit. NO legacy/tier
  compatibility — pre-lattice configs just get the fresh default layout. A
  session-local **Show-grid toggle** paints a dot lattice as a CSS
  background (`radial-gradient` at 25px pitch — zero extra DOM; per-cell
  divs would be thousands of nodes) even on an EMPTY board (hint floats
  over it).
- **`"pixel"` — an absolute pixel canvas**: drag/resize anywhere, exact px in
  `pixel.fx/fy/fw/fh`, no snapping. Widgets may **overlap deliberately** — each
  widget bar has bring-to-front / send-to-back (`restack_widget_px/3`, a `"z"`
  key in the pixel map that survives moves since `put_pixel` merges). No Layout
  bar and no zoom control (pixel has no tiers; fit-to-width handles scale). The
  **`DashboardFreeFit`** hook scales the canvas via `transform: scale` to **fill
  the container width** AND grows its height to at least the pane's (edge-to-edge,
  no gap around the canvas; a loading spinner covers the pane until the fit
  reveals it) — re-fit by a `ResizeObserver` (`scrollbar-gutter: stable` prevents
  a feedback loop); a `.pk-free-spacer` gives the scroll extent. `transform:
  scale` (not CSS `zoom`) so the drag/resize hooks' `rect.width/offsetWidth`
  reads the exact scale. Move = `DashboardFreeDrag` (`left/top`, pane-scroll
  compensated); resize = the corner grip in px.

Both types render + are operable without JS (grid: Settings modal size +
Column/Row inputs; pixel: modal size + X/Y px inputs).
