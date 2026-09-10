defmodule PhoenixKitDashboards.Slot do
  @moduledoc """
  A **place** a dashboard can be shown, and the plain-map provider contract
  that declares one.

  A slot is the counterpart of `PhoenixKitDashboards.Widget`: a widget is
  content a module contributes *into* a dashboard; a slot is a hole a module
  offers *for* a dashboard. Both are duck-typed — a provider defines a
  zero-arity function returning plain maps and never depends on this package:

      def phoenix_kit_dashboard_slots do
        [%{key: "crm.overview", name: "CRM overview", surface: :module_tab,
           parent_tab: :admin_crm}]
      end

  ## The URL belongs to this package, the placement to the declaring module

  A `:module_tab` slot says WHERE in the sidebar its tab appears (`parent_tab`)
  and this package decides the URL — always under its own `dashboards/` prefix.
  A slot must not name a path inside the declaring module's namespace: routes
  are generated per module in declaration order, so a `projects/dashboard`
  would be swallowed by that module's own dynamic `projects/:id` route and
  render its show page against the literal id `"dashboard"`. The sidebar
  position comes from `parent_tab`, which is independent of the URL, so
  nothing is lost by keeping the two separate.

  ## Declaring a slot is consent

  This module *could* inject a sub-tab under any module's sidebar entry without
  asking — core groups sub-tabs by matching a parent id across every module's
  tabs, with no ownership check. It deliberately does not. A module that has
  not declared a slot gets no dashboard tab, so a module always owns its own
  navigation and can say "we have our own overview, don't". The declaration is
  the handshake; the parent-id mechanism is only how it is implemented.

  ## Fields

  | Key | Required | Meaning |
  |---|---|---|
  | `key` | yes | Globally unique slot key (`"projects.project"`). |
  | `name` | yes | Plain-language name shown in the control screen ("Project page"). |
  | `surface` | no | `:module_tab` (a sub-tab in the sidebar under `parent_tab`), `:record_tab` (a tab inside one record's page, rendered by the owning module), or `:admin_home`. Default `:module_tab`. |
  | `parent_tab` | for `:module_tab` | The sidebar tab id to hang the child under (`:admin_crm`). |
  | `slug` | no | Last URL segment for the generated tab. Defaults to the slot key. |
  | `module_key` | no | Gates the slot on that module's enablement + permission. |
  | `provides` | no | Context kinds this slot supplies at render, e.g. `["projects.project"]`. Empty = a context-free slot. |
  | `cardinality` | no | `:one` (default) or `:many` — whether several dashboards may be bound here and shown as tabs. |
  | `allow_personal` | no | Whether a person may fork their own copy here. Default `true`. |
  | `allow_blank` | no | Whether "everyone builds their own" is offered. Default `false`. |
  | `chrome` | no | `:view` (default) or `:builder` — how much editing chrome the embedded render shows. |
  | `icon`, `description`, `priority` | no | Presentation in the control screen and the generated tab. |
  | `gettext_backend` / `gettext_domain` | no | Translate `name` (and the generated tab's label) through the DECLARING module's own catalogue. Without a backend the name renders in whatever language it was authored in, for every locale. |

  `provides` names **context kinds**, not field names. A kind is a namespaced
  string owned by the module that defines the record (`"projects.project"`),
  so two modules cannot disagree about what `"project"` means. The value
  supplied at render is an id, never a struct — a widget re-loads and
  re-authorizes the record itself against the viewer's own scope. **A slot's
  context is a selection, not a permission grant.**
  """

  @type surface :: :module_tab | :record_tab | :admin_home

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          description: String.t() | nil,
          icon: String.t(),
          surface: surface(),
          parent_tab: atom() | nil,
          slug: String.t(),
          module_key: String.t() | nil,
          gettext_backend: module() | nil,
          gettext_domain: String.t(),
          provides: [String.t()],
          cardinality: :one | :many,
          allow_personal: boolean(),
          allow_blank: boolean(),
          chrome: :view | :builder,
          priority: integer(),
          source: module() | nil
        }

  @enforce_keys [:key, :name]
  defstruct key: nil,
            name: nil,
            description: nil,
            icon: "hero-rectangle-group",
            surface: :module_tab,
            parent_tab: nil,
            slug: nil,
            module_key: nil,
            gettext_backend: nil,
            gettext_domain: "default",
            provides: [],
            cardinality: :one,
            allow_personal: true,
            allow_blank: false,
            chrome: :view,
            priority: 500,
            source: nil

  @surfaces [:module_tab, :record_tab, :admin_home]
  @cardinalities [:one, :many]
  @chromes [:view, :builder]

  @doc """
  Normalize a provider-supplied plain map into a `%Slot{}`.

  Returns `{:ok, slot}` or `{:error, reason}`. Mirrors
  `PhoenixKitDashboards.Widget.from_map/2`: one malformed entry is dropped and
  logged by the registry, never allowed to abort discovery.
  """
  @spec from_map(term(), source :: module()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map, source) do
    map = Map.new(map, fn {k, v} -> {to_atom_key(k), v} end)

    with {:ok, key} <- fetch(map, :key),
         true <- is_binary(key) or is_atom(key) or {:error, {:invalid_key, key}},
         {:ok, name} <- fetch(map, :name),
         true <- is_binary(name) or is_atom(name) or {:error, {:invalid_name, name}},
         surface when surface in @surfaces <- normalize_surface(map[:surface]),
         :ok <- validate_surface(surface, map) do
      {:ok,
       %__MODULE__{
         key: to_string(key),
         name: to_string(name),
         description: map[:description],
         icon: map[:icon] || "hero-rectangle-group",
         surface: surface,
         parent_tab: normalize_parent(map[:parent_tab]),
         slug: slug(map[:slug] || key),
         module_key: map[:module_key] && to_string(map[:module_key]),
         # The name belongs to the DECLARING module, so it translates through
         # that module's catalogue — the same way a tab or a permission label
         # does. This package cannot hold msgids for strings other packages
         # author.
         gettext_backend: backend(map[:gettext_backend]),
         gettext_domain: map[:gettext_domain] || "default",
         provides: normalize_provides(map[:provides]),
         cardinality: one_of(map[:cardinality], @cardinalities, :one),
         allow_personal: bool(map[:allow_personal], true),
         allow_blank: bool(map[:allow_blank], false),
         chrome: one_of(map[:chrome], @chromes, :view),
         priority: int(map[:priority], 500),
         source: source
       }}
    else
      {:error, _} = err -> err
      false -> {:error, :invalid_slot}
      other when other not in @surfaces -> {:error, {:invalid_surface, other}}
    end
  end

  def from_map(_other, _source), do: {:error, :not_a_map}

  @doc """
  Whether this slot supplies the given context kind.

  Used both by the control screen (to decide which dashboards may be bound
  here) and by the bind resolver at render.
  """
  @spec provides?(t(), String.t()) :: boolean()
  def provides?(%__MODULE__{provides: provides}, kind) when is_binary(kind),
    do: kind in provides

  def provides?(%__MODULE__{}, _kind), do: false

  @doc """
  The slot's name in the viewer's language.

  Translated through the DECLARING module's backend, since that is where the
  msgid lives. Falls back to the authored string when a provider declares no
  backend.
  """
  @spec localized_name(t()) :: String.t()
  def localized_name(%__MODULE__{gettext_backend: nil, name: name}), do: name

  def localized_name(%__MODULE__{gettext_backend: backend} = slot) do
    Gettext.dgettext(backend, slot.gettext_domain, slot.name)
  rescue
    _ -> slot.name
  end

  @doc "The slot's description in the viewer's language, or `nil`."
  @spec localized_description(t()) :: String.t() | nil
  def localized_description(%__MODULE__{description: nil}), do: nil
  def localized_description(%__MODULE__{gettext_backend: nil, description: d}), do: d

  def localized_description(%__MODULE__{gettext_backend: backend} = slot) do
    Gettext.dgettext(backend, slot.gettext_domain, slot.description)
  rescue
    _ -> slot.description
  end

  @doc "Whether more than one dashboard may be bound to this slot."
  @spec many?(t()) :: boolean()
  def many?(%__MODULE__{cardinality: :many}), do: true
  def many?(%__MODULE__{}), do: false

  # ── Validation ─────────────────────────────────────────────────────

  # A :module_tab slot generates a sidebar tab, so it needs somewhere to hang.
  # A :record_tab is rendered by the owning module inside its own page, and
  # :admin_home is core's landing — neither generates a tab here.
  defp validate_surface(:module_tab, map) do
    cond do
      is_nil(map[:parent_tab]) -> {:error, :module_tab_needs_parent_tab}
      not is_atom(map[:parent_tab]) -> {:error, {:invalid_parent_tab, map[:parent_tab]}}
      true -> :ok
    end
  end

  defp validate_surface(_surface, _map), do: :ok

  # ── Normalizers ────────────────────────────────────────────────────

  defp normalize_surface(nil), do: :module_tab
  defp normalize_surface(value) when value in @surfaces, do: value

  defp normalize_surface(value) when is_binary(value) do
    Enum.find(@surfaces, :invalid, &(to_string(&1) == value))
  end

  defp normalize_surface(other), do: other

  # URL-safe, and stable across restarts because it is derived from the key.
  defp slug(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  defp backend(module) when is_atom(module) and not is_nil(module), do: module
  defp backend(_other), do: nil

  defp normalize_parent(nil), do: nil
  defp normalize_parent(atom) when is_atom(atom), do: atom
  defp normalize_parent(_), do: nil

  # Context kinds are namespaced strings. Anything else in the list is junk
  # from a provider and is dropped rather than poisoning compatibility checks.
  # `nil` is an atom, so the bare-kind clause below would turn an ABSENT
  # `provides` into `[""]` — a phantom context kind that no slot can ever
  # supply and that would render as an empty "about a" badge. Match it first.
  defp normalize_provides(nil), do: []

  defp normalize_provides(list) when is_list(list) do
    for kind <- list, kind not in [nil, ""], is_binary(kind) or is_atom(kind), do: to_string(kind)
  end

  defp normalize_provides(kind) when is_binary(kind) or is_atom(kind) do
    case to_string(kind) do
      "" -> []
      value -> [value]
    end
  end

  defp normalize_provides(_), do: []

  defp one_of(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp one_of(value, allowed, default) when is_binary(value) do
    Enum.find(allowed, default, &(to_string(&1) == value))
  end

  defp one_of(_value, _allowed, default), do: default

  defp bool(value, _default) when is_boolean(value), do: value
  defp bool(_value, default), do: default

  defp int(value, _default) when is_integer(value), do: value
  defp int(_value, default), do: default

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    # An unknown string key is not a field of this struct, so it cannot
    # matter — map it to a throwaway rather than growing the atom table
    # from provider input.
    ArgumentError -> :__unknown__
  end

  defp to_atom_key(key), do: key
end
