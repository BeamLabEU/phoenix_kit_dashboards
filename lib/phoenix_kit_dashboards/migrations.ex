defmodule PhoenixKitDashboards.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_dashboards` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`. This follows the canonical shape
  documented in `phoenix_kit_hello_world`'s README ("Versioned migrations",
  "Adopting a table core already creates") and its
  `mix phoenix_kit_hello_world.audit_migrations` task: **two readers**
  (`migrated_version/1` for migration context, `migrated_version_runtime/1`
  for Mix-task context), `up/1` re-reading the version before it changes
  anything, and a namespaced `COMMENT ON TABLE` marker for a table that may
  already carry a foreign comment. `phoenix_kit_billing` and
  `phoenix_kit_legal` are the closest sibling examples of the specific
  adoption situation below; `phoenix_kit_boards` and
  `phoenix_kit_web_analytics` are the live references for the dual-reader
  protocol shape itself.

  ## Ownership situation — read before touching

  `phoenix_kit_dashboards` (the table) is core's V133 baseline, and its
  `config` column was added later by core's own V139. On every existing
  install both migrations have already run, so the table already has its
  full current shape before this chain ever executes — this is an
  ADOPTION, not a create. Widths are never restated as a second number:
  `PhoenixKitDashboards.Schemas.Dashboard.column_widths/0` is the single
  shape authority this chain's DDL interpolates.

  ### Phase 0 — this V1 adopts, and changes NOTHING

  `CREATE TABLE IF NOT EXISTS` shape-identical to core's V133/V139 baseline,
  under core's exact object names (pkey, both indexes, the unique index, the
  FK), then a **namespaced** marker stamp (`pkd_schema:1` — an adopted table
  may already carry a foreign comment, so the reader must treat prose as
  version 0, never crash on it, never assume it means V1). Because the shape
  is unchanged, core's `ExpectedSchema` manifest stays accurate: **no core
  release is required and there is no release-ordering hazard.** This
  package releases alone.

  ### Phase 1 — the first real shape change (V2+) is when core must move too

  Before shipping a version that changes this table's shape:

    1. add the objects that version alters to core's manifest generator's
       `@excluded_exact` (`dev_docs/squash/generate_baseline.exs`) and
       regenerate `ExpectedSchema` — the maintainer-tooling step the
       document_creator/projects chains already rely on;
    2. raise this package's `:phoenix_kit` floor to the release that ships
       that regenerated manifest.

  Skipping step 1 means `mix phoenix_kit.repair` restores the old shape
  after every run, silently undoing the new version.

  ### Phase 2 — creation leaves core's baseline at the next squash cycle

  When core cuts its next baseline, module-owned tables are simply not
  included: fresh installs from then on get `phoenix_kit_dashboards` from
  THIS chain's V1 — which is why V1's `up/1` ensures the `uuid_generate_v7()`
  function (and its `pgcrypto` extension) exist rather than assuming core's
  chain already provided them, and why the `CREATE TABLE` must already be
  the full, correct definition on its own, not merely a shape-matching
  no-op for an already-existing table. Existing installs are untouched — a
  baseline squash only affects fresh installs and below-floor bridging.

  ## What must NEVER happen

  No conditional core migration of the form "module absent → drop the
  table" — that is nondeterministic (depends on which packages are compiled
  in) and destroys data on a host that merely removed the package. Removing
  this module's data is a human, manual step — see README.md "Removing this
  module" for the operator SQL. There is deliberately no automated
  uninstall path, and `down/1` NEVER drops `phoenix_kit_dashboards` for ANY
  target version, including `0` — it only unstamps (or re-stamps) the
  marker. The rows are every user's saved dashboard layouts, and on most
  installs the table is core-created; rolling back this module's chain must
  not destroy either.

  The migrated version is tracked as a `pkd_schema:<N>` COMMENT on
  `phoenix_kit_dashboards`. A marker-less table, or one carrying a foreign
  (non-`pkd_schema:`) comment, reads as version 0 — the core-baseline shape
  before this chain existed.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKitDashboards.Schemas.Dashboard

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @marker_prefix "pkd_schema:"
  @version_table "phoenix_kit_dashboards"

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The version a bare, freshly-created table is at (Phase 2 — a future
  install whose core baseline no longer creates this table).
  """
  @spec initial_version() :: pos_integer()
  def initial_version, do: @initial_version

  @doc """
  The table carrying the `pkd_schema:<N>` marker.

  Not part of the protocol `mix phoenix_kit.update` calls. Exported so an
  auditor (`mix phoenix_kit_hello_world.audit_migrations`) can verify the
  marker is really a number without hard-coding this table's name.
  """
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Applies every chain version up to `opts[:version]` (default
  `current_version/0`). Migration-context only — re-reads the installed
  version via `migrated_version/1` before making any change, so a database
  already at (or ahead of) the target does nothing.
  """
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    if migrated_version(opts) < opts.version do
      # Don't assume core's chain ran first (Phase 2): `uuid_generate_v7()`
      # is built on pgcrypto's `gen_random_bytes`, and
      # `ensure_uuid_v7_function/1` does not install extensions — without
      # the first call the function is created and then fails on the first
      # insert.
      Helpers.ensure_extension!("pgcrypto")
      Helpers.ensure_uuid_v7_function(opts.prefix)

      opts.prefix
      |> up_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `opts[:version]` (default `0`). Migration-context only.
  Never drops the table or a row in it, for any target — see the moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)

    if migrated_version(opts) > opts.version do
      opts.prefix
      |> down_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  The version currently installed, read INSIDE a migration — through
  `Ecto.Migration`'s own `repo()`. No rescue: inside a migration a version
  that cannot be read must abort the transaction, never be guessed at.
  `up/1` and `down/1` call this — never `migrated_version_runtime/1` —
  before making any change.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  Runtime-safe reader — the one `mix phoenix_kit.update` calls, from a Mix
  task with no migrator running, through PhoenixKit's configured repo
  instead of `Ecto.Migration`'s.

  An invalid prefix is re-raised, matching core's own reader: `0` means
  "not installed here", so reporting it for a bad prefix would tell the
  operator something false and send the updater off to install a schema
  over live data. Genuine unreachability still yields `0`, which is safe
  only because `up/1` re-reads the version in migration context before
  touching anything — a wrong `0` costs a redundant migration file, never
  wrong DDL.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test parses these statements to prove that the object names
  are core's V135/V139 names, that the `CREATE TABLE` stays shape-identical
  to core's `ExpectedSchema` manifest, that every width is
  `Dashboard.column_widths/0`, and that nothing here can drop the table.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `0` applies nothing (not an operation — clearing
  the marker is `down/1`'s job); `1` is the pure V133/V139-adoption step on
  `phoenix_kit_dashboards`.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ @default_prefix, target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)
    qualified = Helpers.qualify_table(@version_table, prefix)
    users = Helpers.qualify_table("phoenix_kit_users", prefix)
    w = Dashboard.column_widths()

    if target == 0 do
      # "Apply up to version 0" is not an operation: there is nothing to
      # apply, and stamping `pkd_schema:0` would be the only statement in
      # this function that assumes the marker-carrying table already
      # exists. Clearing the marker is `down/1`'s job.
      []
    else
      [
        """
        CREATE TABLE IF NOT EXISTS #{qualified} (
          "uuid" uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
          "title" character varying(#{w.title}) NOT NULL,
          "slug" character varying(#{w.slug}) NOT NULL,
          "owner_user_uuid" uuid,
          "role_uuid" uuid,
          "scope" character varying(#{w.scope}) DEFAULT 'personal'::character varying NOT NULL,
          "layout" jsonb DEFAULT '[]'::jsonb NOT NULL,
          "is_default" boolean DEFAULT false NOT NULL,
          "position" integer DEFAULT 0 NOT NULL,
          "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
          "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
          "config" jsonb DEFAULT '{}'::jsonb NOT NULL
        )
        """,
        # Safety net for a host that ran core's V133 but never V139 (table
        # exists, `config` does not) — `CREATE TABLE IF NOT EXISTS` above
        # no-ops against the existing table and does not retroactively add
        # the column.
        "ALTER TABLE #{qualified} ADD COLUMN IF NOT EXISTS \"config\" jsonb DEFAULT '{}'::jsonb NOT NULL",
        """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE c.conname = '#{@version_table}_pkey'
              AND t.relname = '#{@version_table}'
              AND n.nspname = '#{prefix}'
          ) THEN
            ALTER TABLE #{qualified} ADD CONSTRAINT #{@version_table}_pkey PRIMARY KEY (uuid);
          END IF;
        END
        $$
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@version_table}_owner_slug_index ON #{qualified} USING btree (owner_user_uuid, slug)",
        "CREATE INDEX IF NOT EXISTS idx_#{@version_table}_owner ON #{qualified} USING btree (owner_user_uuid) WHERE (owner_user_uuid IS NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_#{@version_table}_scope ON #{qualified} USING btree (scope)",
        """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE c.conname = '#{@version_table}_owner_user_uuid_fkey'
              AND t.relname = '#{@version_table}'
              AND n.nspname = '#{prefix}'
          ) THEN
            ALTER TABLE #{qualified} ADD CONSTRAINT #{@version_table}_owner_user_uuid_fkey FOREIGN KEY (owner_user_uuid) REFERENCES #{users}(uuid) ON DELETE CASCADE;
          END IF;
        END
        $$
        """,
        "COMMENT ON TABLE #{qualified} IS '#{@marker_prefix}#{target}'"
      ]
    end
  end

  @doc """
  The SQL `down/1` executes, as data (marker bookkeeping only). V1 changes
  no shape of its own — it is pure adoption — so there is nothing to drop
  beyond the marker; `phoenix_kit_dashboards` and every row in it are left
  untouched, for any target including `0`.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)
    qualified = Helpers.qualify_table(@version_table, prefix)

    if target > 0 do
      ["COMMENT ON TABLE #{qualified} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{qualified} IS NULL"]
    end
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = validated_prefix(Map.get(opts, :prefix) || @default_prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  # Bound parameters throughout — the prefix (and, for symmetry, the table
  # name) never reach the query text, even though the table name is a
  # compile-time constant and the prefix is already validated above.
  defp read_version(repo, prefix) do
    if table_exists?(repo, prefix) do
      repo |> table_comment(prefix) |> parse_version()
    else
      0
    end
  end

  defp table_exists?(repo, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = $1 AND table_schema = $2
    )
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, error} -> raise error
    end
  end

  defp table_comment(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> comment
      {:ok, %{rows: []}} -> nil
      {:error, error} -> raise error
    end
  end

  # A `pkd_schema:<N>` comment is this chain's own marker. Anything else on
  # a table that exists — no comment at all, or someone else's prose (an
  # adopted table may already carry one) — reads as version 0, never
  # crashes. `Integer.parse/1`, not `String.to_integer/1`: the latter
  # RAISES on prose, and that raise would land in
  # `migrated_version_runtime/1`'s rescue, silently becoming 0 anyway but
  # for the wrong reason, and not at all in `migrated_version/1`, which has
  # none.
  defp parse_version(@marker_prefix <> n) do
    case Integer.parse(n) do
      {version, ""} when version >= 0 -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  # The marker is what every later run reads to decide whether it has
  # anything to do, and nothing downstream sanity-checks the number: a
  # marker of `pkd_schema:999` makes core's `classify/2` answer
  # `:up_to_date` for every version after it, so the next real version is
  # skipped SILENTLY and forever. Applying a body while stamping a version
  # this chain does not have is therefore refused, in both directions.
  # Core's codegen always passes `current_version/0`, so this only fires
  # for a hand-written call — which is exactly the caller that has no
  # other guard.
  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitDashboards.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  # The prefix rules are CORE's, borrowed rather than restated. This chain
  # embeds the prefix directly into index NAMES, and Postgres silently
  # TRUNCATES an identifier past 63 bytes instead of rejecting it — so a
  # prefix core would refuse produces index names that differ from core's
  # while every command still exits 0, breaking the one contract adoption
  # rests on: core's exact object names.
  # `Code.ensure_loaded?` before `function_exported?`: the latter answers
  # false for a module that simply has not been loaded yet, which under a
  # release (and in `mix run --no-start`) is the normal state — the check
  # would silently take the fallback branch and defeat its own purpose.
  defp validated_prefix(prefix) do
    if Code.ensure_loaded?(Helpers) and function_exported?(Helpers, :validate_prefix!, 1) do
      Helpers.validate_prefix!(prefix)
    else
      # Older core without the shared validator: apply core's documented
      # rules here rather than restating a looser local copy that could
      # drift — lower-case identifiers only, capped at 20 bytes (measured
      # from the longest embedded object name, 63 - 1 - 42).
      unless is_binary(prefix) and prefix =~ ~r/^[a-z_][a-z0-9_]*$/ and byte_size(prefix) <= 20 do
        raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
      end
    end

    prefix
  end
end
