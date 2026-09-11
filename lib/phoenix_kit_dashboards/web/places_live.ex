defmodule PhoenixKitDashboards.Web.PlacesLive do
  @moduledoc """
  **Places** — the one screen that answers "where does a dashboard show, and
  for whom".

  ## Why it is not a matrix

  The obvious shape for this is a grid of places × audiences × dashboards.
  Every reviewing seat costed that independently and rejected it: two dozen
  modules with a few slots each, times everyone plus every role plus named
  people, is thousands of mostly-empty cells and a spreadsheet nobody trusts.

  So instead: a **list of places, grouped by the module that offers them**.
  Each place is a card showing the company-wide answer first, then the role
  exceptions under it. You open one place and edit that place. Searching
  filters the places, never the audiences.

  ## What it refuses, and why

  Binding is validated in `PhoenixKitDashboards.Placements.put/3`, and the
  refusals matter more than the affordances:

  * a **personal** dashboard cannot fill a shared place — that would publish
    one person's private canvas to the company;
  * a **pixel** (wall-TV) dashboard cannot fill the admin home;
  * a place that holds one dashboard refuses a second for the same audience.

  Broken placements — the dashboard was deleted, the module was uninstalled —
  are listed as problems and disabled at render, never quietly dropped. An
  administrator needs to see *why* a page went blank.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitDashboards.Gettext

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Slot
  alias PhoenixKitDashboards.Slots
  alias PhoenixKitDashboards.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Placements.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Places"),
       query: "",
       open_slot: nil,
       form_audience: "everyone",
       error: nil
     )
     |> load()}
  end

  @impl true
  def handle_info({:placements_changed, _slot_key}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> load()}
  end

  def handle_event("open", %{"slot" => slot_key}, socket) do
    {:noreply, assign(socket, open_slot: slot_key, error: nil, form_audience: "everyone")}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, open_slot: nil, error: nil)}
  end

  def handle_event("set_audience", %{"audience" => audience}, socket) do
    {:noreply, assign(socket, :form_audience, audience)}
  end

  def handle_event("place", %{"slot" => slot_key} = params, socket) do
    case Placements.put(slot_key, params, Helpers.actor_opts(socket)) do
      {:ok, _placements} ->
        {:noreply, socket |> assign(error: nil) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("unplace", %{"slot" => slot_key} = params, socket) do
    case Placements.delete(slot_key, params, Helpers.actor_opts(socket)) do
      {:ok, _} -> {:noreply, socket |> assign(error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("set_priority", %{"slot" => slot_key, "priority" => raw} = params, socket) do
    case Integer.parse(to_string(raw)) do
      {priority, _} ->
        Placements.set_priority(slot_key, params, priority, Helpers.actor_opts(socket))
        {:noreply, load(socket)}

      :error ->
        {:noreply, socket}
    end
  end

  # ── Loading ────────────────────────────────────────────────────────

  defp load(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    query = String.downcase(String.trim(socket.assigns.query || ""))

    groups =
      scope
      |> Slots.grouped_for_scope()
      |> Enum.map(fn {label, slots} ->
        {label, Enum.filter(slots, &matches?(&1, label, query))}
      end)
      |> Enum.reject(fn {_label, slots} -> slots == [] end)

    assign(socket,
      groups: groups,
      placements: Placements.all(),
      problems: Placements.health(scope),
      # Only SHAREABLE dashboards can be bound centrally; a personal one is
      # excluded at the picker as well as in the context, so the refusal is
      # never a surprise the admin discovers after choosing.
      shareable: Enum.reject(Dashboards.list_system(), &is_nil/1),
      roles: Helpers.list_roles()
    )
  end

  defp matches?(_slot, _label, ""), do: true

  defp matches?(%Slot{} = slot, label, query) do
    # Match the TRANSLATED name: searching for what is on screen has to work.
    String.contains?(String.downcase(Slot.localized_name(slot)), query) or
      String.contains?(String.downcase(slot.name), query) or
      String.contains?(String.downcase(label), query)
  end

  defp error_message(:personal_not_shareable),
    do: gettext("A personal dashboard can't be shown to other people. Pick a shared one.")

  defp error_message(:restricted_not_shareable),
    do: gettext("That dashboard is limited to one role. Only shared dashboards can go here.")

  defp error_message(:pixel_not_allowed_here),
    do: gettext("A wall-screen dashboard can't be used as an admin page.")

  defp error_message(:audience_already_placed),
    do: gettext("This place already shows a dashboard for that audience.")

  defp error_message(:role_required), do: gettext("Pick a role.")
  defp error_message(:unknown_dashboard), do: gettext("Pick a dashboard.")
  defp error_message(:unknown_slot), do: gettext("That place no longer exists.")
  defp error_message(_other), do: gettext("That didn't work. Try again.")

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Same page container as every other admin page here, and no in-page
    <h1>: the admin header breadcrumb already shows @page_title, so the page
    reclaims the space (workspace canon — see DashboardsLive). --%>
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <.admin_page_header subtitle={gettext("Choose which dashboard appears where, and who sees it.")}>
        <:actions>
          <form phx-change="search" phx-submit="search">
            <.input
              type="search"
              name="query"
              value={@query}
              placeholder={gettext("Search places")}
              class="input-sm w-56"
            />
          </form>
          <.button variant="outline" size="sm" navigate={Paths.index()}>
            {gettext("All dashboards")}
          </.button>
        </:actions>
      </.admin_page_header>

      <div :if={@error} class="alert alert-error py-2 text-sm">{@error}</div>

      <div :if={@problems != []} class="alert alert-warning flex-col items-start gap-1 py-2">
        <span class="text-sm font-medium">{gettext("Some places need attention")}</span>
        <span :for={problem <- @problems} class="text-xs">
          {problem_text(problem)}
        </span>
      </div>

      <div :if={@groups == []} class="card bg-base-100 shadow-xl border-2 border-dashed border-base-300">
        <div class="card-body items-center gap-1 py-10 text-center">
          <.icon name="hero-rectangle-group" class="h-8 w-8 opacity-40" />
          <p class="text-sm opacity-70">
            {gettext("No module offers a place for a dashboard yet.")}
          </p>
        </div>
      </div>

      <section :for={{label, slots} <- @groups} class="flex flex-col gap-2">
        <h2 class="text-xs font-semibold uppercase tracking-wide opacity-60">{label}</h2>

        <.place_card
          :for={slot <- slots}
          slot={slot}
          open={@open_slot == slot.key}
          rows={rows_for(@placements, slot)}
          shareable={@shareable}
          roles={@roles}
          form_audience={@form_audience}
        />
      </section>
    </div>
    """
  end

  attr(:slot, :map, required: true)
  attr(:open, :boolean, required: true)
  attr(:rows, :list, required: true)
  attr(:shareable, :list, required: true)
  attr(:roles, :list, required: true)
  attr(:form_audience, :string, required: true)

  defp place_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body gap-3 p-4">
        <div class="flex flex-wrap items-center gap-2">
          <.icon name={@slot.icon} class="h-5 w-5 opacity-70" />
          <div class="min-w-0">
            <.link
              :if={@slot.surface == :module_tab}
              navigate={Paths.slot(@slot.slug)}
              class="block truncate font-medium hover:text-primary"
            >
              {Slot.localized_name(@slot)}
            </.link>
            <p :if={@slot.surface != :module_tab} class="truncate font-medium">
              {Slot.localized_name(@slot)}
            </p>
            <p :if={@slot.description} class="truncate text-xs opacity-60">
              {Slot.localized_description(@slot)}
            </p>
          </div>
          <div class="grow"></div>
          <span :if={@slot.provides != []} class="badge badge-ghost badge-sm">
            {subject_badge(@slot)}
          </span>
          <.button
            variant="outline"
            size="sm"
            phx-click={if @open, do: "close", else: "open"}
            phx-value-slot={@slot.key}
          >
            {if @open, do: gettext("Done"), else: gettext("Change")}
          </.button>
        </div>

        <%!-- The company-wide answer first, then role exceptions: the order
        people read them in, and the order they resolve in. --%>
        <p :if={@rows == []} class="text-sm opacity-60">
          {gettext("Nothing shown here — people see this module's normal page.")}
        </p>

        <ul :if={@rows != []} class="flex flex-col gap-1">
          <li :for={row <- @rows} class="flex flex-wrap items-center gap-2 text-sm">
            <span class="badge badge-sm">{row.audience_label}</span>
            <.link
              :if={row.dashboard_uuid}
              navigate={Paths.builder(row.dashboard_uuid)}
              class="min-w-0 truncate hover:text-primary"
            >
              {row.title}
            </.link>
            <span :if={is_nil(row.dashboard_uuid)} class="min-w-0 truncate">{row.title}</span>
            <span :if={row.audience == "role"} class="text-xs opacity-60">
              {gettext("priority")} {row.priority}
            </span>
            <div class="grow"></div>
            <.button
              :if={@open}
              variant="error"
              size="xs"
              phx-click="unplace"
              phx-value-slot={@slot.key}
              phx-value-audience={row.audience}
              phx-value-role_uuid={row.role_uuid}
              phx-value-dashboard_uuid={row.dashboard_uuid}
            >
              {gettext("Remove")}
            </.button>
          </li>
        </ul>

        <form :if={@open} phx-submit="place" phx-change="set_audience" class="flex flex-wrap items-end gap-2 border-t border-base-200 pt-3">
          <input type="hidden" name="slot" value={@slot.key} />

          <label class="form-control">
            <span class="label-text text-xs">{gettext("Who sees it")}</span>
            <select name="audience" class="select select-sm select-bordered">
              <option value="everyone" selected={@form_audience == "everyone"}>
                {gettext("Everyone")}
              </option>
              <option value="role" selected={@form_audience == "role"}>
                {gettext("A role")}
              </option>
            </select>
          </label>

          <label :if={@form_audience == "role"} class="form-control">
            <span class="label-text text-xs">{gettext("Role")}</span>
            <select name="role_uuid" class="select select-sm select-bordered">
              <option value="">{gettext("Pick a role")}</option>
              <option :for={role <- @roles} value={role.uuid}>{role.name}</option>
            </select>
          </label>

          <label :if={@form_audience == "role"} class="form-control w-24">
            <span class="label-text text-xs">{gettext("Priority")}</span>
            <input type="number" name="priority" value="100" class="input input-sm input-bordered" />
          </label>

          <label class="form-control min-w-56">
            <span class="label-text text-xs">{gettext("Dashboard")}</span>
            <select name="dashboard_uuid" class="select select-sm select-bordered">
              <option value="">{gettext("Pick a dashboard")}</option>
              <option :for={dashboard <- @shareable} value={dashboard.uuid}>
                {dashboard.title}
              </option>
            </select>
          </label>

          <.button type="submit" size="sm">{gettext("Show it here")}</.button>
        </form>

        <p :if={@open and @slot.provides != []} class="text-xs opacity-60">
          {gettext("Widgets on this page can follow whatever this page is about.")}
        </p>
      </div>
    </div>
    """
  end

  # Rows are the shared placements only. A personal placement lives on the
  # person's own dashboard and is theirs to manage — listing everyone's here
  # would turn this screen into a directory of private canvases.
  defp rows_for(placements, %Slot{key: key}) do
    placements
    |> Map.get(key, [])
    |> Enum.sort_by(&{audience_order(&1), &1["priority"] || 100, &1["position"] || 0})
    |> Enum.map(fn placement ->
      dashboard = Dashboards.get(placement["dashboard_uuid"])

      %{
        audience: placement["audience"],
        audience_label: audience_label(placement),
        role_uuid: placement["role_uuid"],
        priority: placement["priority"] || 100,
        dashboard_uuid: placement["dashboard_uuid"],
        title:
          placement["label"] || (dashboard && dashboard.title) ||
            gettext("(deleted dashboard)")
      }
    end)
  end

  defp audience_order(%{"audience" => "everyone"}), do: 0
  defp audience_order(_placement), do: 1

  defp audience_label(%{"audience" => "everyone"}), do: gettext("Everyone")

  defp audience_label(%{"audience" => "role", "role_uuid" => uuid}) do
    case Enum.find(Helpers.list_roles(), &(&1.uuid == uuid)) do
      nil -> gettext("A role")
      role -> role.name
    end
  end

  defp audience_label(_placement), do: gettext("Everyone")

  # Deliberately says nothing about WHICH subject. Interpolating the context
  # key's last segment put a raw English word ("project") inside an otherwise
  # translated sentence, which reads worse in et/ru than a generic phrase.
  defp subject_badge(%Slot{}), do: gettext("about one record")

  defp problem_text(%{slot_key: slot_key, problem: :dashboard_gone}),
    do: gettext("%{place}: the dashboard it showed was deleted.", place: slot_key)

  defp problem_text(%{slot_key: slot_key, problem: :slot_gone}),
    do: gettext("%{place}: this place no longer exists.", place: slot_key)

  defp problem_text(%{slot_key: slot_key, problem: :slot_unavailable}),
    do: gettext("%{place}: its module is turned off.", place: slot_key)

  defp problem_text(%{slot_key: slot_key}), do: slot_key
end
