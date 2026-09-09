defmodule PhoenixKitDashboards.Binds do
  @moduledoc """
  Resolves a placed widget's **binds** — where a setting's value comes from —
  just before the widget renders.

  ## The problem this solves

  Single-record widgets have always stored their subject as a literal in their
  own settings: "Project schedule" keeps a project uuid picked when the widget
  was placed. That makes one shared dashboard show *everybody the same
  project*, which is why a dashboard shown inside Project A and Project B
  renders identically today, and why a "Project managers" dashboard cannot give
  each manager their own project.

  ## Why the host resolves, and not the widget

  A widget provider must never need to depend on this package — that is the
  whole point of the duck-typed contract. If context arrived as a new assign
  every widget had to read, the feature would stay broken until two dozen
  module authors shipped a change. So the **host** resolves instead: it swaps
  the concrete value into `settings` before render, and the widget receives
  exactly the settings shape it always did. Every existing widget becomes
  context-aware with no change at all.

  A `context` assign is passed as well, for widgets that want the whole bag
  (see `PhoenixKitDashboards.Slot`), but nothing depends on a widget reading it.

  ## Where a bind lives

  On the layout item, **beside** `settings`, never inside it:

      %{"id" => "w1", "widget_key" => "projects.schedule",
        "settings" => %{"title" => "Deadlines"},
        "binds"    => %{"project" => "slot"}}

  Settings belong to the widget; binds belong to the host. Keeping a marker
  like `"$current"` inside a uuid-shaped settings field would be eaten the
  first time that field is validated as a uuid, and would make the settings
  form display a value the widget is not actually using.

  ## The three sources

  | Bind | Means | Resolves to |
  |---|---|---|
  | `"slot"` | "whatever this page is about" | the slot's context value |
  | `"viewer"` | "mine" | the viewer's own subject for that kind |
  | `%{"pin" => id}` | "always this one" | `id`, unchanged |

  `"viewer"` is the one that answers "each project manager sees *their*
  project": a shared dashboard on a context-free slot has no page subject, so
  a slot bind cannot help there. Resolution of a viewer bind is delegated to
  the module that owns the kind — this package has no idea what "my project"
  means and must not guess.

  A bind that cannot resolve yields `nil`, and the host renders an
  explanatory placeholder rather than hiding the widget (a hidden widget reads
  as deleted and leaves a hole in the grid) or falling back to some first
  record (which is how one tenant's data ends up in another's screenshot).
  """

  require Logger

  alias PhoenixKitDashboards.Registry
  alias PhoenixKitDashboards.Widget

  @viewer_callback :phoenix_kit_dashboard_viewer_context

  @doc """
  Resolve one layout item's binds against a render context.

  Returns `{settings, unresolved}` — the settings map to hand the widget, and
  the list of context kinds that could not be resolved. A non-empty
  `unresolved` is what makes the host draw the "needs a project" placeholder.

  `context` is `%{kind => value}`, e.g. `%{"projects.project" => uuid}`.
  """
  @spec resolve(map(), map(), map() | nil) :: {map(), [String.t()]}
  def resolve(item, context, scope) when is_map(item) do
    settings = Map.get(item, "settings") || %{}

    case binds(item) do
      empty when empty == %{} ->
        {settings, []}

      binds ->
        widget = Registry.get(item["widget_key"])

        Enum.reduce(binds, {settings, []}, fn {kind, source}, {acc, missing} ->
          field = settings_field(widget, kind)

          case resolve_one(kind, source, context, scope) do
            nil when is_binary(field) -> {Map.put(acc, field, nil), [kind | missing]}
            nil -> {acc, [kind | missing]}
            value when is_binary(field) -> {Map.put(acc, field, value), missing}
            _value -> {acc, missing}
          end
        end)
        |> then(fn {acc, missing} -> {acc, Enum.reverse(missing)} end)
    end
  end

  @doc """
  The binds map stored on a layout item, normalized. `%{}` when absent.
  """
  @spec binds(map()) :: %{String.t() => term()}
  def binds(item) when is_map(item) do
    case Map.get(item, "binds") do
      %{} = binds -> Map.new(binds, fn {k, v} -> {to_string(k), v} end)
      _ -> %{}
    end
  end

  def binds(_item), do: %{}

  @doc """
  Set (or clear, with `nil`) one bind on a layout item.

  `source` is `"slot"`, `"viewer"`, or `{"pin", id}` / `%{"pin" => id}`.
  """
  @spec put_bind(map(), String.t(), term() | nil) :: map()
  def put_bind(item, kind, nil) when is_map(item) and is_binary(kind) do
    case Map.drop(binds(item), [kind]) do
      empty when empty == %{} -> Map.delete(item, "binds")
      rest -> Map.put(item, "binds", rest)
    end
  end

  def put_bind(item, kind, source) when is_map(item) and is_binary(kind) do
    Map.put(item, "binds", Map.put(binds(item), kind, normalize_source(source)))
  end

  @doc """
  The context kinds a placed widget needs but the given slot does not supply.

  Used by the control screen to refuse an incompatible binding, and by the
  builder to badge a dashboard as "needs a project" before it is placed
  anywhere.
  """
  @spec unsatisfied(map(), [String.t()]) :: [String.t()]
  def unsatisfied(item, provided) when is_map(item) and is_list(provided) do
    for {kind, source} <- binds(item),
        source == "slot",
        kind not in provided,
        do: kind
  end

  @doc """
  Every context kind a dashboard's layout binds to the slot.

  A dashboard whose result is `[]` fits anywhere; one that returns
  `["projects.project"]` only belongs in a slot providing a project.
  """
  @spec required_kinds([map()]) :: [String.t()]
  def required_kinds(layout) when is_list(layout) do
    layout
    |> Enum.flat_map(fn item ->
      for {kind, source} <- binds(item), source == "slot", do: kind
    end)
    |> Enum.uniq()
  end

  def required_kinds(_layout), do: []

  # ── Resolution ─────────────────────────────────────────────────────

  defp resolve_one(kind, "slot", context, _scope), do: get_context(context, kind)

  defp resolve_one(kind, "viewer", _context, scope), do: viewer_value(kind, scope)

  defp resolve_one(_kind, %{"pin" => id}, _context, _scope) when is_binary(id), do: id
  defp resolve_one(_kind, {"pin", id}, _context, _scope) when is_binary(id), do: id
  defp resolve_one(_kind, _source, _context, _scope), do: nil

  defp get_context(context, kind) when is_map(context) do
    case Map.get(context, kind) || Map.get(context, String.to_atom(kind)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  rescue
    # An unknown atom key simply is not present.
    ArgumentError -> nil
  end

  defp get_context(_context, _kind), do: nil

  # "My project" is knowledge only the owning module has: it might be the
  # user's single managed project, an explicit default they set, or nothing at
  # all. Asking the module keeps that decision where the data is, and keeps
  # this package from guessing (a "most recently visited" guess is wrong every
  # Monday morning). Duck-typed, like every other contract here.
  defp viewer_value(kind, scope) do
    kind
    |> owner_module()
    |> case do
      nil ->
        nil

      module ->
        if Code.ensure_loaded?(module) and function_exported?(module, @viewer_callback, 2) do
          case apply(module, @viewer_callback, [kind, scope]) do
            value when is_binary(value) and value != "" -> value
            _ -> nil
          end
        end
    end
  rescue
    e ->
      Logger.warning("[Dashboards] viewer context for #{kind} failed: #{Exception.message(e)}")
      nil
  catch
    _kind, _reason -> nil
  end

  # A context kind is namespaced by the module key that owns it
  # ("projects.project" -> the module registered under "projects").
  defp owner_module(kind) do
    with [module_key | _] <- String.split(kind, "."),
         true <- Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
      PhoenixKit.ModuleRegistry.get_by_key(module_key)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Which settings field a bind writes into. A provider marks the field by
  # declaring `context: "<kind>"` on it in `settings_schema`; absent that, a
  # field whose key matches the kind's last segment is used, which is what
  # every current provider already names it ("project").
  defp settings_field(%Widget{settings_schema: schema}, kind) do
    tail = kind |> String.split(".") |> List.last()

    declared = Enum.find(schema, fn field -> field[:context] == kind end)

    cond do
      declared -> declared.key
      field = Enum.find(schema, &(&1.key == tail)) -> field.key
      field = Enum.find(schema, &(&1.key == tail <> "_uuid")) -> field.key
      true -> nil
    end
  end

  defp settings_field(_widget, _kind), do: nil

  defp normalize_source("slot"), do: "slot"
  defp normalize_source("viewer"), do: "viewer"
  defp normalize_source(%{"pin" => id}) when is_binary(id), do: %{"pin" => id}
  defp normalize_source({"pin", id}) when is_binary(id), do: %{"pin" => id}
  defp normalize_source(id) when is_binary(id), do: %{"pin" => id}
  defp normalize_source(_other), do: "slot"
end
