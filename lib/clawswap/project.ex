defmodule Clawswap.Project do
  @moduledoc """
  One project in the daemon: its log (`Clawswap.ProjectLog`), its watcher and its debug panel's Chrome
  (`Clawswap.Walkthrough.Debugger`), under a supervisor of their own. The log starts first and is the
  watcher's group leader, so what the watcher prints goes to the project's pane; if the log goes, the
  others restart with it.

  `Clawswap.Projects` starts one per registered project; `whereis/2` finds its parts by the project's id.
  """

  use Supervisor

  alias Clawswap.{Config, Multiplexer, ProjectLog, Watcher}
  alias Clawswap.Walkthrough.Debugger

  @registry Clawswap.Registry

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @doc "The registered name of a project's `part` (:log, :watcher, :debugger)."
  def via(id, part), do: {:via, Registry, {@registry, {part, id}}}

  @doc "The pid of a project's `part`, or nil."
  def whereis(id, part) do
    case Registry.lookup(@registry, {part, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    project = Keyword.fetch!(opts, :project)
    id = project.id
    on_change = opts[:on_change] || fn _ -> :ok end
    on_debug = opts[:on_debug] || fn _ -> :ok end
    reload = opts[:reload] || fn -> :ok end
    smee = project.host_env["CLAWSWAP_SMEE"] || Config.read_local(project)["smee"]

    watcher = [
      name: via(id, :watcher),
      group_leader: {:log, id},
      project: project,
      smee_url: if(smee in [nil, ""], do: nil, else: smee),
      servers: Multiplexer.pick(project).servers(project, &Watcher.log/1),
      run_step: Watcher.step_runner(project),
      on_change: on_change,
      # A switch or a save changed the config: start this project again on the new one (the others carry on).
      exit: fn _code -> reload.() end
    ]

    children = [
      {ProjectLog, [id: id, name: via(id, :log)] ++ Keyword.take(opts, [:echo])},
      {Watcher, watcher ++ Keyword.take(opts, [:refresh_git, :quiet])},
      {Debugger, name: via(id, :debugger), project: project, on_change: on_debug}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
