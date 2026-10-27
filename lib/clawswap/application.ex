defmodule Clawswap.Application do
  @moduledoc """
  clawswap's OTP app. On its own it only runs the task supervisor; `clawswap watch` adds the watcher and
  the web endpoint for the project it was started in (`start_watcher/2`).
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{Task.Supervisor, name: Clawswap.TaskSupervisor}], strategy: :one_for_one, name: Clawswap.Supervisor)
  end

  @doc "The project the watcher runs, for the API and the page."
  def project, do: :persistent_term.get({__MODULE__, :project})

  @doc "Starts the watcher and the endpoint on the project's port, under the app's supervisor."
  def start_watcher(project, smee_url) do
    :persistent_term.put({__MODULE__, :project}, project)

    endpoint = Application.get_env(:clawswap, ClawswapWeb.Endpoint, [])
    Application.put_env(:clawswap, ClawswapWeb.Endpoint, Keyword.merge(endpoint, http: [ip: {127, 0, 0, 1}, port: project.port], server: true))

    watcher =
      {Clawswap.Watcher,
       project: project,
       smee_url: smee_url,
       servers: Clawswap.Zellij.servers(project, &Clawswap.Watcher.log/1),
       run_step: Clawswap.Watcher.step_runner(project),
       on_change: &ClawswapWeb.View.broadcast/1}

    {:ok, _} = Supervisor.start_child(Clawswap.Supervisor, watcher)
    {:ok, _} = Supervisor.start_child(Clawswap.Supervisor, ClawswapWeb.Endpoint)
    Clawswap.Watcher.log("API and page on http://127.0.0.1:#{project.port} (#{project.name}, base branch #{project.base})")
    :ok
  end
end
