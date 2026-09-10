defmodule PhoenixKitDashboards.Web.AdminHomeLive do
  @moduledoc """
  The dashboard half of core's `/admin` landing page.

  Core owns `/admin`. This view is `live_render`ed into it when this module is
  installed and enabled, and it decides — live — whether there is anything to
  show. Core renders its own built-in overview whenever this view reports
  nothing, so the landing page an install has always had is never lost to an
  optional module being present, disabled, or unbound.

  ## Plain LiveView, not `use PhoenixKitWeb, :live_view`

  Same reason as `Web.ProjectDashboardLive`: an embedded view must not pull the
  admin layout in — core's page already provides it. Mounting off-router also
  means no `on_mount` hook has run, so identity is reconstructed from the embed
  session by `Web.Helpers.assign_embed_identity/2`.

  ## Telling core what happened

  Core cannot ask a child LiveView a question, so this view *tells* it: on
  mount and on every placement change it sends `{:admin_home, :shown | :empty}`
  to its parent. Core keeps its overview hidden while a dashboard is shown and
  brings it back the moment one is unbound — without a reload, which is the
  whole point of doing it this way rather than deciding once in core's mount.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitDashboards.Gettext

  import PhoenixKitDashboards.Web.SlotComponents

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Layouts
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Refresh
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Slots
  alias PhoenixKitDashboards.Web.Helpers
  alias PhoenixKitDashboards.Web.Personal

  @slot_key "core.admin_home"
  @id_prefix "pk-adminhome-"

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Placements.subscribe()

    socket =
      socket
      |> assign(
        id_prefix: @id_prefix,
        context: %{},
        active_index: 0,
        slot_key: @slot_key,
        parent: session["parent_pid"]
      )
      |> Helpers.assign_embed_identity(session)
      |> load()

    {:ok, socket}
  end

  # ── Live sync ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:placements_changed, _slot_key}, socket), do: {:noreply, load(socket)}

  def handle_info({:dashboard_updated, %Dashboard{} = dashboard}, socket) do
    {:noreply,
     socket
     |> update(:dashboards, fn list ->
       Enum.map(list, &if(&1.uuid == dashboard.uuid, do: dashboard, else: &1))
     end)
     |> assign_active()
     |> Refresh.reschedule()}
  end

  def handle_info({:dashboard_deleted, _uuid}, socket), do: {:noreply, load(socket)}

  def handle_info(:refresh_tick, socket) do
    {:noreply, Refresh.tick(socket, socket.assigns[:active], socket.assigns.context)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_dashboard", %{"index" => index}, socket) do
    count = length(socket.assigns.dashboards)

    {:noreply,
     socket
     |> assign(:active_index, clamp_index(index, count))
     |> assign_active()
     |> Refresh.reschedule()}
  end

  def handle_event("fork_and_edit", _params, socket) do
    # Fork FIRST, then open the copy: on a template place the person is meant
    # to edit their own board, never everyone's.
    socket = Personal.fork(socket, &load/1)

    case socket.assigns[:active] do
      %Dashboard{uuid: uuid} -> {:noreply, push_navigate(socket, to: Paths.builder(uuid))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("create_own", _params, socket) do
    {:noreply, Personal.create_own(socket, &load/1)}
  end

  def handle_event("fork_personal", _params, socket) do
    {:noreply, Personal.fork(socket, &load/1)}
  end

  def handle_event("reset_personal", _params, socket) do
    {:noreply, Personal.reset(socket, &load/1)}
  end

  def handle_event("refresh_pause", _params, socket), do: {:noreply, Refresh.pause(socket)}
  def handle_event("refresh_resume", _params, socket), do: {:noreply, Refresh.resume(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Loading ────────────────────────────────────────────────────────

  defp load(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    {tier, dashboards} = Placements.resolve(@slot_key, scope)

    if connected?(socket), do: Enum.each(dashboards, &Dashboards.subscribe(&1.uuid))

    socket
    |> assign(
      slot: Slots.get(@slot_key),
      dashboards: dashboards,
      tier: tier,
      policy: Placements.policy_for(@slot_key, scope),
      active_index: min(socket.assigns.active_index, max(length(dashboards) - 1, 0))
    )
    |> assign_active()
    |> Personal.assign_flags()
    |> notify_parent(dashboards)
    |> Refresh.reschedule()
  end

  defp assign_active(socket) do
    active = Enum.at(socket.assigns.dashboards, socket.assigns.active_index)

    assign(socket,
      active: active,
      mode: active && Dashboard.layout_mode(active),
      active_layout: first_layout_id(active),
      design_h: design_height(active)
    )
  end

  # Core hides its overview only while a dashboard is actually on screen.
  defp notify_parent(socket, dashboards) do
    if is_pid(socket.assigns[:parent]) do
      send(socket.assigns.parent, {:admin_home, if(dashboards == [], do: :empty, else: :shown)})
    end

    socket
  end

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

  defp clamp_index(value, count) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int >= 0 and int < count -> int
      _ -> 0
    end
  end

  defp clamp_index(_value, _count), do: 0

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"#{@id_prefix}root"} phx-hook="DashboardVisibility" class="flex flex-col gap-3">
      <.slot_header
        :if={@active}
        slot={@slot}
        dashboards={@dashboards}
        active_index={@active_index}
        tier={@tier}
        active={@active}
        scope={@phoenix_kit_current_scope}
        can_fork?={@can_fork?}
        mine?={@mine?}
        fork_on_edit?={@fork_on_edit?}
      />
      <.slot_board
        :if={@active}
        active={@active}
        mode={@mode}
        active_layout={@active_layout}
        design_h={@design_h}
        context={@context}
        id_prefix={@id_prefix}
        scope={@phoenix_kit_current_scope}
      />
    </div>
    """
  end
end
