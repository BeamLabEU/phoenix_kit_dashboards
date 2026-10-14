# PR #8 — Read test DB name and pool size from the environment

- **Author:** timujinne
- **Merged as:** `d6f56a1`
- **Reviewer:** Claude (post-merge, reviewed 2026-10-14)
- **Files:** `config/test.exs`, `AGENTS.md`.

## Summary

`PGDATABASE` overrides the test database name and `PGPOOL` bounds the pool, so
the suite can run against a shared instance whose role cannot `CREATE DATABASE`.
Unset, both fall back to the previous behaviour (`MIX_TEST_PARTITION` suffix,
`schedulers_online * 2`).

## Findings

### IMPROVEMENT - MEDIUM — `mix test.reset` drops whatever `PGDATABASE` names

`test.reset` is `ecto.drop` + `test.setup`, and `ecto.drop` follows the repo
config. Before this PR the database name was fixed, so the alias could only
drop `phoenix_kit_dashboards_test`. After it, `PGDATABASE=<shared db> mix
test.reset` drops the *shared* database — the exact scenario the new AGENTS.md
caution describes ("a shared database other modules point at"). Realistic
trigger: someone who exported `PGDATABASE` for the suite runs the documented
reset alias.

**Fixed:** `test.reset` now starts with a guard step that `Mix.raise`s when
`PGDATABASE` is non-empty, naming the variable and telling the operator to
unset it or reset the shared database by hand. Verified by running
`PGDATABASE=some_shared_db MIX_ENV=test mix test.reset` (aborts before any
drop). AGENTS.md's alias list now says so. `test.setup` is left alone —
`ecto.create` on an existing database is a no-op.

### NITPICK — `MIX_TEST_PARTITION` is ignored when `PGDATABASE` is set

Intentional (one explicit database wins) and consistent with core's
`config/test.exs`; recorded only so partitioned runs against a shared DB are
not a surprise. No change.
