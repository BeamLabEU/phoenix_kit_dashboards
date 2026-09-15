# PR #11 — Add a module-owned migration chain for phoenix_kit_dashboards

- **Author:** timujinne (`feature/module-owned-migrations-v1`)
- **Merged as:** `1048435`
- **Reviewer:** Claude (post-merge)
- **Files:** `lib/phoenix_kit_dashboards/migrations.ex` (new),
  `lib/phoenix_kit_dashboards.ex` (`migration_module/0`),
  `schemas/dashboard.ex` (`column_widths/0`), three new test files,
  `test/test_helper.exs`, README / AGENTS / CHANGELOG.

## Summary

Adds `PhoenixKitDashboards.Migrations`, a V1 that *adopts* the table core's
V133/V139 already create: idempotent DDL under core's object names, then a
namespaced `pkd_schema:1` table comment. `down/1` only unstamps the marker.

The code is sound. Verified against the producing code rather than the PR text:

- **Codegen contract.** Core's `mix phoenix_kit.update` writes
  `up(prefix:, version: target)` / `down(prefix:, version: current)`
  (`phoenix_kit.update.ex` `write_migration_file/7`), which matches this
  coordinator's opts handling. The runtime reader is wrapped by
  `PhoenixKit.Migrations.Modules.describe/2` (rescue + `catch :exit`), so a
  re-raised invalid prefix is reported as an unreadable module rather than
  crashing the task.
- **Object names.** All five adopted indexes/constraints appear in core's
  `ExpectedSchema` with `since: 133`; the test that derives the expected set
  from the manifest (not a hand list) keeps that honest.
- **Marker safety.** Core's repair/doctor only ever read or write the comment
  on `phoenix_kit`, never on this table, so `pkd_schema:1` is not clobbered.
- **Core floor.** `Helpers.validate_prefix!/1`, `ensure_extension!/1`,
  `ensure_uuid_v7_function/1`, `uuid_v7_call/1` and `qualify_table/2` all
  shipped in core 1.7.194 — well under the `~> 2.15` floor.
- **Data safety.** `down/1` emits only `COMMENT ON TABLE`; the integration
  test runs it through `Ecto.Migration.Runner` against a seeded row and has a
  mutation check proving the assertion has teeth.

## Findings

### IMPROVEMENT - MEDIUM — README "Removing this module" gives advice core undoes

The section told operators to `DROP TABLE phoenix_kit_dashboards;` and,
alternatively, to clear the marker "to stop this chain from tracking it".

1. In Phase 0 the table is `owner: :core, presence: :required` in core's
   `ExpectedSchema`. After the drop, `mix phoenix_kit.doctor` reports it
   missing and `mix phoenix_kit.repair` (which applies missing required
   objects) recreates it — empty. An operator following the guide sees the
   table "come back" with no explanation.
2. Clearing the marker does not stop tracking: while the module is installed,
   the next `mix phoenix_kit.update` reads 0 and generates a v00→v01
   migration that re-stamps it. Once the module is removed nothing reads the
   marker at all, so clearing it is pointless in both states.
3. The SQL was unqualified, which silently targets the wrong schema (or
   nothing) on a prefixed install.

**Fixed:** rewrote the section — prefix-qualified SQL, an explicit note that
repair recreates an empty table while core owns creation, and "leave the table
alone" as the keep-the-data path.

### IMPROVEMENT - MEDIUM — runtime reader's adoption cases were untested against a DB

The namespaced marker exists specifically because an adopted table may carry a
foreign comment, and `migrated_version_runtime/1` deliberately re-raises an
invalid prefix instead of returning 0. `migrations_runtime_test.exs` only
covered NULL and `pkd_schema:1`, so neither claim was pinned where it matters
(the SQL path).

**Fixed:** added integration tests for a foreign prose comment, malformed
markers (`pkd_schema:`, `pkd_schema:one`, `pkd_schema:1.5`, `pkd_schema:-1`,
and a bare `1` — the boards-style marker), a table absent from the prefix, and
the invalid-prefix re-raise.

### NITPICK — wrong core version cited for the adopted object names

`Migrations.up_statements/2`'s doc said "core's V135/V139 names" and AGENTS.md
"V133/V135/V139 shape". Every adopted index and constraint is `since: 133` in
`ExpectedSchema` (V135 is core 2.0's squash floor, unrelated to these objects).
**Fixed:** both now say V133 (V139 only for the `config` column).

### NITPICK — misleading test comments

- `migrations_test.exs` justified the prefix test with "This chain embeds the
  prefix into index NAMES … Postgres TRUNCATES an identifier past 63 bytes" —
  false: the index names are constant, and `migrations.ex` itself says the
  prefix is never embedded into an object name. **Fixed:** comment now states
  the real reason (the prefix is interpolated into every statement).
- A comment about `up/1`/`down/1` accepting a map and not losing `:version`
  sat above "applying up to version 0 is not an operation", which tests
  nothing of the sort (the map case lives in
  `migrations_data_safety_test.exs`). **Fixed:** removed the stray comment.

## Not changed (on record)

- **`table_exists?/2` uses `information_schema.tables`**, which is filtered by
  the connecting role's privileges, while `table_comment/2` uses `pg_class`.
  A role with no privilege on the table would read 0 and then fail at
  `COMMENT ON TABLE` (ownership required) inside the migration — a loud
  failure, not a wrong stamp, and the same query core and boards use. Not
  worth diverging from the ecosystem pattern.
- **`up/1` stamps without checking shape** beyond the `config` safety net.
  Unlike boards (which infers a version from columns), a table with some other
  drift would be stamped as adopted. Acceptable: shape drift on a core-owned
  table is `mix phoenix_kit.repair`'s job, and V1 changes no shape.
- **Heavy guard tests** (source-text regexes over `migrations.ex`) are brittle
  to refactors by design; they fail loudly, so left as authored.
