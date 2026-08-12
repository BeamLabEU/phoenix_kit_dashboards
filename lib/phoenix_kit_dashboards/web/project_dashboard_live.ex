defmodule PhoenixKitDashboards.Web.ProjectDashboardLive do
  @moduledoc """
  The **Dashboard** tab for the `phoenix_kit_projects` hub — this module's
  `phoenix_kit_project_extensions/0` contribution: a READ-ONLY, live view of
  one linked dashboard inside a project page.

  ## Hub session contract

  Off-router mount (`live_render`, no `handle_params/3`), per the projects
  embed-session contract: `"project_uuid"` / `"config"` /
  `"current_user_uuid"` / `"locale"`. The extension's config carries the
  linkage — `config["dashboard_uuid"]`, picked in the project's Modules panel.

  ## Only SHARED dashboards render here

  A project tab is a project-wide surface; personal and role dashboards
  carry per-user visibility that a shared pane must not blur. The picker
  offers only `scope == "system"` dashboards and the render path re-checks
  (a re-scoped dashboard downgrades to an explanatory card, live). Widget
  bodies still gate per-viewer: the embed identity is reconstructed from
  `current_user_uuid` and each widget re-checks
  `Registry.visible_for_scope?/2`, so a viewer without a module's
  permission sees that widget's placeholder, exactly like the builder.

  ## What renders

  The builder's fitted board (`BuilderComponents.grid_mode/free_mode`) in
  `readonly` mode — no drag/resize hooks, no card chrome, no catalog — with
  an `id_prefix` so the fit hooks' DOM ids stay unique inside the project
  page. Grid dashboards show their FIRST layout (v1: no layout switcher).
  Live widgets keep refreshing via a re-hosted copy of the builder's
  `:refresh_tick` loop, and edits made in the builder elsewhere appear live
  (`Dashboards.subscribe/1`).
  """

  # Plain LiveView, NOT `use PhoenixKitWeb, :live_view` — an embedded tab
  # must not pull the admin layout in (the ProjectDocumentsLive precedent).
  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDashboards.Gettext

  import PhoenixKitDashboards.Web.BuilderComponents,
    only: [grid_mode: 1, free_mode: 1, pixel_cells: 1]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Layouts
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Widget

  @refresh_tick_ms 1000
  @id_prefix "pk-projtab-"

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:id_prefix, @id_prefix)
      |> assign_embed_identity(session)
      |> load_dashboard(session["config"])

    if connected?(socket) do
      case socket.assigns.dashboard do
        %Dashboard{uuid: uuid} -> Dashboards.subscribe(uuid)
        _ -> :ok
      end
    end

    {:ok, maybe_schedule_refresh(socket)}
  end

  # ── Live sync ─────────────────────────────────────────────────────

  @impl true
  def handle_info({:dashboard_updated, %Dashboard{} = dashboard}, socket) do
    # Adopt the authoritative post-write struct; re-check the shared-scope
    # rule (a re-scope away downgrades this pane on the spot). mode +
    # design_h refresh too — the render branches on them (final panel
    # find: a stale mode rendered the wrong board component after a
    # remote grid↔pixel change).
    {:noreply,
     socket
     |> assign(
       dashboard: dashboard,
       state: state_for(dashboard),
       mode: Dashboard.layout_mode(dashboard),
       active_layout: first_layout_id(dashboard),
       design_h: design_height(dashboard)
     )
     |> maybe_schedule_refresh()}
  end

  def handle_info({:dashboard_deleted, _uuid}, socket) do
    {:noreply, assign(socket, dashboard: nil, state: :missing)}
  end

  # ── Refresh loop (re-hosted from the builder; process-dictionary state
  # so a tick never dirties the socket) ─────────────────────────────

  def handle_info(:refresh_tick, socket) do
    cond do
      Process.get(:pk_refresh_paused, false) ->
        Process.put(:pk_refresh_scheduled, false)
        {:noreply, socket}

      socket.assigns.state == :ok and any_live_widget?(socket.assigns.dashboard) ->
        now = System.monotonic_time(:millisecond)
        scope = socket.assigns[:phoenix_kit_current_scope]
        dashboard = socket.assigns.dashboard

        placements =
          dashboard
          |> Dashboards.resolve_items(socket.assigns.active_layout)
          |> Map.new(fn {item, p} -> {item["id"], p} end)

        dashboard.layout
        |> Enum.reduce(
          Process.get(:pk_refresh_at, %{}),
          &refresh_due(&1, &2, now, scope, placements)
        )
        |> then(&Process.put(:pk_refresh_at, &1))

        Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
        Process.put(:pk_refresh_scheduled, true)
        {:noreply, socket}

      true ->
        Process.put(:pk_refresh_scheduled, false)
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Tab visibility (DashboardVisibility hook on the root): pause while
  # hidden, snap-to-now on return — same latch discipline as the builder.
  @impl true
  def handle_event("refresh_pause", _params, socket) do
    Process.put(:pk_refresh_paused, true)
    {:noreply, socket}
  end

  def handle_event("refresh_resume", _params, socket) do
    Process.put(:pk_refresh_paused, false)
    Process.put(:pk_refresh_at, %{})

    unless Process.get(:pk_refresh_scheduled, false) do
      Process.put(:pk_refresh_scheduled, true)
      send(self(), :refresh_tick)
    end

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"#{@id_prefix}root"} phx-hook="DashboardVisibility" class="flex flex-col gap-3">
      <div :if={@state == :ok} class="flex items-center gap-3">
        <span class="hero-squares-2x2 w-5 h-5 opacity-70"></span>
        <div class="min-w-0 grow">
          <h3 class="font-semibold">{@dashboard.title}</h3>
        </div>
        <.link navigate={Paths.builder(@dashboard.uuid)} class="btn btn-ghost btn-sm gap-1">
          {gettext("Open in Dashboards")}
        </.link>
      </div>

      <.empty_note :if={@state == :unconfigured}>
        {gettext("No dashboard linked yet — pick a shared dashboard in the Modules panel.")}
      </.empty_note>
      <.empty_note :if={@state == :missing}>
        {gettext("The linked dashboard no longer exists.")}
      </.empty_note>
      <.empty_note :if={@state == :not_shared}>
        {gettext("The linked dashboard is not shared — only shared dashboards can appear here.")}
      </.empty_note>

      <div
        :if={@state == :ok and @mode == "grid"}
        class="flex flex-col overflow-hidden rounded-lg border border-base-200"
        style={"height: min(75vh, #{@design_h + 40}px);"}
      >
        <.grid_mode
          dashboard={@dashboard}
          scope={@phoenix_kit_current_scope}
          active_layout={@active_layout}
          show_grid_lines={false}
          empty={@dashboard.layout == []}
          readonly
          id_prefix={@id_prefix}
        />
      </div>
      <div
        :if={@state == :ok and @mode == "free"}
        class="flex flex-col overflow-hidden rounded-lg border border-base-200"
        style="height: 70vh;"
      >
        <.free_mode
          dashboard={@dashboard}
          scope={@phoenix_kit_current_scope}
          readonly
          id_prefix={@id_prefix}
        />
      </div>
    </div>
    """
  end

  slot(:inner_block, required: true)

  defp empty_note(assigns) do
    ~H"""
    <div class="card border border-dashed border-base-300 bg-base-100">
      <div class="card-body items-center text-center py-8">
        <p class="text-sm opacity-70">{render_slot(@inner_block)}</p>
      </div>
    </div>
    """
  end

  # ── Mount helpers ─────────────────────────────────────────────────

  # Reconstruct user + scope from the embed session (the on_mount hook never
  # runs under live_render). Prefer core's canonical helper when the running
  # core exposes it; fall back to a local resolve against older cores.
  defp assign_embed_identity(socket, session) do
    if is_nil(socket.assigns[:phoenix_kit_current_scope]) do
      # ensure_loaded? before function_exported?: on a cold VM the module may
      # not be loaded yet and function_exported?/3 answers false WITHOUT
      # loading it — silently taking the legacy fallback against a core that
      # does export the canonical helper. (Same trap as Registry's provider
      # discovery.)
      if Code.ensure_loaded?(PhoenixKitWeb.Users.Auth) and
           function_exported?(PhoenixKitWeb.Users.Auth, :assign_embedded_current_user, 2) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PhoenixKitWeb.Users.Auth, :assign_embedded_current_user, [socket, session])
      else
        {user, scope} = resolve_embed_identity(session["current_user_uuid"])
        assign(socket, phoenix_kit_current_user: user, phoenix_kit_current_scope: scope)
      end
    else
      socket
    end
  end

  defp resolve_embed_identity(uuid) when is_binary(uuid) and uuid != "" do
    user = uuid |> Auth.get_user() |> Auth.ensure_active_user()
    {user, Scope.for_user(user)}
  rescue
    _ -> {nil, Scope.for_user(nil)}
  end

  defp resolve_embed_identity(_), do: {nil, Scope.for_user(nil)}

  defp load_dashboard(socket, config) do
    uuid = is_map(config) && config["dashboard_uuid"]

    dashboard = if is_binary(uuid) and uuid != "", do: Dashboards.get(uuid)

    state =
      cond do
        !(is_binary(uuid) and uuid != "") -> :unconfigured
        is_nil(dashboard) -> :missing
        true -> state_for(dashboard)
      end

    assign(socket,
      dashboard: dashboard,
      state: state,
      mode: dashboard && Dashboard.layout_mode(dashboard),
      active_layout: first_layout_id(dashboard),
      design_h: design_height(dashboard)
    )
  end

  defp state_for(%Dashboard{scope: "system"}), do: :ok
  defp state_for(%Dashboard{}), do: :not_shared

  defp first_layout_id(%Dashboard{} = dashboard) do
    case Layouts.layouts(dashboard) do
      [%{"id" => id} | _] -> id
      _ -> nil
    end
  end

  defp first_layout_id(_), do: nil

  defp design_height(%Dashboard{} = dashboard) do
    Dashboards.design_height(dashboard, first_layout_id(dashboard))
  rescue
    _ -> 900
  end

  defp design_height(_), do: 900

  # ── Refresh helpers (builder semantics) ───────────────────────────

  defp maybe_schedule_refresh(socket) do
    if connected?(socket) and socket.assigns.state == :ok and
         not Process.get(:pk_refresh_scheduled, false) and
         not Process.get(:pk_refresh_paused, false) and
         any_live_widget?(socket.assigns.dashboard) do
      Process.send_after(self(), :refresh_tick, @refresh_tick_ms)
      Process.put(:pk_refresh_scheduled, true)
    end

    socket
  end

  defp any_live_widget?(%Dashboard{} = dashboard) do
    Enum.any?(dashboard.layout, fn inst ->
      match?(%Widget{refresh_interval: ms} when is_integer(ms), Registry.get(inst["widget_key"]))
    end)
  end

  defp any_live_widget?(_), do: false

  defp refresh_due(inst, acc, now, scope, placements) do
    case Registry.get(inst["widget_key"]) do
      %Widget{refresh_interval: ms} = widget when is_integer(ms) ->
        if now >= Map.get(acc, inst["id"], now) and Registry.visible_for_scope?(widget, scope) do
          p = placements[inst["id"]] || pixel_cells(inst)

          send_update(widget.component,
            id: inst["id"],
            settings: inst["settings"] || %{},
            view: (placements[inst["id"]] || %{})["view"] || inst["view"],
            size: %{w: p["w"], h: p["h"]},
            scope: scope
          )

          Map.put(acc, inst["id"], now + ms)
        else
          acc
        end

      _ ->
        acc
    end
  end
end
