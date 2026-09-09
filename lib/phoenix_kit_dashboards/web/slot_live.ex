defmodule PhoenixKitDashboards.Web.SlotLive do
  @moduledoc """
  Renders whichever dashboard(s) a viewer should see in one **slot**.

  Every `:module_tab` slot's generated sidebar tab points here (see
  `PhoenixKitDashboards.Slots.module_tabs/0`); the slot key rides in the tab's
  `metadata`. The page resolves the viewer's placement
  (`Placements.resolve/3` — personal, then their best-priority role, then
  everyone), renders that dashboard read-first, and stays **live**: it
  subscribes both to the dashboard itself and to the placement blob, so a
  rebinding or an edit in the builder lands here without a refresh.

  ## Why it is live even for a shared board

  A panel seat argued a shared landing page should require an explicit
  publish, so one admin's drag cannot rearrange forty people's page mid-morning.
  That was considered and rejected: liveness is the product here, and the same
  broadcast already drives the builder and the project tab. What is kept from
  the objection is the *editing* guard — this page never edits in place; you
  leave for the builder, and a shared board warns before you get there.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitDashboards.Gettext

  import PhoenixKitDashboards.Web.SlotComponents

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Layouts
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Refresh
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Slot
  alias PhoenixKitDashboards.Slots

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Placements.subscribe()

    {:ok, assign(socket, id_prefix: "pk-slot-", context: %{}, active_index: 0)}
  end

  # The slot key comes from the tab's metadata rather than the URL, so a slot's
  # path is whatever the declaring module chose and no route parsing is needed.
  @impl true
  def handle_params(_params, _uri, socket) do
    slot_key = slot_key_from_tab(socket)

    {:noreply,
     socket
     |> assign(:slot_key, slot_key)
     |> load_slot()}
  end

  # ── Live sync ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:placements_changed, _slot_key}, socket) do
    {:noreply, load_slot(socket)}
  end

  def handle_info({:dashboard_updated, %Dashboard{} = dashboard}, socket) do
    {:noreply,
     socket
     |> update(:dashboards, fn list ->
       Enum.map(list, &if(&1.uuid == dashboard.uuid, do: dashboard, else: &1))
     end)
     |> assign_active()
     |> Refresh.reschedule()}
  end

  def handle_info({:dashboard_deleted, _uuid}, socket), do: {:noreply, load_slot(socket)}

  def handle_info(:refresh_tick, socket) do
    {:noreply, Refresh.tick(socket, socket.assigns[:active], socket.assigns.context)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_dashboard", %{"index" => index}, socket) do
    {:noreply,
     socket
     |> assign(:active_index, to_index(index, length(socket.assigns.dashboards)))
     |> assign_active()
     |> Refresh.reschedule()}
  end

  def handle_event("refresh_pause", _params, socket), do: {:noreply, Refresh.pause(socket)}
  def handle_event("refresh_resume", _params, socket), do: {:noreply, Refresh.resume(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Loading ────────────────────────────────────────────────────────

  defp load_slot(%{assigns: %{slot_key: nil}} = socket) do
    assign(socket, slot: nil, dashboards: [], tier: :none, active: nil, page_title: "Dashboard")
  end

  defp load_slot(%{assigns: %{slot_key: slot_key}} = socket) do
    slot = Slots.get(slot_key)
    scope = socket.assigns[:phoenix_kit_current_scope]

    {tier, dashboards} =
      if slot, do: Placements.resolve(slot_key, scope), else: {:none, []}

    # Re-subscribe to exactly the dashboards now on screen. Subscribing is
    # idempotent per topic, and a dashboard that dropped out of the placement
    # simply stops mattering — its messages fall through handle_info/2.
    if connected?(socket) do
      Enum.each(dashboards, &Dashboards.subscribe(&1.uuid))
    end

    socket
    |> assign(
      slot: slot,
      dashboards: dashboards,
      tier: tier,
      active_index: min(socket.assigns.active_index, max(length(dashboards) - 1, 0)),
      page_title: (slot && slot.name) || "Dashboard"
    )
    |> assign_active()
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

  defp slot_key_from_tab(socket) do
    case socket.assigns[:phoenix_kit_current_tab] do
      %{metadata: %{slot_key: key}} when is_binary(key) -> key
      _ -> slot_key_from_path(socket)
    end
  end

  # Fallback for cores that do not assign the current tab: match the request
  # path against the declared slots' own paths.
  defp slot_key_from_path(socket) do
    path = socket.assigns[:phoenix_kit_current_path] || ""

    Enum.find_value(Slots.list(), fn %Slot{} = slot ->
      slot.path && String.ends_with?(path, slot.path) && slot.key
    end)
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

  defp to_index(value, count) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int >= 0 and int < count -> int
      _ -> 0
    end
  end

  defp to_index(_value, _count), do: 0

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
      />

      <.slot_empty :if={is_nil(@active)} slot={@slot} scope={@phoenix_kit_current_scope} />

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
