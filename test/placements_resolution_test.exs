defmodule PhoenixKitDashboards.PlacementsResolutionTest do
  @moduledoc """
  Tier resolution, and specifically the cases a review panel found: a tier that
  HAS a placement must answer even when the dashboards it names are gone.

  Collapsing "this tier declares nothing" with "this tier's dashboards were
  deleted" silently promoted the company-wide board to a role whose own board
  had just been removed — a visibility change nobody asked for, happening
  quietly. These pin the distinction.
  """
  use PhoenixKitDashboards.DataCase, async: false

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitDashboards.Placements
  alias PhoenixKitDashboards.Slots

  defp put_blob(blob) do
    PhoenixKit.Settings.update_setting_with_module(
      "dashboards_placements",
      Jason.encode!(blob),
      "dashboards"
    )
  end

  setup do
    on_exit(fn -> put_blob(%{}) end)
    put_blob(%{})
    :ok
  end

  describe "a tier that names a DELETED dashboard still answers" do
    test "everyone tier reports itself, not :none" do
      put_blob(%{
        "core.admin_home" => [
          %{"audience" => "everyone", "dashboard_uuid" => Ecto.UUID.generate()}
        ]
      })

      # The placement exists; only its dashboard is gone. The caller must show
      # the slot's empty state and `health/1` must be able to explain why —
      # reporting `:none` hides a broken configuration as "nothing configured".
      assert {:everyone, []} = Placements.resolve("core.admin_home", nil)
    end

    test "a broken everyone placement is reported by health/1" do
      put_blob(%{
        "core.admin_home" => [
          %{"audience" => "everyone", "dashboard_uuid" => Ecto.UUID.generate()}
        ]
      })

      assert [%{problem: :dashboard_gone, slot_key: "core.admin_home"}] = Placements.health()
    end
  end

  describe "no placement at all" do
    test "falls through to :none" do
      assert {:none, []} = Placements.resolve("core.admin_home", nil)
    end

    test "an unknown slot is :none, never a crash" do
      assert {:none, []} = Placements.resolve("nope.not_a_slot", nil)
    end
  end

  describe "corrupt storage" do
    test "a non-JSON blob degrades to no placements rather than crashing" do
      PhoenixKit.Settings.update_setting_with_module(
        "dashboards_placements",
        "{not json at all",
        "dashboards"
      )

      assert Placements.all() == %{}
      assert {:none, []} = Placements.resolve("core.admin_home", nil)
    end

    test "a JSON scalar where an object belongs degrades too" do
      PhoenixKit.Settings.update_setting_with_module(
        "dashboards_placements",
        "42",
        "dashboards"
      )

      assert Placements.all() == %{}
    end
  end

  describe "the leaks a review panel found" do
    test "a ROLE-scoped dashboard cannot be published to everyone" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, restricted} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Finance only",
          scope: "role",
          role_uuid: Ecto.UUID.generate(),
          owner_user_uuid: user.uuid
        })

      # Only rejecting `personal` let a Finance-only board be bound to
      # "everyone" and rendered to the whole company.
      assert {:error, :restricted_not_shareable} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => restricted.uuid
               })
    end

    test "a structurally corrupt entry decodes to nothing, not to junk that raises" do
      # `{"core.admin_home": "oops"}` used to survive as `["oops"]`, and the
      # first `placement["position"]` raised on the binary.
      PhoenixKit.Settings.update_setting_with_module(
        "dashboards_placements",
        ~s({"core.admin_home":"oops"}),
        "dashboards"
      )

      assert Placements.all() == %{"core.admin_home" => []}
      assert Placements.for_slot("core.admin_home") == []
      assert {:none, []} = Placements.resolve("core.admin_home", nil)
    end

    test "a list with a junk entry keeps only the well-formed placements" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Good",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      PhoenixKit.Settings.update_setting_with_module(
        "dashboards_placements",
        Jason.encode!(%{
          "core.admin_home" => [
            "junk",
            42,
            %{"audience" => "everyone", "dashboard_uuid" => dashboard.uuid}
          ]
        }),
        "dashboards"
      )

      assert {:everyone, [only]} = Placements.resolve("core.admin_home", nil)
      assert only.uuid == dashboard.uuid
    end
  end

  describe "a placed dashboard that stops being shared" do
    test "stops rendering for everyone" do
      # `put/3` refuses a non-system dashboard, but nothing re-checked
      # afterwards: bind a shared dashboard, then edit it to Personal, and it
      # kept rendering on everyone's admin home — a private board published to
      # the company by an edit that never touched the placement.
      # `ProjectDashboardLive` has always re-checked this; the placement path
      # did not.
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Company home",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, _} =
        Placements.put("core.admin_home", %{
          "audience" => "everyone",
          "dashboard_uuid" => dashboard.uuid
        })

      assert {:everyone, [_shown]} = Placements.resolve("core.admin_home", nil)

      {:ok, _private} =
        PhoenixKitDashboards.Dashboards.update(dashboard, %{scope: "personal"})

      assert {:everyone, []} = Placements.resolve("core.admin_home", nil)
    end

    test "health/1 explains why the place went blank" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Company home",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, _} =
        Placements.put("core.admin_home", %{
          "audience" => "everyone",
          "dashboard_uuid" => dashboard.uuid
        })

      {:ok, _} = PhoenixKitDashboards.Dashboards.update(dashboard, %{scope: "personal"})

      assert [%{problem: :dashboard_not_shared}] = Placements.health()
    end
  end

  describe "the same dashboard placed twice" do
    defp shared(title) do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, d} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: title,
          scope: "system",
          owner_user_uuid: user.uuid
        })

      d
    end

    test "is refused, even in a slot that takes several" do
      # `:many` means several DIFFERENT dashboards shown as tabs. The same one
      # twice is two identical tabs — never what anyone meant, and the slot
      # skipped every duplicate check to get there.
      d = shared("Test Shared Dashboard")

      assert {:ok, _} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => d.uuid
               })

      assert {:error, :dashboard_already_placed} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => d.uuid
               })
    end

    test "but two DIFFERENT dashboards for one audience are still fine" do
      a = shared("Site health")
      b = shared("User activity")

      assert {:ok, _} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => a.uuid
               })

      assert {:ok, _} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => b.uuid
               })

      assert {:everyone, [_, _]} = Placements.resolve("core.admin_home", nil)
    end

    test "removing one duplicate leaves the other, not neither" do
      # Legacy rows can still hold a duplicate. Two rows on screen means two
      # Remove buttons, so one click must remove one — deleting both is a
      # surprise you cannot undo.
      d = shared("Test Shared Dashboard")

      put_blob(%{
        "core.admin_home" => [
          %{"audience" => "everyone", "dashboard_uuid" => d.uuid, "position" => 0},
          %{"audience" => "everyone", "dashboard_uuid" => d.uuid, "position" => 1}
        ]
      })

      {:ok, remaining} =
        Placements.delete("core.admin_home", %{
          "audience" => "everyone",
          "dashboard_uuid" => d.uuid
        })

      assert length(remaining) == 1
    end
  end

  describe "slot tab visibility" do
    test "a place with nothing in it shows no tab, even to an administrator" do
      # An empty place is navigation nobody asked for. Being able to MANAGE
      # dashboards is not a reason to carry a permanent tab that only ever says
      # "nothing here" — Places is where you go to fill one.
      refute Slots.slot_tab_visible?("core.admin_home", nil)
    end

    test "a place with a shared placement shows its tab" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "D",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, _} =
        Placements.put("core.admin_home", %{
          "audience" => "everyone",
          "dashboard_uuid" => dashboard.uuid
        })

      assert Slots.slot_tab_visible?("core.admin_home", nil)
    end

    test "someone whose ONLY board here is their own still gets the tab" do
      # Hiding it would strand a dashboard they can reach nowhere else.
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, mine} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Mine",
          scope: "personal",
          owner_user_uuid: user.uuid
        })

      {:ok, _} = Placements.put_personal(mine, "core.admin_home")
      Process.delete({Slots, :personal_slots, user.uuid})

      refute Slots.slot_tab_visible?("core.admin_home", nil)
      assert Slots.slot_tab_visible?("core.admin_home", Scope.for_user(user))
    end

    test "an unknown slot key is simply not visible" do
      refute Slots.slot_tab_visible?("nope.not_a_slot", nil)
    end
  end

  describe "places_for/2 — the reverse lookup behind \"Shown in\"" do
    test "reports every place a dashboard is bound to" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Everywhere",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, _} =
        Placements.put("core.admin_home", %{
          "audience" => "everyone",
          "dashboard_uuid" => dashboard.uuid
        })

      assert [%{slot_key: "core.admin_home", audience: "everyone"}] =
               Placements.places_for(dashboard.uuid)
    end

    test "an unbound dashboard is shown nowhere" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Library only",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      assert Placements.places_for(dashboard.uuid) == []
    end

    test "a placement whose slot is gone is still listed" do
      # "Shown somewhere that no longer exists" is precisely what an
      # administrator needs to see, so the entry survives with slot: nil.
      put_blob(%{
        "gone.slot" => [%{"audience" => "everyone", "dashboard_uuid" => "abc"}]
      })

      assert [%{slot_key: "gone.slot", slot: nil}] = Placements.places_for("abc")
    end

    test "another person's personal placement is never revealed" do
      owner = PhoenixKitDashboards.Fixtures.user_fixture()
      other = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, personal} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Mine",
          scope: "personal",
          owner_user_uuid: owner.uuid
        })

      {:ok, _} = Placements.put_personal(personal, "core.admin_home")

      assert [%{audience: "personal"}] = Placements.places_for(personal.uuid, owner.uuid)
      assert Placements.places_for(personal.uuid, other.uuid) == []
    end
  end

  describe "any_for_slot?/1 — the sidebar's cheap check" do
    test "false with nothing bound, true once something is" do
      refute Placements.any_for_slot?("core.admin_home")

      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "D",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      Placements.put("core.admin_home", %{
        "audience" => "everyone",
        "dashboard_uuid" => dashboard.uuid
      })

      assert Placements.any_for_slot?("core.admin_home")
    end

    test "an unknown slot is false, not a crash" do
      refute Placements.any_for_slot?("nope.not_a_slot")
    end
  end

  describe "put/3 refusals" do
    test "an unknown dashboard is refused" do
      assert {:error, :unknown_dashboard} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => Ecto.UUID.generate()
               })
    end

    test "an unknown slot is refused" do
      assert {:error, :unknown_slot} =
               Placements.put("nope.not_a_slot", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => Ecto.UUID.generate()
               })
    end

    test "a role placement without a role is refused" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, dashboard} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Shared",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      assert {:error, :role_required} =
               Placements.put("core.admin_home", %{
                 "audience" => "role",
                 "dashboard_uuid" => dashboard.uuid
               })
    end

    test "a PERSONAL dashboard can never fill a shared place" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, personal} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Mine",
          scope: "personal",
          owner_user_uuid: user.uuid
        })

      # Binding it would publish one person's private canvas to the company.
      assert {:error, :personal_not_shareable} =
               Placements.put("core.admin_home", %{
                 "audience" => "everyone",
                 "dashboard_uuid" => personal.uuid
               })
    end

    test "a second everyone placement in a :one slot is refused" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, a} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "A",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, b} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "B",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      # core.admin_home is :many, so use a :one slot for this rule.
      slot = Enum.find(PhoenixKitDashboards.Slots.list(), &(&1.cardinality == :one))

      if slot do
        assert {:ok, _} =
                 Placements.put(slot.key, %{
                   "audience" => "everyone",
                   "dashboard_uuid" => a.uuid
                 })

        assert {:error, :audience_already_placed} =
                 Placements.put(slot.key, %{
                   "audience" => "everyone",
                   "dashboard_uuid" => b.uuid
                 })
      end
    end

    test "a :many slot accepts several, and resolve returns them in order" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      {:ok, a} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "Site health",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, b} =
        PhoenixKitDashboards.Dashboards.create(%{
          title: "User activity",
          scope: "system",
          owner_user_uuid: user.uuid
        })

      {:ok, _} =
        Placements.put("core.admin_home", %{"audience" => "everyone", "dashboard_uuid" => a.uuid})

      {:ok, _} =
        Placements.put("core.admin_home", %{"audience" => "everyone", "dashboard_uuid" => b.uuid})

      assert {:everyone, [first, second]} = Placements.resolve("core.admin_home", nil)
      assert first.uuid == a.uuid
      assert second.uuid == b.uuid
    end

    test "limit_one caps a :many slot for callers that render one board" do
      user = PhoenixKitDashboards.Fixtures.user_fixture()

      for title <- ["One", "Two"] do
        {:ok, d} =
          PhoenixKitDashboards.Dashboards.create(%{
            title: title,
            scope: "system",
            owner_user_uuid: user.uuid
          })

        Placements.put("core.admin_home", %{
          "audience" => "everyone",
          "dashboard_uuid" => d.uuid
        })
      end

      assert {:everyone, [_only_one]} =
               Placements.resolve("core.admin_home", nil, limit_one: true)
    end
  end
end
