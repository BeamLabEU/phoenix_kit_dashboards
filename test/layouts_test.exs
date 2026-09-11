defmodule PhoenixKitDashboards.LayoutsTest do
  @moduledoc """
  `keep_layout_id/2` — the rule that decides which named layout a *viewer*
  lands on. Every placed surface re-derives it on each live update, so the
  contract is "keep what they chose, unless it stopped existing".
  """
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Layouts
  alias PhoenixKitDashboards.Schemas.Dashboard

  defp dashboard(layouts) do
    %Dashboard{config: %{"type" => "grid", "layouts" => layouts}}
  end

  defp entry(id, name), do: %{"id" => id, "name" => name, "cols" => 64, "rows" => 36}

  describe "keep_layout_id/2" do
    test "keeps a layout the dashboard still has" do
      d = dashboard([entry("l1", "Wide"), entry("l2", "Tall")])
      assert Layouts.keep_layout_id(d, "l2") == "l2"
    end

    test "falls back to the first when the chosen layout was deleted" do
      d = dashboard([entry("l1", "Wide")])
      assert Layouts.keep_layout_id(d, "l2") == "l1"
    end

    test "falls back to the first with no preference" do
      d = dashboard([entry("l7", "Only"), entry("l8", "Other")])
      assert Layouts.keep_layout_id(d, nil) == "l7"
    end

    test "a dashboard that never persisted a list lands on the default" do
      assert Layouts.keep_layout_id(%Dashboard{config: %{}}, "l9") == "l1"
    end

    test "no dashboard at all resolves to no layout" do
      assert Layouts.keep_layout_id(nil, "l1") == nil
    end
  end
end
