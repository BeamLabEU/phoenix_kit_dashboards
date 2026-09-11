defmodule PhoenixKitDashboards.Slots do
  @moduledoc """
  Discovers and caches the **slot** catalog — every place a dashboard can be
  shown.

  Convention-based discovery, identical in shape to
  `PhoenixKitDashboards.Registry`: queries `PhoenixKit.ModuleRegistry` at
  runtime and calls `phoenix_kit_dashboard_slots/0` on any module exporting it
  (always including this one, which declares the admin-home slot). No new core
  callback, no dependency in either direction.

  Host apps that are not PhoenixKit modules declare providers in config:

      config :phoenix_kit_dashboards, slot_providers: [MyApp.Slots]

  ## Cache freshness

  Same contract as the widget catalog. The catalog **structure** is memoized in
  `:persistent_term`, so a newly installed provider or a changed slot
  declaration needs `refresh/0`. Module **enablement** and scope **permission**
  are re-checked live on every read, so toggling a module hides its slots
  immediately.

  `refresh/0` also rebuilds the widget catalog's sibling, because a slot and
  its module's widgets appear and disappear together.
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Paths
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Slot
  alias PhoenixKitDashboards.Web.Helpers

  @pt_key {__MODULE__, :catalog}
  @provider_callback :phoenix_kit_dashboard_slots

  @doc """
  The full slot catalog, keyed by slot key. Memoized; first call builds it.
  """
  @spec catalog() :: %{String.t() => Slot.t()}
  def catalog do
    case :persistent_term.get(@pt_key, :miss) do
      :miss -> refresh()
      catalog -> catalog
    end
  end

  @doc "Every declared slot, ordered by priority then name."
  @spec list() :: [Slot.t()]
  def list do
    catalog()
    |> Map.values()
    |> Enum.sort_by(&{&1.priority, &1.name})
  end

  @doc """
  Slots visible to a scope — the owning module enabled, and the viewer holding
  its permission. `nil` scope skips the permission half.
  """
  @spec list_for_scope(scope :: term() | nil) :: [Slot.t()]
  def list_for_scope(nil), do: list()
  def list_for_scope(scope), do: Enum.filter(list(), &visible_for_scope?(&1, scope))

  @doc """
  Slots grouped for the control screen: `[{provider_label, [slot]}]`, ordered
  by the first slot's priority in each group.

  Grouping is by the module that DECLARED the slot, which is what someone
  scanning for "where can I put a dashboard in CRM?" is looking for.
  """
  @spec grouped_for_scope(scope :: term() | nil) :: [{String.t(), [Slot.t()]}]
  def grouped_for_scope(scope) do
    scope
    |> list_for_scope()
    |> Enum.group_by(&provider_label/1)
    |> Enum.sort_by(fn {_label, slots} ->
      {slots |> Enum.map(& &1.priority) |> Enum.min(), slots |> hd() |> Map.get(:name)}
    end)
  end

  @doc "Look up one slot by key."
  @spec get(String.t()) :: Slot.t() | nil
  def get(key) when is_binary(key), do: Map.get(catalog(), key)
  def get(_key), do: nil

  @doc """
  Whether a slot is offerable to a scope: its module enabled, and the viewer
  holding that module's permission. A slot with no `module_key` is always
  visible.
  """
  @spec visible_for_scope?(Slot.t(), scope :: term() | nil) :: boolean()
  def visible_for_scope?(%Slot{module_key: nil}, _scope), do: true

  def visible_for_scope?(%Slot{module_key: key}, scope) do
    module_enabled?(key) and (is_nil(scope) or has_access?(scope, key))
  end

  @doc "Rebuild the slot catalog from every discovered provider and re-cache it."
  @spec refresh() :: %{String.t() => Slot.t()}
  def refresh do
    {modules, complete?} = provider_modules()

    catalog =
      modules
      |> provider_slots()
      |> Enum.reduce(%{}, fn slot, acc ->
        cond do
          Map.has_key?(acc, slot.key) ->
            Logger.warning(
              "[Dashboards] Duplicate slot key #{inspect(slot.key)} from " <>
                "#{inspect(slot.source)} — keeping the first registered one."
            )

            acc

          # Distinct keys can still normalize to the same slug, and therefore
          # to the same route and tab id ("sales.eu" and "sales-eu" both give
          # "sales-eu"). One would shadow the other and open the wrong
          # dashboard, so the collision is refused rather than resolved by
          # whichever module happened to load first.
          slug_taken?(acc, slot) ->
            Logger.warning(
              "[Dashboards] Slot #{inspect(slot.key)} from #{inspect(slot.source)} " <>
                "collides on slug #{inspect(slot.slug)} with an already-registered " <>
                "slot — dropping it."
            )

            acc

          true ->
            Map.put(acc, slot.key, slot)
        end
      end)

    # Only CACHE a catalog built from a complete module list. `admin_tabs/0`
    # runs at router-COMPILE time, when the runtime registry is still empty —
    # memoizing that answer would pin an empty catalog for the life of the
    # BEAM and no module's slots would ever appear.
    if complete?, do: :persistent_term.put(@pt_key, catalog)
    catalog
  end

  @doc """
  The sidebar sub-tabs generated by every `:module_tab` slot that currently has
  something to show.

  This is the ONLY place this module injects a tab under another module's
  sidebar entry, and it does so strictly for slots that module declared — see
  `PhoenixKitDashboards.Slot` on why the declaration is the consent.

  Called from `admin_tabs/0`, so it must never raise: a failure here would
  take the whole admin sidebar down.
  """
  @spec module_tabs() :: [struct()]
  def module_tabs do
    for %Slot{surface: :module_tab} = slot <- list(), not is_nil(slot.parent_tab) do
      tab(slot)
    end
  rescue
    e ->
      Logger.warning("[Dashboards] Slot tab generation failed: #{Exception.message(e)}")
      []
  end

  defp tab(%Slot{} = slot) do
    %PhoenixKit.Dashboard.Tab{
      id: tab_id(slot),
      label: slot.name,
      # The label is the DECLARING module's string, so it must translate
      # through that module's catalogue — a tab with no backend renders its
      # authored English in every locale.
      gettext_backend: slot.gettext_backend,
      gettext_domain: slot.gettext_domain,
      icon: slot.icon,
      # Always under THIS package's own prefix, never inside the declaring
      # module's namespace — see `PhoenixKitDashboards.Slot`. A two-segment
      # path also cannot collide with our own dynamic `dashboards/:uuid`.
      path: slot_path(slot),
      priority: slot.priority,
      level: :admin,
      # The slot's own module gates it — a CRM dashboard tab requires CRM's
      # permission, not this module's, or someone with no Dashboards access
      # could not see a dashboard placed for them inside CRM.
      permission: slot.module_key,
      parent: slot.parent_tab,
      group: :admin_modules,
      match: :exact,
      # An EMPTY place is navigation nobody asked for: a staff member should
      # not find a "Projects dashboard" tab under Projects that only ever says
      # "nothing here". Someone who can manage dashboards still sees it, since
      # that is how they discover the place exists and fill it.
      visible: &slot_tab_visible?(slot.key, &1),
      live_view: {PhoenixKitDashboards.Web.SlotLive, :show},
      metadata: %{slot_key: slot.key}
    }
  end

  @doc false
  # Runs on EVERY sidebar render, so it stays to one cached settings read and a
  # permission check — no dashboard loads, no per-slot queries.
  @spec slot_tab_visible?(String.t(), map() | nil) :: boolean()
  def slot_tab_visible?(slot_key, scope) do
    Placements.any_for_slot?(slot_key) or personal_here?(slot_key, scope)
  rescue
    # Never hide a tab because a check blew up — an unexpectedly missing tab is
    # harder to diagnose than an empty one.
    _ -> true
  end

  # A shared placement is a cached settings read, but a PERSONAL one lives on
  # the person's own dashboard rows. Someone whose only board here is their own
  # must still get the tab — hiding it would strand a dashboard they can reach
  # nowhere else — so the query happens, memoized per process for the render so
  # a sidebar with several slots costs one lookup rather than one each.
  defp personal_here?(slot_key, scope) do
    case Helpers.scope_actor_uuid(scope) do
      nil -> false
      uuid -> slot_key in personal_slots(uuid)
    end
  end

  defp personal_slots(user_uuid) do
    case Process.get({__MODULE__, :personal_slots, user_uuid}) do
      nil ->
        slots =
          user_uuid
          |> Dashboards.list_for_user([])
          |> Enum.filter(&(&1.scope == "personal" and &1.owner_user_uuid == user_uuid))
          |> Enum.map(&Placements.slot_of/1)
          |> Enum.reject(&is_nil/1)

        Process.put({__MODULE__, :personal_slots, user_uuid}, slots)
        slots

      slots ->
        slots
    end
  rescue
    _ -> []
  end

  @doc """
  The tab id generated for a `:module_tab` slot.

  Derived from the slot key so it is stable across restarts and unique per
  slot. Deliberately `String.to_atom/1`: slot keys come from installed module
  code, not from user input, and the set is bounded by the number of declared
  slots.
  """
  @spec tab_id(Slot.t()) :: atom()
  def tab_id(%Slot{key: key}), do: String.to_atom("admin_dash_slot_" <> slug(key))

  defp slug(key), do: String.replace(key, ~r/[^a-zA-Z0-9]+/, "_")

  @doc "The generated route path for a `:module_tab` slot."
  @spec slot_path(Slot.t()) :: String.t()
  def slot_path(%Slot{slug: slug}), do: Paths.slot_segment() <> "/" <> slug

  defp slug_taken?(acc, %Slot{} = slot) do
    Enum.any?(acc, fn {_key, existing} -> existing.slug == slot.slug end)
  end

  # ── Discovery ──────────────────────────────────────────────────────

  defp provider_slots(modules) do
    modules
    |> Enum.flat_map(fn module ->
      module
      |> safe_slots()
      |> Enum.flat_map(&normalize(&1, module))
    end)
  end

  # Returns `{modules, complete?}`. Two discovery sources, deliberately:
  #
  #   * `ModuleRegistry.all_modules/0` — the runtime list, a `:persistent_term`
  #     populated when the app boots.
  #   * `ModuleDiscovery.discover_external_modules/0` — a beam scan, which is
  #     what core itself uses to generate routes and which therefore works at
  #     COMPILE time, when the runtime list is still empty.
  #
  # The second is not redundant. Slot tabs feed `admin_tabs/0`, and core turns
  # that into ROUTES at compile time — so a slot discovered only at runtime
  # would render in the sidebar and 404 when clicked. Using the same source
  # core uses is what keeps the tab and its route in step.
  #
  # `complete?` says whether discovery actually saw the installed modules, so
  # the caller knows whether this answer is worth caching.
  defp provider_modules do
    registered = safe_registry_modules()
    scanned = safe_scanned_modules()
    discovered = Enum.uniq(registered ++ scanned)

    providers =
      ([PhoenixKitDashboards | discovered] ++ config_providers())
      |> Enum.uniq()
      # ensure_loaded? BEFORE function_exported?: on a cold VM a discovered
      # module that has not been called yet is not loaded, and
      # function_exported?/3 answers false without loading it — silently
      # dropping that module's slots. Same trap the widget registry documents.
      |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, @provider_callback, 0)))

    {providers, discovered != []}
  rescue
    e ->
      Logger.warning("[Dashboards] Slot provider discovery failed: #{Exception.message(e)}")
      {[PhoenixKitDashboards], false}
  end

  defp safe_registry_modules do
    if Code.ensure_loaded?(PhoenixKit.ModuleRegistry),
      do: PhoenixKit.ModuleRegistry.all_modules(),
      else: []
  rescue
    _ -> []
  end

  defp safe_scanned_modules do
    if Code.ensure_loaded?(PhoenixKit.ModuleDiscovery),
      do: PhoenixKit.ModuleDiscovery.discover_external_modules(),
      else: []
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp config_providers do
    :phoenix_kit_dashboards
    |> Application.get_env(:slot_providers, [])
    |> List.wrap()
    |> Enum.filter(&(is_atom(&1) and Code.ensure_loaded?(&1)))
  end

  defp safe_slots(module) do
    List.wrap(apply(module, @provider_callback, []))
  rescue
    e ->
      Logger.warning(
        "[Dashboards] #{inspect(module)}.#{@provider_callback}/0 raised: #{Exception.message(e)}"
      )

      []
  catch
    kind, reason ->
      Logger.warning(
        "[Dashboards] #{inspect(module)}.#{@provider_callback}/0 #{kind}: #{inspect(reason)}"
      )

      []
  end

  defp normalize(map, source) do
    case Slot.from_map(map, source) do
      {:ok, slot} ->
        [slot]

      {:error, reason} ->
        Logger.warning(
          "[Dashboards] Dropping invalid slot from #{inspect(source)}: #{inspect(reason)}"
        )

        []
    end
  rescue
    e ->
      Logger.warning(
        "[Dashboards] Dropping slot from #{inspect(source)} (normalize raised: #{Exception.message(e)})"
      )

      []
  end

  # ── Presentation ───────────────────────────────────────────────────

  # The heading a slot is filed under. `module_name/0` is an untranslated
  # literal, so it goes through the SLOT's own backend — the module that
  # authored the name is the one whose catalogue holds it.
  defp provider_label(%Slot{} = slot) do
    slot
    |> provider_module()
    |> module_label()
    |> localize(slot)
  end

  defp provider_module(%Slot{module_key: nil, source: source}), do: source

  defp provider_module(%Slot{module_key: key, source: source}) do
    module_by_key(key) || source
  end

  defp localize(label, %Slot{gettext_backend: nil}), do: label

  defp localize(label, %Slot{gettext_backend: backend} = slot) do
    Gettext.dgettext(backend, slot.gettext_domain, label)
  rescue
    _ -> label
  end

  defp module_label(nil), do: "General"

  defp module_label(module) do
    if function_exported?(module, :module_name, 0), do: module.module_name(), else: "General"
  rescue
    _ -> "General"
  end

  defp module_by_key(key) do
    if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
      PhoenixKit.ModuleRegistry.get_by_key(key)
    end
  rescue
    _ -> nil
  end

  # ── Visibility ─────────────────────────────────────────────────────

  defp module_enabled?(key) do
    case module_by_key(key) do
      nil -> true
      module -> safe_enabled?(module)
    end
  rescue
    _ -> true
  end

  defp safe_enabled?(module) do
    not function_exported?(module, :enabled?, 0) or module.enabled?()
  rescue
    _ -> false
  end

  defp has_access?(scope, key) do
    if Code.ensure_loaded?(Scope) do
      Scope.has_module_access?(scope, key)
    else
      true
    end
  rescue
    # Fail CLOSED — never leak a permissioned slot because access evaluation
    # blew up.
    _ -> false
  end
end
