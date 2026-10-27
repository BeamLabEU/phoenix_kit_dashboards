defmodule PhoenixKitDashboards.Web.HelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Web.Helpers

  defp scope(uuid, roles),
    do: %PhoenixKit.Users.Auth.Scope{
      user: %{uuid: uuid},
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: MapSet.new(["dashboards"])
    }

  # The one manage rule, tested directly (the sub-key's registry-backed path
  # is covered in ManagePermissionTest).
  describe "manageable_by?/2" do
    test "own personal dashboard is manageable" do
      assert Helpers.manageable_by?(%{scope: "personal", owner_user_uuid: "u1"}, scope("u1", []))
    end

    test "someone else's personal dashboard is not, even for an Owner" do
      refute Helpers.manageable_by?(%{scope: "personal", owner_user_uuid: "u1"}, scope("u2", []))

      refute Helpers.manageable_by?(
               %{scope: "personal", owner_user_uuid: "u1"},
               scope("u2", ["Owner"])
             )

      refute Helpers.manageable_by?(%{scope: "personal", owner_user_uuid: "u1"}, nil)
    end

    test "shared and role dashboards are not manageable on the base key alone" do
      refute Helpers.manageable_by?(%{scope: "system", owner_user_uuid: nil}, scope("u1", []))
      refute Helpers.manageable_by?(%{scope: "role", owner_user_uuid: nil}, nil)

      assert Helpers.manageable_by?(
               %{scope: "system", owner_user_uuid: nil},
               scope("u1", ["Owner"])
             )
    end
  end

  describe "scope_label/1" do
    test "translates the known scopes and passes others through" do
      assert Helpers.scope_label("personal") == "personal"
      assert Helpers.scope_label("system") == "shared"
      assert Helpers.scope_label("role") == "role"
      assert Helpers.scope_label("weird") == "weird"
    end
  end

  describe "translate_catalog/1" do
    test "nil passes through; a string round-trips (no translation configured)" do
      assert Helpers.translate_catalog(nil) == nil
      assert Helpers.translate_catalog("Deliverability") == "Deliverability"
    end
  end
end
