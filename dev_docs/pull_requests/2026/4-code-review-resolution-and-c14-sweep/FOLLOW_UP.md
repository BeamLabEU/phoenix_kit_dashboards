# FOLLOW_UP — PR #4: Code-review resolution and C14 sweep

Triaged 2026-09-11 against current `main`. Reviewers: Claude
(`CLAUDE_REVIEW.md`) and Kimi (`KIMI_REVIEW.md`).

Kimi's findings are all recorded under its own "Findings — all fixed in this
round" heading and needed no follow-up.

## Still live (surfaced, not changed in this triage)

- **IMPROVEMENT-MEDIUM (test) — `test/js/geom.test.cjs`'s parity claim is
  weaker than it reads.** The file checks the JS geometry against the same
  cases the Elixir suite uses, which demonstrates agreement on those cases
  rather than parity of the two implementations. A generative check over random
  rectangles would be the real thing.
- **NITPICK — `Web.Helpers.viewable_by?/2` has no direct unit test.** Confirmed:
  no match for `viewable_by?` anywhere in `test/`. It is exercised indirectly
  through the manage page's LiveView tests, so a regression in the helper would
  surface, but not with a message that names it.

## Files touched

None in this triage.

## Verification

`mix precommit` clean; 362 tests, 0 failures (2026-09-11).

## Open

The two items above, both test-quality rather than correctness.
