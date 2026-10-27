defmodule PhoenixKitDashboards.Web.Helpers do
  @moduledoc """
  Cross-cutting helpers shared by the Dashboards LiveViews.

  `actor_opts/1` is the canonical way to thread the acting user's uuid into
  context mutations that accept a trailing `opts \\ []` (for activity logging).
  """

  use Gettext, backend: PhoenixKitDashboards.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Roles
  alias PhoenixKitDashboards.Dashboards

  @doc """
  Dynamic translation for catalog DATA (widget names, descriptions, view names,
  settings labels — plain strings from the provider contract). Falls back to
  the input when no translation exists, so provider strings pass through.

  Routes through THIS module's own backend: the built-in widgets' catalog
  strings are pinned as msgids via `Widgets.__catalog_strings__/0`
  (`gettext_noop/1` — `mix gettext.extract` can't see a literal passed through
  a variable, so that anchor is what keeps them in the `.pot`). A widget
  contributed by another module (a foreign `name`/`description`) simply passes
  through unchanged unless that exact string happens to also be a msgid here.
  """
  @spec translate_catalog(String.t() | nil) :: String.t() | nil
  def translate_catalog(nil), do: nil

  def translate_catalog(string) when is_binary(string) do
    # Runtime translation of a dynamic value — the `gettext/1` macro needs a
    # literal, so this stays the explicit runtime-function form.
    Gettext.gettext(PhoenixKitDashboards.Gettext, string)
  end

  @doc "Translated label for a dashboard scope enum value."
  @spec scope_label(String.t()) :: String.t()
  def scope_label("personal"), do: gettext("personal")
  def scope_label("system"), do: gettext("shared")
  def scope_label("role"), do: gettext("role")
  def scope_label(other), do: other

  @doc "The current user's uuid, or `nil` — see `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defdelegate actor_uuid(socket), to: PhoenixKitWeb.Actor, as: :uuid

  @doc """
  The current user's uuid from a bare SCOPE, for render-side callers that have
  no socket (the slot chrome decides whether to show "Edit layout" from the
  scope it was handed).
  """
  @spec scope_actor_uuid(PhoenixKit.Users.Auth.Scope.t() | nil) :: String.t() | nil
  defdelegate scope_actor_uuid(scope), to: PhoenixKitWeb.Actor, as: :uuid

  @doc """
  Keyword opts threading the acting user's uuid into context mutations:
  `[actor_uuid: uuid]`, or `[]` when there is no current user (so the context
  call is unaffected) — see `PhoenixKitWeb.Actor.opts/1`.
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  defdelegate actor_opts(socket), to: PhoenixKitWeb.Actor, as: :opts

  @doc """
  The current user's role uuids, mapped from the scope's cached role names — used
  by both LiveViews to resolve `role`-scoped dashboard visibility. Reuses a
  `@roles` assign if present, else queries core once. `[]` when roles are
  unavailable.
  """
  @spec user_role_uuids(Phoenix.LiveView.Socket.t()) :: [String.t()]
  def user_role_uuids(socket) do
    scope_role_uuids(socket.assigns[:phoenix_kit_current_scope], socket.assigns[:roles])
  end

  @doc """
  The same mapping from a bare scope, for callers that have no socket.

  `PhoenixKitDashboards.Placements` resolves role placements during render and
  from contexts with no LiveView around, so the role lookup cannot live behind
  a socket. `user_role_uuids/1` delegates here, so the two can never disagree
  about which roles a viewer holds.
  """
  @spec scope_role_uuids(map() | nil, [struct()] | nil) :: [String.t()]
  def scope_role_uuids(scope, roles \\ nil)

  def scope_role_uuids(%{cached_roles: names}, roles) when is_list(names) and names != [] do
    for role <- roles || list_roles(), role.name in names, do: role.uuid
  end

  def scope_role_uuids(_scope, _roles), do: []

  @doc """
  Whether `dashboard` is viewable by the socket's user (own personal · any
  shared/system · role dashboards for the user's roles). The single view rule,
  shared by the list page and the builder so the two never disagree.
  """
  @spec viewable_by?(map(), Phoenix.LiveView.Socket.t()) :: boolean()
  def viewable_by?(dashboard, socket) do
    Dashboards.visible_to?(dashboard, actor_uuid(socket), user_role_uuids(socket))
  end

  @manage_permission "dashboards.manage"

  @doc "The sub-permission that manages shared dashboards and places."
  @spec manage_permission() :: String.t()
  def manage_permission, do: @manage_permission

  @doc """
  Whether `scope` may manage (edit, re-scope, delete) `dashboard`: a personal
  dashboard only by its owner, a shared (`system`) or `role` one only by a
  holder of `dashboards.manage` (an Owner always). The base `dashboards` key
  reaches the section and shows a viewer the shared dashboards, but does not
  let them change what everyone else sees. Takes the scope so socket callers
  and render-side callers (the slot chrome) share one rule.
  """
  @spec manageable_by?(map(), map() | nil) :: boolean()
  def manageable_by?(%{scope: "personal"} = dashboard, scope) do
    owner = dashboard.owner_user_uuid
    not is_nil(owner) and owner == scope_actor_uuid(scope)
  end

  def manageable_by?(_dashboard, scope), do: can_manage_shared?(scope)

  @doc """
  Whether `scope` holds `dashboards.manage` (an Owner always): creating,
  editing and deleting shared and role dashboards, and choosing what a place
  shows. Fails closed on an absent scope.
  """
  @spec can_manage_shared?(map() | nil) :: boolean()
  def can_manage_shared?(%Scope{} = scope),
    do: Scope.owner?(scope) or Scope.can?(scope, @manage_permission)

  def can_manage_shared?(_scope), do: false

  @doc """
  Apply the locale the host put in an EMBED session.

  `live_render/3` spawns a FRESH process and the Gettext locale lives in the
  process dictionary, so it is not inherited from the page around it. Both
  hosts already send the key — core's `/admin` and the projects hub — and
  without this every string these views render falls back to the backend
  default while the page around them is correctly translated, which reads as a
  half-translated page rather than as missing wiring.

  Both backends are set: this module's own for its strings, and core's for
  anything rendered through a core component.
  """
  @spec put_embed_locale(map()) :: :ok | nil
  def put_embed_locale(session) when is_map(session) do
    case Map.get(session, "locale") do
      locale when is_binary(locale) and locale != "" ->
        Gettext.put_locale(PhoenixKitDashboards.Gettext, locale)
        Gettext.put_locale(PhoenixKitWeb.Gettext, locale)

      _ ->
        :ok
    end
  end

  def put_embed_locale(_session), do: :ok

  @doc """
  Reconstruct the viewer's user + scope from an EMBED session.

  A dashboard rendered with `live_render/3` inside another page (the projects
  hub tab, core's admin home) mounts off-router, so none of the `on_mount`
  hooks that normally assign the current user have run. Prefer core's canonical
  helper when the running core exposes it; fall back to resolving the uuid the
  host put in the session.

  `Code.ensure_loaded?/1` comes BEFORE `function_exported?/3` deliberately: on a
  cold VM the module may not be loaded yet and `function_exported?/3` answers
  false WITHOUT loading it, silently taking the legacy path against a core that
  does export the helper.
  """
  @spec assign_embed_identity(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_embed_identity(socket, session) do
    if is_nil(socket.assigns[:phoenix_kit_current_scope]) do
      do_assign_embed_identity(socket, session)
    else
      socket
    end
  end

  defp do_assign_embed_identity(socket, session) do
    if Code.ensure_loaded?(PhoenixKitWeb.Users.Auth) and
         function_exported?(PhoenixKitWeb.Users.Auth, :assign_embedded_current_user, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitWeb.Users.Auth, :assign_embedded_current_user, [socket, session])
    else
      {user, scope} = resolve_embed_identity(session["current_user_uuid"])

      Phoenix.Component.assign(socket,
        phoenix_kit_current_user: user,
        phoenix_kit_current_scope: scope
      )
    end
  end

  defp resolve_embed_identity(uuid) when is_binary(uuid) and uuid != "" do
    user = uuid |> Auth.get_user() |> Auth.ensure_active_user()
    {user, Scope.for_user(user)}
  rescue
    _ -> {nil, Scope.for_user(nil)}
  end

  defp resolve_embed_identity(_uuid), do: {nil, Scope.for_user(nil)}

  @doc """
  Whether this viewer may change what is shown in a place.

  Placing a dashboard is an administrative act separate from editing one: a
  person may own a dashboard they are not allowed to publish onto the admin
  home. It needs `dashboards.manage`, like changing a shared dashboard.
  """
  @spec can_manage_places?(map() | nil) :: boolean()
  def can_manage_places?(scope), do: can_manage_shared?(scope)

  @doc "All roles (for pickers); `[]` when the roles API is unavailable."
  @spec list_roles() :: [struct()]
  def list_roles do
    if Code.ensure_loaded?(Roles), do: Roles.list_roles(), else: []
  rescue
    _ -> []
  end
end
