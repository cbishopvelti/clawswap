defmodule ClawswapWeb.DebugView do
  @moduledoc """
  What the debug panel (`ClawswapWeb.DebugPanel`) shows of `Clawswap.Walkthrough.Debugger`'s state, worked
  out here so the template only lays it out. `broadcast/1` sends it to the open pages' debug panels.
  """

  alias Clawswap.Walkthrough

  @doc "Sends a project's debugger's new state to its open pages' debug panels (its on_change)."
  def broadcast(project, state) do
    if Hologram.enabled?(), do: Hologram.Realtime.broadcast_action({:clawswap_debug, project.id}, :debug_changed, view: page(state, project))
    :ok
  end

  @doc "The page's view of a project's debugger's state (no project: none of its walkthroughs or servers)."
  def page(state, project) do
    walk = state.walk

    %{
      browser: state.browser,
      closed: state.browser == "closed",
      open: state.browser == "open",
      browser_label: browser_label(state),
      busy: state.busy,
      paused: match?(%{phase: "paused"}, walk),
      running: match?(%{phase: "running"}, walk),
      walk: walk_status(walk),
      walkthroughs: if(project, do: Enum.map(Walkthrough.list(project), & &1.name), else: []),
      servers: servers(project),
      tabs:
        Enum.map(state.tabs, fn t ->
          %{handle: t.handle, url: t.url, label: tab_label(t), class: if(t.current, do: "tab current", else: "tab")}
        end),
      url: state.url,
      shot: if(state.shot > 0 and project, do: "/p/#{project.id}/debug/screenshot.png?v=#{state.shot}"),
      # Newest first, so what just happened is at the top.
      log: state.log |> Enum.reverse() |> Enum.take(150)
    }
  end

  defp browser_label(%{browser: "closed"}), do: "Chrome is closed"
  defp browser_label(%{browser: "opening"}), do: "Opening Chrome..."
  defp browser_label(%{busy: busy}) when is_binary(busy), do: "#{busy}..."
  defp browser_label(%{headless: true}), do: "Chrome is open (headless)"
  defp browser_label(_), do: "Chrome is open"

  # The project's servers with a port, for the Visit buttons.
  defp servers(nil), do: []
  defp servers(project), do: Enum.filter(project.server_names, &project.servers[&1].port)

  defp tab_label(%{title: title}) when title not in [nil, ""], do: title
  defp tab_label(%{url: url}) when url not in [nil, ""], do: url
  defp tab_label(_), do: "(blank)"

  defp walk_status(nil), do: %{text: nil, class: ""}
  defp walk_status(%{phase: "running"} = w), do: %{text: "▶ #{w.name}: #{w.step || "starting"}", class: "running"}
  defp walk_status(%{phase: "paused"} = w), do: %{text: "⏸ #{w.name}, paused before: #{w.step}", class: "running"}
  defp walk_status(%{phase: "passed"} = w), do: %{text: "✓ #{w.name} ran to the end", class: "passed"}
  defp walk_status(%{phase: "stopped"} = w), do: %{text: "■ #{w.name} stopped#{if w.step, do: " at: #{w.step}", else: ""}", class: ""}
  defp walk_status(%{phase: "failed"} = w), do: %{text: "✕ #{w.name}: #{w.error}", class: "failed"}
end
