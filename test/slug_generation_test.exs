defmodule PhoenixKitDashboards.SlugGenerationTest do
  @moduledoc """
  Slug generation goes through core (and therefore `locale_slug`), not a local
  ASCII-only pipeline.

  The pipeline this replaced deleted every non-ASCII character, so a Cyrillic or
  Greek title produced an EMPTY slug — and an empty slug is worse than a wrong
  one, because callers read it as "no slug yet" and regenerate on every save.

  These are the assertions that would fail if the change were reverted.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Schemas.Dashboard

  test "a Cyrillic title gets a real slug instead of the 'dashboard' fallback" do
    assert Dashboard.slugify("Видеопродакшн") == "videoprodakshn"
    assert Dashboard.slugify("Καλημέρα") == "kalimera"
  end

  test "the fallback still covers genuinely content-less titles" do
    assert Dashboard.slugify("!!!") == "dashboard"
    assert Dashboard.slugify("") == "dashboard"
  end

  test "plain ASCII is unchanged" do
    assert Dashboard.slugify("My Dashboard") == "my-dashboard"
  end
end
