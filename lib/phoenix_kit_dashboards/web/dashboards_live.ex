defmodule PhoenixKitDashboards.Web.DashboardsLive do
  @moduledoc """
  Manage page — lists the current user's personal dashboards, all shared
  (system) dashboards, and any `role`-scoped dashboards for the user's roles.
  Creating and editing metadata happens on the dedicated form page
  (`DashboardFormLive`); from here admins open the builder, **clone** any
  visible dashboard into a private editable copy, edit, or delete (own
  personal ones + shared/role ones).

  Admin layout, sidebar, and the `@phoenix_kit_current_user` / `_scope` assigns
  are injected by PhoenixKit's on_mount hooks.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitDashboards.Gettext

  require Logger

  import PhoenixKitDashboards.Web.Helpers,
    only: [
      actor_uuid: 1,
      actor_opts: 1,
      user_role_uuids: 1,
      scope_label: 1,
      translate_catalog: 1,
      viewable_by?: 2,
      manageable_by?: 2
    ]

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Schemas.Dashboard

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Dashboards"))
     |> load_dashboards()}
  end

  @impl true
  def handle_event("clone", %{"uuid" => uuid}, socket) do
    with %{} = dashboard <- Dashboards.get(uuid),
         true <- viewable_by?(dashboard, socket),
         {:ok, clone} <- Dashboards.clone(dashboard, actor_uuid(socket), actor_opts(socket)) do
      {:noreply, push_navigate(socket, to: Paths.builder(clone.uuid))}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not clone dashboard.")
         )}
    end
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with %{} = dashboard <- Dashboards.get(uuid),
         # Must be able to SEE it to delete it (mirrors clone) — so a crafted
         # uuid can't blind-delete a role dashboard the actor isn't a member of.
         true <- viewable_by?(dashboard, socket),
         true <- manageable_by?(dashboard, actor_uuid(socket)),
         {:ok, _} <- Dashboards.delete(dashboard, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Dashboard deleted."))
       |> load_dashboards()}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not delete dashboard.")
         )}
    end
  end

  # Ignore any malformed / unexpected event rather than crashing the page
  # (mirrors DashboardFormLive/BuilderLive — "clone"/"delete" above require a
  # "uuid" param and would otherwise raise FunctionClauseError on a bad push).
  @impl true
  def handle_event(event, _params, socket) do
    Logger.debug("[Dashboards] Unhandled event: #{inspect(event)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Dashboards] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_dashboards(socket) do
    actor = actor_uuid(socket)
    dashboards = Dashboards.list_for_user(actor, user_role_uuids(socket))

    # One map for the whole list rather than a lookup per card: `places_for/2`
    # reads the placement blob, and calling it once per dashboard would read it
    # once per card.
    places = Map.new(dashboards, &{&1.uuid, Placements.places_for(&1.uuid, actor)})

    socket
    |> assign(:dashboards, dashboards)
    |> assign(:places, places)
    |> assign(:current_user_uuid, actor)
  end

  # A place's chip. Prefers the placement's own label (so "Quarterly Sales
  # Dashboard 2026" can read as "Sales" where it is shown), then the slot's
  # name, and falls back to the raw key only when the declaring module is gone
  # — which is itself the useful signal.
  defp place_label(%{label: label}) when is_binary(label) and label != "", do: label
  defp place_label(%{slot: %{name: name}}), do: translate_catalog(name)
  defp place_label(%{slot_key: key}), do: key

  defp place_title(%{audience: "personal"} = place),
    do: gettext("%{place} — only you", place: place_label(place))

  defp place_title(%{audience: "role"} = place),
    do: gettext("%{place} — for a role", place: place_label(place))

  defp place_title(place), do: gettext("%{place} — everyone", place: place_label(place))

  # Translated label for a scope enum (the raw value renders as a badge).
  defp type_icon(dashboard) do
    case Dashboard.type(dashboard) do
      "pixel" -> "hero-arrows-pointing-out"
      _ -> "hero-squares-2x2"
    end
  end

  defp type_label(dashboard) do
    case Dashboard.type(dashboard) do
      "pixel" -> gettext("Pixel")
      _ -> gettext("Grid")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- No in-page <h1>: the admin header breadcrumb already shows the page
      title (@page_title), so the page reclaims the space (workspace canon). --%>
      <div class="flex items-center justify-end">
        <.link navigate={Paths.new()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" />
          {gettext("Create dashboard")}
        </.link>
      </div>

      <.empty_state
        :if={@dashboards == []}
        variant="featured"
        icon="hero-squares-2x2"
        title={gettext("No dashboards yet.")}
      >
        <.link navigate={Paths.new()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" />
          {gettext("Create your first dashboard")}
        </.link>
      </.empty_state>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={dashboard <- @dashboards} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-start justify-between gap-2">
              <.link
                navigate={Paths.builder(dashboard.uuid)}
                class="card-title text-base hover:text-primary transition-colors min-w-0 truncate"
              >
                {dashboard.title}
              </.link>
              <span class={[
                "badge badge-sm",
                if(dashboard.scope == "system", do: "badge-info", else: "badge-ghost")
              ]}>
                {scope_label(dashboard.scope)}
              </span>
            </div>
            <p class="flex items-center gap-1.5 text-xs text-base-content/50">
              <.icon name={type_icon(dashboard)} class="w-3.5 h-3.5" />
              <span>{type_label(dashboard)}</span>
              <span aria-hidden="true">·</span>
              <span>
                {ngettext("%{count} widget", "%{count} widgets", length(dashboard.layout))}
              </span>
            </p>
            <%!-- WHERE this dashboard is shown. Without it discovery only runs
            one way — a place tells you what fills it, but a dashboard tells
            you nothing about where it appears, so it is possible to edit the
            company's admin home without realising that is what it is. --%>
            <p class="flex flex-wrap items-center gap-1 text-xs">
              <span class="text-base-content/50">{gettext("Shown in")}:</span>
              <span
                :if={@places[dashboard.uuid] in [nil, []]}
                class="text-base-content/40"
              >
                {gettext("nowhere yet")}
              </span>
              <.link
                :for={place <- @places[dashboard.uuid] || []}
                navigate={Paths.places()}
                class="badge badge-ghost badge-sm hover:badge-neutral"
                title={place_title(place)}
              >
                {place_label(place)}
              </.link>
            </p>
            <%!-- Primary action stays a visible button; secondary actions live
            in the canonical <.table_row_menu> kebab (staff/entities pattern). --%>
            <div class="card-actions items-center justify-end mt-2">
              <.link navigate={Paths.builder(dashboard.uuid)} class="btn btn-outline btn-xs">
                <.icon name="hero-pencil-square" class="w-3 h-3" />
                {gettext("Open")}
              </.link>
              <.table_row_menu
                id={"dashboard-menu-#{dashboard.uuid}"}
                label={gettext("Actions")}
              >
                <.table_row_menu_link
                  :if={manageable_by?(dashboard, @current_user_uuid)}
                  navigate={Paths.edit(dashboard.uuid)}
                  icon="hero-pencil"
                  label={gettext("Edit")}
                />
                <.table_row_menu_button
                  phx-click="clone"
                  phx-value-uuid={dashboard.uuid}
                  phx-disable-with={gettext("Cloning…")}
                  icon="hero-document-duplicate"
                  label={gettext("Clone")}
                />
                <.table_row_menu_divider :if={manageable_by?(dashboard, @current_user_uuid)} />
                <.table_row_menu_button
                  :if={manageable_by?(dashboard, @current_user_uuid)}
                  phx-click="delete"
                  phx-value-uuid={dashboard.uuid}
                  data-confirm={gettext("Delete this dashboard?")}
                  phx-disable-with={gettext("Deleting…")}
                  icon="hero-trash"
                  label={gettext("Delete")}
                  variant="error"
                />
              </.table_row_menu>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
