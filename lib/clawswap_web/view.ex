defmodule ClawswapWeb.View do
  @moduledoc """
  What the branch page shows, worked out on the server from the watcher's state, so the page's template
  only lays it out. `broadcast/1` sends it to every open page when the state changes.
  """

  @doc """
  Sends the new state to the open pages (the watcher's on_change). Without HOLOGRAM_START=1 (which
  bin/clawswap sets) Hologram isn't running, and there are no pages to tell.
  """
  def broadcast(state) do
    if Hologram.enabled?(), do: Hologram.Realtime.broadcast_action(:clawswap, :state_changed, view: page(state))
    :ok
  end

  @doc "The page's view of the watcher's state."
  def page(state) do
    run = state.switch
    current = state.current && state.current.branch
    running = match?(%{phase: "running"}, run)
    behind = (state.upstream && state.upstream.behind) || 0

    %{
      project: state.project,
      current: current || "",
      dirty: state.dirty,
      webhook: webhook(state),
      webhook_class: if(state.webhook == "connected", do: "ok", else: "off"),
      busy: running,
      pull_label: pull_label(run, current, behind),
      pull_class: cond do
        running and match?(%{pull: true}, run) -> "running"
        behind > 0 -> "behind"
        true -> ""
      end,
      error: (match?(%{phase: "failed"}, run) && "#{run.target}: #{run.error}") || state.error,
      branches: Enum.map(state.branches, &branch(&1, state, run, current))
    }
  end

  defp webhook(%{webhook: "connected"}), do: "webhook on"
  defp webhook(%{webhook: "off"}), do: "webhook off: run clawswap smee"
  defp webhook(%{webhookError: error}) when is_binary(error), do: "webhook lost: #{error}"
  defp webhook(_), do: "webhook connecting"

  defp pull_label(%{pull: true, phase: "running", step: step}, _, _), do: "Pulling: #{step || "..."}"
  defp pull_label(_, nil, _), do: "Pull"
  defp pull_label(_, _, 0), do: "↓ Pull (up to date)"
  defp pull_label(_, _, n), do: "↓ Pull #{n} new commit#{if n == 1, do: "", else: "s"}"

  defp branch(b, state, run, current) do
    pr = Map.get(b, :pr)
    targeted = run != nil and run.target == b.branch

    {class, status} =
      cond do
        targeted and run.phase == "running" -> {"running", run.step || "Switching"}
        targeted and run.phase == "failed" -> {"failed", "Failed"}
        b.branch == current and b.sha && b.sha != state.current.sha -> {"behind", "New commits"}
        b.branch == current -> {"current", if(state.dirty, do: "Uncommitted", else: "Current")}
        true -> {"", ""}
      end

    %{
      branch: b.branch,
      title: (pr && pr.title) || b.short,
      number: pr && "##{pr.number}",
      # ✓ merged into the base, ● open PR, ◌ draft PR, ○ neither.
      mark: cond do
        Map.get(b, :merged) -> "✓"
        pr && pr.draft -> "◌"
        pr -> "●"
        true -> "○"
      end,
      class: class,
      status: status
    }
  end
end
