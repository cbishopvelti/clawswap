defmodule Clawswap.OpenDeck do
  @moduledoc """
  OpenDeck on this machine, for `clawswap reload`: where its plugins folder is, copying clawswap's plugin
  into it, and quitting and starting OpenDeck (it only starts plugins when it launches).

  OpenDeck is either the Flatpak (`me.amankhanna.opendeck`, found by its folder under `~/.var/app`) or an
  `opendeck` on the PATH (the .deb, .rpm or AppImage). Two variables override what's found:

    * `CLAWSWAP_OPENDECK_PLUGINS`: the plugins folder.
    * `CLAWSWAP_OPENDECK_CMD`: the shell command that starts OpenDeck.
  """

  @tool Path.expand("../..", __DIR__)
  @flatpak "me.amankhanna.opendeck"
  @plugin "dev.clawswap.sdPlugin"

  @doc "The plugin in this checkout of clawswap."
  def source, do: Path.join([@tool, "opendeck", @plugin])

  @doc "Whether OpenDeck is the Flatpak."
  def flatpak?(env \\ System.get_env()), do: File.dir?(flatpak_home(env))

  defp flatpak_home(env), do: Path.join([env["HOME"] || System.user_home!(), ".var/app", @flatpak])

  @doc """
  OpenDeck's plugins folder: `CLAWSWAP_OPENDECK_PLUGINS`, else the Flatpak's, else
  `$XDG_CONFIG_HOME/opendeck/plugins` (`~/.config` without it). opendeck/install.sh picks the same.
  """
  def plugins_dir(env \\ System.get_env(), flatpak? \\ nil) do
    flatpak? = if flatpak? == nil, do: flatpak?(env), else: flatpak?
    home = env["HOME"] || System.user_home!()

    cond do
      present(env["CLAWSWAP_OPENDECK_PLUGINS"]) -> Path.expand(env["CLAWSWAP_OPENDECK_PLUGINS"])
      flatpak? -> Path.join(flatpak_home(env), "config/opendeck/plugins")
      present(env["XDG_CONFIG_HOME"]) -> Path.join(env["XDG_CONFIG_HOME"], "opendeck/plugins")
      true -> Path.join(home, ".config/opendeck/plugins")
    end
  end

  defp present(value), do: is_binary(value) and value != ""

  @doc """
  How OpenDeck is started here, as a shell command: `CLAWSWAP_OPENDECK_CMD`, else the Flatpak's
  `flatpak run`, else `opendeck` on the PATH. nil when there's no OpenDeck to start.
  """
  def start_command(env \\ System.get_env(), flatpak? \\ nil, find \\ &System.find_executable/1) do
    flatpak? = if flatpak? == nil, do: flatpak?(env), else: flatpak?

    cond do
      present(env["CLAWSWAP_OPENDECK_CMD"]) -> env["CLAWSWAP_OPENDECK_CMD"]
      flatpak? and find.("flatpak") -> "flatpak run #{@flatpak}"
      find.("opendeck") -> "opendeck"
      true -> nil
    end
  end

  @doc "Copies the plugin into the plugins folder, replacing the one there. Returns where it went."
  def install(dir \\ plugins_dir()) do
    target = Path.join(dir, @plugin)
    File.mkdir_p!(dir)
    File.rm_rf!(target)
    File.cp_r!(source(), target)
    target
  end

  @doc "Whether OpenDeck is running."
  def running? do
    match?({_, 0}, System.cmd("pgrep", ["-x", "opendeck"], stderr_to_stdout: true))
  end

  @doc """
  Quits OpenDeck (and so the plugins it started), waiting up to 10 seconds before killing it. :ok, or
  :not_running.
  """
  def stop do
    if running?() do
      if flatpak?() and System.find_executable("flatpak"),
        do: System.cmd("flatpak", ["kill", @flatpak], stderr_to_stdout: true),
        else: System.cmd("pkill", ["-x", "opendeck"], stderr_to_stdout: true)

      unless wait_until_stopped(20), do: System.cmd("pkill", ["-KILL", "-x", "opendeck"], stderr_to_stdout: true)
      :ok
    else
      :not_running
    end
  end

  defp wait_until_stopped(0), do: false

  defp wait_until_stopped(tries) do
    if running?() do
      Process.sleep(500)
      wait_until_stopped(tries - 1)
    else
      true
    end
  end

  @doc """
  Starts OpenDeck in the background, in a session of its own, so it outlives this terminal (its output goes
  to `log`). {:ok, command}, or :none when there's no OpenDeck to start.
  """
  def start(log) do
    case start_command() do
      nil ->
        :none

      command ->
        File.mkdir_p!(Path.dirname(log))

        script = """
        if command -v setsid >/dev/null 2>&1; then
          (trap '' INT QUIT HUP; exec setsid sh -c "$1") >>"$2" 2>&1 </dev/null &
        else
          (trap '' INT QUIT HUP; exec sh -c "$1") >>"$2" 2>&1 </dev/null &
        fi
        """

        {_, 0} = System.cmd("sh", ["-c", script, "sh", command, log])
        {:ok, command}
    end
  end
end
