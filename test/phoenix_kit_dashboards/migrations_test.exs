defmodule PhoenixKitDashboards.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_dashboards`: this package owns
  the table's FUTURE shape through its module migration chain, while core's
  V133/V139 baseline still creates the table (and its `config` column) on
  every install, and the chain's V1 merely ADOPTS that shape (stamps the
  `pkd_schema:` marker, changes no shape).

  Every test here is a pure data/string assertion over
  `up_statements/2`/`down_statements/2`/`up/1`/`down/1`-as-source-text and
  core's static `PhoenixKit.Migrations.ExpectedSchema.objects/1` manifest —
  none of them touch a database.
  """

  test "PhoenixKitDashboards declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(PhoenixKitDashboards)

    assert PhoenixKitDashboards.migration_module() == Migrations,
           """
           PhoenixKitDashboards no longer declares its migration chain \
           (migration_module/0 returned #{inspect(PhoenixKitDashboards.migration_module())}).

           The chain is how phoenix_kit_dashboards's future shape is versioned
           (pkd_schema marker) and how `mix phoenix_kit.update` migrates hosts.
           """
  end

  describe "the coordinator implements the protocol" do
    alias PhoenixKit.Migrations.Postgres.Helpers

    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 1
      assert Migrations.version_table() == "phoenix_kit_dashboards"
    end

    test "initial_version/0" do
      assert Migrations.initial_version() == 1
    end

    # `mix phoenix_kit_hello_world.audit_migrations` (the canonical auditor
    # for this protocol) refuses to drive a coordinator missing any of these
    # five — `mix phoenix_kit.update` itself only calls
    # `migrated_version_runtime/1` + `current_version/0`, but `up/1` needs
    # `migrated_version/1` to re-read the version it is about to change.
    test "exports the full five-function protocol, plus version_table/0 and initial_version/0" do
      for {fun, arity} <- [
            {:current_version, 0},
            {:up, 1},
            {:down, 1},
            {:migrated_version, 1},
            {:migrated_version_runtime, 1},
            {:version_table, 0},
            {:initial_version, 0}
          ] do
        assert function_exported?(Migrations, fun, arity),
               "#{inspect(Migrations)} does not export #{fun}/#{arity}"
      end
    end

    # The marker decides whether any LATER version ever runs: core's
    # `classify/2` reads it and answers `:up_to_date` for every version at or
    # below it. Stamping a version this chain does not have therefore skips
    # V2 and everything after it, silently and permanently.
    test "refuses to stamp a version this chain does not have" do
      too_high = Migrations.current_version() + 1

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.up_statements("public", too_high)
      end

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.down_statements("public", too_high)
      end

      # The ceiling itself stays reachable, or the guard would just break
      # the chain instead of bounding it.
      assert Migrations.up_statements("public", Migrations.current_version()) != []
    end

    # The prefix is interpolated into every statement (as a schema qualifier
    # and inside the DO blocks' string literals), so it must be validated
    # before it reaches SQL. This chain embeds it into no object NAME, but a
    # prefix core would refuse is still one core's own chain never created
    # this table under — the rules are therefore core's, and this test
    # compares against core rather than restating them.
    test "every public builder that emits SQL validates its own prefix" do
      for fun <- [:up_statements, :down_statements] do
        assert_raise ArgumentError, fn -> apply(Migrations, fun, ["EVIL\";DROP"]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [String.duplicate("a", 30)]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [123]) end
      end
    end

    test "the prefix rules are core's, case and length included" do
      for prefix <- [
            "public",
            "dashboards_alt",
            "Dashboards",
            "9leading_digit",
            "has-dash",
            String.duplicate("a", 20),
            String.duplicate("a", 21),
            String.duplicate("a", 30)
          ] do
        core_accepts =
          try do
            Helpers.validate_prefix!(prefix)
            true
          rescue
            ArgumentError -> false
          end

        ours_accepts =
          try do
            Migrations.up_statements(prefix)
            true
          rescue
            ArgumentError -> false
          end

        assert ours_accepts == core_accepts,
               "prefix #{inspect(prefix)}: core #{if core_accepts, do: "accepts", else: "rejects"}, " <>
                 "this chain #{if ours_accepts, do: "accepts", else: "rejects"} — the two must agree, " <>
                 "or the index names this chain creates stop matching core's"
      end
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain's per-version statement content is pinned (drift guard)" do
    # V1 is a PUBLISHED version once this ships. A host that has already run
    # it will never run it again, so editing its content does not "fix" that
    # host — it silently splits fresh installs from existing ones. Pinning
    # the exact normalised text makes that split a deliberate, visible diff
    # instead of an accidental one buried in a refactor.
    defp normalised(statements),
      do: Enum.map(statements, &(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

    test "V1's published statements are frozen" do
      v1 = Migrations.up_statements("public", 1) |> normalised()

      assert v1 == [
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_dashboards ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"title\" character varying(255) NOT NULL, \"slug\" character varying(255) NOT NULL, \"owner_user_uuid\" uuid, \"role_uuid\" uuid, \"scope\" character varying(20) DEFAULT 'personal'::character varying NOT NULL, \"layout\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"is_default\" boolean DEFAULT false NOT NULL, \"position\" integer DEFAULT 0 NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL, \"config\" jsonb DEFAULT '{}'::jsonb NOT NULL )",
               "ALTER TABLE public.phoenix_kit_dashboards ADD COLUMN IF NOT EXISTS \"config\" jsonb DEFAULT '{}'::jsonb NOT NULL",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_dashboards_pkey' AND t.relname = 'phoenix_kit_dashboards' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_dashboards ADD CONSTRAINT phoenix_kit_dashboards_pkey PRIMARY KEY (uuid); END IF; END $$",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_dashboards_owner_slug_index ON public.phoenix_kit_dashboards USING btree (owner_user_uuid, slug)",
               "CREATE INDEX IF NOT EXISTS idx_phoenix_kit_dashboards_owner ON public.phoenix_kit_dashboards USING btree (owner_user_uuid) WHERE (owner_user_uuid IS NOT NULL)",
               "CREATE INDEX IF NOT EXISTS idx_phoenix_kit_dashboards_scope ON public.phoenix_kit_dashboards USING btree (scope)",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_dashboards_owner_user_uuid_fkey' AND t.relname = 'phoenix_kit_dashboards' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_dashboards ADD CONSTRAINT phoenix_kit_dashboards_owner_user_uuid_fkey FOREIGN KEY (owner_user_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE CASCADE; END IF; END $$",
               "COMMENT ON TABLE public.phoenix_kit_dashboards IS 'pkd_schema:1'"
             ]
    end
  end

  describe "the chain DDL adopts core's V133/V139 shape" do
    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for name <- [
            "phoenix_kit_dashboards_pkey",
            "phoenix_kit_dashboards_owner_user_uuid_fkey",
            "phoenix_kit_dashboards_owner_slug_index",
            "idx_phoenix_kit_dashboards_owner",
            "idx_phoenix_kit_dashboards_scope"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V133/V139"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_dashboards IS 'pkd_schema:1'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    test "applying up to version 0 is not an operation" do
      assert Migrations.up_statements("public", 0) == []
      assert Migrations.up_statements("dashboards_alt", 0) == []
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V133/V139 already created everything,
      # so every statement must be a no-op against an object that is already
      # there.
      ddl = Enum.reject(Migrations.up_statements(), &String.starts_with?(&1, "COMMENT"))

      for stmt <- ddl do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end
  end

  describe "the chain can never destroy the table" do
    # Compared against the WHOLE expected content, not scanned for a
    # forbidden substring — a substring check only sees statements the
    # builder produced, so anything appended past it (a literal
    # `execute("DROP TABLE ...")` in `up/1`) would be invisible to it. That
    # path is closed by the source-text test below, which checks what is
    # executed rather than what is built.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_dashboards IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_dashboards IS 'pkd_schema:1'"]

      assert Migrations.down_statements("dashboards_alt", 0) ==
               ["COMMENT ON TABLE dashboards_alt.phoenix_kit_dashboards IS NULL"]

      assert Migrations.down_statements("dashboards_alt", 1) ==
               ["COMMENT ON TABLE dashboards_alt.phoenix_kit_dashboards IS 'pkd_schema:1'"]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it.
    @up_operations [
      {"CREATE TABLE", "phoenix_kit_dashboards"},
      {"ALTER TABLE", "phoenix_kit_dashboards"},
      {"DO", "phoenix_kit_dashboards_pkey"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_dashboards_owner_slug_index"},
      {"CREATE INDEX", "idx_phoenix_kit_dashboards_owner"},
      {"CREATE INDEX", "idx_phoenix_kit_dashboards_scope"},
      {"DO", "phoenix_kit_dashboards_owner_user_uuid_fkey"},
      {"COMMENT ON TABLE", "phoenix_kit_dashboards"}
    ]

    test "up_statements/2 emits exactly these operations and no others" do
      for prefix <- ["public", "dashboards_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix), &operation/1)

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version (V2+), not something to
               slip past this list.
               """
      end
    end

    # `ON DELETE CASCADE` is part of the foreign key's DEFINITION — the word
    # DELETE there describes what Postgres does to a child row when the
    # PARENT is deleted, and adoption reproducing core's FK means
    # reproducing core's referential action verbatim. Scanning the raw text
    # for the token would flag it, so the clause is removed before the scan.
    # `the referential-action strip does not blind the destructive scan`
    # below proves the removal did not blind the check.
    defp strip_referential_actions(statement) do
      String.replace(
        statement,
        ~r/ON\s+(DELETE|UPDATE)\s+(CASCADE|RESTRICT|NO\s+ACTION|SET\s+NULL|SET\s+DEFAULT)/i,
        "ON <referential action>"
      )
    end

    test "the referential-action strip does not blind the destructive scan" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      mutant =
        "ALTER TABLE public.phoenix_kit_dashboards ADD CONSTRAINT x FOREIGN KEY (owner_user_uuid) " <>
          "REFERENCES public.phoenix_kit_users(uuid) ON DELETE CASCADE; DROP TABLE public.phoenix_kit_dashboards"

      assert strip_referential_actions(mutant) =~ forbidden

      assert strip_referential_actions("DELETE FROM public.phoenix_kit_dashboards") =~ forbidden
      assert strip_referential_actions("TRUNCATE public.phoenix_kit_dashboards") =~ forbidden
    end

    test "no statement anywhere in the data-level chain can drop the table, truncate, or delete rows" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "dashboards_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute strip_referential_actions(stmt) =~ forbidden,
                 "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1] do
          for stmt <- Migrations.down_statements(prefix, target) do
            refute strip_referential_actions(stmt) =~ forbidden,
                   "down_statements(#{inspect(prefix)}, #{target}) contains: #{stmt}"
          end
        end
      end
    end

    # `{verb, object}` for one statement. The DO block is identified by the
    # constraint it adds, since its verb says nothing about its target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.starts_with?(normalized, "DO ") do
        [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
        {"DO", constraint}
      else
        [_, verb, object] =
          Regex.run(
            ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
            normalized
          )

        {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/2` and `down_statements/2`. The
    # database gets `up/1` and `down/1`. Nothing connected the two, so a
    # literal `execute("DROP TABLE ...")` written straight into `up/1` would
    # have passed every one of them — the guard was watching the data while
    # the function did the work.
    @source "lib/phoenix_kit_dashboards/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every statement this chain runs must come from up_statements/2 or
             down_statements/2, because those are what the tests above compare
             against their expected content. A statement executed directly is
             invisible to all of them.
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what the up_statements-based tests above check"

      assert source =~ ~r/down_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end

    # Scoped to the two functions' own bodies, not the whole file — the
    # moduledoc legitimately discusses "never drops the table" in prose,
    # which a whole-file, case-insensitive scan would flag as a false
    # positive on the English word rather than a SQL token.
    test "up/1 and down/1 themselves contain no DROP/TRUNCATE/DELETE token" do
      source = File.read!(@source)

      [up_body] = Regex.run(~r/def up\(.*?\n  end\n/s, source)
      [down_body] = Regex.run(~r/def down\(.*?\n  end\n/s, source)

      for {name, body} <- [{"up/1", up_body}, {"down/1", down_body}] do
        refute body =~ ~r/DROP|TRUNCATE|DELETE/i,
               "#{name}'s own body in #{@source} contains a DROP/TRUNCATE/DELETE token"
      end
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the table)" do
    alias PhoenixKitDashboards.Schemas.Dashboard

    # The lesson phoenix_kit_legal paid for once (three disagreeing DDLs of
    # one table): never a second copy of a width. Parsed back out of the
    # CREATE rather than trusted, so a hard-coded number slipped into
    # up_statements/2 instead of Dashboard.column_widths/0 fails here even
    # though the two happen to agree today.
    test "every varchar width in the CREATE is Dashboard.column_widths/0" do
      [create | _] = Migrations.up_statements("public", 1)

      parsed =
        ~r/"(\w+)" character varying\((\d+)\)/
        |> Regex.scan(create)
        |> Map.new(fn [_, col, width] ->
          {String.to_existing_atom(col), String.to_integer(width)}
        end)

      assert parsed == Dashboard.column_widths(),
             """
             The CREATE TABLE widths and Dashboard.column_widths/0 disagree.

             parsed from DDL: #{inspect(parsed)}
             declared:        #{inspect(Dashboard.column_widths())}

             up_statements/2 must interpolate column_widths/0 — never restate a number.
             """
    end
  end
end
