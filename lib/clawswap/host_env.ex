defmodule Clawswap.HostEnv do
  @moduledoc """
  Gives your project its own environment back. `bin/clawswap` runs clawswap on the Elixir its
  `.tool-versions` pins, which can differ from the one your project pins, and passes your environment
  along as it was in your repo: all of it in the file `CLAWSWAP_HOST_ENV` names (`env -0`), and your PATH
  in `CLAWSWAP_HOST_PATH`. Every command puts that environment back before it does anything
  (`Clawswap.CLI.main/1`), so what it runs in your repo (the update steps, `git`, the servers it restarts)
  and the environment it registers your project with have your project's `mix` and `elixir`, not
  clawswap's. A step run on clawswap's Elixir would rebuild every dependency in your `_build`, and your
  own server would then rebuild them again on yours.

  With the file, what the version manager added for clawswap goes too (mise's `MIX_HOME` and
  `MIX_ARCHIVES`, say), along with the variables Erlang's `erl` sets for itself. Without it (an `env`
  with no `-0`), only the PATH is put back and erl's variables dropped. Without either (clawswap run with
  `mix` directly, the tests) it changes nothing.

  The daemon runs several projects, each registered from its own shell, so it leaves its own environment
  alone and gives each project's commands the environment that project was registered with instead
  (`for_project/2`).
  """

  # Set by erl for the VM it starts; another Elixir's erl sets its own, so they only mislead.
  @erl_vars ~w(ROOTDIR BINDIR EMU PROGNAME)

  @doc """
  Restores the host's environment in this VM, so every command clawswap starts inherits it. The
  environment clawswap itself was started with is kept for `own/0`.
  """
  def restore do
    env = System.get_env()
    unless :persistent_term.get({__MODULE__, :own}, nil), do: :persistent_term.put({__MODULE__, :own}, env)

    for {name, value} <- changes(env) do
      try do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      rescue
        # A value this VM can't write in its encoding (UTF-8 under a latin1 locale): it reads differently
        # from the file than from the environment, and is the host's already.
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc "The environment clawswap was started with, before `restore/0`: its own Elixir's, for compiling itself."
  def own, do: :persistent_term.get({__MODULE__, :own}, nil) || System.get_env()

  # clawswap's own, for the command it was started with; nothing a project's commands should see.
  @own_vars ~w(CLAWSWAP_EXEC CLAWSWAP_REPO CLAWSWAP_HOST_PATH CLAWSWAP_HOST_ENV CLAWSWAP_PIN_WARNED CLAWSWAP_DAEMON HOLOGRAM_START)

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
  The changes `restore/0` makes to `env`: `{name, value}` to set, `{name, nil}` to remove. `read` reads
  the file `CLAWSWAP_HOST_ENV` names.
  """
  def changes(env, read \\ &File.read/1) do
    case host(env["CLAWSWAP_HOST_ENV"], read) do
      nil ->
        path_changes(env)

      host ->
        # clawswap's own stay, for the command that is running.
        host = Map.drop(host, @own_vars)
        set = for {name, value} <- Enum.sort(host), env[name] != value, do: {name, value}
        set ++ for(name <- Enum.sort(Map.keys(env)), not Map.has_key?(host, name), name not in @own_vars, do: {name, nil})
    end
  end

  # The host's environment from `env -0`'s output: name=value entries, each ended by a NUL.
  defp host(file, read) when is_binary(file) and file != "" do
    case read.(file) do
      {:ok, data} ->
        vars = for entry <- String.split(data, <<0>>, trim: true), [name, value] <- [String.split(entry, "=", parts: 2)], into: %{}, do: {name, value}
        if vars["PATH"], do: vars

      _ ->
        nil
    end
  end

  defp host(_file, _read), do: nil

  defp path_changes(env) do
    case env["CLAWSWAP_HOST_PATH"] do
      path when is_binary(path) and path != "" ->
        [{"PATH", path} | for(name <- @erl_vars, Map.has_key?(env, name), do: {name, nil})]

      _ ->
        []
    end
  end
end
