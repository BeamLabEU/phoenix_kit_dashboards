defmodule PhoenixKitDashboards.SlotsTest do
  @moduledoc """
  The slot contract and its catalog. No database — a slot is a declaration.
  """
  use ExUnit.Case, async: false

  alias PhoenixKitDashboards.Slot
  alias PhoenixKitDashboards.Slots

  defmodule GoodProvider do
    @moduledoc false
    def phoenix_kit_dashboard_slots do
      [
        %{
          key: "test.module",
          name: "Test module place",
          surface: :module_tab,
          parent_tab: :admin_test,
          path: "test/dashboard",
          provides: [],
          cardinality: :many
        },
        %{
          key: "test.record",
          name: "Test record place",
          surface: :record_tab,
          provides: ["test.thing"]
        }
      ]
    end
  end

  defmodule BadProvider do
    @moduledoc false
    def phoenix_kit_dashboard_slots do
      [
        # No key at all.
        %{name: "Nameless"},
        # A module_tab with nowhere to hang.
        %{key: "bad.no_parent", name: "No parent", surface: :module_tab, path: "x"},
        # A module_tab with no path.
        %{key: "bad.no_path", name: "No path", surface: :module_tab, parent_tab: :admin_x},
        # Junk that is not a map at all.
        "not a map",
        # One VALID entry, which must survive its malformed siblings.
        %{key: "bad.ok", name: "Fine", surface: :record_tab}
      ]
    end
  end

  setup do
    previous = Application.get_env(:phoenix_kit_dashboards, :slot_providers, [])

    on_exit(fn ->
      Application.put_env(:phoenix_kit_dashboards, :slot_providers, previous)
      Slots.refresh()
    end)

    :ok
  end

  defp with_providers(modules) do
    Application.put_env(:phoenix_kit_dashboards, :slot_providers, modules)
    Slots.refresh()
  end

  describe "from_map/2" do
    test "accepts string keys as readily as atom keys — the contract says plain maps" do
      assert {:ok, %Slot{key: "a.b", name: "Thing", surface: :record_tab}} =
               Slot.from_map(%{"key" => "a.b", "name" => "Thing", "surface" => "record_tab"}, nil)
    end

    test "defaults are the safe ones" do
      {:ok, slot} = Slot.from_map(%{key: "a.b", name: "T", surface: :record_tab}, nil)

      assert slot.cardinality == :one
      assert slot.provides == []
      assert slot.chrome == :view
      assert slot.allow_blank == false
      assert slot.allow_personal == true
    end

    test "a module_tab without a parent or a path is refused, not silently mounted somewhere" do
      assert {:error, :module_tab_needs_parent_tab} =
               Slot.from_map(%{key: "a.b", name: "T", surface: :module_tab, path: "p"}, nil)

      assert {:error, :module_tab_needs_path} =
               Slot.from_map(%{key: "a.b", name: "T", surface: :module_tab, parent_tab: :x}, nil)
    end

    test "provides normalizes a bare kind and drops junk entries" do
      {:ok, one} =
        Slot.from_map(%{key: "a.b", name: "T", provides: "x.y", surface: :record_tab}, nil)

      assert one.provides == ["x.y"]

      {:ok, mixed} =
        Slot.from_map(
          %{key: "a.c", name: "T", provides: ["x.y", 42, %{}], surface: :record_tab},
          nil
        )

      assert mixed.provides == ["x.y"]
    end

    test "a non-map provider entry is an error rather than a crash" do
      assert {:error, :not_a_map} = Slot.from_map("nope", nil)
    end
  end

  describe "catalog discovery" do
    test "collects slots from a configured provider" do
      with_providers([GoodProvider])

      assert %Slot{name: "Test module place"} = Slots.get("test.module")
      assert %Slot{provides: ["test.thing"]} = Slots.get("test.record")
    end

    test "one malformed entry never takes the catalog down with it" do
      with_providers([BadProvider])

      assert %Slot{name: "Fine"} = Slots.get("bad.ok")
      assert Slots.get("bad.no_parent") == nil
      assert Slots.get("bad.no_path") == nil
    end

    test "this module's own admin-home slot is always present" do
      with_providers([])

      assert %Slot{surface: :admin_home, cardinality: :many} = Slots.get("core.admin_home")
    end

    test "module_tabs/0 generates a tab per module_tab slot, and only those" do
      with_providers([GoodProvider])

      tabs = Slots.module_tabs()
      keys = Enum.map(tabs, & &1.metadata.slot_key)

      assert "test.module" in keys
      # A record_tab is rendered by its owning module, and admin_home is core's
      # page — neither generates a sidebar tab here.
      refute "test.record" in keys
      refute "core.admin_home" in keys
    end

    test "a generated tab hangs off the DECLARED parent and carries that module's permission" do
      with_providers([GoodProvider])

      tab = Enum.find(Slots.module_tabs(), &(&1.metadata.slot_key == "test.module"))

      assert tab.parent == :admin_test
      assert tab.path == "test/dashboard"
      assert tab.live_view == {PhoenixKitDashboards.Web.SlotLive, :show}
    end

    test "tab ids are stable and unique per slot" do
      with_providers([GoodProvider])

      {:ok, slot} = Slot.from_map(%{key: "test.module", name: "x", surface: :record_tab}, nil)
      assert Slots.tab_id(slot) == Slots.tab_id(slot)

      {:ok, other} = Slot.from_map(%{key: "test.other", name: "x", surface: :record_tab}, nil)
      refute Slots.tab_id(slot) == Slots.tab_id(other)
    end
  end

  describe "provides?/2" do
    test "answers only for kinds actually declared" do
      {:ok, slot} =
        Slot.from_map(%{key: "a.b", name: "T", surface: :record_tab, provides: ["x.y"]}, nil)

      assert Slot.provides?(slot, "x.y")
      refute Slot.provides?(slot, "x.z")
      refute Slot.provides?(slot, nil)
    end
  end
end
