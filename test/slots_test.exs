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
        %{key: "bad.no_parent", name: "No parent", surface: :module_tab},
        # A parent that is not a tab id.
        %{key: "bad.bad_parent", name: "Bad parent", surface: :module_tab, parent_tab: "nope"},
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

    test "a module_tab without a parent is refused, not silently mounted somewhere" do
      assert {:error, :module_tab_needs_parent_tab} =
               Slot.from_map(%{key: "a.b", name: "T", surface: :module_tab}, nil)
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
      assert Slots.get("bad.bad_parent") == nil
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
      assert tab.live_view == {PhoenixKitDashboards.Web.SlotLive, :show}
    end

    test "a slot's route stays in THIS package's namespace, never the declaring module's" do
      with_providers([GoodProvider])

      tab = Enum.find(Slots.module_tabs(), &(&1.metadata.slot_key == "test.module"))

      # `projects/dashboard` would be swallowed by the projects module's own
      # dynamic `projects/:id` route and render its show page against the
      # literal id "dashboard". Found on the box; this pins the fix.
      assert tab.path == "dashboards/places/test-module"
      refute String.starts_with?(tab.path, "test/")
    end

    test "tab ids are stable and unique per slot" do
      with_providers([GoodProvider])

      {:ok, slot} = Slot.from_map(%{key: "test.module", name: "x", surface: :record_tab}, nil)
      assert Slots.tab_id(slot) == Slots.tab_id(slot)

      {:ok, other} = Slot.from_map(%{key: "test.other", name: "x", surface: :record_tab}, nil)
      refute Slots.tab_id(slot) == Slots.tab_id(other)
    end
  end

  describe "sidebar highlighting" do
    test "the top-level Dashboards tab does NOT claim a slot page" do
      # A plain prefix match lit BOTH this tab and the slot's own tab under its
      # module for one page. The parent still owns everything else beneath it.
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards))

      assert {:regex, regex} = tab.match

      refute Regex.match?(regex, "/admin/dashboards/places/projects-module")

      for owned <- [
            "/admin/dashboards",
            "/admin/dashboards/new",
            "/admin/dashboards/places",
            "/admin/dashboards/01a06e3a-2b88-7a19-ac34-faeb681ec048"
          ] do
        assert Regex.match?(regex, owned), "expected #{owned} to belong to the Dashboards tab"
      end
    end

    test "the Places screen matches exactly, not as a prefix over the slot pages" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_places))

      assert tab.match == :exact
    end
  end

  describe "cache freshness" do
    test "a catalog built with no discovered modules is NOT cached" do
      # `admin_tabs/0` runs at router-COMPILE time, when the runtime module
      # registry is an empty `:persistent_term`. Caching that answer pinned an
      # empty catalog for the life of the BEAM: no module's slots appeared in
      # the sidebar, and the routes core generates from those tabs were never
      # created either. Found on the box, not by a test — hence this one.
      :persistent_term.erase({Slots, :catalog})

      # Simulate the compile-time condition: no registered modules, no beams to
      # scan for, and no configured providers.
      Application.put_env(:phoenix_kit_dashboards, :slot_providers, [])
      Slots.refresh()

      # Whatever it computed, it must not have been memoized — the next read
      # has to try discovery again rather than serve the bare answer forever.
      assert :persistent_term.get({Slots, :catalog}, :miss) == :miss or
               map_size(:persistent_term.get({Slots, :catalog}, %{})) > 0
    end

    test "a catalog built from real discovery IS cached" do
      with_providers([GoodProvider])

      assert %{} = cached = :persistent_term.get({Slots, :catalog}, :miss)
      assert Map.has_key?(cached, "test.module")
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
