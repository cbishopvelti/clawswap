defmodule Clawswap.Projects do
  @moduledoc """
  The daemon's projects: one `Clawswap.Project` each, under a DynamicSupervisor, by id (`Clawswap.Config`'s
  `id`, from the session's name).

  A project comes in with `register/2`, from `clawswap up` and from the `clawswap watch` in its session's
  clawswap pane, which then follows the project's log (`attach/2`). The project leaves when no pane has
  followed it for a while (its session ended), or with `unregister/1`, or `down/1` (`clawswap down`), which
  also keeps its session's pane from bringing it back: a register `from_pane` is turned down until `up`
  registers it again. `reload/1` starts a project again
  on its config as it is now, which a switch that changed it and the settings page ask for.

  One project is the selected one: what the API's paths without /p/<id> answer for, and what Stream
  Deck keys that follow the selected project show. It's the first one to come in, until something picks
  another (`select/1`, `select_next/0`, or a page coming into view, `focus/1`).

  One project may be the focused one: the project whose page you last looked at (`focus/1`, which the
  branch page and the debug panel call when they come into view), so another tool, such as a notes app,
  can follow the project you're working on. Each change goes to `focus_listeners/0`'s registry key as
  `{:clawswap_focus, focused}`. Focusing a project selects it too, so the deck's keys show the project
  whose tab you're on; the deck's project key can still select another until you next change tab.

  Options: `on_change` (called with no arguments when the list or the selection changes), `project_opts`
  (more options for each `Clawswap.Project`), `detached_ms` (how long a project stays with no pane
  following it), `idle_ms` and `on_idle` (called once the daemon has had no project that long; nil for
  never).
  """

  use GenServer

  alias Clawswap.{Config, Project}

  @supervisor Clawswap.ProjectSupervisor
  @table :clawswap_projects

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Loads the config found from `cwd` with the shell's environment `env` (a map), and starts the project
  unless it's running already. `{:ok, project}` or `{:error, message}`; with `from_pane: true` (a session
  pane's `clawswap watch`), `{:error, :down}` for a project `down/1` took down.
  """
  def register(cwd, env, opts \\ [], server \\ __MODULE__) do
    case load(cwd, env) do
      {:ok, project} -> GenServer.call(server, {:register, project, cwd, opts[:from_pane] == true}, 60_000)
      {:error, message} -> {:error, message}
    end
  end

  @doc "Stops a project and forgets it."
  def unregister(id, server \\ __MODULE__), do: GenServer.call(server, {:unregister, id})

  @doc """
  Stops a project for good (`clawswap down`): as `unregister/1`, and until `clawswap up` registers it again,
  its session's panes can't bring it back. `:ok`, or `:none` when it wasn't running.
  """
  def down(id, server \\ __MODULE__), do: GenServer.call(server, {:down, id})

  @doc "Starts the project again on its config as it is now. It keeps running as it was if the config doesn't load."
  def reload(id, server \\ __MODULE__), do: GenServer.cast(server, {:reload, id})

  @doc "The projects, in the order they came in: `%{id, name, root, port}` each."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc ~s(A project by its id, or the selected one for "selected" or nil; nil when there's no such project.)
  def get(id, server \\ __MODULE__), do: GenServer.call(server, {:get, id})

  @doc "The selected project's id, or nil when there are none."
  def selected(server \\ __MODULE__), do: GenServer.call(server, :selected)

  @doc "Selects a project by its id: `:ok` or `{:error, message}`."
  def select(id, server \\ __MODULE__), do: GenServer.call(server, {:select, id})

  @doc "Selects the project after the selected one (the first after the last), and returns its id."
  def select_next(server \\ __MODULE__), do: GenServer.call(server, :select_next)

  @doc """
  Makes the project the focused one, the project whose page was last in view, and selects it:
  `{:ok, focused}` or `{:error, message}`. See `focused/0`.
  """
  def focus(id, server \\ __MODULE__), do: GenServer.call(server, {:focus, id})

  @doc "The focused project as `%{project: id, root: root, at: ms}` (`at` from `System.os_time(:millisecond)`), or nil when none is."
  def focused(server \\ __MODULE__), do: GenServer.call(server, :focused)

  @doc "The `Clawswap.Listeners` key that each change of the focused project is sent to, as `{:clawswap_focus, focused}`."
  def focus_listeners, do: :focus

  @doc "`pid` follows the project's log (a pane's `clawswap watch`): the project stays while one does."
  def attach(id, pid \\ self(), server \\ __MODULE__), do: GenServer.call(server, {:attach, id, pid})

  def detach(id, pid \\ self(), server \\ __MODULE__), do: GenServer.call(server, {:detach, id, pid})

  @impl true
  def init(opts) do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.insert(@table, [{:list, []}, {:selected, nil}])
    # Each project's watcher state as it last told its pages (ClawswapWeb.View.broadcast/2).
    if :ets.whereis(:clawswap_views) == :undefined, do: :ets.new(:clawswap_views, [:named_table, :public, read_concurrency: true])

    state = %{
      projects: %{},
      order: [],
      selected: nil,
      focused: nil,
      on_change: opts[:on_change] || fn -> :ok end,
      project_opts: opts[:project_opts] || [],
      detached_ms: opts[:detached_ms] || 30_000,
      # A project `clawswap up` registered has this long for its pane to start following it.
      first_attach_ms: opts[:first_attach_ms] || 120_000,
      idle_ms: opts[:idle_ms],
      on_idle: opts[:on_idle],
      idle: nil,
      # Projects `down/1` took down, which a pane's register can't bring back.
      down: MapSet.new()
    }

    # Projects a previous run of this server started (it crashed and was restarted) are unknown to it now.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor), do: DynamicSupervisor.terminate_child(@supervisor, pid)

    {:ok, idle(state)}
  end

  @impl true
  def handle_call({:register, project, cwd, from_pane}, _from, state) do
    id = project.id
    down = MapSet.member?(state.down, id)
    state = if from_pane, do: state, else: %{state | down: MapSet.delete(state.down, id)}

    case state.projects[id] do
      _ when from_pane and down ->
        {:reply, {:error, :down}, state}

      %{project: %{root: root}} = entry when root == project.root ->
        {:reply, {:ok, entry.project}, state}

      %{project: other} ->
        {:reply, {:error, "#{other.root} is already running as #{id}: give #{project.root} another session: in its config"}, state}

      nil ->
        case start(project, state) do
          {:ok, pid} ->
            entry = %{project: project, cwd: cwd, pid: pid, panes: %{}, timer: nil}
            entry = arm(entry, id, state.first_attach_ms)
            state = %{state | projects: Map.put(state.projects, id, entry), order: state.order ++ [id], selected: state.selected || id}
            log(id, "Registered #{project.name} (#{project.root}) as /p/#{id}")
            {:reply, {:ok, project}, state |> no_idle() |> changed()}

          {:error, reason} ->
            {:reply, {:error, "Couldn't start #{project.name}: #{inspect(reason)}"}, state}
        end
    end
  end

  def handle_call({:unregister, id}, _from, state), do: {:reply, :ok, drop(state, id)}

  def handle_call({:down, id}, _from, state) do
    answer = if Map.has_key?(state.projects, id), do: :ok, else: :none
    if answer == :ok, do: log(id, "Taken down (clawswap down)")
    {:reply, answer, drop(%{state | down: MapSet.put(state.down, id)}, id)}
  end

  def handle_call(:list, _from, state), do: {:reply, summary(state), state}

  def handle_call({:get, id}, _from, state) do
    id = if id in [nil, "selected"], do: state.selected, else: id
    {:reply, get_in(state.projects, [id, :project]), state}
  end

  def handle_call(:selected, _from, state), do: {:reply, state.selected, state}

  def handle_call({:select, id}, _from, state) do
    cond do
      not Map.has_key?(state.projects, id) -> {:reply, {:error, "No project #{id}"}, state}
      id == state.selected -> {:reply, :ok, state}
      true -> {:reply, :ok, changed(%{state | selected: id})}
    end
  end

  def handle_call({:focus, id}, _from, state) do
    case state.projects[id] do
      nil ->
        {:reply, {:error, "No project #{id}"}, state}

      %{project: project} ->
        state = focus_on(state, %{project: id, root: project.root, at: System.os_time(:millisecond)})
        # The page you're looking at is the project you're working on: deck keys that follow the
        # selection show it, so changing browser tab changes the keys.
        state = if id == state.selected, do: state, else: changed(%{state | selected: id})
        {:reply, {:ok, state.focused}, state}
    end
  end

  def handle_call(:focused, _from, state), do: {:reply, state.focused, state}

  def handle_call(:select_next, _from, %{order: []} = state), do: {:reply, nil, state}

  def handle_call(:select_next, _from, state) do
    index = Enum.find_index(state.order, &(&1 == state.selected)) || -1
    id = Enum.at(state.order, rem(index + 1, length(state.order)))
    {:reply, id, if(id == state.selected, do: state, else: changed(%{state | selected: id}))}
  end

  def handle_call({:attach, id, pid}, _from, state) do
    case state.projects[id] do
      nil ->
        {:reply, {:error, "No project #{id}"}, state}

      entry ->
        entry = if Map.has_key?(entry.panes, pid), do: entry, else: put_in(entry.panes[pid], Process.monitor(pid))
        {:reply, :ok, put_in(state.projects[id], disarm(entry))}
    end
  end

  def handle_call({:detach, id, pid}, _from, state), do: {:reply, :ok, gone(state, id, pid)}

  @impl true
  def handle_cast({:reload, id}, state) do
    case state.projects[id] do
      nil ->
        {:noreply, state}

      entry ->
        case load(entry.cwd, entry.project.host_env) do
          {:ok, %{id: ^id} = project} ->
            :ok = DynamicSupervisor.terminate_child(@supervisor, entry.pid)

            case start(project, state) do
              {:ok, pid} ->
                log(id, "Started #{project.name} again on its config as it is now")
                {:noreply, put_in(state.projects[id], %{entry | project: project, pid: pid})}

              {:error, reason} ->
                log(id, "Couldn't start #{project.name} again: #{inspect(reason)}")
                {:noreply, drop(state, id)}
            end

          {:ok, project} ->
            log(id, "The config changed the session to #{project.session}; run clawswap up again to use it")
            {:noreply, state}

          {:error, message} ->
            log(id, "The config doesn't load (#{message}); carrying on with the one before")
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    ids = for {id, entry} <- state.projects, Map.has_key?(entry.panes, pid), do: id
    {:noreply, Enum.reduce(ids, state, &gone(&2, &1, pid))}
  end

  # No pane has followed the project for a while: its session has ended.
  def handle_info({:detached, id, ref}, state) do
    case state.projects[id] do
      %{timer: {^ref, _}, panes: panes} when map_size(panes) == 0 ->
        log(id, "No clawswap pane follows #{id} any more; stopping it")
        {:noreply, drop(state, id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:idle, ref}, %{idle: ref, projects: projects} = state) when map_size(projects) == 0 do
    state.on_idle && state.on_idle.()
    {:noreply, %{state | idle: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # A config is code: one that doesn't run is an error, not a crash.
  defp load(cwd, env) do
    Config.load(cwd, env)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp start(project, state) do
    id = project.id
    on_change = Keyword.get(state.project_opts, :on_change, fn _id, _view -> :ok end)
    on_debug = Keyword.get(state.project_opts, :on_debug, fn _project, _view -> :ok end)
    me = self()

    opts =
      Keyword.merge(state.project_opts,
        project: project,
        on_change: &on_change.(id, &1),
        on_debug: &on_debug.(project, &1),
        reload: fn -> reload(id, me) end
      )

    DynamicSupervisor.start_child(@supervisor, Supervisor.child_spec({Project, opts}, restart: :temporary))
  end

  defp gone(state, id, pid) do
    case state.projects[id] do
      nil ->
        state

      entry ->
        {ref, panes} = Map.pop(entry.panes, pid)
        if ref, do: Process.demonitor(ref, [:flush])
        entry = %{entry | panes: panes}
        entry = if panes == %{}, do: arm(entry, id, state.detached_ms), else: entry
        put_in(state.projects[id], entry)
    end
  end

  defp arm(entry, id, ms) do
    entry = disarm(entry)
    ref = make_ref()
    %{entry | timer: {ref, Process.send_after(self(), {:detached, id, ref}, ms)}}
  end

  defp disarm(%{timer: {_, timer}} = entry) do
    Process.cancel_timer(timer)
    %{entry | timer: nil}
  end

  defp disarm(entry), do: entry

  defp drop(state, id) do
    case Map.pop(state.projects, id) do
      {nil, _} ->
        state

      {entry, projects} ->
        disarm(entry)
        Enum.each(entry.panes, fn {_, ref} -> Process.demonitor(ref, [:flush]) end)
        DynamicSupervisor.terminate_child(@supervisor, entry.pid)
        order = List.delete(state.order, id)
        selected = if state.selected == id, do: List.first(order), else: state.selected
        state = if match?(%{project: ^id}, state.focused), do: focus_on(state, nil), else: state
        changed(idle(%{state | projects: projects, order: order, selected: selected}))
    end
  end

  # With no projects left, the daemon goes after idle_ms.
  defp idle(%{idle_ms: ms, projects: projects} = state) when is_integer(ms) and map_size(projects) == 0 do
    ref = make_ref()
    Process.send_after(self(), {:idle, ref}, ms)
    %{state | idle: ref}
  end

  defp idle(state), do: state

  defp no_idle(state), do: %{state | idle: nil}

  # Tells each listener (the API's /focus/events streams) about the focused project, every time a page
  # reports, so a tool following it hears the same project coming back into view too.
  defp focus_on(state, focused) do
    if Process.whereis(Clawswap.Listeners),
      do: Registry.dispatch(Clawswap.Listeners, focus_listeners(), fn entries -> for {pid, _} <- entries, do: send(pid, {:clawswap_focus, focused}) end)

    %{state | focused: focused}
  end

  defp summary(state) do
    Enum.map(state.order, fn id ->
      p = state.projects[id].project
      %{id: id, name: p.name, root: p.root, port: p.port, session: p.session}
    end)
  end

  defp changed(state) do
    :ets.insert(@table, [{:list, summary(state)}, {:selected, state.selected}])
    state.on_change.()
    state
  end

  @doc """
  The list and the selection as they were last changed, read without asking this server (so a watcher
  telling its pages about a change can, without waiting on it): `cached(:list)`, `cached(:selected)`.
  """
  def cached(key) do
    case :ets.whereis(@table) != :undefined && :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> if key == :list, do: [], else: nil
    end
  end

  defp log(id, text), do: IO.puts("\e[36m[clawswap]\e[0m [#{id}] #{text}")
end
