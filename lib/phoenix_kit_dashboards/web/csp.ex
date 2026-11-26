defmodule PhoenixKitDashboards.Web.CSP do
  @moduledoc """
  The host's Content-Security-Policy nonce for the inline `<style>` tags this module renders,
  read from core's `PhoenixKitWeb.CSP` when the installed core has it.

      <style nonce={PhoenixKitDashboards.Web.CSP.nonce(:style)}>

  Core gained `PhoenixKitWeb.CSP` after this module's core floor, so every call here is
  feature-detected: on an older core `nonce/1` is `nil` (HEEx renders no attribute) and the
  `on_mount` does nothing. Nothing else in this module calls `PhoenixKitWeb.CSP`.

  The views that other pages embed with `live_render/3` (`AdminHomeLive` in core's `/admin`,
  `ProjectDashboardLive` in the projects hub) are processes of their own on bare
  `Phoenix.LiveView`, so the live session's `on_mount` never runs for them. The page hands
  the nonces over in the embed session (core's `PhoenixKitWeb.CSP.nested_session/1`) and the
  view restores them with `on_mount PhoenixKitDashboards.Web.CSP`. The routed views
  (`use PhoenixKitWeb, :live_view`) get core's own `on_mount`.

  Inline event handlers (`onclick="…"`) cannot take a nonce: the module renders none.
  `test/csp_inline_tags_test.exs` enforces both rules.
  """

  @core PhoenixKitWeb.CSP

  @type kind :: :script | :style

  @doc "The page's nonce for `kind`, or `nil` (none set, or a core without nonce support)."
  @spec nonce(kind) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    case core(:nonce, [kind], nil) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc false
  def on_mount(_arg, params, session, socket) do
    core(:on_mount, [:default, params, session, socket], {:cont, socket})
  end

  # The one call into core: `apply/3`, because the published core has no such module and a
  # direct call would not pass the compiler there.
  defp core(function, args, default) do
    if Code.ensure_loaded?(@core) and function_exported?(@core, function, length(args)) do
      apply(@core, function, args)
    else
      default
    end
  end
end
