defmodule PhoenixKitDashboards.Web.ProjectDashboardLiveTest do
  @moduledoc """
  The read-only project-tab viewer: state machine (unconfigured / missing /
  not-shared / ok), the shared-only render rule, the absence of edit
  affordances, live downgrade on re-scope, and the provider descriptor +
  options contract the `phoenix_kit_projects` hub consumes.
  """
  use PhoenixKitDashboards.LiveCase, async: false

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Slots
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
      assert html =~ "No dashboard here yet"
    end

    test "nil config (extension enabled, never saved) → configure hint", %{conn: conn} do
      {:ok, _view, html} = mount_tab(conn, nil)
      assert html =~ "No dashboard here yet"
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

  describe "viewer controls" do
    setup do
      {:ok, dashboard} = Dashboards.create(%{title: "Ops Board", scope: "system"})
      {:ok, dashboard} = Dashboards.add_widget(dashboard, "core.note")
      {:ok, dashboard: dashboard, viewer: user_fixture()}
    end

    test "a placed board offers fullscreen, targeting ITS OWN fit container",
         %{conn: conn, dashboard: dashboard, viewer: viewer} do
      {:ok, _view, html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid}, user: viewer)

      assert html =~ ~s(phx-hook="DashboardFullscreen")
      # The prefix is what keeps two boards on one page from stealing each
      # other's fullscreen target.
      assert html =~ ~s(data-target="pk-projtab-dashboard-grid-fit")
      assert html =~ ~s(id="pk-projtab-fullscreen-btn")
    end

    test "one layout means no layout picker",
         %{conn: conn, dashboard: dashboard, viewer: viewer} do
      {:ok, _view, html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid}, user: viewer)

      refute html =~ "select_layout"
    end

    test "several layouts are switchable, and the choice survives a live update",
         %{conn: conn, dashboard: dashboard, viewer: viewer} do
      {:ok, dashboard, %{"id" => second}} = Dashboards.add_layout(dashboard, "l1")

      {:ok, view, html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid}, user: viewer)
      assert html =~ "select_layout"

      view
      |> element("form[phx-change=select_layout]")
      |> render_change(%{"layout" => second})

      assert render(view) =~ ~s(value="#{second}" selected)

      # A broadcast re-renders the whole board; it must not yank the viewer
      # back to Layout 1.
      {:ok, _} = Dashboards.update(dashboard, %{title: "Ops Board v2"})

      html = render(view)
      assert html =~ "Ops Board v2"
      assert html =~ ~s(value="#{second}" selected)
    end

    test "an unknown layout id falls back instead of blanking the board",
         %{conn: conn, dashboard: dashboard, viewer: viewer} do
      {:ok, dashboard, _entry} = Dashboards.add_layout(dashboard, "l1")
      {:ok, view, _html} = mount_tab(conn, %{"dashboard_uuid" => dashboard.uuid}, user: viewer)

      view
      |> element("form[phx-change=select_layout]")
      |> render_change(%{"layout" => "nope"})

      assert render(view) =~ ~s(value="l1" selected)
    end
  end

  defmodule ProjectsSlot do
    # Mirrors the `projects.project` entry `phoenix_kit_projects` declares.
    # This package does not depend on that one, so the slot has to be supplied
    # here for the resolution path to have anything to resolve against.
    def phoenix_kit_dashboard_slots do
      [
        %{
          key: "projects.project",
          name: "Project page",
          surface: :record_tab,
          provides: ["projects.project"],
          cardinality: :one
        }
      ]
    end
  end

  describe "which dashboard the tab shows" do
    setup do
      previous = Application.get_env(:phoenix_kit_dashboards, :slot_providers, [])
      Application.put_env(:phoenix_kit_dashboards, :slot_providers, [ProjectsSlot])
      Slots.refresh()

      on_exit(fn ->
        Application.put_env(:phoenix_kit_dashboards, :slot_providers, previous)
        Slots.refresh()
      end)

      {:ok, shared} = Dashboards.create(%{title: "Every Project", scope: "system"})
      {:ok, shared} = Dashboards.add_widget(shared, "core.note")
      {:ok, pinned} = Dashboards.create(%{title: "Just This One", scope: "system"})
      {:ok, pinned} = Dashboards.add_widget(pinned, "core.note")

      {:ok, shared: shared, pinned: pinned, viewer: user_fixture()}
    end

    test "a placement shows on a project that pins nothing",
         %{conn: conn, shared: shared, viewer: viewer} do
      {:ok, _} =
        Placements.put("projects.project", %{
          "audience" => "everyone",
          "dashboard_uuid" => shared.uuid
        })

      {:ok, _view, html} = mount_tab(conn, %{}, user: viewer)

      assert html =~ "Every Project"
      refute html =~ "No dashboard here yet"
    end

    # The per-project pick is a statement about ONE project; the placement
    # answers for all of them. The narrower one wins, or "override" would
    # mean nothing.
    test "this project's own pick beats the placement",
         %{conn: conn, shared: shared, pinned: pinned, viewer: viewer} do
      {:ok, _} =
        Placements.put("projects.project", %{
          "audience" => "everyone",
          "dashboard_uuid" => shared.uuid
        })

      {:ok, _view, html} =
        mount_tab(conn, %{"dashboard_uuid" => pinned.uuid}, user: viewer)

      assert html =~ "Just This One"
      refute html =~ "Every Project"
    end

    test "binding one on the Places screen reaches an OPEN project page, live",
         %{conn: conn, shared: shared, viewer: viewer} do
      {:ok, view, html} = mount_tab(conn, %{}, user: viewer)
      assert html =~ "No dashboard here yet"

      {:ok, _} =
        Placements.put("projects.project", %{
          "audience" => "everyone",
          "dashboard_uuid" => shared.uuid
        })

      assert render(view) =~ "Every Project"
    end

    test "unbinding it takes the board away again, live",
         %{conn: conn, shared: shared, viewer: viewer} do
      {:ok, _} =
        Placements.put("projects.project", %{
          "audience" => "everyone",
          "dashboard_uuid" => shared.uuid
        })

      {:ok, view, html} = mount_tab(conn, %{}, user: viewer)
      assert html =~ "Every Project"

      {:ok, _} =
        Placements.delete("projects.project", %{
          "audience" => "everyone",
          "dashboard_uuid" => shared.uuid
        })

      assert render(view) =~ "No dashboard here yet"
    end

    test "nothing anywhere names both ways of fixing it",
         %{conn: conn, viewer: viewer} do
      {:ok, _view, html} = mount_tab(conn, %{}, user: viewer)

      assert html =~ "No dashboard here yet"
      assert html =~ "Show one on every project page"
      assert html =~ Paths.places()
    end
  end

  describe "stale subscriptions" do
    setup do
      {:ok, a} = Dashboards.create(%{title: "Board A", scope: "system"})
      {:ok, a} = Dashboards.add_widget(a, "core.note")
      {:ok, b} = Dashboards.create(%{title: "Board B", scope: "system"})
      {:ok, b} = Dashboards.add_widget(b, "core.note")
      {:ok, a: a, b: b, viewer: user_fixture()}
    end

    # This pane subscribes to whichever dashboard it resolves to and never
    # unsubscribes, so after a re-point it is still listening to the old one.
    test "an edit to a board this tab no longer shows does not swap it back",
         %{conn: conn, a: a, b: b, viewer: viewer} do
      {:ok, view, html} = mount_tab(conn, %{"dashboard_uuid" => a.uuid}, user: viewer)
      assert html =~ "Board A"

      # Simulate the re-point: the pane is now showing B, but its subscription
      # to A is still live, so A's broadcast still arrives here.
      send(view.pid, {:dashboard_updated, %{b | title: "Board B"}})
      send(view.pid, {:dashboard_updated, %{a | title: "Board A renamed"}})

      html = render(view)
      assert html =~ "Board A renamed"
      refute html =~ "Board B"
    end

    test "deleting a board this tab no longer shows does not blank it",
         %{conn: conn, a: a, b: b, viewer: viewer} do
      {:ok, view, _html} = mount_tab(conn, %{"dashboard_uuid" => a.uuid}, user: viewer)

      send(view.pid, {:dashboard_deleted, b.uuid})

      html = render(view)
      assert html =~ "Board A"
      refute html =~ "no longer exists"
    end

    test "deleting the board it IS showing still blanks it",
         %{conn: conn, a: a, viewer: viewer} do
      {:ok, view, _html} = mount_tab(conn, %{"dashboard_uuid" => a.uuid}, user: viewer)

      send(view.pid, {:dashboard_deleted, a.uuid})

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
