# KIMI_REVIEW — PR #4 post-merge (round 4)

Independent post-merge sweep after round 3 (`CLAUDE_REVIEW.md` + commit `f5d227e`).
Scope: verify the round-3 fixes actually hold, look for anything rounds 1–3 missed.

Severity taxonomy: `BUG-CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT-HIGH/MEDIUM`, `NITPICK`.

## Findings — all fixed in this round

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | BUG-HIGH | **Both regression tests added by round 3 (`f5d227e`) fail when run against a real DB.** They were committed unverified — the round-3 reviewer explicitly had no PostgreSQL (93 unit tests only), and the "237 tests, 0 failures" figure in `2026-07-16-code-review-FOLLOWUP.md` predates the commit. (a) `place_widget_grid/5 "coerces a legacy string span instead of raising"` asserts `%{"h" => 4}` on the persisted placement, but `place_at_cell/5` persisted only `%{"x","y","w"}` — the coerced `h` was used for clamping and then dropped, so the tampered string `"h" => "4"` survived the write and the assertion MatchErrors (verified with the pure `Layout` merge: `match?(%{"h" => 4}, …)` → `false`). (b) `resize_widget/5 "view-switch growth coerces a legacy string w…"` parks the clock at `(0, 0)` — occupied by the setup note (pinned `(0,0)` 16×8 by `new_instance`) — so `place_widget_grid/5` returns `{:error, :occupied}` and the `{:ok, d}` match fails immediately; and even on a free cell the scenario couldn't exercise growth (clock already at h=8 = the analog floor → the no-op guard returns the item with the string `"w"` intact → `%{"w" => 12}` would MatchError too). | (a) **Code fix, not a test weakening**: `place_at_cell/5` now also persists the coerced `"h"` — completing the coercion round 3 started and matching `resize_instance/7` / `grow_on_layout/5`, which both persist coerced `w` **and** `h`. Every drag now heals a legacy string span instead of reading past it forever. The test passes as written. (b) Test redesigned to actually reach the guarded path: park the clock at `(20, 0)` (free), shrink to 12×4 (the normal view's floor) so the analog switch genuinely grows `h` 4→8, *then* tamper `"w"` to `"12"`. On unfixed code `p["x"] + w` = `20 + "12"` raises `ArithmeticError` — the test pins exactly the round-3 crash; on fixed code it asserts the coerced `%{"w" => 12, "h" => 8}`. |
| 2 | BUG-MEDIUM | `mix.exs` `docs()` sets `source_ref: "v#{@version}"`, but repo tags are **bare** (`0.1.0`, `0.2.0`, `0.2.1` — AGENTS.md mandates "no `v` prefix", and `git ls-remote --tags origin` confirms). Every ExDoc source link points at a non-existent `vX.Y.Z` ref → 404 on GitHub. | `source_ref: "#{@version}"` + a comment tying it to the bare-tag convention. |
| 3 | NITPICK | `mix.exs` pin comment said "Floor is 1.7.179" while the pin is `~> 1.7.189` (raised in `4914289` for `PhoenixKit.SchemaPrefix`), and used pre-rename vocabulary ("home tier, customized breakpoints"). `AGENTS.md` ("Database & Migrations") likewise claimed the pin floor is `~> 1.7.179`. | Comment rewritten: floor 1.7.189 (SchemaPrefix), ≥1.7.179 for V139's `config` column (type + named layouts), V133/1.7.145 for the table. AGENTS.md updated to match. |

## Verified clean (checked, no issue)

- **Round-3 geometry fixes themselves are correct**: `place_at_cell/5`, `grow_on_layout/5`,
  `resize_instance/7` now coerce via `int/2` → `Lattice.to_int/2` floored at 1, matching every
  other geometry call site; the no-op guard compares against the coerced originals. A full
  re-sweep of every `["w"]/["h"]/["x"]/["y"]/["fx"]/["fy"]/["fw"]/["fh"]` read in `lib/` found
  no remaining uncoerced arithmetic site — `grid.ex` (collides?/below_all/pack/compact),
  `occupied_extent/3`, `pixel_bound/2`, `next_pixel_y/1`, and the render helpers in
  `builder_components.ex` all coerce at the point of arithmetic or guard with `is_integer`.
- **Gettext `ngettext` macro conversion** (`dashboards_live.ex`): msgids are static literals,
  `ngettext/3` is in scope via `use PhoenixKitWeb, :live_view`, and `%{count}` auto-binds —
  compile-verified by `mix precommit` (warnings-as-errors) on the merged tree.
- **`resolve_designed` sort keys** are homogeneous `{int, int, int}` (`pos` is always pinned),
  so the reading-order sort can't hit Erlang cross-type term ordering.
- **`mix precommit`** (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, `format --check-formatted`, `credo --strict`, dialyzer): clean on the merged
  tree before this round's changes, against local core (`PHOENIX_KIT_PATH=../phoenix_kit`).
- **JS geometry harness**: `npm test` (`node --test "test/js/**/*.test.cjs"`) — 4/4 pass.

## Environment note

No PostgreSQL is available in this review environment either, so the two repaired
integration tests were verified by deterministic tracing of the pure layer
(`Layout.put_placement` merge semantics, `Grid.collides?/5` math, `Sizing.bounds` analog
floor 8×8, grow/no-op guard arithmetic) rather than executed. **They still need one
`mix test` run with a DB before release** — the exact gap that let them ship broken.
Expected suite total with a DB: 239 tests (237 prior + 2 round-3 regression guards).

## Files changed in this round

- `lib/phoenix_kit_dashboards/dashboards.ex` — `place_at_cell/5` persists the coerced `"h"`.
- `test/dashboards_test.exs` — the view-switch coercion test now reaches the guarded path.
- `mix.exs` — `source_ref` bare tag; pin comment corrected (1.7.189 / SchemaPrefix).
- `AGENTS.md` — pin floor mention corrected to `~> 1.7.189`.
