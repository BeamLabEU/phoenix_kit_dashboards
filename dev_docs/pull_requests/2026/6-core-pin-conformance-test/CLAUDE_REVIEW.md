# PR #6 — Add a conformance test for the :phoenix_kit requirement

- **Author:** mdon
- **Merged as:** `6f97aee`
- **Reviewer:** Claude (post-merge, reviewed 2026-10-14)
- **Files:** `test/core_pin_conformance_test.exs` (new).

## Summary

Guards the `:phoenix_kit` requirement against re-narrowing to one core minor
(`~> 2.0.x` expands to `< 2.1.0`) and against a committed `path:` dep. Reads the
resolved dep first and falls back to the committed literal in `mix.exs` so the
`PHOENIX_KIT_PATH` workflow still works.

## Findings

No bugs. The resolution order is correct: under `PHOENIX_KIT_PATH` the
resolved dep is a `path:` tuple with no requirement, the literal fallback is
used, and a *committed* path dep leaves no literal, so the test flunks as
intended. The test earns its keep — it was extended in #12 for the 2.38.0
floor with no restructuring.

One wording defect in the follow-up edit to this file is recorded in the #12
review and fixed there.
