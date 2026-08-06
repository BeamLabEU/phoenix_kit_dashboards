defmodule PhoenixKitDashboards.Web.ProjectDashboardLiveTest do
  @moduledoc """
  The read-only project-tab viewer: state machine (unconfigured / missing /
  not-shared / ok), the shared-only render rule, the absence of edit
  affordances, live downgrade on re-scope, and the provider descriptor +
  options contract the `phoenix_kit_projects` hub consumes.
  """
  use PhoenixKitDashboards.LiveCase, async: false

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Web.ProjectDashboardLive

  setup do
    # The globally-named PubSub the live-sync broadcasts resolve to (the
    # BuilderLiveSyncTest arrangement).
    start_supervised!({Phoenix.PubSub, name: PhoenixKit.PubSub})
    :ok
  end

  defp mount_tab(conn, config, opts \\ []) do
    user = Keyword.get(opts, :user)

    live_isolated(conn, ProjectDashboardLive,
      session: %{
        "project_uuid" => Ecto.UUID.generate(),
        "ext_key" => "dashboards_board",
        "instance_key" => "default",
        "config" => config,
        "can_write" => false,
        "locale" => "en",
        "current_user_uuid" => user && user.uuid
      }
    )
  end

  describe "state machine" do
    test "no linked dashboard → configure hint", %{conn: conn} do
      {:ok, _view, html} = mount_tab(conn, %{})
      assert html =~ "No dashboard linked yet"
    end

    test "nil config (extension enabled, never saved) → configure hint", %{conn: conn} do
      {:ok, _view, html} = mount_tab(conn, nil)
      assert html =~ "No dashboard linked yet"
    end

    test "bogus uuid → missing", %{conn: conn} do
      {:ok, _view, html} = mount_tab(conn, %{"dashboard_uuid" => Ecto.UUID.generate()})
      assert html =~ "no longer exists"
    end

    test "a PERSONAL dashboard never renders here", %{conn: conn} do
      owner = user_fixture()

      {:ok, personal} =
        Dashboards.create(%{title: "My Private", scope: "personal", owner_user_uuid: owner.uuid})

      {:ok, _view, html} = mount_tab(conn, %{"dashboard_uuid" => personal.uuid}, user: owner)

      refute html =~ "My Private"
      assert html =~ "not shared"
    end
  end

  describe "shared dashboard rendering" do
    setup do
      {:ok, dashboard} = Dashboards.create(%{title: "Ops Board", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      {:ok, dashboard: dashboard, viewer: user_fixture()}
    end

    test "renders the fitted board with NO edit affordances",
         %{conn: conn, dashboard: dashboard, viewer: viewer} do
      {:ok, _view, html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid}, user: viewer)

      assert html =~ "Ops Board"
      # The board surface is there (fit hook, prefixed id)…
      assert html =~ "pk-projtab-dashboard-grid-fit"
      # …but none of the builder chrome is.
      refute html =~ "DashboardGridDrag"
      refute html =~ "DashboardResize"
      refute html =~ "pk-resize-handle"
      refute html =~ "remove_widget"
      refute html =~ "open_settings"
    end

    test "anonymous embed (no current_user_uuid) still renders a shared board",
         %{conn: conn, dashboard: dashboard} do
      {:ok, _view, html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid})
      assert html =~ "Ops Board"
    end

    test "live downgrade: re-scoping the linked dashboard away swaps in the notice",
         %{conn: conn, dashboard: dashboard, viewer: viewer} do
      {:ok, view, _html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid}, user: viewer)

      {:ok, _} =
        Dashboards.update(dashboard, %{scope: "personal", owner_user_uuid: viewer.uuid})

      assert render(view) =~ "not shared"
    end

    test "live deletion swaps in the missing notice",
         %{conn: conn, dashboard: dashboard, viewer: viewer} do
      {:ok, view, _html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid}, user: viewer)

      {:ok, _} = Dashboards.delete(dashboard)

      assert render(view) =~ "no longer exists"
    end
  end

  describe "the provider contract" do
    test "descriptor shape the projects hub consumes" do
      assert [ext] = PhoenixKitDashboards.phoenix_kit_project_extensions()
      assert ext.key == "dashboards_board"
      assert [%{lv: ProjectDashboardLive}] = ext.tabs
      assert [%{key: "dashboard_uuid", type: :select, options: {mod, fun}}] = ext.config_schema
      assert function_exported?(mod, fun, 0)
    end

    test "project_dashboard_options lists ONLY shared dashboards" do
      owner = user_fixture()
      {:ok, shared} = Dashboards.create(%{title: "Shared A", scope: "system"})

      {:ok, _personal} =
        Dashboards.create(%{title: "Mine", scope: "personal", owner_user_uuid: owner.uuid})

      options = PhoenixKitDashboards.project_dashboard_options()

      assert %{value: shared.uuid, label: "Shared A"} in options
      refute Enum.any?(options, &(&1.label == "Mine"))
    end
  end
end
