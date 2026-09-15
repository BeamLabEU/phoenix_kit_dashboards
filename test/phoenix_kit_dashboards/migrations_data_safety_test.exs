defmodule PhoenixKitDashboards.MigrationsDataSafetyTest do
  use PhoenixKitDashboards.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitDashboards.Dashboards
  alias PhoenixKitDashboards.Migrations
  alias PhoenixKitDashboards.Schemas.Dashboard

  @moduledoc """
  The acceptance a table full of user dashboards actually needs, and that no
  static test can give: a REAL row, a REAL `down/1` run as a migration, and
  the row (including its `config`/`layout` JSONB) still there afterwards,
  byte-for-byte.

  `migrations_test.exs` proves what the chain BUILDS (no DROP/TRUNCATE/DELETE
  token anywhere, `down/1` emits marker bookkeeping only). That is a proof
  about text. This file proves what the chain DOES to a database that holds a
  real dashboard.

  The last test is the mutation check: it runs the same survival harness
  against a deliberately destructive rollback and requires it to FAIL.
  Without that, a survival assertion that silently stopped asserting (wrong
  table name, empty row set) would stay green forever and prove nothing.

  `async: false` — the migrator wants the shared sandbox connection.
  """

  defmodule RollbackToZero do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.down(prefix: "public", version: 0)
    def down, do: :ok
  end

  defmodule RollbackToOneFromMap do
    @moduledoc false
    use Ecto.Migration

    # Deliberately the MAP shape: it is accepted, so it must carry
    # `:version` like the keyword list does.
    def up, do: Migrations.down(%{prefix: "public", version: 1})
    def down, do: :ok
  end

  defmodule DestructiveRollback do
    @moduledoc false
    use Ecto.Migration

    # NOT what the package ships — the mutant the survival check must catch.
    def up do
      execute("DELETE FROM public.phoenix_kit_dashboards")
    end

    def down, do: :ok
  end

  setup do
    user = user_fixture()

    {:ok, dashboard} =
      Dashboards.create(%{
        title: "Safety #{System.unique_integer([:positive])}",
        scope: "personal",
        owner_user_uuid: user.uuid,
        config: %{
          "type" => "grid",
          "layouts" => [%{"id" => "l1", "name" => "Desktop", "cols" => 20, "rows" => 10}]
        },
        layout: [
          %{
            "id" => "w1",
            "widget_key" => "core.note",
            "view" => nil,
            "settings" => %{"text" => "hi"}
          }
        ]
      })

    {:ok, dashboard: dashboard}
  end

  test "a real down(version: 0) leaves the seeded dashboard row alive, config/layout unchanged",
       %{dashboard: dashboard} do
    before_count = count()

    run_migration(RollbackToZero)

    assert count() == before_count,
           "rolling this chain back changed the row count in phoenix_kit_dashboards"

    reloaded = Repo.get!(Dashboard, dashboard.uuid)
    assert reloaded.title == dashboard.title
    assert reloaded.config == dashboard.config
    assert reloaded.layout == dashboard.layout
  end

  test "the rollback still does its one real job: the marker is cleared" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_dashboards IS 'pkd_schema:1'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    run_migration(RollbackToZero)

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "a rollback to version 1 passed as a map stops at 1, not at 0" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_dashboards IS 'pkd_schema:1'")

    run_migration(RollbackToOneFromMap)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1,
           "the map shape lost :version and rolled the chain further back than asked"
  end

  test "the survival check has teeth: a destructive rollback fails it", %{dashboard: dashboard} do
    before_count = count()

    run_migration(DestructiveRollback)

    # The same assertions the real test makes. Both must fail here, or the
    # real test above is decoration.
    assert_raise ExUnit.AssertionError, fn ->
      assert count() == before_count
    end

    assert_raise ExUnit.AssertionError, fn ->
      assert Repo.get(Dashboard, dashboard.uuid) != nil
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Runs the migration IN THIS PROCESS, through Ecto's own migration runner,
  # rather than `Ecto.Migrator.up/4`. The Migrator runs the migration inside a
  # `Task`, which then has to check out the sandbox connection this test
  # already owns — it never gets it, and every assertion below dies in the
  # checkout queue instead of testing the rollback. The runner is what the
  # Migrator itself calls once it has dealt with locking and version
  # bookkeeping; going straight to it keeps the real migration context (so
  # `execute/1` inside `down/1` is the real `execute/1`) and drops only the
  # parts this file is not about.
  defp run_migration(module) do
    Runner.run(
      Repo,
      [],
      :os.system_time(:microsecond),
      module,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )
  end

  defp count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM phoenix_kit_dashboards")
    count
  end
end
