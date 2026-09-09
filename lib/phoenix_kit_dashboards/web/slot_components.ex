defmodule PhoenixKitDashboards.Web.SlotComponents do
  @moduledoc """
  The chrome around a dashboard rendered **in a slot** — the header, the
  several-dashboards switcher, the empty state and the board frame.

  Shared by `Web.SlotLive` (a module's dashboard tab) and the admin home, so
  the two surfaces cannot drift apart in how they name things or where the
  edit affordance sits.

  ## One horizontal tab strip, ever

  A dashboard already draws a tab strip for its own named layouts ("Layout 1",
  "Wall TV"). Putting a second strip above it — one meaning "which dashboard",
  one meaning "which layout of this dashboard" — is a collision every panel
  seat independently flagged, and people would click the wrong row for a year.
  So when a slot holds several dashboards they render as the strip, and the
  layout picker degrades to a compact `Layout: …` select inside the board.
  """

  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitDashboards.Gettext

  import PhoenixKitDashboards.Web.BuilderComponents, only: [grid_mode: 1, free_mode: 1]

  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Slot
  alias PhoenixKitDashboards.Web.Helpers

  attr(:slot, :any, required: true)
  attr(:dashboards, :list, required: true)
  attr(:active_index, :integer, required: true)
  attr(:tier, :atom, required: true)
  attr(:active, :map, required: true)
  attr(:scope, :any, default: nil)

  def slot_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <%!-- Several dashboards in one slot: THIS is the page's only tab strip. --%>
      <div
        :if={length(@dashboards) > 1}
        role="tablist"
        aria-label={gettext("Dashboards")}
        class="flex min-w-0 flex-nowrap items-center gap-1 overflow-x-auto overflow-y-hidden"
      >
        <button
          :for={{dashboard, index} <- Enum.with_index(@dashboards)}
          type="button"
          role="tab"
          aria-selected={to_string(index == @active_index)}
          phx-click="select_dashboard"
          phx-value-index={index}
          class={[
            "btn btn-sm max-w-48 shrink-0",
            if(index == @active_index, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          <span class="truncate">{dashboard.title}</span>
        </button>
      </div>

      <h3 :if={length(@dashboards) <= 1} class="min-w-0 grow truncate font-semibold">
        {@active.title}
      </h3>
      <div :if={length(@dashboards) > 1} class="grow"></div>

      <%!-- Which rule won. Only shown when it is not the plain company-wide
      answer, because "Everyone" on every page is noise; "Yours" and the role
      name are the ones that explain why your page differs from a colleague's. --%>
      <span :if={tier_label(@tier)} class="badge badge-ghost badge-sm shrink-0">
        {tier_label(@tier)}
      </span>

      <.link
        :if={Helpers.manageable_by?(@active, Helpers.scope_actor_uuid(@scope))}
        navigate={Paths.builder(@active.uuid)}
        class="btn btn-ghost btn-sm shrink-0 gap-1"
      >
        <.icon name="hero-pencil-square" class="h-4 w-4" />
        {gettext("Edit layout")}
      </.link>
    </div>
    """
  end

  attr(:slot, :any, default: nil)
  attr(:scope, :any, default: nil)

  def slot_empty(assigns) do
    ~H"""
    <div class="card border border-dashed border-base-300 bg-base-100">
      <div class="card-body items-center gap-2 py-10 text-center">
        <.icon name="hero-squares-2x2" class="h-8 w-8 opacity-40" />
        <p class="text-sm opacity-70">
          {gettext("No dashboard is shown here yet.")}
        </p>
        <.link :if={@slot} navigate={Paths.places()} class="btn btn-sm btn-primary">
          {gettext("Choose a dashboard")}
        </.link>
      </div>
    </div>
    """
  end

  attr(:active, :map, required: true)
  attr(:mode, :string, required: true)
  attr(:active_layout, :any, required: true)
  attr(:design_h, :integer, required: true)
  attr(:context, :map, default: %{})
  attr(:id_prefix, :string, default: "")
  attr(:scope, :any, default: nil)

  def slot_board(assigns) do
    ~H"""
    <div
      :if={@mode == "grid"}
      class="flex flex-col overflow-hidden rounded-lg border border-base-200"
      style={"height: min(80vh, #{@design_h + 40}px);"}
    >
      <.grid_mode
        dashboard={@active}
        scope={@scope}
        active_layout={@active_layout}
        show_grid_lines={false}
        empty={@active.layout == []}
        readonly
        id_prefix={@id_prefix}
        context={@context}
      />
    </div>
    <div
      :if={@mode == "free"}
      class="flex flex-col overflow-hidden rounded-lg border border-base-200"
      style="height: 75vh;"
    >
      <.free_mode
        dashboard={@active}
        scope={@scope}
        readonly
        id_prefix={@id_prefix}
        context={@context}
      />
    </div>
    """
  end

  @doc """
  Human name for the audience rule that won, or `nil` for the company-wide
  default (which needs no label).
  """
  @spec tier_label(atom()) :: String.t() | nil
  def tier_label(:personal), do: gettext("Yours")
  def tier_label(:role), do: gettext("For your role")
  def tier_label(_tier), do: nil

  @doc "Whether a slot may hold more than one dashboard (drives the strip)."
  @spec many?(Slot.t() | nil) :: boolean()
  def many?(%Slot{} = slot), do: Slot.many?(slot)
  def many?(_slot), do: false
end
