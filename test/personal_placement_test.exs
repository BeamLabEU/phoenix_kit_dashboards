defmodule PhoenixKitDashboards.PersonalPlacementTest do
  @moduledoc """
  The per-person tier: copying a place's dashboard for yourself, and giving it
  back.

  The rules that matter here are about blast radius. Forking must not touch
  what anyone else sees, and resetting must not destroy the work someone did
  on their copy.
  """
  use PhoenixKitDashboards.DataCase, async: false

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Fixtures
  alias PhoenixKitDashboards.Placements

  @slot "core.admin_home"

  defp shared_dashboard(owner) do
    {:ok, dashboard} =
      Dashboards.create(%{
        title: "Company home",
        scope: "system",
        owner_user_uuid: owner.uuid
      })

    {:ok, _} =
      Placements.put(@slot, %{"audience" => "everyone", "dashboard_uuid" => dashboard.uuid})

    dashboard
  end

  setup do
    on_exit(fn ->
      PhoenixKit.Settings.update_setting_with_module(
        "dashboards_placements",
        "{}",
        "dashboards"
      )
    end)

    :ok
  end

  test "a personal placement wins over the shared one, for that person only" do
    owner = Fixtures.user_fixture()
    other = Fixtures.user_fixture()
    shared = shared_dashboard(owner)

    {:ok, mine} = Dashboards.clone(shared, owner.uuid)
    {:ok, _} = Placements.put_personal(mine, @slot)

    assert {:personal, [seen]} = Placements.resolve(@slot, scope_for(owner))
    assert seen.uuid == mine.uuid

    # Everybody else is untouched — forking is not a takeover.
    assert {:everyone, [theirs]} = Placements.resolve(@slot, scope_for(other))
    assert theirs.uuid == shared.uuid
  end

  test "a clone does NOT inherit the source's placement" do
    owner = Fixtures.user_fixture()
    shared = shared_dashboard(owner)

    {:ok, mine} = Dashboards.clone(shared, owner.uuid)
    {:ok, _} = Placements.put_personal(mine, @slot)

    # Copying a placed dashboard again must not produce a second personal
    # dashboard claiming the same place, with the winner decided by row order.
    {:ok, copy_of_mine} = Dashboards.clone(mine, owner.uuid)

    assert Placements.slot_of(copy_of_mine) == nil
    assert {:personal, [still]} = Placements.resolve(@slot, scope_for(owner))
    assert still.uuid == mine.uuid
  end

  test "resetting unplaces the copy but does not delete it" do
    owner = Fixtures.user_fixture()
    shared = shared_dashboard(owner)

    {:ok, mine} = Dashboards.clone(shared, owner.uuid)
    {:ok, placed} = Placements.put_personal(mine, @slot)
    {:ok, _} = Placements.put_personal(placed, nil)

    # Back to the shared board...
    assert {:everyone, [seen]} = Placements.resolve(@slot, scope_for(owner))
    assert seen.uuid == shared.uuid

    # ...and the work survives in the library.
    assert %{} = kept = Dashboards.get(mine.uuid)
    assert kept.uuid == mine.uuid
  end

  test "only a personal dashboard can hold a personal placement" do
    owner = Fixtures.user_fixture()
    shared = shared_dashboard(owner)

    assert {:error, :not_a_personal_dashboard} = Placements.put_personal(shared, @slot)
  end

  test "a personal placement in one place does not leak into another" do
    owner = Fixtures.user_fixture()
    shared = shared_dashboard(owner)

    {:ok, mine} = Dashboards.clone(shared, owner.uuid)
    {:ok, _} = Placements.put_personal(mine, @slot)

    assert {:none, []} = Placements.resolve("projects.module", scope_for(owner))
  end

  defp scope_for(user), do: Scope.for_user(user)
end
