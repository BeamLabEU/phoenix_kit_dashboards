defmodule PhoenixKitDashboards.BindsTest do
  @moduledoc """
  Bind resolution — the mechanism that lets ONE dashboard serve every project.

  These are the cases that decide whether the feature is safe: an unresolvable
  bind must yield nothing (never someone else's record), and an instance saved
  before binds existed must keep behaving exactly as it did.
  """
  use ExUnit.Case, async: false

  alias PhoenixKitDashboards.Binds
  alias PhoenixKitDashboards.Registry

  defmodule ThingWidget do
    @moduledoc false
    use Phoenix.LiveComponent
    def render(assigns), do: ~H"<div></div>"
  end

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_widgets do
      [
        %{
          key: "test.thing",
          name: "Thing",
          component: PhoenixKitDashboards.BindsTest.ThingWidget,
          settings_schema: [
            %{key: "thing", type: :select, label: "Thing", context: "test.thing", options: []},
            %{key: "limit", type: :number, label: "Limit", default: "5"}
          ]
        }
      ]
    end
  end

  setup do
    previous = Application.get_env(:phoenix_kit_dashboards, :widget_providers, [])
    Application.put_env(:phoenix_kit_dashboards, :widget_providers, [Provider])
    Registry.refresh()

    on_exit(fn ->
      Application.put_env(:phoenix_kit_dashboards, :widget_providers, previous)
      Registry.refresh()
    end)

    :ok
  end

  defp item(binds, settings \\ %{}) do
    %{"id" => "w1", "widget_key" => "test.thing", "settings" => settings, "binds" => binds}
  end

  describe "resolve/3" do
    test "a slot bind writes the page's subject into the widget's own settings field" do
      {settings, unresolved} =
        Binds.resolve(item(%{"test.thing" => "slot"}), %{"test.thing" => "abc"}, nil)

      assert settings["thing"] == "abc"
      assert unresolved == []
    end

    test "a widget with no binds is passed through untouched" do
      original = %{"thing" => "kept", "limit" => "9"}
      {settings, unresolved} = Binds.resolve(item(%{}, original), %{"test.thing" => "abc"}, nil)

      assert settings == original
      assert unresolved == []
    end

    test "an instance saved before binds existed keeps its stored value — never reinterpreted" do
      legacy = %{"id" => "w1", "widget_key" => "test.thing", "settings" => %{"thing" => "old"}}
      {settings, unresolved} = Binds.resolve(legacy, %{"test.thing" => "current"}, nil)

      assert settings["thing"] == "old"
      assert unresolved == []
    end

    test "a pin always wins over the page it is on — that is the point of pinning" do
      {settings, _} =
        Binds.resolve(
          item(%{"test.thing" => %{"pin" => "fixed"}}),
          %{"test.thing" => "current"},
          nil
        )

      assert settings["thing"] == "fixed"
    end

    test "an unresolvable slot bind yields NOTHING, never a fallback record" do
      {settings, unresolved} = Binds.resolve(item(%{"test.thing" => "slot"}), %{}, nil)

      assert unresolved == ["test.thing"]
      # The field is explicitly blanked so a stale value cannot leak through.
      assert settings["thing"] == nil
    end

    test "a context supplied under a DIFFERENT kind does not satisfy the bind" do
      {_settings, unresolved} =
        Binds.resolve(item(%{"test.thing" => "slot"}), %{"other.kind" => "abc"}, nil)

      assert unresolved == ["test.thing"]
    end

    test "an empty-string context value counts as missing" do
      {_settings, unresolved} =
        Binds.resolve(item(%{"test.thing" => "slot"}), %{"test.thing" => ""}, nil)

      assert unresolved == ["test.thing"]
    end

    test "a viewer bind with no module to answer it resolves to nothing, not a guess" do
      {_settings, unresolved} = Binds.resolve(item(%{"test.thing" => "viewer"}), %{}, nil)

      assert unresolved == ["test.thing"]
    end

    test "other settings survive bind resolution" do
      {settings, _} =
        Binds.resolve(
          item(%{"test.thing" => "slot"}, %{"limit" => "9"}),
          %{"test.thing" => "abc"},
          nil
        )

      assert settings["limit"] == "9"
      assert settings["thing"] == "abc"
    end
  end

  describe "the leak cases a review panel found" do
    test "a bind whose kind matches NO settings field is unresolved, not silently ignored" do
      # The widget's field is "thing"; this bind names a kind nothing claims.
      # Previously the bind resolved, wrote nowhere, and reported no problem —
      # so the widget kept whatever id was already pinned in its settings and
      # rendered ANOTHER record on this page. That is the exact leak the whole
      # mechanism exists to prevent.
      item = %{
        "id" => "w1",
        "widget_key" => "test.thing",
        "settings" => %{"thing" => "old-record"},
        "binds" => %{"unclaimed.kind" => "slot"}
      }

      {settings, unresolved} = Binds.resolve(item, %{"unclaimed.kind" => "new"}, nil)

      assert unresolved == ["unclaimed.kind"]
      # The stale id is still in settings, but `unresolved` means the host
      # draws a placeholder instead of mounting the widget with it.
      assert settings["thing"] == "old-record"
    end

    test "an unresolvable bind BLANKS its field rather than leaving the old id" do
      item = item(%{"test.thing" => "slot"}, %{"thing" => "old-record"})
      {settings, unresolved} = Binds.resolve(item, %{}, nil)

      assert unresolved == ["test.thing"]
      assert settings["thing"] == nil
    end

    test "an empty pin is not a selection" do
      {_settings, unresolved} =
        Binds.resolve(item(%{"test.thing" => %{"pin" => ""}}), %{}, nil)

      assert unresolved == ["test.thing"]
    end

    test "a bare-string bind reads as a pin, matching how put_bind writes one" do
      # put_bind/3 normalizes a bare id to %{"pin" => id}; resolution has to
      # agree, or a stored bind would mean one thing written and another read.
      {settings, unresolved} = Binds.resolve(item(%{"test.thing" => "abc"}), %{}, nil)

      assert unresolved == []
      assert settings["thing"] == "abc"
    end

    test "a very long context kind does not blow the atom table or crash" do
      # The kind was previously looked up as an atom too, which raises
      # SystemLimitError past 255 bytes — and grew the atom table from values
      # that originate in layout JSON.
      long = String.duplicate("a", 300)

      assert {_settings, [^long]} = Binds.resolve(item(%{long => "slot"}), %{}, nil)
    end

    test "a bind on an unknown widget is unresolved rather than a crash" do
      # No widget means no settings field to write into, and the board must
      # still render — this runs inside the render path, so raising here would
      # take the whole dashboard down.
      {_settings, unresolved} =
        Binds.resolve(
          %{"id" => "w1", "widget_key" => "nope.unknown", "binds" => %{"a.b" => "slot"}},
          %{"a.b" => "v"},
          nil
        )

      assert unresolved == ["a.b"]
    end
  end

  describe "put_bind/3" do
    test "setting then clearing leaves no binds key at all" do
      bound = Binds.put_bind(%{"id" => "w1"}, "test.thing", "slot")
      assert Binds.binds(bound) == %{"test.thing" => "slot"}

      cleared = Binds.put_bind(bound, "test.thing", nil)
      refute Map.has_key?(cleared, "binds")
    end

    test "a bare id is normalized to a pin" do
      bound = Binds.put_bind(%{"id" => "w1"}, "test.thing", "some-uuid")
      assert Binds.binds(bound) == %{"test.thing" => %{"pin" => "some-uuid"}}
    end

    test "clearing one bind leaves the others" do
      item =
        %{"id" => "w1"}
        |> Binds.put_bind("a.b", "slot")
        |> Binds.put_bind("c.d", "viewer")
        |> Binds.put_bind("a.b", nil)

      assert Binds.binds(item) == %{"c.d" => "viewer"}
    end
  end

  describe "required_kinds/1 and unsatisfied/2" do
    test "only SLOT binds make a dashboard demand something of its page" do
      layout = [
        item(%{"test.thing" => "slot"}),
        item(%{"other.kind" => "viewer"}),
        item(%{"third.kind" => %{"pin" => "x"}})
      ]

      # A viewer bind resolves per person and a pin needs nothing, so neither
      # constrains where the dashboard may be placed.
      assert Binds.required_kinds(layout) == ["test.thing"]
    end

    test "unsatisfied reports what a slot cannot supply" do
      assert Binds.unsatisfied(item(%{"test.thing" => "slot"}), []) == ["test.thing"]
      assert Binds.unsatisfied(item(%{"test.thing" => "slot"}), ["test.thing"]) == []
      assert Binds.unsatisfied(item(%{"test.thing" => "viewer"}), []) == []
    end
  end
end
