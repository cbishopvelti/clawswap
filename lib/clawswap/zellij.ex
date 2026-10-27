defmodule Clawswap.Zellij do
  @moduledoc """
  The project's zellij session (zellij 0.44 or newer, for --pane-id): the layout `up` opens, and restarting
  the servers' panes in it.
  """

  alias Clawswap.{Ports, Run}

  import Clawswap.Multiplexer, only: [keep: 0, cli: 0]

  def version do
    with {:ok, out} <- Run.capture("zellij", ["--version"]),
         [_ | v] <- Regex.run(~r/(\d+)\.(\d+)\.(\d+)/, out) do
      Enum.map(v, &String.to_integer/1)
    else
      _ -> nil
    end
  end

  def version_ok?([major, minor, _]), do: major > 0 or minor >= 44
  def version_ok?(_), do: false

  def check do
    version = version()

    if version_ok?(version),
      do: :ok,
      else:
        {:error,
         "clawswap needs zellij 0.44 or newer (found #{if version, do: Enum.join(version, "."), else: "none"}): https://github.com/zellij-org/zellij/releases"}
  end

  @doc "zellij's command for `up`: attach to the running session, or start it from the layout."
  def up(project, catch_up) do
    sessions =
      case Run.capture("zellij", ["list-sessions", "--no-formatting"]),
        do: (
          {:ok, out} -> out
          _ -> ""
        )

    line = sessions |> String.split("\n") |> Enum.find(&(hd(String.split(&1, " ")) == project.session))
    # An exited session would come back with its panes waiting for Enter; start it fresh instead.
    if line && line =~ "EXITED", do: Run.capture("zellij", ["delete-session", project.session])

    if line != nil and not (line =~ "EXITED") do
      ["zellij", "attach", project.session]
    else
      catch_up.()

      layout =
        if project.layout do
          Path.expand(project.layout, project.root)
        else
          path = String.replace_suffix(project.local_file, ".json", ".kdl")
          File.write!(path, layout(project))
          path
        end

      ["zellij", "--session", project.session, "--new-session-with-layout", layout]
    end
  end

  defp kdl(s), do: ~s(") <> (s |> to_string() |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))) <> ~s(")
  defp indent(text, n), do: String.replace(text, ~r/^/m, String.duplicate(" ", n))

  @doc """
  The layout `up` opens when the config names none: the servers stacked on the left, the watcher and the
  other panes on the right. The watcher finds the servers' panes by these names.
  """
  def layout(project) do
    pane = fn name, %{command: command, cwd: cwd}, focus ->
      ~s(pane name=#{kdl(name)} command=#{kdl(keep())} cwd=#{kdl(Path.expand(cwd, project.root))}#{if focus, do: " focus=true"} {\n) <>
        ~s(    args #{command |> List.wrap() |> Enum.map_join(" ", &kdl/1)}\n})
    end

    servers = project.server_names |> Enum.with_index() |> Enum.map(fn {n, i} -> pane.(n, project.servers[n], i == 0) end)
    # From the config's folder, so the watcher loads the same config.
    watcher = pane.("clawswap", %{command: [cli(), "watch"], cwd: Path.dirname(project.file)}, servers == [])
    side = [watcher | Enum.map(project.pane_names, &pane.(&1, project.panes[&1], false))]
    column = fn panes, size -> ~s(pane split_direction="horizontal"#{if size, do: ~s( size="#{size}")} {\n#{indent(Enum.join(panes, "\n"), 4)}\n}) end

    body =
      if servers == [],
        do: column.(side, nil),
        else: ~s(pane split_direction="vertical" {\n#{indent(column.(servers, "60%"), 4)}\n#{indent(column.(side, nil), 4)}\n})

    """
    // Written by clawswap for #{project.name}; set layout in #{project.file} to use your own.
    layout {
        default_tab_template {
            pane size=1 borderless=true {
                plugin location="zellij:tab-bar"
            }
            children
            pane size=2 borderless=true {
                plugin location="zellij:status-bar"
            }
        }
        tab name=#{kdl(project.name)} focus=true {
    #{indent(body, 8)}
        }
    }
    """
  end

  @doc """
  `%{stop: fn name, note -> ... end, start: fn name -> ... end}` for the watcher: replaces a server's
  pane in place, with a note while the switch runs, then with the server again.
  """
  def servers(project, log \\ &IO.puts/1) do
    action = fn args -> Run.capture!("zellij", ["--session", project.session, "action" | args]) end

    # A pane's id is found again each time, since replacing a pane gives the new one a new id.
    find_pane = fn name ->
      panes = action.(["list-panes", "--json"]) |> JSON.decode!() |> Enum.reject(& &1["is_plugin"])
      match = project.servers[name][:match]

      Enum.find(panes, &(&1["title"] == name)) ||
        (match && Enum.find(panes, &Regex.match?(match, "#{&1["terminal_command"]} #{&1["pane_command"]}")))
    end

    # Replaces a pane with one running `command`, closing the old pane (which ends what ran in it).
    replace = fn name, command, cwd ->
      pane = find_pane.(name) || raise RuntimeError, ~s(No "#{name}" pane in zellij session #{project.session})
      action.(["new-pane", "--in-place", "--pane-id", "terminal_#{pane["id"]}", "--close-replaced-pane", "--name", name, "--cwd", cwd, "--" | command])
    end

    %{
      stop: fn name, note ->
        server = project.servers[name]
        replace.(name, ["sh", "-c", ~s(printf '%s\\n' "$1"; exec sleep infinity), "sh", note], Path.expand(server.cwd, project.root))
        if server.port, do: Ports.free_port(server.port, log)
        :ok
      end,
      # Through bin/keep, as in the layout, so the pane stays when the server stops.
      start: fn name ->
        server = project.servers[name]
        replace.(name, [keep() | List.wrap(server.command)], Path.expand(server.cwd, project.root))
        :ok
      end
    }
  end
end
