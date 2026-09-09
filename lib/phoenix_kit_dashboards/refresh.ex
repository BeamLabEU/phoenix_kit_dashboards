defmodule PhoenixKitDashboards.Refresh do
  @moduledoc """
  The host-driven widget refresh loop, shared by every surface that renders a
  dashboard.

  A widget is a `Phoenix.LiveComponent` and therefore has **no process** — it
  cannot subscribe or time itself. So the hosting LiveView runs a single
  one-second tick and `send_update/2`s each widget whose `refresh_interval` is
  due. That loop was written twice (the builder and the project tab) and is now
  written once here, because a third and fourth surface (`Web.SlotLive`, the
  admin home) need exactly the same behaviour — and because the `context`
  assign has to ride along on every refresh, not only on the first render.
  That last part is easy to get wrong in a copy: a widget refreshed without its
  context would silently revert to unbound data a second after it appeared.

  Timing state lives in the **process dictionary**, not in socket assigns, so a
  tick never dirties the socket and never triggers a re-render on its own.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, send_update: 2]

  alias PhoenixKitDashboards.Binds
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Widget

  @tick_ms 1000

  @doc """
  Schedule the tick if this socket has anything live to refresh.

  Safe to call after every state change: it is a no-op when a tick is already
  scheduled, when the tab is hidden, or when no placed widget declares an
  interval.
  """
  @spec reschedule(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reschedule(socket) do
    dashboard = socket.assigns[:active] || socket.assigns[:dashboard]

    if connected?(socket) and not scheduled?() and not paused?() and any_live?(dashboard) do
      Process.send_after(self(), :refresh_tick, @tick_ms)
      Process.put(:pk_refresh_scheduled, true)
    end

    socket
  end

  @doc """
  Handle one `:refresh_tick`: update every due widget and re-arm.

  `context` is threaded into each `send_update/2` so a bound widget keeps its
  subject across refreshes.
  """
  @spec tick(Phoenix.LiveView.Socket.t(), Dashboard.t() | nil, map()) ::
          Phoenix.LiveView.Socket.t()
  def tick(socket, dashboard, context \\ %{})

  def tick(socket, %Dashboard{} = dashboard, context) do
    if paused?() do
      Process.put(:pk_refresh_scheduled, false)
      socket
    else
      do_tick(socket, dashboard, context)
      socket
    end
  end

  def tick(socket, _dashboard, _context) do
    Process.put(:pk_refresh_scheduled, false)
    socket
  end

  defp do_tick(socket, dashboard, context) do
    # A board with nothing live must let the loop DIE. `resume/1` arms a tick
    # without checking (it cannot — the dashboard may have changed while the
    # tab was hidden), so this is the only place that decides to stop; without
    # it a static dashboard re-armed itself every second forever after the
    # viewer came back to the tab.
    if any_live?(dashboard) do
      run_tick(socket, dashboard, context)
    else
      Process.put(:pk_refresh_scheduled, false)
    end
  end

  defp run_tick(socket, dashboard, context) do
    now = System.monotonic_time(:millisecond)
    scope = socket.assigns[:phoenix_kit_current_scope]
    layout_id = socket.assigns[:active_layout]

    placements =
      dashboard
      |> Dashboards.resolve_items(layout_id)
      |> Map.new(fn {item, placement} -> {item["id"], placement} end)

    dashboard.layout
    |> Enum.reduce(Process.get(:pk_refresh_at, %{}), fn item, acc ->
      refresh_due(item, acc, now, scope, placements, context)
    end)
    |> then(&Process.put(:pk_refresh_at, &1))

    Process.send_after(self(), :refresh_tick, @tick_ms)
    Process.put(:pk_refresh_scheduled, true)
  rescue
    # A refresh must never take the page down — the widgets simply miss a beat.
    _ -> Process.put(:pk_refresh_scheduled, false)
  end

  defp refresh_due(item, acc, now, scope, placements, context) do
    case Registry.get(item["widget_key"]) do
      %Widget{refresh_interval: ms} = widget when is_integer(ms) ->
        due? = now >= Map.get(acc, item["id"], now)
        {settings, unresolved} = Binds.resolve(item, context, scope)

        # An unresolved bind is showing a placeholder, not a live component —
        # sending it an update would target a component that is not mounted.
        if due? and unresolved == [] and Registry.visible_for_scope?(widget, scope) do
          placement = placements[item["id"]] || %{}

          send_update(widget.component,
            id: item["id"],
            settings: settings,
            view: placement["view"] || item["view"],
            size: %{w: placement["w"], h: placement["h"]},
            scope: scope,
            context: context
          )

          Map.put(acc, item["id"], now + ms)
        else
          acc
        end

      _ ->
        acc
    end
  end

  @doc "Pause the loop while the browser tab is hidden (the `DashboardVisibility` hook)."
  @spec pause(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def pause(socket) do
    Process.put(:pk_refresh_paused, true)
    socket
  end

  @doc """
  Resume on return, snapping every widget to due so the page is current
  immediately rather than up to one interval stale.
  """
  @spec resume(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def resume(socket) do
    Process.put(:pk_refresh_paused, false)
    Process.put(:pk_refresh_at, %{})

    unless scheduled?() do
      Process.put(:pk_refresh_scheduled, true)
      send(self(), :refresh_tick)
    end

    socket
  end

  @doc "Whether any placed widget on `dashboard` declares a refresh interval."
  @spec any_live?(Dashboard.t() | nil) :: boolean()
  def any_live?(%Dashboard{} = dashboard) do
    Enum.any?(dashboard.layout, fn item ->
      match?(%Widget{refresh_interval: ms} when is_integer(ms), Registry.get(item["widget_key"]))
    end)
  end

  def any_live?(_dashboard), do: false

  defp scheduled?, do: Process.get(:pk_refresh_scheduled, false)
  defp paused?, do: Process.get(:pk_refresh_paused, false)

  @doc "Assign a socket-visible flag for templates that want to show a live dot."
  @spec assign_live_flag(Phoenix.LiveView.Socket.t(), Dashboard.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_live_flag(socket, dashboard),
    do: assign(socket, :live_widgets?, any_live?(dashboard))
end
