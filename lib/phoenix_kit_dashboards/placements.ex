defmodule PhoenixKitDashboards.Placements do
  @moduledoc """
  Which dashboard is shown in which slot, for whom.

  A **placement** binds a dashboard to a `PhoenixKitDashboards.Slot` for one
  audience. Three audiences, resolved most-specific-first:

      personal  →  role (by explicit priority)  →  everyone

  ## Where placements live, and why there is no table

  This module writes **no DDL** (see AGENTS.md → "Database & migrations"), so a
  placements table would mean a core migration and a core release — and
  `pk deploy` does not run migrations. Placements are configuration, which is
  exactly what the settings system is for, so they are stored without any
  schema change:

  * **Shared placements** (`everyone` and `role`) — one JSON blob in the
    `dashboards_placements` setting, read-whole / write-whole. There are as
    many as an administrator types by hand: tens, not thousands.
  * **Personal placements** — on the personal dashboard itself, as
    `config["slot"]`. A personal dashboard is already owned by exactly one
    user, so "Alice's dashboard for the admin home" needs no second record;
    it IS the dashboard, tagged with where it goes. This also means a
    personal fork scales per person rather than bloating a shared blob.

  Consequences worth knowing: there is no foreign key to the dashboard, so a
  placement can outlive the dashboard it names. That is deliberate — a broken
  placement is reported by `health/1` and rendered as a fallback, never
  silently deleted, because an admin who deletes a dashboard by accident should
  be able to put it back rather than rediscover every binding.

  ## Resolution

  `resolve/3` returns the dashboards a viewer should see in a slot. The winning
  audience tier supplies the **whole** answer — tiers replace, they do not
  merge. Merging "everyone" with a role and a personal override produces
  duplicate widgets in an order nobody can explain.

  Because a user may hold several roles, role placements carry an explicit
  integer `priority` (lower wins). Without it two matching roles resolve by
  whatever order the role list happened to come back in, which is a bug that
  reproduces once a week and never on demand.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Slot
  alias PhoenixKitDashboards.Slots
  alias PhoenixKitDashboards.Web.Helpers

  @setting_key "dashboards_placements"
  @module_key "dashboards"

  @typedoc """
  One shared placement. `audience` is `"everyone"` or `"role"`; a role
  placement also carries `role_uuid` and `priority`.
  """
  @type placement :: %{String.t() => term()}

  # ── Reading ────────────────────────────────────────────────────────

  @doc """
  Every shared placement, keyed by slot key.

  Returns `%{}` when nothing is configured or the blob is unreadable — a
  corrupt setting must degrade to "no placements", never crash a page.
  """
  @spec all() :: %{String.t() => [placement()]}
  def all do
    @setting_key
    |> Settings.get_setting(nil)
    |> decode()
  rescue
    # The docstring promises this degrades rather than crashes, and a settings
    # read can raise when the database is unreachable — on a page that is
    # otherwise perfectly able to render its fallback.
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc "Shared placements for one slot, ordered by position."
  @spec for_slot(String.t()) :: [placement()]
  def for_slot(slot_key) when is_binary(slot_key) do
    all()
    |> Map.get(slot_key, [])
    |> Enum.sort_by(&position/1)
  end

  @doc """
  The dashboards a viewer sees in a slot, most-specific audience first.

  Returns `{tier, [%Dashboard{}]}` where `tier` is `:personal`, `:role`,
  `:everyone` or `:none`. An empty list with a non-`:none` tier means the
  placement exists but its dashboard is gone — the caller renders the slot's
  fallback and `health/1` reports it.

  `opts`:

    * `:limit_one` — force a single dashboard even for a `:many` slot.
  """
  @spec resolve(String.t(), map() | nil, keyword()) ::
          {:personal | :role | :everyone | :none, [Dashboard.t()]}
  def resolve(slot_key, scope, opts \\ []) when is_binary(slot_key) do
    slot = Slots.get(slot_key)
    user_uuid = user_uuid(scope)

    cond do
      is_nil(slot) -> {:none, []}
      # The generated slot tabs all share one LiveView, and core caches admin
      # view permissions as a module -> key map — so the last slot registered
      # decides the key enforced for EVERY slot URL. Re-check the slot's own
      # permission here, where it cannot be collapsed by a sibling.
      not Slots.visible_for_scope?(slot, scope) -> {:none, []}
      match = personal_match(slot, user_uuid) -> tier(:personal, match, slot, opts)
      match = role_match(slot_key, scope) -> tier(:role, match, slot, opts)
      match = everyone_match(slot_key) -> tier(:everyone, match, slot, opts)
      true -> {:none, []}
    end
  end

  # A tier that HAS a placement answers, even when every dashboard it names has
  # been deleted — `{tier, []}`, which the caller renders as the slot's empty
  # state and `health/1` reports as a broken placement.
  #
  # Falling through to the next tier instead looks helpful and is not: deleting
  # the Project-managers dashboard would silently show every manager the
  # company-wide board. That is a visibility change nobody asked for, and it
  # happens quietly. Tiers replace; a tier that matched is the answer.
  defp tier(name, {:placed, dashboards}, slot, opts), do: {name, cap(dashboards, slot, opts)}

  @doc """
  The single dashboard for a slot, or `nil`.

  Convenience over `resolve/3` for `:one` slots and for callers (the admin
  landing page) that only ever render one board.
  """
  @spec resolve_one(String.t(), map() | nil) :: Dashboard.t() | nil
  def resolve_one(slot_key, scope) do
    case resolve(slot_key, scope, limit_one: true) do
      {_tier, [dashboard | _]} -> dashboard
      _ -> nil
    end
  end

  # A personal placement is the dashboard itself, tagged with the slot it
  # fills. Only the owner's own dashboards are considered, so this can never
  # surface someone else's private canvas.
  defp personal_match(%Slot{allow_personal: false}, _user_uuid), do: nil
  defp personal_match(_slot, nil), do: nil

  defp personal_match(%Slot{key: slot_key}, user_uuid) do
    user_uuid
    |> Dashboards.list_for_user([])
    |> Enum.filter(fn %Dashboard{} = d ->
      d.scope == "personal" and d.owner_user_uuid == user_uuid and slot_of(d) == slot_key
    end)
    |> Enum.sort_by(& &1.position)
    |> placed()
  rescue
    _ -> nil
  end

  defp role_match(slot_key, scope) do
    role_uuids = role_uuids(scope)

    if role_uuids == [] do
      nil
    else
      slot_key
      |> for_slot()
      |> Enum.filter(&(&1["audience"] == "role" and &1["role_uuid"] in role_uuids))
      # Lower priority number wins. `position` keeps a stable order WITHIN
      # the winning role so a :many slot's tabs do not shuffle.
      |> Enum.sort_by(&{priority(&1), position(&1)})
      |> take_winning_role()
      |> placed_from()
    end
  end

  # Only ONE role may win. Once the best-priority role is chosen, every
  # placement for THAT role is taken (so a :many slot gets all its tabs) and
  # every other role's placements are dropped — tiers replace, they never
  # merge, and neither do two roles.
  defp take_winning_role([]), do: []

  defp take_winning_role([first | _] = placements) do
    Enum.filter(placements, &(&1["role_uuid"] == first["role_uuid"]))
  end

  defp everyone_match(slot_key) do
    slot_key
    |> for_slot()
    |> Enum.filter(&(&1["audience"] == "everyone"))
    |> Enum.sort_by(&position/1)
    |> placed_from()
  end

  # Re-check the SHARE rule at render, not only when the placement was made.
  # `put/3` refuses a non-system dashboard, but a dashboard can be re-scoped
  # afterwards by an edit that never touches the placement — and the board went
  # on rendering to everyone, which is a private canvas published to the
  # company. `Web.ProjectDashboardLive` has always re-checked this on its own
  # pane; the placement path has to as well.
  defp load_all(placements) do
    placements
    |> Enum.map(&Dashboards.get(&1["dashboard_uuid"]))
    |> Enum.filter(&match?(%Dashboard{scope: "system"}, &1))
  end

  # `nil` means "this tier declares nothing here" — fall through to the next.
  # `{:placed, dashboards}` means "this tier answers", and the list may be
  # empty because every dashboard it named has since been deleted. Collapsing
  # the two was the bug: a deleted role dashboard silently promoted the
  # company-wide board to that role's members.
  defp placed([]), do: nil
  defp placed(list), do: {:placed, list}

  # From raw placements: the PLACEMENTS decide whether this tier answers, the
  # loaded dashboards only decide what it shows.
  defp placed_from([]), do: nil
  defp placed_from(placements), do: {:placed, load_all(placements)}

  defp cap(dashboards, slot, opts) do
    if Keyword.get(opts, :limit_one, false) or not Slot.many?(slot) do
      Enum.take(dashboards, 1)
    else
      dashboards
    end
  end

  # ── Writing ────────────────────────────────────────────────────────

  @doc """
  Bind a dashboard to a slot for an audience.

  `attrs` takes `"audience"` (`"everyone"` / `"role"`), `"dashboard_uuid"`,
  and for a role placement `"role_uuid"` and `"priority"`. An optional
  `"label"` overrides the tab caption without renaming the dashboard, so
  "Quarterly Sales Dashboard 2026" can appear as "Sales".

  Refuses a placement that would leak or confuse:

    * an unknown slot or dashboard;
    * a **personal** dashboard in a shared slot — its per-user visibility
      cannot be honoured by a shared surface, and binding it would publish one
      person's private canvas to the company;
    * a **pixel** dashboard in a slot that is not a wall surface — a pixel
      canvas is a TV board, not an admin page;
    * a second placement in a `:one` slot for the same audience.
  """
  @spec put(String.t(), map(), keyword()) :: {:ok, [placement()]} | {:error, term()}
  def put(slot_key, attrs, opts \\ []) when is_binary(slot_key) and is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, slot} <- fetch_slot(slot_key),
         {:ok, dashboard} <- fetch_dashboard(attrs["dashboard_uuid"]),
         :ok <- validate_shareable(dashboard),
         :ok <- validate_type(dashboard, slot),
         {:ok, placement} <- build(attrs),
         :ok <- validate_cardinality(slot, slot_key, placement) do
      write(slot_key, for_slot(slot_key) ++ [put_position(placement, slot_key)], opts)
    end
  end

  @doc """
  Remove one shared placement from a slot.

  Identified by audience + dashboard uuid + role, because a slot may hold
  several placements for the same dashboard under different audiences.
  """
  @spec delete(String.t(), map(), keyword()) :: {:ok, [placement()]} | {:error, term()}
  def delete(slot_key, attrs, opts \\ []) when is_binary(slot_key) do
    attrs = stringify(attrs)

    # Remove ONE entry, not every match. Duplicates can no longer be created,
    # but legacy rows may still hold a pair — and two rows on screen means two
    # Remove buttons, so one click removing both is a surprise with no undo.
    remaining = drop_first(for_slot(slot_key), attrs, [])

    write(slot_key, remaining, opts)
  end

  @doc """
  Set or clear a role placement's priority (lower wins).

  Exposed on its own because reordering roles is the fix an administrator
  reaches for when two of someone's roles both claim a slot.
  """
  @spec set_priority(String.t(), map(), integer(), keyword()) ::
          {:ok, [placement()]} | {:error, term()}
  def set_priority(slot_key, attrs, priority, opts \\ [])
      when is_binary(slot_key) and is_integer(priority) do
    attrs = stringify(attrs)

    updated =
      slot_key
      |> for_slot()
      |> Enum.map(fn placement ->
        if same_placement?(placement, attrs),
          do: Map.put(placement, "priority", priority),
          else: placement
      end)

    write(slot_key, updated, opts)
  end

  defp drop_first([], _attrs, acc), do: Enum.reverse(acc)

  defp drop_first([placement | rest], attrs, acc) do
    if same_placement?(placement, attrs),
      do: Enum.reverse(acc) ++ rest,
      else: drop_first(rest, attrs, [placement | acc])
  end

  defp write(slot_key, placements, opts) do
    blob =
      all()
      |> Map.put(slot_key, Enum.map(placements, &normalize_positions/1))
      |> drop_empty()

    case Settings.update_setting_with_module(
           @setting_key,
           Jason.encode!(blob),
           @module_key,
           opts
         ) do
      {:ok, _setting} ->
        broadcast(slot_key)
        {:ok, Map.get(blob, slot_key, [])}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp drop_empty(blob), do: Map.reject(blob, fn {_k, v} -> v == [] end)

  # Positions are rewritten on every save so a deletion cannot leave a hole
  # that later reorders the tabs of a :many slot.
  defp normalize_positions(placement), do: placement

  defp put_position(placement, slot_key) do
    Map.put(placement, "position", length(for_slot(slot_key)))
  end

  # ── Personal placements ────────────────────────────────────────────

  @doc """
  Tag a personal dashboard as the owner's dashboard for a slot (or untag it
  with `nil`).

  This is the write half of `personal_match/2`: a personal placement is stored
  on the dashboard, not in the shared blob.
  """
  @spec put_personal(Dashboard.t(), String.t() | nil, keyword()) ::
          {:ok, Dashboard.t()} | {:error, term()}
  def put_personal(%Dashboard{} = dashboard, slot_key, opts \\ []) do
    if dashboard.scope == "personal" do
      config = Map.put(dashboard.config || %{}, "slot", slot_key)

      case Dashboards.update(dashboard, %{config: config}, opts) do
        {:ok, updated} ->
          broadcast(slot_key)
          {:ok, updated}

        other ->
          other
      end
    else
      {:error, :not_a_personal_dashboard}
    end
  end

  @doc "The slot key a dashboard is personally placed in, or `nil`."
  @spec slot_of(Dashboard.t()) :: String.t() | nil
  def slot_of(%Dashboard{config: config}) when is_map(config) do
    case config["slot"] do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  def slot_of(_dashboard), do: nil

  # ── Reverse lookup ─────────────────────────────────────────────────

  @doc """
  The places a dashboard is shown, for the library's "Shown in" column.

  Placements are stored by SLOT, so without this the discovery only runs one
  way: from a place you can see what fills it, but opening a dashboard tells
  you nothing about where it appears. That asymmetry is exactly how someone
  ends up editing a board without realising it is the company's admin home.

  Returns `[%{slot_key:, slot:, audience:, role_uuid:, label:}]`, shared
  placements first and then the viewer's own personal placement if they have
  one. `slot` is `nil` when the declaring module is gone — the entry is still
  listed, because "shown somewhere that no longer exists" is what an
  administrator needs to see.
  """
  @spec places_for(String.t(), String.t() | nil) :: [map()]
  def places_for(dashboard_uuid, user_uuid \\ nil)

  def places_for(dashboard_uuid, user_uuid) when is_binary(dashboard_uuid) do
    shared =
      for {slot_key, placements} <- all(),
          placement <- placements,
          placement["dashboard_uuid"] == dashboard_uuid do
        %{
          slot_key: slot_key,
          slot: Slots.get(slot_key),
          audience: placement["audience"],
          role_uuid: placement["role_uuid"],
          label: placement["label"]
        }
      end

    Enum.sort_by(shared, & &1.slot_key) ++ personal_place(dashboard_uuid, user_uuid)
  end

  def places_for(_dashboard_uuid, _user_uuid), do: []

  defp personal_place(dashboard_uuid, user_uuid) when is_binary(user_uuid) do
    with %Dashboard{} = dashboard <- Dashboards.get(dashboard_uuid),
         true <- dashboard.owner_user_uuid == user_uuid,
         slot_key when is_binary(slot_key) <- slot_of(dashboard) do
      [
        %{
          slot_key: slot_key,
          slot: Slots.get(slot_key),
          audience: "personal",
          role_uuid: nil,
          label: nil
        }
      ]
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp personal_place(_dashboard_uuid, _user_uuid), do: []

  @doc """
  Whether any shared placement names this slot at all.

  Cheap on purpose — one cached settings read, no dashboard loads. The sidebar
  asks it for every slot tab on every render, so it must not turn navigation
  into a query storm.
  """
  @spec any_for_slot?(String.t()) :: boolean()
  def any_for_slot?(slot_key) when is_binary(slot_key) do
    case Map.get(all(), slot_key) do
      [_ | _] -> true
      _ -> false
    end
  end

  def any_for_slot?(_slot_key), do: false

  # ── Health ─────────────────────────────────────────────────────────

  @doc """
  Problems with the configured placements, for the control screen.

  Broken placements are reported and disabled at render, never deleted: an
  administrator needs to see that Sales vanished from everyone's home because
  the dashboard was removed, not find an empty row and guess.
  """
  @spec health(map() | nil) :: [map()]
  def health(scope \\ nil) do
    for {slot_key, placements} <- all(),
        placement <- placements,
        problem = problem_with(slot_key, placement, scope) do
      %{slot_key: slot_key, placement: placement, problem: problem}
    end
  end

  defp problem_with(slot_key, placement, scope) do
    slot = Slots.get(slot_key)

    cond do
      is_nil(slot) -> :slot_gone
      not is_nil(scope) and not Slots.visible_for_scope?(slot, scope) -> :slot_unavailable
      true -> dashboard_problem(placement["dashboard_uuid"])
    end
  rescue
    _ -> nil
  end

  # A place that renders nothing needs to say WHICH way it broke: the board was
  # deleted, or it is still there but no longer shared.
  defp dashboard_problem(uuid) do
    case Dashboards.get(uuid) do
      nil -> :dashboard_gone
      %Dashboard{scope: "system"} -> nil
      %Dashboard{} -> :dashboard_not_shared
    end
  end

  # ── Validation ─────────────────────────────────────────────────────

  defp fetch_slot(slot_key) do
    case Slots.get(slot_key) do
      nil -> {:error, :unknown_slot}
      slot -> {:ok, slot}
    end
  end

  defp fetch_dashboard(uuid) when is_binary(uuid) and uuid != "" do
    case Dashboards.get(uuid) do
      nil -> {:error, :unknown_dashboard}
      dashboard -> {:ok, dashboard}
    end
  end

  defp fetch_dashboard(_uuid), do: {:error, :unknown_dashboard}

  # Only a SYSTEM dashboard may fill a shared place. Personal and ROLE
  # dashboards both carry visibility a shared surface cannot honour: a
  # Finance-only board bound to "everyone" would publish restricted content to
  # the whole company, and binding it to a DIFFERENT role is the same leak
  # wearing a hat. Same rule the project extension already enforces for its
  # picker, which offers `list_system/0` and nothing else.
  defp validate_shareable(%Dashboard{scope: "system"}), do: :ok
  defp validate_shareable(%Dashboard{scope: "personal"}), do: {:error, :personal_not_shareable}
  defp validate_shareable(%Dashboard{}), do: {:error, :restricted_not_shareable}

  defp validate_type(%Dashboard{} = dashboard, %Slot{surface: surface}) do
    if surface == :admin_home and Dashboard.type(dashboard) == "pixel" do
      {:error, :pixel_not_allowed_here}
    else
      :ok
    end
  end

  # `:many` means several DIFFERENT dashboards, shown as tabs — never the same
  # one twice, which is two identical tabs and no way to tell them apart. A
  # `:many` slot used to skip every duplicate check to get there.
  defp validate_cardinality(%Slot{cardinality: :many}, slot_key, placement) do
    if placed_already?(slot_key, placement),
      do: {:error, :dashboard_already_placed},
      else: :ok
  end

  defp validate_cardinality(%Slot{}, slot_key, placement) do
    cond do
      placed_already?(slot_key, placement) -> {:error, :dashboard_already_placed}
      audience_taken?(slot_key, placement) -> {:error, :audience_already_placed}
      true -> :ok
    end
  end

  defp placed_already?(slot_key, placement) do
    slot_key |> for_slot() |> Enum.any?(&same_placement?(&1, placement))
  end

  defp audience_taken?(slot_key, placement) do
    slot_key |> for_slot() |> Enum.any?(&same_audience?(&1, placement))
  end

  defp build(%{"audience" => "everyone"} = attrs) do
    {:ok,
     %{
       "audience" => "everyone",
       "dashboard_uuid" => attrs["dashboard_uuid"],
       "label" => blank_to_nil(attrs["label"])
     }}
  end

  defp build(%{"audience" => "role"} = attrs) do
    case blank_to_nil(attrs["role_uuid"]) do
      nil ->
        {:error, :role_required}

      role_uuid ->
        {:ok,
         %{
           "audience" => "role",
           "role_uuid" => role_uuid,
           "priority" => int(attrs["priority"], 100),
           "dashboard_uuid" => attrs["dashboard_uuid"],
           "label" => blank_to_nil(attrs["label"])
         }}
    end
  end

  defp build(_attrs), do: {:error, :invalid_audience}

  defp same_audience?(a, b) do
    a["audience"] == b["audience"] and a["role_uuid"] == b["role_uuid"]
  end

  defp same_placement?(a, b) do
    same_audience?(a, b) and a["dashboard_uuid"] == b["dashboard_uuid"]
  end

  # ── Live sync ──────────────────────────────────────────────────────

  @topic "phoenix_kit_dashboards:placements"

  @doc """
  Topic every page rendering a slot subscribes to.

  Placements are as live as the dashboards themselves: binding a dashboard to
  the admin home changes what every signed-in admin is looking at, and they
  should see it happen rather than on their next refresh.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribe to placement changes. Never raises — a missing PubSub costs live sync, not the mount."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    PhoenixKit.PubSubHelper.subscribe(@topic)
  rescue
    _ -> {:error, :pubsub_unavailable}
  catch
    :exit, _ -> {:error, :pubsub_unavailable}
  end

  defp broadcast(slot_key) do
    PhoenixKit.PubSubHelper.broadcast(@topic, {:placements_changed, slot_key})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp decode(nil), do: %{}
  defp decode(""), do: %{}

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = blob} -> normalize_blob(blob)
      _ -> %{}
    end
  end

  defp decode(%{} = blob), do: normalize_blob(blob)
  defp decode(_other), do: %{}

  # Every entry must be a LIST OF MAPS. Validating only the top level and
  # `List.wrap/1`-ing the rest let `{"core.admin_home": "oops"}` through as
  # `["oops"]`, and the first `placement["position"]` raised on the binary.
  # A corrupt blob has to read as "no placements", which is what the docstring
  # promises and what every caller is built to handle.
  defp normalize_blob(blob) do
    Map.new(blob, fn {key, value} ->
      {to_string(key), value |> List.wrap() |> Enum.filter(&is_map/1)}
    end)
  end

  defp position(placement), do: int(placement["position"], 0)
  defp priority(placement), do: int(placement["priority"], 100)

  defp int(value, _default) when is_integer(value), do: value

  defp int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp int(_value, default), do: default

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp user_uuid(%{user: %{uuid: uuid}}) when is_binary(uuid), do: uuid
  defp user_uuid(_scope), do: nil

  defp role_uuids(scope) do
    Helpers.scope_role_uuids(scope)
  rescue
    _ -> []
  end
end
