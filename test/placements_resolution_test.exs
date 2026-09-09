defmodule PhoenixKitDashboards.PlacementsResolutionTest do
  @moduledoc """
  Tier resolution, and specifically the cases a review panel found: a tier that
  HAS a placement must answer even when the dashboards it names are gone.

  Collapsing "this tier declares nothing" with "this tier's dashboards were
  deleted" silently promoted the company-wide board to a role whose own board
  had just been removed — a visibility change nobody asked for, happening
  quietly. These pin the distinction.
  """
  use PhoenixKitDashboards.DataCase, async: false

  alias PhoenixKitDashboards.Placements

  defp put_blob(blob) do
    PhoenixKit.Settings.update_setting_with_module(
      "dashboards_placements",
      Jason.encode!(blob),
      "dashboards"
    )
  end

  setup do
    on_exit(fn -> put_blob(%{}) end)
    put_blob(%{})
    :ok
  end

  describe "a tier that names a DELETED dashboard still answers" do
    test "everyone tier reports itself, not :none" do
      put_blob(%{
        "core.admin_home" => [
          %{"audience" => "everyone", "dashboard_uuid" => Ecto.UUID.generate()}
        ]
      })

      # The placement exists; only its dashboard is gone. The caller must show
      # the slot's empty state and `health/1` must be able to explain why —
      # reporting `:none` hides a broken configuration as "nothing configured".
      assert {:everyone, []} = Placements.resolve("core.admin_home", nil)
    end

    test "a broken everyone placement is reported by health/1" do
      put_blob(%{
        "core.admin_home" => [
          %{"audience" => "everyone", "dashboard_uuid" => Ecto.UUID.generate()}
        ]
      })

      assert [%{problem: :dashboard_gone, slot_key: "core.admin_home"}] = Placements.health()
    end
  end

  describe "no placement at all" do
    test "falls through to :none" do
      assert {:none, []} = Placements.resolve("core.admin_home", nil)
    end

    test "an unknown slot is :none, never a crash" do
      assert {:none, []} = Placements.resolve("nope.not_a_slot", nil)
    end
  end

  describe "corrupt storage" do
    test "a non-JSON blob degrades to no placements rather than crashing" do
      PhoenixKit.Settings.update_setting_with_module(
        "dashboards_placements",
        "{not json at all",
        "dashboards"
      )

      assert Placements.all() == %{}
      assert {:none, []} = Placements.resolve("core.admin_home", nil)
    end

    test "a JSON scalar where an object belongs degrades too" do
      PhoenixKit.Settings.update_setting_with_module(
        "dashboards_placements",
        "42",
        "dashboards"
      )

      assert Placements.all() == %{}
    end
  end

  describe "put/3 refusals" do
    test "an unknown dashboard is refused" do
      assert {:error, :unknown_dashboard} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => Ecto.UUID.generate()
               })
    end

    test "an unknown slot is refused" do
      assert {:error, :unknown_slot} =
               Placements.put("nope.not_a_slot", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => Ecto.UUID.generate()
               })
    end

    test "a role placement without a role is refused" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Shared",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      assert {:error, :role_required} =
               Placements.put("core.admin_home", %{
                 "audience" => "role",
                 "dashboard_uuid" => dashboard.uuid
               })
    end

    test "a PERSONAL dashboard can never fill a shared place" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, personal} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Mine",
          scope: "personal",
          owner_user_uuid: user.uuid
        })

      # Binding it would publish one person's private canvas to the company.
      assert {:error, :personal_not_shareable} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => personal.uuid
               })
    end

    test "a second everyone placement in a :one slot is refused" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, a} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "A",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, b} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "B",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      # core.admin_home is :many, so use a :one slot for this rule.
      slot = Enum.find(PhoenixKitDashboards.Slots.list(), &(&1.cardinality == :one))

      if slot do
        assert {:ok, _} =
                 Placements.put(slot.key, %{
                   "audience" => "everyone",
                   "dashboard_uuid" => a.uuid
                 })

        assert {:error, :audience_already_placed} =
                 Placements.put(slot.key, %{
                   "audience" => "everyone",
                   "dashboard_uuid" => b.uuid
                 })
      end
    end

    test "a :many slot accepts several, and resolve returns them in order" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, a} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Site health",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, b} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "User activity",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, _} =
        Placements.put("core.admin_home", %{"audience" => "everyone", "dashboard_uuid" => a.uuid})

      {:ok, _} =
        Placements.put("core.admin_home", %{"audience" => "everyone", "dashboard_uuid" => b.uuid})

      assert {:everyone, [first, second]} = Placements.resolve("core.admin_home", nil)
      assert first.uuid == a.uuid
      assert second.uuid == b.uuid
    end

    test "limit_one caps a :many slot for callers that render one board" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      for title <- ["One", "Two"] do
        {:ok, d} =
          PhoenixKitDashboards.Dashboards.create(%{
            title: title,
            scope: "system",
            owner_user_uuid: user.uuid
          })

        Placements.put("core.admin_home", %{
          "audience" => "everyone",
          "dashboard_uuid" => d.uuid
        })
      end

      assert {:everyone, [_only_one]} =
               Placements.resolve("core.admin_home", nil, limit_one: true)
    end
  end
end
