defmodule PhoenixKitDashboards.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring (see
  `/www/phoenix_kit/guides/per-module-i18n.md`).

  Confirms that:
    * Every tab registered by `PhoenixKitDashboards.admin_tabs/0` carries
      `gettext_backend: PhoenixKitDashboards.Gettext`.
    * `permission_metadata/0` carries the same backend.
    * The hex package ships `priv/` (the compiled `.po` catalogues) —
      without it every UI renders in English regardless of locale, the
      exact regression that shipped in `phoenix_kit_warehouse` 0.3.0 and
      `phoenix_kit_manufacturing` 0.4.0.
    * All four `admin_tabs/0` labels resolve to their real translation in
      `ru` and `et` (regression guard for `priv/gettext/<locale>/LC_MESSAGES/
      default.po` shipping with the package, and for `translatable_labels/0`'s
      `dgettext_noop/2` anchors, without which these labels would silently
      drop out of `default.pot` on the next `mix gettext.extract`) — and that
      a `label:` renamed in `admin_tabs/0` without updating its matching
      `translatable_labels/0` anchor gets caught: the renamed label has no
      catalogue entry, so it comes back untranslated.
    * Falls back to the raw msgid for an unknown locale.

  Not covered, and can't be by this technique: the `en` catalogue. Its
  msgstrs equal their msgids by design (English is the source language), so
  a missing or blanked `en` translation is indistinguishable from a correct
  one — this suite stays green even if
  `priv/gettext/en/LC_MESSAGES/default.po` were deleted outright.
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

  describe "hex package ships the gettext catalogues" do
    test "priv/ is in the :package :files list" do
      files = Mix.Project.config()[:package][:files]

      assert "priv" in files,
             "mix.exs :package :files dropped \"priv\" — the compiled .po catalogues " <>
               "would ship out of the hex tarball and every UI would silently render in " <>
               "English regardless of locale (this exact regression shipped in " <>
               "phoenix_kit_warehouse 0.3.0 and phoenix_kit_manufacturing 0.4.0)"
    end
  end

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

    test "ru locale resolves the hidden 'Dashboard Settings' tab" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_edit))

      Gettext.with_locale(DashboardsGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Настройки дашборда"
      end)
    end

    test "ru locale resolves the hidden 'Dashboard Builder' tab" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_builder))

      Gettext.with_locale(DashboardsGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Конструктор дашборда"
      end)
    end

    test "et locale resolves the hidden 'New Dashboard' tab" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_new))

      Gettext.with_locale(DashboardsGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Uus töölaud"
      end)
    end

    test "et locale resolves the hidden 'Dashboard Settings' tab" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_edit))

      Gettext.with_locale(DashboardsGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Töölaua seaded"
      end)
    end

    test "et locale resolves the hidden 'Dashboard Builder' tab" do
      tab = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards_builder))

      Gettext.with_locale(DashboardsGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Töölaua koostaja"
      end)
    end

    test "unknown locale falls back to the raw msgid" do
      parent = Enum.find(PhoenixKitDashboards.admin_tabs(), &(&1.id == :admin_dashboards))

      Gettext.with_locale(DashboardsGettext, "zz", fn ->
        assert Tab.localized_label(parent) == parent.label
      end)
    end
  end

  describe "admin_tabs/0 labels stay independently translated (rename-drift guard)" do
    # translatable_labels/0 pins each tab's label as a literal dgettext_noop/2
    # call — deliberately, because `mix gettext.extract` only sees literals,
    # never a variable, so the anchor can't be rewritten to pull labels off
    # admin_tabs/0 without breaking extraction (see that function's @doc).
    #
    # That leaves a gap from the other direction: nothing stops the anchor's
    # copy of a label from drifting out of sync with admin_tabs/0 itself, e.g.
    # a `label:` rename that forgets to update the matching
    # translatable_labels/0 literal. This test closes it by reading the
    # expected labels straight off admin_tabs/0 — the single source of truth
    # for what the UI actually shows — instead of duplicating them as
    # literals here. A drifted label has no catalogue entry, so
    # Gettext.dgettext/3 hands it back unchanged, and "translated must differ
    # from the source label" goes red.
    test "every tab label translates to something other than itself in ru" do
      for tab <- PhoenixKitDashboards.admin_tabs(), tab.label do
        translated =
          Gettext.with_locale(DashboardsGettext, "ru", fn -> Tab.localized_label(tab) end)

        assert translated != tab.label,
               "Tab #{inspect(tab.id)}'s label #{inspect(tab.label)} did not translate in ru — " <>
                 "translatable_labels/0's dgettext_noop/2 anchor is probably stale after a rename"
      end
    end

    test "every tab label translates to something other than itself in et" do
      for tab <- PhoenixKitDashboards.admin_tabs(), tab.label do
        translated =
          Gettext.with_locale(DashboardsGettext, "et", fn -> Tab.localized_label(tab) end)

        assert translated != tab.label,
               "Tab #{inspect(tab.id)}'s label #{inspect(tab.label)} did not translate in et — " <>
                 "translatable_labels/0's dgettext_noop/2 anchor is probably stale after a rename"
      end
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
