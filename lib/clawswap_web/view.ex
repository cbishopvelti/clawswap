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
      # The checkout's branch as its row names it, for the header.
      on: on(state, current),
      dirty: state.dirty,
      webhook: webhook(state),
      webhook_class: if(state.webhook == "connected", do: "ok", else: "off"),
      busy: running,
      pull_label: pull_label(run, current, behind),
      pull_class:
        cond do
          running and match?(%{pull: true}, run) -> "running"
          behind > 0 -> "behind"
          true -> ""
        end,
      error: (match?(%{phase: "failed"}, run) && "#{run.target}: #{run.error}") || state.error,
      branches: Enum.map(state.branches, &branch(&1, state, run, current)),
      walkthroughs: Enum.map(Map.get(state, :walkthroughs, []), &walkthrough(&1, Map.get(state, :walk))),
      walk: walk_status(Map.get(state, :walk)),
      keys: keys(state)
    }
  end

  @doc """
  The Stream Deck keys a page that drives a deck itself (ClawswapWeb.StreamDeck) shows: each branch's
  image, the walkthrough key's (with the walkthrough it plays, or nil) and the pull key's. They're the OpenDeck plugin's (Clawswap.Deck), so the two decks look alike.
  """
  def keys(state) do
    # The plugin reads the state as the API sends it: JSON, with string keys.
    json = state |> JSON.encode!() |> JSON.decode!()

    %{
      branches: Enum.map(json["branches"] || [], &%{branch: &1["branch"], image: Clawswap.Deck.branch_image(Clawswap.Deck.key_look(json, &1))}),
      walk: %{name: get_in(Clawswap.Deck.walkthrough(json) || %{}, ["name"]), image: Clawswap.Deck.branch_image(Clawswap.Deck.walk_look(json))},
      pull: Clawswap.Deck.branch_image(Clawswap.Deck.pull_look(json))
    }
  end

  defp on(_state, nil), do: nil

  defp on(state, current) do
    case Enum.find(state.branches, &(&1.branch == current)) do
      %{pr: %{title: title}} -> title
      %{short: short} -> short
      _ -> current
    end
  end

  # A walkthrough's button: new ones (the branch added or changed them) are marked, and the one running or
  # last run shows how it went.
  defp walkthrough(w, walk) do
    last = walk && walk.name == w.name && walk.phase

    %{
      name: w.name,
      class: Enum.join(Enum.reject([w.new && "new", last], &(&1 in [nil, false])), " "),
      title: if(w.new, do: "#{w.path}, new on this branch", else: w.path)
    }
  end

  defp walk_status(nil), do: %{text: nil, class: ""}
  defp walk_status(%{phase: "running"} = w), do: %{text: "▶ #{w.name}: #{w.step || "opening Chrome"}", class: "running"}
  defp walk_status(%{phase: "passed"} = w), do: %{text: "✓ #{w.name} ran to the end", class: "passed"}
  defp walk_status(%{phase: "failed"} = w), do: %{text: "✕ #{w.name}: #{w.error}", class: "failed"}

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
        (b.branch == current and b.sha) && b.sha != state.current.sha -> {"behind", "New commits"}
        b.branch == current -> {"current", if(state.dirty, do: "Uncommitted", else: "Current")}
        true -> {"", ""}
      end

    {mark, mark_class, mark_title} = merge_status(b, pr, state)

    %{
      branch: b.branch,
      title: (pr && pr.title) || b.short,
      number: pr && "##{pr.number}",
      mark: mark,
      mark_class: mark_class,
      mark_title: mark_title,
      class: class,
      # The checkout's row is marked as such whatever else it shows (a switch, new commits).
      row_class: if(b.branch == current, do: String.trim("#{class} checkout"), else: class),
      status: status
    }
  end

  # A row's merge status, as bmx's branch menu shows it: the symbol, its class (its colour) and what it
  # means. ⎇ the base, ✓ merged into it, ● open PR, ◌ draft PR, ○ neither.
  defp merge_status(b, pr, state) do
    base = Map.get(state, :base)

    cond do
      b.branch == base -> {"⎇", "base", "#{base}, the branch the others merge into"}
      Map.get(b, :merged) -> {"✓", "merged", "Merged into #{base}"}
      pr && pr.draft -> {"◌", "draft", "Draft PR ##{pr.number}, not merged yet"}
      pr -> {"●", "open", "Open PR ##{pr.number}, not merged yet"}
      Map.get(state, :prs) -> {"○", "", "Not merged into #{base}, and no open PR"}
      true -> {"○", "", "Not merged into #{base}"}
    end
  end
end
