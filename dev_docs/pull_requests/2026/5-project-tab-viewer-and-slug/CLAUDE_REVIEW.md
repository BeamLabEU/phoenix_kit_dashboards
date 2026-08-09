# Claude Review — PR #5

**Reviewed**: 2026-08-09
**Range**: `b4d4dcc..feb4614` (merge `46cc04f`)
**Author**: @mdon
**Verdict**: the project-tab viewer is sound and well-scoped. The slug half of the
PR **did not work** — it shipped with its own pinning test failing, and the failure
was the real bug, not a bad expectation.

---

## BUG - CRITICAL — the slug fix was a no-op; `transliterate` defaults to `false`

`lib/phoenix_kit_dashboards/schemas/dashboard.ex`

```elixir
case Slug.slugify(title) do   # ← arity-1 call: transliterate: false
```

Core's `PhoenixKit.Utils.Slug.slugify/2` only romanizes when explicitly asked:

```elixir
def slugify(text, opts) when is_binary(text) do
  text
  |> String.downcase()
  |> maybe_transliterate(Keyword.get(opts, :transliterate, false))   # ← DEFAULT FALSE
  |> String.replace(~r/[^a-z0-9]+/u, separator)
  ...
```

Without the option, `maybe_transliterate/2` is the identity function and the very
next line strips every non-ASCII character — **exactly what the local pipeline
this replaced did**. Verified against the pinned core:

| Input | `Slug.slugify(t)` (what the PR called) | `Slug.slugify(t, transliterate: true)` |
|---|---|---|
| `"Видеопродакшн"` | `""` → falls back to `"dashboard"` | `"videoprodakshn"` |
| `"Übung Café"` | `"bung-caf"` | `"ubung-cafe"` |

So the PR's stated goal — "a Cyrillic name no longer produces an EMPTY slug" —
was **not achieved**, and the code comment asserting `Slug.slugify/2 romanizes
instead` was false as written. The German case was arguably made *worse*: the old
pipeline's `[^a-z0-9\s-]` strip and the new default both drop the umlaut, but the
new one silently splits `"Übung"` into `"bung"` rather than a whole word.

**Fixed**: pass `transliterate: true`, and replace the comment with one that says
*why* the option is load-bearing (so it doesn't get "simplified" away again).

### Why this got through

The PR's own test asserted the correct behaviour and **failed**. `mix test` at the
merge commit reports `96 tests, 1 failure`. The pinning test did its job; it was
merged red. The repo has no CI (AGENTS.md: "test state is whatever local `mix test`
reports"), so nothing else caught it.

---

## BUG - HIGH — the new test asserted a romanization core cannot produce

`test/slug_generation_test.exs`

```elixir
assert Dashboard.slugify("Καλημέρα") == "kalimera"
```

Core's `@cyrillic_map` covers **Russian and Ukrainian Cyrillic only**;
`transliterate/1` additionally NFD-strips Latin diacritics. Greek is in neither
set, so it survives transliteration unchanged and is then stripped by the
`[^a-z0-9]+` pass — `""` → `"dashboard"`. This assertion could never pass, with or
without the `transliterate` option; it would have kept the suite red even after
the critical fix above.

**Fixed**: the Greek case now asserts the truth (it reduces to the fallback) and
is documented as a known limitation rather than an aspiration. Added a Ukrainian
case (`"Проєкт Огляд"` → `"proiekt-oglyad"`, exercising the multi-char `є`→`ie`
mapping) and a Latin-diacritic case (`"Übung Café"` → `"ubung-cafe"`).

Also added a **regression guard** that asserts core's *default* is not what we
call:

```elixir
assert Slug.slugify("Видеопродакшн") == ""
assert Dashboard.slugify("Видеопродакшн") != "dashboard"
```

That is the assertion that fails the moment someone drops the option again.

---

## BUG - MEDIUM — `assign_embed_identity/2` repeats the cold-VM trap this same PR fixed

`lib/phoenix_kit_dashboards/web/project_dashboard_live.ex`

`registry.ex` in this PR correctly added:

```elixir
|> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, @provider_callback, 0)))
```

…with a good comment explaining that `function_exported?/3` answers `false`
*without loading* an unloaded module. The new LiveView then does the unguarded
thing 80 lines away:

```elixir
if function_exported?(PhoenixKitWeb.Users.Auth, :assign_embedded_current_user, 2) do
```

Same failure mode, different consequence: on a cold VM this silently takes the
legacy `resolve_embed_identity/1` fallback against a core that *does* export the
canonical helper. The fallback builds a scope by hand (`Auth.get_user/1` +
`Scope.for_user/1`), so any identity assign core's helper does that the fallback
does not — now or later — is silently missing for the embedded tab.

**Fixed**: `Code.ensure_loaded?/1` guard added, with a comment cross-referencing
the Registry case.

---

## BUG - MEDIUM — the read-only board told viewers to use a panel that isn't there

`lib/phoenix_kit_dashboards/web/builder_components.ex`

`grid_mode` takes `empty` and renders the builder's hint verbatim:

> Add widgets from the panel on the right.

`ProjectDashboardLive` passes `empty={@dashboard.layout == []}` and `readonly`.
The read-only tab has no catalog panel and no way to add anything, so an empty
linked dashboard instructs the viewer to do something impossible — and, in the
common case, something they lack permission to do at all.

**Fixed**: the hint branches on `@readonly` ("This dashboard has no widgets yet.").

---

## IMPROVEMENT - MEDIUM — DB query in `mount/3` (not fixed; forced by the embed contract)

`load_dashboard/2` calls `Dashboards.get/1` from `mount/3`, which runs twice
(disconnected HTTP render + WebSocket connect). The Iron Law says move it to
`handle_params/3` — but this LiveView is mounted off-router via `live_render`,
where `handle_params/3` never fires, so there is no correct place to move it to.

The alternatives are both worse: gating on `connected?/1` throws away the
server-rendered first paint (a visible empty flash inside an otherwise-rendered
project page), and `assign_async/3` adds a loading state for a single indexed
primary-key lookup. **Deliberately left as-is** — recording it so the duplicate
query is a known, priced cost rather than an oversight.

---

## IMPROVEMENT - MEDIUM — a config change is invisible to a sticky embed (not fixed)

The linkage lives in `session["config"]["dashboard_uuid"]`, read once at mount.
`Dashboards.subscribe/1` keeps the *linked* dashboard fresh, but nothing carries a
change to *which* dashboard is linked. If the projects hub embeds this tab as a
**sticky** nested LiveView, `push_navigate` will not re-mount it and the pane
keeps showing the old dashboard until a full page load.

Not fixed here: the fix belongs on the hub side (re-render the tab non-sticky, or
broadcast an extension-config-changed message this LV could subscribe to), and
guessing at a contract the other package owns is how the two drift apart. Recorded
in the PR README's *Known Limitations* so it is on the record for the hub work.

---

## NITPICK — the `readonly` docstring overstates what is dropped

> Readonly (the project-tab viewer) drops the bar entirely — widgets render
> frameless, just their bodies.

The chrome bar and resize grip go, but the card keeps its `border`, `shadow-sm`,
`bg-base-100` and `m-[2px]`. "Frameless" is exactly the wrong word for a card that
still draws a frame. Left as-is (cosmetic, and the surrounding comments are
otherwise excellent), but noted since AGENTS.md-grade comments are load-bearing
documentation in this repo.

---

## Reviewed and found correct

- **`normalize_span/1`** — floors `w`/`h` while deliberately *not* coercing
  `x`/`y`, because their integer-ness is the placed-vs-order-only discriminator in
  `resolve_designed/2`'s `Enum.split_with`. Coercing them would silently promote
  every order-only widget to "placed at 0,0". The comment says so; the code does
  what the comment says.
- **The shared-only rule** — enforced at both the picker and the render path, and
  re-checked on every broadcast rather than trusted from mount. `state_for/1` is
  total over `%Dashboard{}`. The test asserting a personal dashboard's title never
  reaches the HTML is the right assertion.
- **Widget bodies are inert.** Checked every `Widgets.*` LiveComponent for
  `handle_event/3` — there are none, so "read-only" is not quietly undermined by
  an interactive widget body reachable via `phx-target`.
- **`{:dashboard_updated, _}` refreshes `mode` and `design_h`**, not just the
  struct — without those the pane would render the wrong board component after a
  remote grid↔pixel change. Correctly caught by the author in `916d5a9`.
- **`Code.ensure_loaded?` in `registry.ex`** — right fix, right reason.
- **`phx-hook={!@readonly && "..."}`** — HEEx drops a `false` attribute, so this
  correctly emits no hook rather than `phx-hook="false"`. The tests assert the
  absence.

---

## Gate

`mix precommit` — green (`compile --warnings-as-errors`, `deps.unlock
--check-unused`, `hex.audit`, `format --check-formatted`, `credo --strict`,
`dialyzer`: 0 errors). `mix test` — **98 tests, 0 failures** (156 `:integration`
excluded, no local PostgreSQL).

Two gate failures were pre-existing at HEAD and are fixed here:

- **`mix format --check-formatted` failed.** The `slugify/1` change was committed
  unformatted (the replacement comment and `case` were left at the wrong indent).
  `mix precommit` would have caught both this and the failing test.
- **`mix deps.unlock --check-unused` failed** with eight stale lock entries
  (`igniter`, `sourceror`, `rewrite`, `spitfire`, `ex_ast`, `glob_ex`, `owl`,
  `text_diff`) left behind by the post-merge `79638b0 "lib upgrades"` commit —
  not by this PR. Pruned so the gate can run.
