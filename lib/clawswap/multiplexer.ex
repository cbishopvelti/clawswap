defmodule Clawswap.Multiplexer do
  @moduledoc """
  The terminal multiplexer the session runs in: `Clawswap.Zellij` or `Clawswap.Tmux`. Each one has

    * `check/0`: `:ok`, or `{:error, message}` when it's missing or too old
    * `up/2`: the command (program and arguments) that opens the session, or attaches to it when it's
      running; the function it's given gets the checkout ready, and is called only for a new session
    * `layout/1`: what `clawswap layout` prints
    * `servers/2`: the watcher's `%{stop:, start:}` for the servers' panes
    * `kill_session/1`: ends the session of that name (`clawswap down`): `:ok`, or `:none`
  """

  alias Clawswap.{Tmux, Zellij}

  @tool Path.expand("../..", __DIR__)

  @doc "Runs a pane's command and leaves a shell there when it stops. A single argument goes through sh -c."
  def keep, do: Path.join(@tool, "bin/keep")
  def cli, do: Path.join(@tool, "bin/clawswap")

  @doc """
  A server's pane command: its command through `keep/0`, under `env` with the server's
  `Clawswap.Ports.marker/2`, which the server's processes (and the shell `keep` leaves, so a restart from
  there too) inherit. That's how the port it listens on is found when it had to take another.
  """
  def server_command(project, name),
    do: ["env", Clawswap.Ports.marker(project, name), keep() | List.wrap(project.servers[name].command)]

  @doc """
  The session's clawswap pane's command: `clawswap watch`, with the override configs `up` was given (as
  full paths, since the pane runs in the config's folder), so it runs the same project.
  """
  def watch(project), do: [cli(), "watch" | Enum.map(project[:overrides] || [], &Path.expand(&1, project.root))]

  @doc """
  `up`'s command for the session, run with CLAWSWAP_OVERRIDES set when there are override configs, so the
  clawswap commands run in the session's panes load the same project. (tmux passes it on only when its
  server starts with the session; otherwise its panes get the server's environment.)
  """
  def with_overrides(%{overrides: [_ | _] = overrides} = project, command),
    do: ["env", "CLAWSWAP_OVERRIDES=" <> Enum.map_join(overrides, ",", &Path.expand(&1, project.root)) | command]

  def with_overrides(_project, command), do: command

  @doc """
  The config's `multiplexer` (or CLAWSWAP_MULTIPLEXER) when it names one. Otherwise: the one clawswap runs
  inside (so the watcher drives the session it's in), zellij for a config with its own zellij `layout`,
  then zellij if it's installed and new enough, then tmux if it's installed.
  """
  def pick(project, env \\ nil, installed \\ &installed?/1) do
    # The shell the project was registered from: inside zellij or tmux there, not in the daemon.
    env = env || project[:host_env] || System.get_env()

    case project[:multiplexer] && to_string(project.multiplexer) do
      "zellij" -> Zellij
      "tmux" -> Tmux
      nil -> detect(project, env, installed)
      other -> raise ArgumentError, ~s(multiplexer is "zellij" or "tmux", not #{inspect(other)})
    end
  end

  defp detect(project, env, installed) do
    cond do
      env["ZELLIJ"] -> Zellij
      env["TMUX"] -> Tmux
      project[:layout] -> Zellij
      installed.(Zellij) -> Zellij
      installed.(Tmux) -> Tmux
      true -> Zellij
    end
  end

  @doc """
  Ends the session named `session` in whichever installed multiplexer has it (a project's config may have
  changed multiplexer since its session started). The ones that had it, e.g. `[Clawswap.Zellij]`.
  """
  def kill_session(session, installed \\ &installed?/1) do
    for mux <- [Zellij, Tmux], installed.(mux), mux.kill_session(session) == :ok, do: mux
  end

  defp installed?(mux), do: mux.check() == :ok
end
