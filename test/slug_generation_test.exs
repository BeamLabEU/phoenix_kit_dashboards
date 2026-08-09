defmodule PhoenixKitDashboards.SlugGenerationTest do
  @moduledoc """
  Slug generation goes through core's `PhoenixKit.Utils.Slug` (with
  transliteration ON), not a local ASCII-only pipeline.

  The pipeline this replaced deleted every non-ASCII character, so a Cyrillic
  title produced an EMPTY slug — and an empty slug is worse than a wrong one,
  because callers read it as "no slug yet" and regenerate on every save.

  These are the assertions that would fail if the change were reverted.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Slug
  alias PhoenixKitDashboards.Schemas.Dashboard

  test "a Cyrillic title gets a real slug instead of the 'dashboard' fallback" do
    assert Dashboard.slugify("Видеопродакшн") == "videoprodakshn"
    assert Dashboard.slugify("Проєкт Огляд") == "proiekt-oglyad"
  end

  test "Latin diacritics survive as their base letters" do
    assert Dashboard.slugify("Übung Café") == "ubung-cafe"
  end

  # The `transliterate: true` option is what makes the two tests above pass —
  # it defaults to FALSE, and the first cut of this change omitted it, so the
  # delegation to core was a no-op and every Cyrillic title still slugged to
  # "dashboard". Keep this assertion: it is the one that fails if the option
  # is dropped again.
  test "core's default (no transliteration) is NOT what we call" do
    assert Slug.slugify("Видеопродакшн") == ""
    assert Dashboard.slugify("Видеопродакшн") != "dashboard"
  end

  test "the fallback covers content-less titles and un-romanized scripts" do
    assert Dashboard.slugify("!!!") == "dashboard"
    assert Dashboard.slugify("") == "dashboard"
    # Core romanizes Cyrillic + Latin diacritics only; Greek/CJK reduce to the
    # fallback. Documented, not aspirational.
    assert Dashboard.slugify("Καλημέρα") == "dashboard"
  end

  test "plain ASCII is unchanged" do
    assert Dashboard.slugify("My Dashboard") == "my-dashboard"
  end
end
