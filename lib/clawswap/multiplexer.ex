defmodule Clawswap.Multiplexer do
  @moduledoc """
  The terminal multiplexer the session runs in: `Clawswap.Zellij` or `Clawswap.Tmux`. Each one has

    * `check/0`: `:ok`, or `{:error, message}` when it's missing or too old
    * `up/2`: the command (program and arguments) that opens the session, or attaches to it when it's
      running; the function it's given gets the checkout ready, and is called only for a new session
    * `layout/1`: what `clawswap layout` prints
    * `servers/2`: the watcher's `%{stop:, start:}` for the servers' panes
  """

  alias Clawswap.{Tmux, Zellij}

  @tool Path.expand("../..", __DIR__)

  @doc "Runs a pane's command and leaves a shell there when it stops. A single argument goes through sh -c."
  def keep, do: Path.join(@tool, "bin/keep")
  def cli, do: Path.join(@tool, "bin/clawswap")

  @doc """
  The config's `multiplexer` (or CLAWSWAP_MULTIPLEXER) when it names one. Otherwise: the one clawswap runs
  inside (so the watcher drives the session it's in), zellij for a config with its own zellij `layout`,
  then zellij if it's installed and new enough, then tmux if it's installed.
  """
  def pick(project, env \\ System.get_env(), installed \\ &installed?/1) do
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

  defp installed?(mux), do: mux.check() == :ok
end
