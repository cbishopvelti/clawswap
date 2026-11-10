defmodule Clawswap.HostEnv do
  @moduledoc """
  Gives your project its own environment back. `bin/clawswap` runs clawswap on the Elixir its
  `.tool-versions` pins, which can differ from the one your project pins, and passes your PATH along as it
  was in your repo in `CLAWSWAP_HOST_PATH`. At start, clawswap puts that PATH back and drops the variables
  Erlang's `erl` sets for itself, so what it runs in your repo (the update steps, `git`, the servers it
  restarts) finds your project's `mix` and `elixir`, not clawswap's.

  Without `CLAWSWAP_HOST_PATH` (clawswap run with `mix` directly, the tests) it changes nothing.

  The daemon runs several projects, each registered from its own shell, so it leaves its own environment
  alone and gives each project's commands the environment that project was registered with instead
  (`for_project/2`).
  """

  # Set by erl for the VM it starts; another Elixir's erl sets its own, so they only mislead.
  @erl_vars ~w(ROOTDIR BINDIR EMU PROGNAME)

  @doc "Restores the host's environment in this VM, so every command clawswap starts inherits it."
  def restore do
    for {name, value} <- changes(System.get_env()) do
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end

    :ok
  end

  # clawswap's own, for the command it was started with; nothing a project's commands should see.
  @own_vars ~w(CLAWSWAP_EXEC CLAWSWAP_REPO CLAWSWAP_HOST_PATH CLAWSWAP_PIN_WARNED CLAWSWAP_DAEMON HOLOGRAM_START)

  @doc """
  The environment for a command run for a project registered with `host_env` (the shell it was registered
  from, as `{name, value}` pairs, or nil to unset), given this VM's own `env`: exactly the project's, so
  one project's shell (its direnv, its PATH) never leaks into another's. For `System.cmd/3`'s `env:` and
  `Clawswap.Run`'s.
  """
  def for_project(host_env, env \\ System.get_env())

  def for_project(nil, _env), do: []

  def for_project(host_env, env) do
    drop = @erl_vars ++ @own_vars
    keep = Map.drop(host_env, drop)
    Enum.sort(Map.to_list(keep)) ++ for(name <- Enum.sort(Map.keys(env)), not Map.has_key?(keep, name), do: {name, nil})
  end

  @doc """
  The changes `restore/0` makes to `env`: `{name, value}` to set, `{name, nil}` to remove.
  """
  def changes(env) do
    case env["CLAWSWAP_HOST_PATH"] do
      path when is_binary(path) and path != "" ->
        [{"PATH", path} | for(name <- @erl_vars, Map.has_key?(env, name), do: {name, nil})]

      _ ->
        []
    end
  end
end
