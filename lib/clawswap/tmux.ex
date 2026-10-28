defmodule Clawswap.Tmux do
  @moduledoc """
  The project's tmux session (tmux 3.1 or newer, for split sizes in %): the panes `up` opens, and restarting
  the servers' panes in it. Each pane carries its name in the @clawswap pane option (a title would be
  overwritten by what runs there), shown on its border.
  """

  alias Clawswap.{Ports, Run}

  import Clawswap.Multiplexer, only: [keep: 0, cli: 0]

  def version do
    with {:ok, out} <- Run.capture("tmux", ["-V"]),
         [_ | v] <- Regex.run(~r/(\d+)\.(\d+)/, out) do
      Enum.map(v, &String.to_integer/1)
    else
      _ -> nil
    end
  end

  def version_ok?([major, minor]), do: major > 3 or (major == 3 and minor >= 1)
  def version_ok?(_), do: false

  def check do
    version = version()

    if version_ok?(version),
      do: :ok,
      else: {:error, "clawswap needs tmux 3.1 or newer (found #{if version, do: Enum.join(version, "."), else: "none"})"}
  end

  # tmux reads an argument ending in ; as the end of a command; \; keeps it.
  defp arg(s), do: s |> to_string() |> String.replace(~r/;$/, "\\;")

  # tmux turns . and : in a session's name into _, since they separate a target's parts.
  defp session(project), do: String.replace(project.session, ~r/[.:]/, "_")
  defp target(project), do: "=" <> session(project)

  @doc """
  The tmux commands that build the session, as one argument list joined by ";": the servers stacked on
  the left, the watcher and the other panes on the right, as zellij's layout. The watcher finds the
  servers' panes by these names. Each command names its target, since run from inside tmux they would
  otherwise act on the pane they were run from.
  """
  def commands(project) do
    pane = fn
      # A pane with no command opens tmux's default shell there.
      name, %{command: nil, cwd: cwd} -> {name, ["-c", Path.expand(cwd, project.root)]}
      name, %{command: command, cwd: cwd} -> {name, ["-c", Path.expand(cwd, project.root), "--", keep() | List.wrap(command)]}
    end

    servers = Enum.map(project.server_names, &pane.(&1, project.servers[&1]))
    # From the config's folder, so the watcher loads the same config.
    watcher = pane.("clawswap", %{command: [cli(), "watch"], cwd: Path.dirname(project.file)})
    side = [watcher | Enum.map(project.pane_names, &pane.(&1, project.panes[&1]))]
    t = target(project) <> ":"
    name = fn {n, _} -> ["set-option", "-p", "-t", t, "@clawswap", n] end

    # Each split takes its share from the pane above, so a column of n ends up even.
    column = fn [_ | rest] = panes ->
      n = length(panes)

      rest
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{_, spec} = p, k} -> [["split-window", "-v", "-t", t, "-l", "#{div(100 * (n - k), n - k + 1)}%" | spec], name.(p)] end)
    end

    [{_, first_spec} = first | _] = servers ++ side

    first_pane = [
      ["new-session", "-s", session(project), "-n", project.name | first_spec],
      name.(first),
      ["set-option", "-w", "-t", t, "pane-border-status", "top"],
      ["set-option", "-w", "-t", t, "pane-border-format", " \#{@clawswap} "]
    ]

    rest =
      if servers == [] do
        column.(side)
      else
        [{_, watcher_spec} | _] = side
        # The right-hand column, then back to the first server for the left one.
        [["split-window", "-h", "-t", t, "-l", "40%" | watcher_spec], name.(watcher)] ++
          column.(side) ++ if(length(servers) > 1, do: [["select-pane", "-t", t <> ".{top-left}"] | column.(servers)], else: [])
      end

    first_pane ++ rest ++ [["select-pane", "-t", t <> ".{top-left}"]]
  end

  defp join(commands), do: commands |> Enum.map(&Enum.map(&1, fn a -> arg(a) end)) |> Enum.intersperse([";"]) |> Enum.concat()

  @doc "What `clawswap layout` prints for tmux: the command `up` runs for a new session."
  def layout(project) do
    quote = fn a -> if a =~ ~r{^[\w@%=./:-]+$}, do: a, else: "'" <> String.replace(a, "'", ~S('\'')) <> "'" end
    "tmux " <> Enum.map_join(join(commands(project)), " ", quote) <> "\n"
  end

  @doc """
  tmux's command for `up`: attach to the running session, or build it. Inside tmux already, it builds the
  session detached and switches this client to it, since tmux won't nest.
  """
  def up(project, catch_up) do
    inside = System.get_env("TMUX") not in [nil, ""]

    case Run.capture("tmux", ["has-session", "-t", target(project)]) do
      {:ok, _} ->
        ["tmux", if(inside, do: "switch-client", else: "attach-session"), "-t", target(project)]

      _ ->
        catch_up.()
        [["new-session" | spec] | commands] = commands(project)
        spec = if inside, do: ["-d" | spec], else: spec
        switch = if inside, do: [["switch-client", "-t", target(project)]], else: []
        ["tmux" | join([["new-session" | spec] | commands] ++ switch)]
    end
  end

  @doc """
  `%{stop: fn name, note -> ... end, start: fn name -> ... end}` for the watcher: respawns a server's pane
  in place, with a note while the switch runs, then with the server again.
  """
  def servers(project, log \\ &IO.puts/1) do
    tmux = fn args -> Run.capture!("tmux", Enum.map(args, &arg/1)) end

    find_pane = fn name ->
      panes =
        tmux.(["list-panes", "-s", "-t", target(project), "-F", "\#{pane_id}\t\#{@clawswap}\t\#{pane_start_command} \#{pane_current_command}"])
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))

      match = project.servers[name][:match]

      Enum.find(panes, &(Enum.at(&1, 1) == name)) ||
        (match && Enum.find(panes, &Regex.match?(match, Enum.at(&1, 2, ""))))
    end

    # Kills what runs in the pane and starts `command` there.
    respawn = fn name, command, cwd ->
      [id | _] = find_pane.(name) || raise RuntimeError, ~s(No "#{name}" pane in tmux session #{project.session})
      tmux.(["respawn-pane", "-k", "-t", id, "-c", cwd, "--" | command])
    end

    %{
      stop: fn name, note ->
        server = project.servers[name]
        respawn.(name, ["sh", "-c", ~s(printf '%s\\n' "$1"; exec sleep infinity), "sh", note], Path.expand(server.cwd, project.root))
        if server.port, do: Ports.free_port(server.port, log)
        :ok
      end,
      # Through bin/keep, as in the layout, so the pane stays when the server stops.
      start: fn name ->
        server = project.servers[name]
        respawn.(name, [keep() | List.wrap(server.command)], Path.expand(server.cwd, project.root))
        :ok
      end
    }
  end
end
