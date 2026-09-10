defmodule PhoenixKitDashboards.Web.Personal do
  @moduledoc """
  "Make this mine" — the per-person half of a place.

  A place resolves personal → role → everyone, and the personal tier was
  reachable only from code: `Placements.put_personal/3` existed and nothing in
  the UI ever called it. This is the two events that make it real, shared by
  every surface that renders a place (`Web.SlotLive`, `Web.AdminHomeLive`) so
  the behaviour cannot drift between them.

  ## What forking does, and does not

  Forking **copies** the dashboard currently shown and places the copy for this
  person in this place. It does not modify the shared original, and it does not
  hide it from anybody else — the shared board stays exactly as it was, and
  everyone without their own copy keeps seeing it.

  Resetting **unplaces** the copy; it does not delete it. Someone who spent an
  afternoon arranging widgets and then clicks Reset should find their work in
  the library, not in the bin. The shared board takes over again immediately,
  because that is simply the next tier down.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Schemas.Dashboard
  alias PhoenixKitDashboards.Slot
  alias PhoenixKitDashboards.Web.Helpers

  @doc """
  Copy the dashboard on screen and make the copy this person's version of the
  place.

  Returns the socket with the place reloaded by `reload`, a 0-arity-on-socket
  function the caller supplies (each surface loads its own way).
  """
  @spec fork(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                             Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def fork(socket, reload) do
    with {:ok, user_uuid} <- actor(socket),
         {:ok, slot} <- forkable_slot(socket),
         %Dashboard{} = source <- socket.assigns[:active],
         opts = [actor_uuid: user_uuid],
         {:ok, copy} <- Dashboards.clone(source, user_uuid, opts),
         {:ok, _placed} <- Placements.put_personal(copy, slot.key, opts) do
      reload.(socket)
    else
      _ -> socket
    end
  end

  @doc """
  Drop this person's version, so the shared one takes over again.

  Only ever touches a dashboard this person owns and has placed here, so it
  cannot unplace anyone else's.
  """
  @spec reset(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                              Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def reset(socket, reload) do
    with {:ok, user_uuid} <- actor(socket),
         {:ok, slot} <- forkable_slot(socket),
         %Dashboard{scope: "personal", owner_user_uuid: ^user_uuid} = mine <-
           socket.assigns[:active],
         ^slot <- slot,
         {:ok, _} <- Placements.put_personal(mine, nil, actor_uuid: user_uuid) do
      reload.(socket)
    else
      _ -> socket
    end
  end

  @doc """
  Assign the two flags the header renders from.

  Computed here rather than in the template so both surfaces agree on when the
  controls appear: you may fork when the place allows a personal copy, you are
  a real signed-in user, and something is actually on screen to copy.
  """
  @spec assign_flags(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_flags(socket) do
    mine? = socket.assigns[:tier] == :personal

    can_fork? =
      not mine? and
        match?({:ok, _}, actor(socket)) and
        match?({:ok, _}, forkable_slot(socket)) and
        match?(%Dashboard{}, socket.assigns[:active])

    policy = socket.assigns[:policy] || "shared"
    forkable? = match?({:ok, _}, actor(socket)) and match?({:ok, _}, forkable_slot(socket))

    socket
    |> assign(:can_fork?, can_fork?)
    |> assign(:mine?, mine?)
    # A `template` place says the bound board is a starting point, so editing
    # should hand you your own copy rather than change everyone's.
    |> assign(:fork_on_edit?, policy == "template" and can_fork?)
    # An `own` place shares nothing; an empty one invites you to build yours.
    |> assign(:can_create_own?, policy == "own" and forkable? and not mine?)
  end

  @doc """
  Start a brand-new personal dashboard in this place.

  The `own` policy's path: nothing is shared here, so there is nothing to copy
  and the person begins with an empty board of their own.
  """
  @spec create_own(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                                   Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def create_own(socket, reload) do
    with {:ok, user_uuid} <- actor(socket),
         {:ok, slot} <- forkable_slot(socket),
         opts = [actor_uuid: user_uuid],
         {:ok, created} <-
           Dashboards.create(
             %{
               title: Slot.localized_name(slot),
               scope: "personal",
               owner_user_uuid: user_uuid
             },
             opts
           ),
         {:ok, _placed} <- Placements.put_personal(created, slot.key, opts) do
      reload.(socket)
    else
      _ -> socket
    end
  end

  defp actor(socket) do
    case Helpers.scope_actor_uuid(socket.assigns[:phoenix_kit_current_scope]) do
      uuid when is_binary(uuid) and uuid != "" -> {:ok, uuid}
      _ -> :error
    end
  end

  defp forkable_slot(socket) do
    case socket.assigns[:slot] do
      %Slot{allow_personal: true} = slot -> {:ok, slot}
      _ -> :error
    end
  end
end
