defmodule PhoenixKitDashboards.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_dashboards` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`: `current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware `down/1`.
  `phoenix_kit_billing` (over `phoenix_kit_payment_provider_configs`) and
  `phoenix_kit_legal` (over `phoenix_kit_consent_logs`) are the closest sibling
  examples of this exact situation — a core-created table whose FUTURE shape a
  module chain adopts.

  ## Ownership situation — read before touching

  `phoenix_kit_dashboards` (the table) is core's V133 baseline, and its
  `config` column was added later by core's own V139. On every existing
  install both migrations have already run, so the table already has its full
  current shape before this chain ever executes.

  V1 is purely an ADOPTION step, not a create:

    * on existing installs the table (and its `config` column) are already
      there, `CREATE TABLE IF NOT EXISTS` finds it, and the only new object is
      the `pkd_schema:1` marker — from then on this chain owns the table's
      future shape;
    * on a hypothetical future install whose core baseline no longer creates
      the table, the same statements create it — shape-identical to core's
      V135/V139 combined, with core's exact index and constraint names,
      `config` included from the CREATE itself;
    * on the narrower hypothetical of a host that ran V133 but never V139 (the
      table exists, `config` does not), the `ALTER TABLE ... ADD COLUMN IF NOT
      EXISTS config ...` statement right after the `CREATE TABLE` closes that
      gap — `CREATE TABLE IF NOT EXISTS` alone would not, since the table
      already exists and Postgres does not retroactively add columns to an
      existing table from a `CREATE TABLE` statement.

  Because V1 changes no shape, core's `ExpectedSchema` manifest (which still
  audits the V135/V139 shape of this table) stays accurate and NO core release
  is required for this version.

  From this version on, any future shape change to `phoenix_kit_dashboards` is
  a new version in THIS chain — never a new core migration.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops
  `phoenix_kit_dashboards`. The table is core-created and holds every user's
  dashboard layouts, and rolling back this module's chain must not destroy it
  — only core's own baseline rollback does that.

  The migrated version is tracked as a `pkd_schema:<N>` COMMENT on
  `phoenix_kit_dashboards` (the marker convention from the billing/legal
  chains, namespaced). A marker-less table reads as version 0 — the
  core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pkd_schema:"
  @version_table "phoenix_kit_dashboards"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkd_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkd_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    # classoid anchors the description join to pg_class (the billing/legal
    # chains' convention).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed") — that misleads the operator AND
    # lets the unvalidated string reach interpolated SQL in callers'
    # fallback paths.
    e in ArgumentError ->
      reraise e, __STACKTRACE__

    _ ->
      0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)
    target = target_version(opts, @current_version)

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`, default `0`). Never drops the table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = target_version(opts, 0)

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test parses these statements to prove that the object names are
  core's V135/V139 names, that the `CREATE TABLE` stays shape-identical to
  core's `ExpectedSchema` manifest, and that nothing here can drop the table.

  `target` selects how much of the chain to emit (default `current_version/0`):
  `0` applies nothing (not an operation — clearing the marker is `down/1`'s
  job); `1` is the pure V133/V139-adoption step on `phoenix_kit_dashboards`.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target == 0 do
      # "Apply up to version 0" is not an operation: there is nothing to
      # apply, and stamping `pkd_schema:0` would be the only statement in
      # this function that assumes the marker-carrying table already
      # exists. Clearing the marker is `down/1`'s job.
      []
    else
      [
        """
        CREATE TABLE IF NOT EXISTS #{p}#{@version_table} (
          "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
          "title" character varying(255) NOT NULL,
          "slug" character varying(255) NOT NULL,
          "owner_user_uuid" uuid,
          "role_uuid" uuid,
          "scope" character varying(20) DEFAULT 'personal'::character varying NOT NULL,
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
        "ALTER TABLE #{p}#{@version_table} ADD COLUMN IF NOT EXISTS \"config\" jsonb DEFAULT '{}'::jsonb NOT NULL",
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
            ALTER TABLE #{p}#{@version_table} ADD CONSTRAINT #{@version_table}_pkey PRIMARY KEY (uuid);
          END IF;
        END
        $$
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@version_table}_owner_slug_index ON #{p}#{@version_table} USING btree (owner_user_uuid, slug)",
        "CREATE INDEX IF NOT EXISTS idx_#{@version_table}_owner ON #{p}#{@version_table} USING btree (owner_user_uuid) WHERE (owner_user_uuid IS NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_#{@version_table}_scope ON #{p}#{@version_table} USING btree (scope)",
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
            ALTER TABLE #{p}#{@version_table} ADD CONSTRAINT #{@version_table}_owner_user_uuid_fkey FOREIGN KEY (owner_user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE;
          END IF;
        END
        $$
        """,
        "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
      ]
    end
  end

  @doc """
  The SQL `down/1` executes, as data (marker bookkeeping only). V1 changes no
  shape of its own — it is pure adoption, like V1 in the billing/legal chains
  — so there is nothing to drop beyond the marker; `phoenix_kit_dashboards`
  and every row in it are left untouched.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  # The marker is what every later run reads to decide whether it has
  # anything to do, and nothing downstream sanity-checks the number: a marker
  # of `pkd_schema:999` makes core's `classify/2` answer `:up_to_date` for
  # every version after it, so the next real version is skipped SILENTLY and
  # forever. Applying a body while stamping a version this chain does not
  # have is therefore refused, in both directions. Core's codegen always
  # passes `current_version/0`, so this only fires for a hand-written call —
  # which is exactly the caller that has no other guard.
  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitDashboards.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  # `:version` is read from a keyword list AND from a map, because
  # `validated_prefix/1` accepts both — and a shape it accepts must not
  # silently lose the version.
  defp target_version(opts, default) when is_list(opts) do
    Keyword.get(opts, :version, default)
  end

  defp target_version(%{} = opts, default), do: Map.get(opts, :version, default)
  defp target_version(_opts, default), do: default

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

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
    helpers = PhoenixKit.Migrations.Postgres.Helpers

    if Code.ensure_loaded?(helpers) and function_exported?(helpers, :validate_prefix!, 1) do
      helpers.validate_prefix!(prefix)
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
