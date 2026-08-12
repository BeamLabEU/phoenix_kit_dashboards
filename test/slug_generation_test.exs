defmodule PhoenixKitDashboards.SlugGenerationTest do
  @moduledoc """
  Slug generation goes through core's `PhoenixKit.Utils.Slug` (with
  transliteration ON), not a local ASCII-only pipeline.

  The pipeline this replaced deleted every non-ASCII character, so a Cyrillic
  title produced an EMPTY slug — and an empty slug is worse than a wrong one,
  because callers read it as "no slug yet" and regenerate on every save.

  These are the assertions that would fail if the change were reverted.

  Core has since moved the rule into the `locale_slug` package and made
  romanization unconditional (`:transliterate` is accepted and ignored), which
  widened what romanizes — Greek now does — and changed one Cyrillic mapping
  (`є` → `ye`, not `ie`). The expectations below track core's current output.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Slug
  alias PhoenixKitDashboards.Schemas.Dashboard

  test "a Cyrillic title gets a real slug instead of the 'dashboard' fallback" do
    assert Dashboard.slugify("Видеопродакшн") == "videoprodakshn"
    assert Dashboard.slugify("Проєкт Огляд") == "proyekt-oglyad"
  end

  test "Latin diacritics survive as their base letters" do
    assert Dashboard.slugify("Übung Café") == "ubung-cafe"
  end

  test "Greek romanizes too" do
    assert Dashboard.slugify("Καλημέρα") == "kalimera"
  end

  # This used to assert `Slug.slugify("Видеопродакшн") == ""` — that core's
  # default was NOT to transliterate, which is what made passing
  # `transliterate: true` the load-bearing part of the delegation.
  #
  # Core removed that distinction: `PhoenixKit.Utils.Slug` moved its rule into
  # the `locale_slug` package and made romanization unconditional, documenting
  # `:transliterate` as accepted-and-ignored for source compatibility. So the
  # old assertion cannot hold, and no option choice here can bring the empty
  # slug back.
  #
  # What is still worth guarding is that this module *delegates* rather than
  # growing its own ASCII-only pipeline again — the regression that produced
  # empty slugs for Cyrillic titles, which callers read as "no slug yet" and
  # regenerated on every save.
  test "slugify delegates to core rather than reimplementing" do
    for title <- ["Видеопродакшн", "Проєкт Огляд", "Καλημέρα", "Übung Café"] do
      assert Dashboard.slugify(title) == Slug.slugify(title)
      refute Dashboard.slugify(title) == "dashboard"
    end
  end

  test "the fallback covers content-less titles and un-romanized scripts" do
    assert Dashboard.slugify("!!!") == "dashboard"
    assert Dashboard.slugify("") == "dashboard"

    # Core romanizes Cyrillic, Greek and Latin diacritics; CJK still has no
    # romanization and yields "" from core, which is what the fallback is for.
    # Documented, not aspirational — core's `fallback: :empty` is deliberate,
    # so that an unromanizable script never emits native script into a path
    # this codebase assumes is ASCII.
    assert Slug.slugify("日本語のダッシュボード") == ""
    assert Dashboard.slugify("日本語のダッシュボード") == "dashboard"
    assert Dashboard.slugify("中文") == "dashboard"
  end

  test "plain ASCII is unchanged" do
    assert Dashboard.slugify("My Dashboard") == "my-dashboard"
  end
end
