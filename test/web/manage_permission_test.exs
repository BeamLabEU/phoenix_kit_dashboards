defmodule PhoenixKitDashboards.Web.ManagePermissionTest do
  @moduledoc """
  `dashboards.manage`: creating, editing and deleting shared (and role)
  dashboards, and choosing what a place shows, need the sub-key; the base
  `dashboards` key keeps a person's own private dashboards theirs to manage
  and lets them look at the shared ones. Every page checks at mount and every
  write event again; the one-time backfill carries existing roles across.
  """

  use PhoenixKitDashboards.LiveCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Role}
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Test.Repo, as: TestRepo
  alias PhoenixKitDashboards.Web.Helpers

  @flag "dashboards_manage_backfilled"

  setup do
    # Sub-permission checks resolve through core's module registry, which
    # asks the module whether it is enabled — as in production.
    # The suite may already have the module registered (discovery); leave
    # the registry as it was found so later tests see the same baseline.
    registered? = PhoenixKitDashboards in ModuleRegistry.all_modules()
    unless registered?, do: :ok = ModuleRegistry.register(PhoenixKitDashboards)
    PhoenixKitDashboards.enable_system()

    on_exit(fn ->
      unless registered?, do: ModuleRegistry.unregister(PhoenixKitDashboards)
      # enable_system/0 rebuilt the memoized widget catalog with the module
      # enabled; rebuild it for the suite's baseline.
      PhoenixKitDashboards.Registry.refresh()
    end)

    :ok
  end

  defp base_scope(user), do: fake_scope(user_uuid: user.uuid, roles: ["Employee"])

  defp manager_scope(user),
    do:
      fake_scope(
        user_uuid: user.uuid,
        roles: ["Employee"],
        permissions: ["dashboards", "dashboards.manage"]
      )

  defp shared_dashboard!,
    do: fixture_dashboard(nil, %{title: "Company board", scope: "system", owner_user_uuid: nil})

  # Swap the mounted page's scope — what core's live scope refresh does when
  # a role loses a grant while the page is open.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
    end)
  end

  describe "manageable_by?/2" do
    test "a personal dashboard is its owner's, whatever the keys" do
      user = user_fixture()
      own = %{scope: "personal", owner_user_uuid: user.uuid}

      assert Helpers.manageable_by?(own, base_scope(user))
      refute Helpers.manageable_by?(own, manager_scope(user_fixture()))
    end

    test "a shared or role dashboard needs dashboards.manage" do
      user = user_fixture()

      for scope <- ["system", "role"] do
        board = %{scope: scope, owner_user_uuid: nil}
        refute Helpers.manageable_by?(board, base_scope(user))
        refute Helpers.manageable_by?(board, nil)
        assert Helpers.manageable_by?(board, manager_scope(user))
        assert Helpers.manageable_by?(board, fake_scope(roles: ["Owner"], permissions: []))
      end
    end
  end

  describe "the Places page" do
    test "the tab carries dashboards.manage" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_places))
      assert tab.permission == "dashboards.manage"
    end

    test "the base key alone is refused at mount", %{conn: conn} do
      conn = put_test_scope(conn, base_scope(user_fixture()))

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/en/admin/dashboards/places")

      assert to =~ "/admin/dashboards"
      assert flash["error"] =~ "permission"
    end

    test "every write re-checks the key", %{conn: conn} do
      user = user_fixture()

      {:ok, view, _html} =
        live(put_test_scope(conn, manager_scope(user)), "/en/admin/dashboards/places")

      board = shared_dashboard!()
      swap_scope(view, base_scope(user))

      for {event, params} <- [
            {"place", %{"slot" => "core.admin_home", "dashboard_uuid" => board.uuid}},
            {"unplace", %{"slot" => "core.admin_home", "dashboard_uuid" => board.uuid}},
            {"set_priority", %{"slot" => "core.admin_home", "priority" => "1"}}
          ] do
        assert render_click(view, event, params) =~ "permission to change places"
      end
    end
  end

  describe "shared dashboards with the base key alone" do
    test "the list offers no edit or delete, and a crafted delete changes nothing",
         %{conn: conn} do
      board = shared_dashboard!()

      {:ok, view, html} =
        live(put_test_scope(conn, base_scope(user_fixture())), "/en/admin/dashboards")

      assert html =~ "Company board"
      refute html =~ "/#{board.uuid}/edit"

      render_click(view, "delete", %{"uuid" => board.uuid})
      assert Dashboards.get(board.uuid)
    end

    test "the settings page refuses a shared dashboard", %{conn: conn} do
      board = shared_dashboard!()

      assert {:error, {:live_redirect, _}} =
               live(
                 put_test_scope(conn, base_scope(user_fixture())),
                 "/en/admin/dashboards/#{board.uuid}/edit"
               )
    end

    test "the new form offers Personal only, and a crafted shared save is refused",
         %{conn: conn} do
      {:ok, view, html} =
        live(put_test_scope(conn, base_scope(user_fixture())), "/en/admin/dashboards/new")

      refute html =~ ~s(value="system")

      html = render_submit(view, "save", %{"title" => "Sneaky", "scope" => "system"})
      assert html =~ "permission to share dashboards"
      refute Enum.any?(Dashboards.list_system(), &(&1.title == "Sneaky"))
    end

    test "the builder shows it without edit chrome and refuses a crafted change",
         %{conn: conn} do
      board = shared_dashboard!()

      {:ok, view, html} =
        live(
          put_test_scope(conn, base_scope(user_fixture())),
          "/en/admin/dashboards/#{board.uuid}"
        )

      assert html =~ "Company board"
      refute has_element?(view, "#dashboard-catalog-toggle")
      refute has_element?(view, "#dashboard-catalog")

      assert render_click(view, "add_widget", %{"key" => "core.note"}) =~
               "permission to change this dashboard"

      assert Dashboards.get(board.uuid).layout == []
    end
  end

  describe "a person's own dashboards stay theirs" do
    test "the base key edits and deletes an own private dashboard", %{conn: conn} do
      user = user_fixture()
      own = fixture_dashboard(user.uuid)
      conn = put_test_scope(conn, base_scope(user))

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{own.uuid}")
      render_click(view, "add_widget", %{"key" => "core.note"})
      assert length(Dashboards.get(own.uuid).layout) == 1

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      render_click(view, "delete", %{"uuid" => own.uuid})
      assert Dashboards.get(own.uuid) == nil
    end
  end

  describe "a holder of dashboards.manage" do
    test "creates, changes and deletes shared dashboards and opens Places", %{conn: conn} do
      conn = put_test_scope(conn, manager_scope(user_fixture()))

      {:ok, view, html} = live(conn, "/en/admin/dashboards/new")
      assert html =~ ~s(value="system")

      assert {:error, {:live_redirect, _}} =
               render_submit(view, "save", %{"title" => "Team board", "scope" => "system"})

      board = Enum.find(Dashboards.list_system(), &(&1.title == "Team board"))
      assert board

      {:ok, view, _html} = live(conn, "/en/admin/dashboards/#{board.uuid}")
      assert has_element?(view, "#dashboard-catalog-toggle")
      render_click(view, "add_widget", %{"key" => "core.note"})
      assert length(Dashboards.get(board.uuid).layout) == 1

      {:ok, view, _html} = live(conn, "/en/admin/dashboards")
      render_click(view, "delete", %{"uuid" => board.uuid})
      assert Dashboards.get(board.uuid) == nil

      assert {:ok, _view, _html} = live(conn, "/en/admin/dashboards/places")
    end
  end

  describe "migrate_legacy/0 — the dashboards.manage backfill" do
    defp role!(name) do
      TestRepo.insert!(%Role{
        name: "#{name} #{System.unique_integer([:positive])}",
        is_system_role: false
      })
    end

    test "a role holding dashboards gets the key once; later roles do not" do
      Settings.delete_setting(@flag)
      holder = role!("Editors")
      outsider = role!("Outsiders")
      {:ok, _} = Permissions.grant_permission(holder.uuid, "dashboards", nil)

      assert :ok = PhoenixKitDashboards.migrate_legacy()

      assert "dashboards.manage" in Permissions.get_permissions_for_role(holder.uuid)
      assert Permissions.get_permissions_for_role(outsider.uuid) == []
      assert Settings.get_setting(@flag) == "true"

      late = role!("Late")
      {:ok, _} = Permissions.grant_permission(late.uuid, "dashboards", nil)
      assert :ok = PhoenixKitDashboards.migrate_legacy()
      assert Permissions.get_permissions_for_role(late.uuid) == ["dashboards"]

      :ok = Permissions.revoke_permission(holder.uuid, "dashboards.manage")
      PhoenixKitDashboards.migrate_legacy()
      refute "dashboards.manage" in Permissions.get_permissions_for_role(holder.uuid)
    end

    test "a failed permission lookup leaves the flag unset and grants nothing" do
      Settings.delete_setting(@flag)
      holder = role!("Editors")
      {:ok, _} = Permissions.grant_permission(holder.uuid, "dashboards", nil)

      broken_lookup = fn -> raise DBConnection.ConnectionError, "lookup failed" end

      assert_raise DBConnection.ConnectionError, fn ->
        PhoenixKitDashboards.backfill_manage_permission(role_grants: broken_lookup)
      end

      assert Settings.get_setting(@flag) != "true"
      refute "dashboards.manage" in Permissions.get_permissions_for_role(holder.uuid)
    end

    test "a failed grant leaves the flag unset, so the next boot retries" do
      Settings.delete_setting(@flag)
      holder = role!("Editors")
      {:ok, _} = Permissions.grant_permission(holder.uuid, "dashboards", nil)

      failing = fn _role, _key, _by -> {:error, :boom} end

      assert {:error, {:manage_backfill_incomplete, failures}} =
               PhoenixKitDashboards.backfill_manage_permission(grant: failing)

      assert {holder.uuid, {:error, :boom}} in failures
      assert Settings.get_setting(@flag) != "true"
      refute "dashboards.manage" in Permissions.get_permissions_for_role(holder.uuid)

      assert :ok = PhoenixKitDashboards.migrate_legacy()
      assert Settings.get_setting(@flag) == "true"
      assert "dashboards.manage" in Permissions.get_permissions_for_role(holder.uuid)
    end
  end
end
