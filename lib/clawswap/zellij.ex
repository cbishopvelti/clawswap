defmodule Clawswap.Zellij do
  @moduledoc """
  The project's zellij session (zellij 0.44 or newer, for --pane-id): the layout `up` opens, and restarting
  the servers' panes in it.
  """

  alias Clawswap.Run

  @tool Path.expand("../..", __DIR__)

  @doc "Runs a pane's command and leaves a shell there when it stops. A single argument goes through sh -c."
  def keep, do: Path.join(@tool, "bin/keep")
  def cli, do: Path.join(@tool, "bin/clawswap")

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
    watcher = pane.("clawswap", %{command: [cli(), "watch"], cwd: "."}, servers == [])
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

  def port_open?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  @doc "Waits (up to `ms`) for something to listen on the port."
  def wait_for_port(port, ms \\ 30_000) do
    Enum.reduce_while(0..div(ms, 500), nil, fn _, _ ->
      if port_open?(port), do: {:halt, :ok}, else: (Process.sleep(500); {:cont, :timeout})
    end)
  end

  @doc """
  Whoever listens on the port. On Linux: the listening sockets' inodes from /proc/net/tcp*, then the
  processes holding them. Elsewhere: lsof. Only your own processes can be seen, which are the only ones we
  could stop.
  """
  def port_pids(port) do
    if match?({:unix, :linux}, :os.type()), do: proc_port_pids(port), else: lsof_port_pids(port)
  end

  defp lsof_port_pids(port) do
    case Run.capture("lsof", ["-t", "-iTCP:#{port}", "-sTCP:LISTEN"]) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
      _ -> []
    end
  end

  defp proc_port_pids(port) do
    hex = port |> Integer.to_string(16) |> String.pad_leading(4, "0")

    inodes =
      for file <- ["/proc/net/tcp", "/proc/net/tcp6"],
          {:ok, text} <- [File.read(file)],
          line <- text |> String.split("\n") |> Enum.drop(1),
          cols = String.split(String.trim(line)),
          # local_address is ADDR:PORT; state 0A is LISTEN.
          length(cols) > 9 and String.ends_with?(Enum.at(cols, 1), ":" <> hex) and Enum.at(cols, 3) == "0A",
          into: MapSet.new(),
          do: Enum.at(cols, 9)

    if MapSet.size(inodes) == 0 do
      []
    else
      for pid <- File.ls!("/proc"),
          String.match?(pid, ~r/^\d+$/),
          {:ok, fds} <- [File.ls("/proc/#{pid}/fd")],
          Enum.any?(fds, &MapSet.member?(inodes, socket_inode("/proc/#{pid}/fd/#{&1}"))),
          do: String.to_integer(pid)
    end
  end

  defp socket_inode(fd_path) do
    with {:ok, link} <- :file.read_link(String.to_charlist(fd_path)),
         [_, inode] <- Regex.run(~r/^socket:\[(\d+)\]$/, to_string(link)) do
      inode
    else
      _ -> nil
    end
  end

  # Waits up to 5 s for the port to close; true when it has.
  defp wait_closed(port, tries \\ 20) do
    cond do
      not port_open?(port) -> true
      tries == 0 -> false
      true -> Process.sleep(250) && wait_closed(port, tries - 1)
    end
  end

  @doc """
  Waits for the port to close, then ends whatever still holds it (a server started outside zellij, or one
  that ignored its pane closing): TERM, then KILL.
  """
  def free_port(port, log) do
    if wait_closed(port) do
      :ok
    else
      Enum.reduce_while(["TERM", "KILL"], nil, fn signal, _ ->
        case port_pids(port) do
          [] ->
            {:halt, nil}

          pids ->
            log.("Port #{port} is still taken; sending #{signal} to #{Enum.join(pids, ", ")}")
            Enum.each(pids, &System.cmd("kill", ["-#{signal}", to_string(&1)], stderr_to_stdout: true))
            if wait_closed(port), do: {:halt, :ok}, else: {:cont, nil}
        end
      end)

      if port_open?(port), do: raise(RuntimeError, "Port #{port} is still in use"), else: :ok
    end
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
        if server.port, do: free_port(server.port, log)
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
