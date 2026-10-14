# PR #2 — Add PhoenixKit.SchemaPrefix for runtime named-schema (--prefix) support

- **Author:** mdon
- **Merged as:** `e0bfc83`
- **Reviewer:** Claude (post-merge, reviewed 2026-10-14)
- **Files:** `schemas/dashboard.ex`, `test/schema_prefix_conformance_test.exs` (new),
  `web/{builder,dashboards}_live.ex`, `web/helpers.ex`, `mix.exs`, `AGENTS.md`, two LiveView tests.

## Summary

Adds `use PhoenixKit.SchemaPrefix` to the only table-backed schema, plus a
conformance test that fails any `schema "phoenix_kit…"` file missing it. Also
drops the `gutter_fix_style/0` daisyUI workaround (core now ships the rule),
raises the core pin to `~> 1.7.189`, and (briefly) offered role-scoped
creation in the create modal.

## Findings

No bugs. Verified against the code as it stands now:

- **`SchemaPrefix` coverage.** `Dashboard` is the only `schema "phoenix_kit…"`
  in `lib/`, and it carries the `use`. The conformance test is a literal
  substring match, so it would miss a schema declared with a computed table
  name — acceptable for this package, which has one.
- **`gutter_fix_style/0` removal.** No references remain in `lib/` or `test/`.
- **Role-scope creation.** The modal offer this PR enabled (`offer_role_scope?/1`)
  no longer exists; the form page authors personal/system only and role scope is
  grandfathered on edit (see AGENTS.md "Scopes and sharing"). The test added
  here (`create role-scoped`) still passes because it submits the event
  directly, which is the intended "handler path must hold" coverage.

### NITPICK — nothing to fix

The pin `~> 1.7.189` is long gone (core 2.x floor now); superseded by #6 and #12.
