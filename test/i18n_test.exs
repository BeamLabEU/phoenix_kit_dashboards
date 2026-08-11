defmodule PhoenixKitDashboards.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring (see
  `/www/phoenix_kit/guides/per-module-i18n.md`).

  Confirms that:
    * Every tab registered by `PhoenixKitDashboards.admin_tabs/0` carries
      `gettext_backend: PhoenixKitDashboards.Gettext`.
    * `permission_metadata/0` carries the same backend.
    * Locale switching on the module's own backend produces translated
      labels for well-known msgids (regression guard for
      `priv/gettext/<locale>/LC_MESSAGES/default.po` shipping with the
      package — and for `translatable_labels/0`'s `dgettext_noop/2` anchors,
      without which these labels would silently drop out of `default.pot`
      on the next `mix gettext.extract`).
    * Falls back to the raw msgid for an unknown locale.
  """

  use ExUnit.Case, async: true

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
  # This module's mix.exs floor (~> 2.0) already postdates it, so this only
  # matters if `phoenix_kit` is ever resolved down to a pre-API release.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitDashboards.Gettext, as: DashboardsGettext
  alias PhoenixKitDashboards.Web.Helpers

  describe "admin_tabs/0 and permission_metadata/0 wiring" do
    test "every tab carries the module's own gettext backend" do
      for tab <- PhoenixKitDashboards.admin_tabs() do
        assert tab.gettext_backend == DashboardsGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"

        assert tab.gettext_domain == "default"
      end
    end

    test "permission_metadata/0 carries the module's own gettext backend" do
      meta = PhoenixKitDashboards.permission_metadata()
      assert meta.gettext_backend == DashboardsGettext
      assert meta.gettext_domain == "default"
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'Dashboards' tab" do
      parent = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards))

      Gettext.with_locale(DashboardsGettext, "ru", fn ->
        assert Tab.localized_label(parent) == "Дашборды"
      end)
    end

    test "et locale resolves the parent 'Dashboards' tab" do
      parent = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards))

      Gettext.with_locale(DashboardsGettext, "et", fn ->
        assert Tab.localized_label(parent) == "Töölauad"
      end)
    end

    test "ru locale resolves the hidden 'New Dashboard' tab" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_new))

      Gettext.with_locale(DashboardsGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Новый дашборд"
      end)
    end

    test "unknown locale falls back to the raw msgid" do
      parent = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards))

      Gettext.with_locale(DashboardsGettext, "zz", fn ->
        assert Tab.localized_label(parent) == parent.label
      end)
    end
  end

  describe "Web.Helpers.translate_catalog/1 against the built-in widget catalog" do
    test "ru locale translates the built-in 'Note' widget name" do
      Gettext.with_locale(DashboardsGettext, "ru", fn ->
        assert Helpers.translate_catalog("Note") == "Заметка"
      end)
    end

    test "et locale translates the built-in 'Note' widget name" do
      Gettext.with_locale(DashboardsGettext, "et", fn ->
        assert Helpers.translate_catalog("Note") == "Märkus"
      end)
    end

    test "a foreign (non-catalogued) string passes through unchanged" do
      Gettext.with_locale(DashboardsGettext, "ru", fn ->
        assert Helpers.translate_catalog("Deliverability") ==
                 "Deliverability"
      end)
    end
  end
end
