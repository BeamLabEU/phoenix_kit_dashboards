defmodule PhoenixKitDashboards.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_dashboards"

  def project do
    [
      app: :phoenix_kit_dashboards,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Customizable dashboards for PhoenixKit — compose admin dashboard pages from widgets exposed by any module",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit], ignore_warnings: ".dialyzer_ignore.exs"],

      # Docs
      name: "PhoenixKitDashboards",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :gettext, :phoenix_kit]
    ]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitDashboards.Test.Repo"
      ],
      "test.reset": [
        &guard_shared_test_db/1,
        "ecto.drop --quiet -r PhoenixKitDashboards.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # `PGDATABASE` points the suite at a database the test role does not own (see
  # config/test.exs), and `ecto.drop` follows it — so a reset would drop a
  # shared database other modules are using.
  defp guard_shared_test_db(_args) do
    case System.get_env("PGDATABASE") do
      value when is_binary(value) and value != "" ->
        Mix.raise("""
        test.reset refuses to run with PGDATABASE=#{value}: it would DROP that database.
        Unset PGDATABASE to reset the module's own test database, or reset the shared one by hand.
        """)

      _ ->
        :ok
    end
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit.
  # Unset => the published pin, so mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, Repo helper, and
      # the ModuleRegistry we query to discover widget providers.
      #
      # Floor 3.5.0, the minimum core every PhoenixKit module requires. It
      # carries everything this module builds on:
      # `Settings.update_setting_with_module/4`, `PhoenixKitWeb.Actor`,
      # `PhoenixKit.Activity.log/3` and the `file_references/0` and
      # `expected_schema/0` callbacks.
      # Patch-precise floor in the compound form, so the ceiling stays open
      # through every core 3.x (see test/core_pin_conformance_test.exs).
      pk_dep(:phoenix_kit, ">= 3.5.0 and < 4.0.0"),

      # Per-module i18n — own Gettext backend for the sidebar tab labels and
      # this module's own UI strings (see `PhoenixKitDashboards.Gettext`).
      {:gettext, "~> 1.0"},

      # LiveView powers the dashboard builder and the widget LiveComponents.
      {:phoenix_live_view, "~> 1.1"},

      # Docs
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # HTML parser for Phoenix.LiveViewTest in LiveView smoke tests
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitDashboards",
      # Repo tags are BARE version numbers (0.2.1, no "v" prefix) — see
      # AGENTS.md "Versioning & Releases". A "v"-prefixed source_ref would
      # point every ExDoc source link at a tag that doesn't exist.
      source_ref: "#{@version}"
    ]
  end
end
