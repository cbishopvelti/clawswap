defmodule Clawswap.Application do
  @moduledoc """
  clawswap's OTP app. On its own it runs the task supervisor and an empty list of projects
  (`Clawswap.Projects`); `clawswap daemon` adds the web endpoint, which serves every project registered
  with it (`start_daemon/1`).
  """

  use Application

  @impl true
  def start(_type, _args) do
    # clawswap may run on another Elixir than your project: what it starts in your repo gets yours back.
    # (The daemon leaves its own alone: each project's commands get the environment it was registered with.)
    Clawswap.HostEnv.restore()

    children = [
      {Task.Supervisor, name: Clawswap.TaskSupervisor},
      {Registry, keys: :unique, name: Clawswap.Registry},
      # GET /p/<id>/events streams, by project id (ClawswapWeb.Api.notify/2), and GET /focus/events streams,
      # under Clawswap.Projects.focus_listeners/0.
      {Registry, keys: :duplicate, name: Clawswap.Listeners},
      {DynamicSupervisor, name: Clawswap.ProjectSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Clawswap.Supervisor)
  end

  @doc """
  Starts the daemon on `port`: the projects, the Stream Deck's owner and the endpoint, under the app's
  supervisor. Options: `idle_ms` (the daemon stops after that long with no projects; nil for never).
  """
  def start_daemon(port, opts \\ []) do
    endpoint = Application.get_env(:clawswap, ClawswapWeb.Endpoint, [])
    # A stopping daemon closes the pages' event streams at once rather than after Bandit's 15 seconds: a
    # page only reconnects (to the daemon `clawswap up` starts next) once its stream has closed.
    http = [ip: {127, 0, 0, 1}, port: port, thousand_island_options: [shutdown_timeout: 500]]
    Application.put_env(:clawswap, ClawswapWeb.Endpoint, Keyword.merge(endpoint, http: http, server: true))
    :persistent_term.put({__MODULE__, :port}, port)

    projects =
      {Clawswap.Projects,
       on_change: &ClawswapWeb.View.projects_changed/0,
       idle_ms: Keyword.get(opts, :idle_ms),
       on_idle: fn ->
         Clawswap.Watcher.log("No projects for a while; the daemon stops (clawswap up starts it again)")
         System.stop(0)
       end,
       project_opts: [on_change: &ClawswapWeb.View.broadcast/2, on_debug: &ClawswapWeb.DebugView.broadcast/2]}

    {:ok, _} = Supervisor.start_child(Clawswap.Supervisor, {Clawswap.DeckOwner, on_change: &ClawswapWeb.View.deck_changed/0})
    {:ok, _} = Supervisor.start_child(Clawswap.Supervisor, projects)
    {:ok, _} = Supervisor.start_child(Clawswap.Supervisor, ClawswapWeb.Endpoint)
    Clawswap.Watcher.log("clawswap daemon on http://127.0.0.1:#{port}")
    :ok
  end

  @doc "The daemon's port (nil outside it)."
  def port, do: :persistent_term.get({__MODULE__, :port}, nil)
end
