defmodule Clawswap.HostEnv do
  @moduledoc """
  Gives your project its own environment back. `bin/clawswap` runs clawswap on the Elixir its
  `.tool-versions` pins, which can differ from the one your project pins, and passes your PATH along as it
  was in your repo in `CLAWSWAP_HOST_PATH`. At start, clawswap puts that PATH back and drops the variables
  Erlang's `erl` sets for itself, so what it runs in your repo (the update steps, `git`, the servers it
  restarts) finds your project's `mix` and `elixir`, not clawswap's.

  Without `CLAWSWAP_HOST_PATH` (clawswap run with `mix` directly, the tests) it changes nothing.
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
