# Two levels: unit tests always run; integration tests (`:integration` tag, via
# DataCase/LiveCase) require PostgreSQL and are auto-excluded when the DB is
# unavailable.
#   mix test.setup   # createdb
#   mix test         # schema built by PhoenixKit.Migration.ensure_current/2 below
#
# Elixir 1.19 no longer auto-loads test/support modules — require them explicitly.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "fixtures.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

db_name =
  Application.get_env(:phoenix_kit_dashboards, PhoenixKitDashboards.Test.Repo)[:database] ||
    "phoenix_kit_dashboards_test"

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(
           Application.get_env(:phoenix_kit_dashboards, PhoenixKitDashboards.Test.Repo, [])
         ) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Cannot reach test database "#{db_name}" — integration tests will be excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitDashboards.Test.Repo.start_link()

      # Build the schema by running core's versioned migrations directly
      # (phoenix_kit_dashboards ships as core V133 — no module-owned DDL).
      PhoenixKit.Migration.ensure_current(PhoenixKitDashboards.Test.Repo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitDashboards.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_dashboards, :test_repo_available, repo_available)

# Start minimal PhoenixKit services so runtime deps (PubSub topics, ModuleRegistry
# — which Registry.provider_modules/0 queries) resolve.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# The per-module i18n API (`gettext_backend:`/`gettext_domain:` on %Tab{} +
# `Tab.localized_label/1`) shipped in a specific `phoenix_kit` core release —
# see /www/phoenix_kit/guides/per-module-i18n.md. This module's mix.exs floor
# (~> 2.0) already postdates it, so this is a defensive guard, not a real
# fork: it keeps `mix test` green if `phoenix_kit` is ever resolved down to a
# pre-API release (e.g. a stale lockfile), the same pattern phoenix_kit_crm
# uses.
i18n_api_available =
  Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
    function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1)

unless i18n_api_available do
  require Logger

  Logger.info(
    "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
      "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
      "upgraded to a release that ships the gettext_backend API."
  )
end

exclude =
  [
    if(!repo_available, do: :integration),
    if(!i18n_api_available, do: :requires_phoenix_kit_i18n_api)
  ]
  |> Enum.reject(&is_nil/1)

# Force PhoenixKit's URL prefix cache so `Paths.index()` etc. produce paths that
# match the test router (no settings table to read the prefix from).
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint (server: false) only when the DB is available.
if repo_available do
  {:ok, _} = PhoenixKitDashboards.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
