# PR #11 — Follow-up

Resolution of the findings in `CLAUDE_REVIEW.md`, landed with the 0.6.0
release commit.

| Severity | Finding | Resolution |
|---|---|---|
| IMPROVEMENT - MEDIUM | README "Removing this module": `DROP` is undone (empty) by `mix phoenix_kit.repair` while core owns creation; clearing the marker is re-stamped by the next update; SQL unqualified | **Fixed** — section rewritten in `README.md` |
| IMPROVEMENT - MEDIUM | `migrated_version_runtime/1` foreign-comment / malformed-marker / absent-table / invalid-prefix paths untested against a DB | **Fixed** — four integration tests added to `migrations_runtime_test.exs` |
| NITPICK | "V135" cited for the adopted object names (all are core V133) | **Fixed** — `migrations.ex` `up_statements/2` doc, `AGENTS.md` |
| NITPICK | Test comment claiming the prefix is embedded into index names; stray map-shape comment on the version-0 test | **Fixed** — `migrations_test.exs` |
| — | `information_schema` vs `pg_class` privilege asymmetry in the reader | **Not changed** — fails loudly, matches core/boards pattern |
| — | `up/1` stamps without shape inference | **Not changed** — shape drift on a core-owned table is `repair`'s job |

Gate: `mix precommit` (compile --warnings-as-errors, format, credo --strict,
dialyzer) and the full `mix test` suite, database-backed tests included.
