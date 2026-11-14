defmodule ClawswapWeb.View do
  @moduledoc """
  What the pages show, worked out on the server, so their templates only lay it out: a project's branch
  page (from its watcher's state), the index of projects, and the pages' Stream Deck. `broadcast/2` sends
  a project's to its open pages when its state changes.
  """

  @views :clawswap_views

  @doc """
  A project's watcher changed (its on_change, in the daemon): keeps its state for the index page and the
  deck, and sends it to the project's open pages, the index page, the deck when it shows this project, and the API's /events streams.
  Without HOLOGRAM_START=1 (which bin/clawswap sets) Hologram isn't running, and there are no pages to tell.
  """
  def broadcast(id, state) do
    if :ets.whereis(@views) != :undefined, do: :ets.insert(@views, {id, state})
    ClawswapWeb.Api.notify(id, state)

    if Hologram.enabled?() do
      Hologram.Realtime.broadcast_action({:clawswap, id}, :state_changed, view: page(state))
      Hologram.Realtime.broadcast_action(:clawswap_index, :projects_changed, projects: index())
      if deck_target(Clawswap.DeckOwner.status()) == id, do: deck_changed()
    end

    :ok
  end

  @doc "The list of projects or the selected one changed: tells the index page and the deck."
  def projects_changed do
    if :ets.whereis(@views) != :undefined do
      ids = MapSet.new(Clawswap.Projects.cached(:list), & &1.id)
      for {id, _} <- :ets.tab2list(@views), not MapSet.member?(ids, id), do: :ets.delete(@views, id)
    end

    if Hologram.enabled?(), do: Hologram.Realtime.broadcast_action(:clawswap_index, :projects_changed, projects: index())
    deck_changed()
  end

  @doc "What the deck shows changed (its owner, what its keys serve, or that project): tells the pages' decks."
  def deck_changed do
    if Hologram.enabled?(), do: Hologram.Realtime.broadcast_action(:clawswap_deck, :draw, deck: deck())
    :ok
  end

  @doc "A project's watcher state as it last told the pages, or nil."
  def cached(id) do
    case :ets.whereis(@views) != :undefined && :ets.lookup(@views, id) do
      [{^id, state}] -> state
      _ -> nil
    end
  end

  @doc "The index page's rows: each project, the branch it's on, and how its last switch went."
  def index do
    selected = Clawswap.Projects.cached(:selected)

    for p <- Clawswap.Projects.cached(:list) do
      state = cached(p.id)
      view = state && page(state)

      %{
        id: p.id,
        name: p.name,
        root: p.root,
        href: "/p/#{p.id}",
        on: (view && view.on) || "",
        status: (view && index_status(state)) || "starting",
        class: if(p.id == selected, do: "project selected", else: "project")
      }
    end
  end

  defp index_status(%{switch: %{phase: "running"} = run}), do: "#{if run.pull, do: "pulling", else: "switching to #{run.target}"}: #{run.step}"
  defp index_status(%{switch: %{phase: "failed"} = run}), do: failure(run)
  defp index_status(%{error: error}) when is_binary(error), do: error
  defp index_status(%{dirty: true}), do: "uncommitted changes"
  defp index_status(_), do: ""

  @doc "The page's view of the watcher's state."
  def page(state) do
    run = state.switch
    current = state.current && state.current.branch
    running = match?(%{phase: "running"}, run)
    behind = (state.upstream && state.upstream.behind) || 0
    # Nothing to pull from: not on a branch, or the branch isn't on GitHub.
    pullable = current not in [nil, "HEAD"] and state.upstream != nil

    %{
      project: state.project,
      id: Map.get(state, :id),
      current: current || "",
      # The checkout's branch as its row names it, for the header.
      on: on(state, current),
      dirty: state.dirty,
      webhook: webhook(state),
      webhook_class: webhook_class(state.webhook),
      busy: running,
      # When the last switch or pull was asked for (nil before one): the page keeps a click's spinner
      # until this changes, so it knows the watcher has heard of it.
      run_at: run && Map.get(run, :at),
      # The switch or pull that finished last (its branch, and when), so a page in an app's iframe can tell
      # the app to reload when it changes; nil until one has.
      switched: switched(run),
      pull_label: pull_label(run, pullable, behind),
      pull_class:
        cond do
          running and match?(%{pull: true}, run) -> "running"
          not pullable -> "none"
          behind > 0 -> "behind"
          true -> ""
        end,
      pull_title: pull_title(current, pullable),
      error: (match?(%{phase: "failed"}, run) && failure(run)) || state.error,
      branches: Enum.map(state.branches, &branch(&1, state, run, current)),
      # Why there are no branches to show, nil when there are.
      empty: if(state.branches == [], do: Map.get(state, :empty)),
      walkthroughs: Enum.map(Map.get(state, :walkthroughs, []), &walkthrough(&1, Map.get(state, :walk))),
      walk: walk_status(Map.get(state, :walk))
    }
  end

  @doc """
  What the pages' Stream Deck (ClawswapWeb.StreamDeck) shows: which tab drives it (`tab`), what its keys
  serve (`keys`: "follow" or a project's id), the project they show now (`target`, `target_name`; nil
  when that project isn't running), the projects to pin them to, and the keys' images (`ClawswapWeb.View.keys/2`),
  nil when there's no project to show.
  """
  def deck(status \\ Clawswap.DeckOwner.status()) do
    projects = Clawswap.Projects.cached(:list)
    target = deck_target(status, projects)
    state = target && cached(target)
    follow = status.keys == "follow"

    %{
      tab: status.tab,
      keys: status.keys,
      target: target,
      target_name: Enum.find_value(projects, &(&1.id == target && &1.name)),
      projects: Enum.map(projects, &%{id: &1.id, name: &1.name}),
      images: state && keys(state, follow && length(projects) > 1 && project_key(projects, target))
    }
  end

  defp deck_target(status, projects \\ Clawswap.Projects.cached(:list)) do
    case status.keys do
      "follow" -> Clawswap.Projects.cached(:selected)
      id -> Enum.find_value(projects, &(&1.id == id && id))
    end
  end

  # The key that selects the next project, showing the one the keys follow now.
  defp project_key(projects, target) do
    index = Enum.find_index(projects, &(&1.id == target)) || 0
    name = Enum.at(projects, index).name
    Clawswap.Deck.branch_image(%{title: name, mark: "⇄", status: "Project #{index + 1}/#{length(projects)}", bar: "#58a6ff"})
  end

  @doc """
  The Stream Deck keys a page that drives a deck itself (ClawswapWeb.StreamDeck) shows: each branch's
  image, the walkthrough key's (with the walkthrough it plays, or nil) and the pull key's, and the key that
  selects the next project (`project`, nil when there's none). They're the OpenDeck plugin's (Clawswap.Deck),
  so the two decks look alike.
  """
  def keys(state, project \\ nil) do
    # The plugin reads the state as the API sends it: JSON, with string keys.
    json = state |> JSON.encode!() |> JSON.decode!()

    %{
      branches: Enum.map(json["branches"] || [], &%{branch: &1["branch"], image: Clawswap.Deck.branch_image(Clawswap.Deck.key_look(json, &1))}),
      walk: %{name: get_in(Clawswap.Deck.walkthrough(json) || %{}, ["name"]), image: Clawswap.Deck.branch_image(Clawswap.Deck.walk_look(json))},
      pull: Clawswap.Deck.branch_image(Clawswap.Deck.pull_look(json)),
      project: project || nil
    }
  end

  defp switched(%{phase: "done", doneAt: at, target: branch}), do: %{branch: branch, at: at}
  defp switched(_run), do: nil

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
  defp webhook(%{webhook: "unchecked", webhookError: error}) when is_binary(error), do: "webhook listening: #{error}"
  defp webhook(%{webhook: "unchecked"}), do: "webhook listening"
  defp webhook(%{webhook: "off", webhookError: error}) when is_binary(error), do: "webhook off: #{error}"
  defp webhook(%{webhook: "off"}), do: "webhook off: run clawswap smee"
  defp webhook(%{webhookError: error}) when is_binary(error), do: "webhook lost: #{error}"
  defp webhook(_), do: "webhook connecting"

  # Unchecked isn't a fault (it listens all the same), so it isn't shown as one.
  defp webhook_class("connected"), do: "ok"
  defp webhook_class("unchecked"), do: "unchecked"
  defp webhook_class(_), do: "off"

  # A failed switch or pull, said as which it was.
  defp failure(%{pull: true} = run), do: "Pull failed: #{run.error}"
  defp failure(run), do: "Couldn't switch to #{run.target}: #{run.error}"

  defp pull_label(%{pull: true, phase: "running", step: step}, _, _), do: "Pulling: #{step || "..."}"
  defp pull_label(_, false, _), do: "Pull (not on GitHub)"
  defp pull_label(_, _, 0), do: "↓ Pull (up to date)"
  defp pull_label(_, _, n), do: "↓ Pull #{n} new commit#{if n == 1, do: "", else: "s"}"

  defp pull_title(current, _) when current in [nil, "HEAD"], do: "Not on a branch, so there's nothing to pull"
  defp pull_title(current, false), do: "#{current} isn't on GitHub, so there's nothing to pull"
  defp pull_title(current, true), do: "Pull #{current} from GitHub"

  defp branch(b, state, run, current) do
    pr = Map.get(b, :pr)
    targeted = run != nil and run.target == b.branch

    {class, status} =
      cond do
        targeted and run.phase == "running" -> {"running", run.step || "Switching"}
        targeted and run.phase == "failed" -> {"failed", if(run.pull, do: "Pull failed", else: "Failed")}
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
