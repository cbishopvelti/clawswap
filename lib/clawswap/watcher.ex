defmodule Clawswap.Watcher do
  @moduledoc """
  The watcher that runs in the session's "clawswap" pane: keeps the branch list fresh (GitHub
  webhook through smee.io), and switches branch when a Stream Deck key or a page asks.

  Options: `project` (from `Clawswap.Config`), `servers` (`%{stop: fn name, note, start: fn name}`:
  `Clawswap.Zellij.servers/2` in the session, stand-ins in tests), `run_step` (runs one planned step),
  `smee_url`, `on_change` (called with the public state after every change; the web layer broadcasts it),
  `exit` (restarts the watcher after a switch changed its config), `refresh_git` (false skips git fetch).
  """

  use GenServer

  alias Clawswap.{Config, Git, GitHub, Plan, Smee}

  # Without webhooks (or if smee drops a delivery), look anyway this often.
  @fallback_ms 15 * 60_000
  # Webhook deliveries come in bursts (push + pull_request...), so wait a moment and look once.
  @debounce_ms 1500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The state the API and the keys show."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc "Looks at GitHub now, and returns the state once that's done."
  def refresh(server \\ __MODULE__), do: GenServer.call(server, {:after_refresh, :state}, :infinity)

  @doc "Switches to a listed branch: `{:ok, state}` once it has started, or `{:error, http_status, message}`."
  def switch_to(server \\ __MODULE__, branch), do: GenServer.call(server, {:after_refresh, {:switch, branch}}, :infinity)

  @doc """
  Pulls the checkout's branch: the same as switching to it, except that it works for any branch on
  origin, and leaves the servers alone when there's nothing new.
  """
  def pull(server \\ __MODULE__), do: GenServer.call(server, {:after_refresh, :pull}, :infinity)

  def log(text), do: IO.puts("\e[36m[clawswap]\e[0m #{text}")

  @impl true
  def init(opts) do
    project = Keyword.fetch!(opts, :project)
    smee_url = opts[:smee_url]

    state = %{
      project: project,
      servers: Keyword.fetch!(opts, :servers),
      run_step: Keyword.fetch!(opts, :run_step),
      on_change: opts[:on_change] || fn _ -> :ok end,
      exit: opts[:exit] || fn code -> System.halt(code) end,
      refresh_git: Keyword.get(opts, :refresh_git, true),
      pr_cache: nil,
      refreshing: nil,
      again: false,
      waiters: [],
      debounce: nil,
      view: %{
        project: project.name,
        base: project.base,
        current: nil,
        dirty: false,
        branches: [],
        # Whether the list comes from open PRs (a GitHub token was found).
        prs: false,
        # "off" (no channel set), "connecting" (set, not connected yet or lost), "connected".
        webhook: if(smee_url, do: "connecting", else: "off"),
        webhookError: nil,
        refreshedAt: nil,
        error: nil,
        # The checkout's branch on origin: how many commits it is ahead of the checkout (nil when the
        # branch isn't on origin).
        upstream: nil,
        # %{target, pull, phase: "running" | "done" | "failed", step, error, notes, at}
        switch: nil
      }
    }

    if smee_url do
      {:ok, _} = Smee.start_link(url: smee_url, owner: self(), log: &log/1)
    else
      if opts[:quiet] != true, do: log("No smee.io channel set (clawswap smee); looking for new branches every 15 minutes")
    end

    :timer.send_interval(@fallback_ms, :refresh_now)
    {:ok, start_refresh(state)}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.view, state}

  def handle_call({:after_refresh, what}, from, state) do
    {:noreply, start_refresh(%{state | waiters: state.waiters ++ [{from, what}]})}
  end

  @impl true
  def handle_cast({:run, changes}, state) do
    {:noreply, changed(put_in(state.view.switch, Map.merge(state.view.switch, changes)))}
  end

  def handle_cast({:run_finished, changed_paths}, state) do
    notes = state.view.switch.notes ++ Plan.notes(state.project.notes, changed_paths)
    Enum.each(notes, &log/1)
    state = changed(put_in(state.view.switch, %{state.view.switch | notes: notes, step: nil}))

    if Enum.any?(changed_paths, state.project.restart) do
      log("#{state.project.file} changed; restarting the watcher")
      state.exit.(75)
    end

    {:noreply, start_refresh(state)}
  end

  @impl true
  def handle_info(:refresh_now, state), do: {:noreply, start_refresh(%{state | debounce: nil})}

  def handle_info({:smee, :open}, state) do
    # Look for anything missed while disconnected.
    {:noreply, soon(changed(%{state | view: %{state.view | webhook: "connected", webhookError: nil}}))}
  end

  def handle_info({:smee, {:drop, reason}}, state) do
    {:noreply, changed(%{state | view: %{state.view | webhook: "connecting", webhookError: reason}})}
  end

  def handle_info({:smee, {:delivery, kind}}, state) do
    log("GitHub: #{kind}")
    {:noreply, soon(state)}
  end

  def handle_info({ref, result}, %{refreshing: ref} = state) do
    Process.demonitor(ref, [:flush])
    finish_refresh(state, result)
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{refreshing: ref} = state) do
    finish_refresh(state, {:error, Exception.format_exit(reason), state.pr_cache})
  end

  def handle_info(_, state), do: {:noreply, state}

  defp soon(state) do
    if state.debounce, do: Process.cancel_timer(state.debounce)
    %{state | debounce: Process.send_after(self(), :refresh_now, @debounce_ms)}
  end

  defp changed(state) do
    state.on_change.(state.view)
    state
  end

  # One refresh at a time; asking during one means another runs right after it.
  defp start_refresh(%{refreshing: nil} = state) do
    %{project: project, refresh_git: refresh_git, pr_cache: cache} = state
    task = Task.Supervisor.async_nolink(Clawswap.TaskSupervisor, fn -> snapshot(project, refresh_git, cache) end)
    %{state | refreshing: task.ref, again: false}
  end

  defp start_refresh(state), do: %{state | again: true}

  defp finish_refresh(state, result) do
    state = %{state | refreshing: nil}

    state =
      case result do
        {:ok, view, cache} ->
          changed(%{state | pr_cache: cache, view: Map.merge(state.view, view)})

        {:error, message, cache} ->
          log("Refresh failed: #{message}")
          changed(%{state | pr_cache: cache, view: %{state.view | error: message}})
      end

    if state.again do
      {:noreply, start_refresh(state)}
    else
      {waiters, state} = {state.waiters, %{state | waiters: []}}

      state =
        Enum.reduce(waiters, state, fn {from, what}, state ->
          {reply, state} = after_refresh(what, state)
          GenServer.reply(from, reply)
          state
        end)

      {:noreply, state}
    end
  end

  # What the watcher knows about the checkout and origin, read without blocking the watcher.
  defp snapshot(project, refresh_git, cache) do
    root = project.root
    if refresh_git, do: Git.fetch_origin(root)
    current = Git.current_branch(root)

    {pulls, cache} =
      with token when token != nil <- GitHub.token(), repo when repo != nil <- Git.github_repo(root) do
        case GitHub.read_pulls(repo, token, cache) do
          {:ok, pulls, cache} ->
            {pulls, cache}

          {:error, message, cache} ->
            log("Couldn't read pull requests (#{message}); showing every branch")
            {nil, cache}
        end
      else
        _ -> {nil, cache}
      end

    branches =
      Git.branch_list(
        remote: Git.remote_branches(root),
        pulls: pulls,
        merged: Git.merged_branches(root, project.base),
        base: project.base,
        current: current.branch,
        short_name: project.short_name
      )
      |> Enum.map(fn
        %{pr: pr} = b -> %{b | pr: %{number: pr.number, title: pr.title, updatedAt: pr.updated_at, draft: pr.draft}}
        b -> b
      end)

    view = %{
      current: current,
      dirty: Git.dirty?(root),
      upstream: Git.upstream(root, current.branch),
      branches: branches,
      prs: pulls != nil,
      refreshedAt: DateTime.utc_now() |> DateTime.to_iso8601(),
      error: nil
    }

    {:ok, view, cache}
  rescue
    error -> {:error, Exception.message(error), cache}
  end

  defp after_refresh(:state, state), do: {state.view, state}

  defp after_refresh({:switch, target}, state) do
    view = state.view

    cond do
      running?(view) -> {{:error, 409, "Already switching to #{view.switch.target}"}, state}
      not Enum.any?(view.branches, &(&1.branch == target)) -> {{:error, 404, "#{target} isn't one of the listed branches"}, state}
      view.dirty -> refuse(state, %{target: target, pull: false}, 409, "Uncommitted changes: commit or stash them first")
      true -> start_run(state, %{target: target, pull: false})
    end
  end

  defp after_refresh(:pull, state) do
    view = state.view
    target = view.current && view.current.branch
    run = %{target: target, pull: true}

    cond do
      running?(view) ->
        {{:error, 409, "Already switching to #{view.switch.target}"}, state}

      target in [nil, "HEAD"] ->
        refuse(state, run, 409, "Not on a branch")

      view.upstream == nil ->
        refuse(state, run, 404, "#{target} isn't on GitHub")

      view.upstream.behind == 0 ->
        reply_ok(changed(put_in(state.view.switch, Map.merge(run, %{phase: "done", step: nil, error: nil, notes: ["Already up to date"], at: now()}))))

      view.dirty ->
        refuse(state, run, 409, "Uncommitted changes: commit or stash them first")

      true ->
        start_run(state, run)
    end
  end

  defp running?(view), do: match?(%{phase: "running"}, view.switch)
  defp now, do: System.system_time(:millisecond)
  defp reply_ok(state), do: {{:ok, state.view}, state}

  # Refusals are kept in the state too, so the key that was pressed can say why nothing happened.
  defp refuse(state, run, status, message) do
    state = changed(put_in(state.view.switch, Map.merge(run, %{phase: "failed", step: nil, error: message, notes: [], at: now()})))
    {{:error, status, message}, state}
  end

  defp start_run(state, run) do
    run = Map.merge(run, %{phase: "running", step: "Stopping servers", error: nil, notes: [], at: now()})
    state = changed(put_in(state.view.switch, run))
    watcher = self()
    %{project: project, servers: servers, run_step: run_step} = state
    before = state.view.current && state.view.current.sha
    Task.Supervisor.start_child(Clawswap.TaskSupervisor, fn -> do_switch(watcher, project, servers, run_step, run, before) end)
    reply_ok(state)
  end

  defp do_switch(watcher, project, servers, run_step, run, before) do
    %{target: target} = run
    update = fn changes -> GenServer.cast(watcher, {:run, changes}) end
    log(if run.pull, do: "Pulling #{target}", else: "Switching to #{target}")
    # The step is kept here too, so a failure can say where it happened.
    step = fn label ->
      Process.put(:clawswap_step, label)
      update.(%{step: label})
    end

    {phase, changed_paths} =
      try do
        note = if run.pull, do: "Pulling #{target}...", else: "Switching to #{target}..."
        Process.put(:clawswap_step, "Stopping servers")
        Enum.each(project.server_names, &servers.stop.(&1, note))
        step.("Checking out #{target}")
        checkout!(project.root, target)
        after_sha = Git.head(project.root)
        changed_paths = if before && before != after_sha, do: elem(Git.changed(project.root, before, after_sha), 1), else: []

        for planned <- Plan.steps(project.steps, changed_paths) do
          step.(planned.label)
          log(planned.label)

          case run_step.(planned) do
            :ok -> :ok
            {:error, message} -> raise RuntimeError, message
          end
        end

        log("On #{target}")

        try do
          Config.mark_updated(project, after_sha)
        rescue
          error -> log("Couldn't note the update in #{project.local_file}: #{Exception.message(error)}")
        end

        {:done, changed_paths}
      rescue
        error ->
          message = "#{Process.get(:clawswap_step)}: #{Exception.message(error)}"
          update.(%{phase: "failed", error: message, at: System.system_time(:millisecond)})
          log("Failed at #{message}")
          {:failed, []}
      end

    # Start the servers whatever happened, so a failed step doesn't leave you without them.
    start_failure =
      Enum.find_value(project.server_names, fn name ->
        try do
          servers.start.(name)
          nil
        rescue
          error ->
            log("Couldn't start #{name}: #{Exception.message(error)}")
            "Starting #{name}: #{Exception.message(error)}"
        end
      end)

    cond do
      phase == :failed -> :ok
      start_failure -> update.(%{phase: "failed", error: start_failure, at: System.system_time(:millisecond)})
      true -> update.(%{phase: "done"})
    end

    GenServer.cast(watcher, {:run_finished, changed_paths})
  end

  defp checkout!(root, target) do
    git = &Git.git!(root, &1)

    if match?({:ok, _}, Git.git(root, ["rev-parse", "--verify", "--quiet", "refs/heads/#{target}"])) do
      git.(["checkout", target])
      git.(["merge", "--ff-only", "origin/#{target}"])
    else
      git.(["checkout", "-b", target, "--track", "origin/#{target}"])
    end
  end

  @doc "The real step runner: output goes to the watcher's pane (or the terminal, for `up` and `update`)."
  def step_runner(project) do
    fn step -> Clawswap.Run.stream(step.cmd, step.args, cwd: Path.expand(step.cwd, project.root), prefix: "  #{step.name} | ") end
  end
end
