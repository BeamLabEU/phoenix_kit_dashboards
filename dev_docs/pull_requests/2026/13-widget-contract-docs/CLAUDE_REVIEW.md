# PR #13 — Bring the widget contract docs up to date

- **Author:** mdon
- **Merged as:** `5bb0ee9`
- **Reviewer:** Claude (post-merge, reviewed 2026-10-14)
- **Files:** `widget.ex` (moduledoc + `settings_field` type), `widgets/note_widget.ex` (moduledoc), `AGENTS.md`.

## Summary

Documentation catch-up: the example widget uses current lattice sizes (16×8 /
8×4 instead of 6×2 / 3×1), the `context` assign is documented as part of the
render call, and `settings_schema` documents the optional `context:` kind.
`@type settings_field` gains `optional(:context) => String.t() | nil`. The
AGENTS.md test-harness paragraph is updated for the preflight and the module's
own migration chain.

## Findings

No bugs. Every claim checked against the code:

- Defaults `%{w: 16, h: 8}` / `%{w: 8, h: 4}` match `Widget.from_map/2`;
  the 160 cap matches `Lattice` (`@max_dim 160`); the default layout is
  64×36 (`Layouts`).
- `context={…}` is actually passed to the widget `live_component` in
  `BuilderComponents` (both render sites), defaulting to `%{}`.
- `Binds` exists and is what resolves a `context:`-declaring field.
- The new `:context` key is a doc/type addition only; `from_map/2` behaviour
  is unchanged, so no test change was needed.

### NITPICK — nothing to fix

The note_widget moduledoc line now runs past the file's usual wrap column;
`mix format` does not touch docstrings. Left as is.
