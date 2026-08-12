# Claude Review — PR #7 (per-module Gettext i18n) and PR #8 (test DB from env)

Reviewed 2026-08-12 as part of the ecosystem PR sweep. Both merged into `main`.

**Verdict: both APPROVED**, with one gate failure introduced by #7 that had to
be fixed before release, plus three pre-existing test failures repaired.

## PR #8 — Read test DB name and pool size from the environment

`config/test.exs` plus an `AGENTS.md` note. Identical mechanism to core
`phoenix_kit`'s `config/test.exs` and the sibling changes in `phoenix_kit_ai`
#18 and `phoenix_kit_catalogue` #58 — including the part that matters, reading
through a `case` on `System.get_env/1` rather than `System.get_env/2`, so a
set-but-empty `PGPOOL=` falls back instead of crashing config loading with an
`ArgumentError` that never names the variable. Defaults preserved. Nothing to
fix.

## PR #7 — Per-module Gettext i18n (en/et/ru)

**The backend switch is complete.** Audited every file in `lib/` containing a
`gettext`/`ngettext`/`gettext_noop` call — 10 files, all 10 carrying `use
Gettext, backend: PhoenixKitDashboards.Gettext`. None left on core's backend,
including the two LiveComponents and `Web.ProjectDashboardLive`, which uses
plain `Phoenix.LiveView` rather than `use PhoenixKitWeb` and so had an explicit
core-backend `use` line to replace.

**The catalogues are mechanically sound.** Parsed all three `.po` files:

| Check | en | et | ru |
|---|---|---|---|
| Entries | 125 | 125 | 125 |
| `fuzzy`-flagged | 0 | 0 | 0 |
| Empty `msgstr` | 0 | 0 | 0 |
| `%{...}` placeholder mismatch | 0 | 0 | 0 |

Plural handling is right: one plural msgid per locale, with a full `msgstr[2]`
in ru and none in en/et.

**`translate_catalog/1`'s rerouting is the subtle part, and it's correct.** It
now looks widget catalog data up in this module's backend instead of core's.
That would silently regress every built-in widget's name and description to raw
English if those strings weren't in the new catalogues — but
`Widgets.__catalog_strings__/0` already pins them with `gettext_noop/1`, and
widgets.ex now uses this backend, so the anchor lands in the right `.pot`.
Spot-checked the resulting translations rather than trusting the mechanism:
`Note` → `Заметка`, `Clock` → `Часы`, `Digital` → `Цифровой`, `Analog` →
`Аналоговый`, `Timezone` → `Часовой пояс`. All present.

The `translatable_labels/0` anchor is right for the same reason it was in
`phoenix_kit_ai` #17: `admin_tabs/0` declares labels as plain struct literals
that `mix gettext.extract` cannot see, and `mix gettext.merge` deletes any
`.po` entry absent from a freshly built `.pot`. The PR's own note is accurate —
`"Dashboards"` would survive today only by coincidence, because a literal
`gettext("Dashboards")` happens to exist in `DashboardsLive`'s page title,
while the other three labels have no such accident to protect them.

No red flags against the Phoenix skill's checklist: no queries added to
`mount/3`, no PubSub topics touched, no `terminate/2` or `start_async` usage.

## Fixed on `main`: PR #7 left the gate red

`mix precommit` failed at dialyzer after the merge. Gettext 1.0 + Expo 1.1
generate a `Gettext.Plural.plural/2` call against Expo's **opaque**
`PluralForms` struct inside the code `use Gettext.Backend` writes, which
Dialyzer reports as `call_without_opaque` at `gettext.ex:1` — three warnings,
one per locale's plural form.

This is a known upstream false positive in code nobody here authors, and every
sibling package that owns a Gettext backend already carries the same skip
(`phoenix_kit_ai`, `phoenix_kit_crm`, `phoenix_kit_manufacturing`,
`phoenix_kit_warehouse`). PR #7 added the backend without it.

Fixed by adding `.dialyzer_ignore.exs` scoped to that one file and that one
warning type — so real opacity violations elsewhere still surface — and wiring
`ignore_warnings: ".dialyzer_ignore.exs"` into `mix.exs`'s dialyzer config, the
same shape `phoenix_kit_ai` uses. Dialyzer now reports `Total errors: 3,
Skipped: 3, Unnecessary Skips: 0`.

## Fixed on `main`: three slug tests encoded a core contract that no longer exists

Pre-existing, unrelated to either PR, and not caused by this sweep's dependency
update — `mix.lock` moved only `phoenix`, `hackney`, `h2`, `webtransport` and
`beamlab_ex_aws_sqs`; neither `phoenix_kit` (2.2.0) nor `locale_slug` (0.2.0)
changed, and neither PR touched `test/slug_generation_test.exs`.

The cause is core. `PhoenixKit.Utils.Slug` moved its rule into the
`locale_slug` package and **made romanization unconditional**, documenting
`:transliterate` as accepted-and-ignored for source compatibility. Three
assertions written against the old behavior broke:

| Assertion | Was | Now |
|---|---|---|
| `Slug.slugify("Видеопродакшн")` | `""` | `"videoprodakshn"` |
| `Dashboard.slugify("Проєкт Огляд")` | `"proiekt-oglyad"` | `"proyekt-oglyad"` |
| `Dashboard.slugify("Καλημέρα")` | `"dashboard"` | `"kalimera"` |

The middle one is a mapping change (`є` → `ye`, not `ie`); the other two are
scope changes — core's default now romanizes, and Greek is covered where it
previously fell through.

Repaired rather than deleted, because one of the three was load-bearing. Its
original purpose was to prove that passing `transliterate: true` was what made
the delegation work — if the option were dropped, Cyrillic would slug to `""`
and callers reading empty as "no slug yet" would regenerate on every save. That
premise is gone: no option choice can bring the empty slug back. So the
assertion now guards what is still true and still worth protecting — that this
module *delegates* to core rather than regrowing its own ASCII-only pipeline —
by asserting `Dashboard.slugify(title) == Slug.slugify(title)` across the
romanizable scripts, and that none of them hits the `"dashboard"` fallback.

The fallback test moved to CJK (`日本語のダッシュボード`, `中文`), verified to
still yield `""` from core — core sets `fallback: :empty` deliberately, so an
unromanizable script never emits native script into a path this codebase
assumes is ASCII. Greek moved into its own romanization test. Every replacement
expectation was taken from the actual output of the installed core, not
guessed.

**Why this went unnoticed:** `mix precommit` in this repo is `compile
--warnings-as-errors` + `deps.unlock --check-unused` + `quality.ci` — it runs
no tests, and these three are not database-gated, so they fail on any machine.
Worth running `mix test` in this repo's release path, not only `precommit`.
