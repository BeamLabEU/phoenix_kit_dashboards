defmodule PhoenixKitDashboards.MigrationsRuntimeTest do
  use PhoenixKitDashboards.DataCase, async: false

  alias PhoenixKitDashboards.Migrations

  @moduledoc """
  Exercises `migrated_version_runtime/1` against a real database — the read
  path the pure data/string tests in `migrations_test.exs` cannot cover (see
  that file's moduledoc: none of its tests touch a database). A regression in
  the SELECT itself (broken join, wrong classoid) would leave that suite
  green while this function permanently returns 0 in production, and callers
  (status/update task) would never see the real installed version.

  `async: false` — each test mutates the table-level COMMENT rather than rows.
  """

  @table "phoenix_kit_dashboards"

  test "reads 0 when the table carries no marker comment" do
    Repo.query!("COMMENT ON TABLE #{@table} IS NULL")

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "reads the version parsed out of the pkd_schema marker" do
    Repo.query!("COMMENT ON TABLE #{@table} IS 'pkd_schema:1'")

    assert Migrations.migrated_version_runtime(prefix: "public") == 1
  end

  test "reads 0 again once a stamped marker is cleared" do
    Repo.query!("COMMENT ON TABLE #{@table} IS 'pkd_schema:1'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    Repo.query!("COMMENT ON TABLE #{@table} IS NULL")
    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  # The adoption case the namespaced marker exists for: a core-created table
  # may already carry someone else's comment, which must read as "not yet
  # adopted", never crash and never pass for a version.
  test "reads 0 when the table carries a foreign (non-marker) comment" do
    Repo.query!("COMMENT ON TABLE #{@table} IS 'User dashboards - do not edit by hand'")

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "reads 0 for a malformed marker rather than raising or guessing" do
    for marker <- ["pkd_schema:", "pkd_schema:one", "pkd_schema:1.5", "pkd_schema:-1", "1"] do
      Repo.query!("COMMENT ON TABLE #{@table} IS '#{marker}'")

      assert Migrations.migrated_version_runtime(prefix: "public") == 0,
             "marker #{inspect(marker)} did not read as version 0"
    end
  end

  test "reads 0 when the table does not exist under the prefix" do
    assert Migrations.migrated_version_runtime(prefix: "no_such_schema") == 0
  end

  # `0` means "not installed here" — reporting it for a bad prefix would send
  # the updater off to install over live data.
  test "re-raises an invalid prefix instead of reporting 0" do
    assert_raise ArgumentError, fn ->
      Migrations.migrated_version_runtime(prefix: "Bad-Prefix")
    end
  end
end
