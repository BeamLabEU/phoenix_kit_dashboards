defmodule PhoenixKitDashboards.Paths do
  @moduledoc """
  Centralized path helpers for the Dashboards module.

  All paths route through `PhoenixKit.Utils.Routes.path/1` so they honor the host
  app's PhoenixKit URL prefix and locale. Never hardcode `/admin/dashboards`.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/dashboards"

  @doc "List of dashboards (manage page)."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @doc "The builder/editor for a single dashboard."
  @spec builder(String.t()) :: String.t()
  def builder(uuid), do: Routes.path("#{@base}/#{uuid}")

  @doc "The create-dashboard page."
  @spec new() :: String.t()
  def new, do: Routes.path("#{@base}/new")

  @doc "The settings/edit page for a single dashboard."
  @spec edit(String.t()) :: String.t()
  def edit(uuid), do: Routes.path("#{@base}/#{uuid}/edit")

  @doc """
  The **Places** page — the one screen listing every slot a dashboard can be
  shown in, and which dashboard fills each for whom.

  Named "places" rather than "slots" or "placements" because the URL is user
  visible and the UI never uses the internal vocabulary.
  """
  @spec places() :: String.t()
  def places, do: Routes.path("#{@base}/places")

  @doc """
  The route prefix a `:module_tab` slot's page lives under, relative to
  `/admin` — `"dashboards/places"`.

  A slot's page belongs to THIS module's namespace, not the declaring
  module's: routes are emitted per module in discovery order and Phoenix
  matches in definition order, so `projects/dashboard` is swallowed by that
  module's own dynamic `projects/:id` and renders its show page against the
  literal id "dashboard". Two segments also keep it clear of our own
  `dashboards/:uuid`.
  """
  @spec slot_segment() :: String.t()
  def slot_segment, do: "dashboards/places"

  @doc "The page showing whatever fills one place."
  @spec slot(String.t()) :: String.t()
  def slot(slug), do: Routes.path("#{@base}/places/#{slug}")
end
