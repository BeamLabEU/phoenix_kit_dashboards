defmodule PhoenixKitDashboards.Web.ProjectDashboardLive do
  @moduledoc """
  The **Dashboard** tab for the `phoenix_kit_projects` hub — this module's
  `phoenix_kit_project_extensions/0` contribution: a READ-ONLY, live view of
  one linked dashboard inside a project page.

  ## Hub session contract

  Off-router mount (`live_render`, no `handle_params/3`), per the projects
  embed-session contract: `"project_uuid"` / `"config"` /
  `"current_user_uuid"` / `"locale"`.

  ## Which dashboard, and who decided

  Two things can name it, and the more specific one wins:

  1. **This project's own pick** — `config["dashboard_uuid"]`, set in the
     project's Modules panel. It is a statement about ONE project, so it
     overrides anything set module-wide.
  2. **The `projects.project` placement** — set once on the Places screen and
     answering for every project, with the usual audience tiers (personal →
     role → everyone). This is the reason a slot exists for this surface at
     all: one board serves every project instead of needing a copy each.

  Both are live. Re-pointing the placement re-renders every project page that
  is not overriding it, without a reload.

  ## Only SHARED dashboards may be PINNED here

  A per-project pin is a project-wide surface; personal and role dashboards
  carry per-user visibility that a shared pane must not blur. The picker
  offers only `scope == "system"` dashboards and the render path re-checks
  (a re-scoped dashboard downgrades to an explanatory card, live). A
  PLACEMENT needs no such check: resolution already answers per viewer, so
  the personal tier is a board its owner is entitled to see. Widget
  bodies still gate per-viewer: the embed identity is reconstructed from
  `current_user_uuid` and each widget re-checks
  `Registry.visible_for_scope?/2`, so a viewer without a module's
  permission sees that widget's placeholder, exactly like the builder.

  ## What renders

  The builder's fitted board (`BuilderComponents.grid_mode/free_mode`) in
  `readonly` mode — no drag/resize hooks, no card chrome, no catalog — with
  an `id_prefix` so the fit hooks' DOM ids stay unique inside the project
  page. A dashboard with several named layouts offers a compact layout
  picker; the viewer's choice survives live updates.
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
  alias PhoenixKitDashboards.Binds
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Layouts
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Web.Helpers
  alias PhoenixKitDashboards.Widget

  @refresh_tick_ms 1000
  @id_prefix "pk-projtab-"
  @slot_key "projects.project"

  @impl true
  def mount(_params, session, socket) do
    Helpers.put_embed_locale(session)

    socket =
      socket
      # THE context this tab supplies. Without it a dashboard shown inside
      # Project A and Project B rendered identically — every project-flavoured
      # widget fell back to whatever uuid was typed into its own settings when
      # it was placed. The tab has always received the project uuid in its
      # session; it simply never passed it down.
      |> assign(:context, project_context(session))
      |> assign(:id_prefix, @id_prefix)
      # Kept so a placement change can re-decide without the hub re-mounting
      # us: the per-project pin still has to win, and it arrives only here.
      |> assign(:ext_config, session["config"])
      |> assign_embed_identity(session)
      |> load_dashboard(session["config"])

    if connected?(socket) do
      # The board this tab shows can change from OUTSIDE the project — an
      # admin binding one on the Places screen. Without this the tab would
      # keep saying "nothing linked" until someone reloaded the page.
      Placements.subscribe()

      case socket.assigns.dashboard do
        %Dashboard{uuid: uuid} -> Dashboards.subscribe(uuid)
        _ -> :ok
      end
    end

    {:ok, maybe_schedule_refresh(socket)}
  end

  # ── Live sync ─────────────────────────────────────────────────────

  @impl true
  # Only the board actually on screen. This pane subscribes to whichever
  # dashboard it resolves to and never unsubscribes, so once a placement is
  # re-pointed it is still listening to the previous one — without this guard
  # an edit to the OLD board would swap it back onto a project it is no longer
  # placed on. `BuilderLive` has always guarded this; this view did not.
  def handle_info(
        {:dashboard_updated, %Dashboard{uuid: uuid} = dashboard},
        %{assigns: %{dashboard: %Dashboard{uuid: uuid}}} = socket
      ) do
    # Adopt the authoritative post-write struct; re-check the shared-scope
    # rule (a re-scope away downgrades this pane on the spot). mode +
    # design_h refresh too — the render branches on them (final panel
    # find: a stale mode rendered the wrong board component after a
    # remote grid↔pixel change).
    layout = Layouts.keep_layout_id(dashboard, socket.assigns[:active_layout])

    {:noreply,
     socket
     |> assign(
       dashboard: dashboard,
       state: state_for(dashboard),
       mode: Dashboard.layout_mode(dashboard),
       active_layout: layout,
       design_h: design_height(dashboard, layout)
     )
     |> maybe_schedule_refresh()}
  end

  # Same guard on the delete side: a stale subscription's delete must not
  # blank a pane that is showing a different, healthy board.
  def handle_info(
        {:dashboard_deleted, uuid},
        %{assigns: %{dashboard: %Dashboard{uuid: uuid}}} = socket
      ) do
    {:noreply, assign(socket, dashboard: nil, state: :missing)}
  end

  def handle_info({:placements_changed, _slot_key}, socket) do
    socket = load_dashboard(socket, socket.assigns[:ext_config])

    # Follow whatever we ended up on. Subscribing is idempotent per topic, and
    # a dashboard that dropped out simply stops mattering — its messages fall
    # through the clause above.
    if connected?(socket) do
      case socket.assigns.dashboard do
        %Dashboard{uuid: uuid} -> Dashboards.subscribe(uuid)
        _ -> :ok
      end
    end

    {:noreply, maybe_schedule_refresh(socket)}
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

        context = socket.assigns.context

        dashboard.layout
        |> Enum.reduce(
          Process.get(:pk_refresh_at, %{}),
          &refresh_due(&1, &2, now, scope, placements, context)
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

  # View state only — a project viewer may look at every layout of the linked
  # board without holding any right to change it.
  def handle_event("select_layout", %{"layout" => id}, socket) do
    dashboard = socket.assigns[:dashboard]
    layout = Layouts.keep_layout_id(dashboard, id)

    {:noreply, assign(socket, active_layout: layout, design_h: design_height(dashboard, layout))}
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
        <form
          :if={length(Layouts.layouts(@dashboard)) > 1}
          id={"#{@id_prefix}layout-form"}
          phx-change="select_layout"
          class="shrink-0"
        >
          <select
            name="layout"
            class="select select-sm select-bordered"
            aria-label={gettext("Layout")}
          >
            <option
              :for={entry <- Layouts.layouts(@dashboard)}
              value={entry["id"]}
              selected={entry["id"] == @active_layout}
            >
              {entry["name"]}
            </option>
          </select>
        </form>
        <button
          id={"#{@id_prefix}fullscreen-btn"}
          phx-hook="DashboardFullscreen"
          data-target={"#{@id_prefix}dashboard-#{if @mode == "free", do: "free", else: "grid"}-fit"}
          type="button"
          class="btn btn-ghost btn-sm btn-square shrink-0"
          title={gettext("Full screen")}
        >
          <span class="hero-arrows-pointing-out h-4 w-4"></span>
        </button>
        <.link navigate={Paths.builder(@dashboard.uuid)} class="btn btn-ghost btn-sm gap-1">
          {gettext("Open in Dashboards")}
        </.link>
      </div>

      <%!-- Two routes reach this tab, so the empty state names both. The
      module-wide one is a real page and is linked; the per-project one is a
      drawer with no address, so it is spelled out as the click path — the
      old copy said "the Modules panel" and there is no such thing on screen
      to look for. --%>
      <.empty_note :if={@state == :unconfigured}>
        {gettext("No dashboard here yet.")}
        <.link navigate={Paths.places()} class="link link-primary">
          {gettext("Show one on every project page")}
        </.link>
        {gettext("— or pick one for this project alone under ⋮ → Edit → Modules → Dashboard.")}
      </.empty_note>
      <.empty_note :if={@state == :missing}>
        {gettext("The linked dashboard no longer exists.")}
      </.empty_note>
      <.empty_note :if={@state == :not_shared}>
        {gettext("The dashboard pinned to this project is not shared — only shared dashboards can be pinned here.")}
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
          context={@context}
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
          context={@context}
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
    {dashboard, state} =
      case pinned_uuid(config) do
        nil -> placed(socket)
        uuid -> pinned(uuid)
      end

    layout = Layouts.keep_layout_id(dashboard, socket.assigns[:active_layout])

    assign(socket,
      dashboard: dashboard,
      state: state,
      mode: dashboard && Dashboard.layout_mode(dashboard),
      active_layout: layout,
      design_h: design_height(dashboard, layout)
    )
  end

  defp pinned_uuid(config) do
    case is_map(config) && config["dashboard_uuid"] do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  # This project's own pick. Shared-only, and re-checked here rather than
  # trusted from the picker: a dashboard re-scoped after it was pinned must
  # downgrade to the explanatory card rather than leak.
  defp pinned(uuid) do
    case Dashboards.get(uuid) do
      %Dashboard{} = dashboard -> {dashboard, state_for(dashboard)}
      _ -> {nil, :missing}
    end
  end

  # The module-wide placement, resolved FOR THIS VIEWER. No scope re-check:
  # unlike a pin, resolution has already decided what this person may see —
  # the personal tier is by definition a board its owner owns, and refusing
  # it here would make "shared only" mean "nobody's own", which is not the
  # rule. `resolve_one/2` stops at the first match, so a slot declared
  # `cardinality: :one` costs one lookup.
  defp placed(socket) do
    case Placements.resolve_one(@slot_key, socket.assigns[:phoenix_kit_current_scope]) do
      %Dashboard{} = dashboard -> {dashboard, :ok}
      _ -> {nil, :unconfigured}
    end
  rescue
    _ -> {nil, :unconfigured}
  catch
    :exit, _ -> {nil, :unconfigured}
  end

  defp state_for(%Dashboard{scope: "system"}), do: :ok
  defp state_for(%Dashboard{}), do: :not_shared

  defp design_height(%Dashboard{} = dashboard, layout) do
    Dashboards.design_height(dashboard, layout)
  rescue
    _ -> 900
  end

  defp design_height(_dashboard, _layout), do: 900

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

  defp refresh_due(inst, acc, now, scope, placements, context) do
    case Registry.get(inst["widget_key"]) do
      %Widget{refresh_interval: ms} = widget when is_integer(ms) ->
        {settings, unresolved} = Binds.resolve(inst, context, scope)

        # An unresolved bind is showing a placeholder card, not a mounted
        # LiveComponent — updating it would target a component that isn't there.
        if now >= Map.get(acc, inst["id"], now) and unresolved == [] and
             Registry.visible_for_scope?(widget, scope) do
          p = placements[inst["id"]] || pixel_cells(inst)

          send_update(widget.component,
            id: inst["id"],
            settings: settings,
            view: (placements[inst["id"]] || %{})["view"] || inst["view"],
            size: %{w: p["w"], h: p["h"]},
            scope: scope,
            context: context
          )

          Map.put(acc, inst["id"], now + ms)
        else
          acc
        end

      _ ->
        acc
    end
  end

  # The hub passes the project uuid in the embed session (the contract in the
  # moduledoc). Keyed by CONTEXT KIND, not by a bare field name, so a second
  # record type later cannot be mistaken for a project.
  defp project_context(session) do
    case session["project_uuid"] do
      uuid when is_binary(uuid) and uuid != "" -> %{"projects.project" => uuid}
      _ -> %{}
    end
  end
end
