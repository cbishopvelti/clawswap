defmodule Clawswap.Ports do
  @moduledoc "The servers' ports: waiting for them to open, and freeing them before a switch starts the servers again."

  alias Clawswap.Run

  @doc """
  Whether something listens on the port, on IPv4 or IPv6 loopback: a dev server that binds `localhost` can
  get either (Vite takes ::1 where localhost resolves to it first, as on macOS and GitHub's Ubuntu runners).
  """
  def port_open?(port), do: Enum.any?([{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}], &listening?(&1, port))

  defp listening?(address, port) do
    case :gen_tcp.connect(address, port, [], 500) do
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
      if port_open?(port),
        do: {:halt, :ok},
        else:
          (
            Process.sleep(500)
            {:cont, :timeout}
          )
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

  defp proc_port_pids(port), do: for({pid, ^port} <- listeners(), uniq: true, do: pid)

  # {pid, port} for each listening TCP socket (IPv4 or IPv6) your own processes hold, from /proc: the
  # sockets' inodes from /proc/net/tcp*, then the processes whose fds point at them. [] off Linux.
  defp listeners do
    if match?({:unix, :linux}, :os.type()), do: proc_listeners(), else: []
  end

  defp proc_listeners do
    ports =
      for file <- ["/proc/net/tcp", "/proc/net/tcp6"],
          {:ok, text} <- [File.read(file)],
          line <- text |> String.split("\n") |> Enum.drop(1),
          cols = String.split(String.trim(line)),
          # local_address is ADDR:PORT (hex); state 0A is LISTEN.
          length(cols) > 9 and Enum.at(cols, 3) == "0A",
          [_, hex] <- [Regex.run(~r/:([0-9A-F]{4})$/, Enum.at(cols, 1))],
          into: %{},
          do: {Enum.at(cols, 9), String.to_integer(hex, 16)}

    if map_size(ports) == 0 do
      []
    else
      for pid <- File.ls!("/proc"),
          String.match?(pid, ~r/^\d+$/),
          {:ok, fds} <- [File.ls("/proc/#{pid}/fd")],
          fd <- fds,
          port = ports[socket_inode("/proc/#{pid}/fd/#{fd}")],
          uniq: true,
          do: {String.to_integer(pid), port}
    end
  end

  @doc """
  The environment variable, as NAME=value, that marks a server's processes: its pane's command runs under
  `env` with it (`Clawswap.Multiplexer.server_command/2`), and everything the server starts inherits it, so
  the port it took can be found even when it isn't the configured one.
  """
  def marker(project, name), do: "CLAWSWAP_SERVER=#{project.id}/#{name}"

  defp marked?(pid, marker) do
    case File.read("/proc/#{pid}/environ") do
      {:ok, env} -> marker in String.split(env, <<0>>)
      _ -> false
    end
  end

  # The ports the server's (marked) processes listen on, lowest first.
  defp ours(listeners, project, name) do
    marker = marker(project, name)
    for({pid, port} <- listeners, marked?(pid, marker), uniq: true, do: port) |> Enum.sort()
  end

  # The port a dev server that moves when its own is taken (Vite, Next) tried next: one of the twenty above.
  defp moved(ours, port), do: if(port not in ours, do: Enum.find(ours, &(&1 in (port + 1)..(port + 20)//1)))

  @doc """
  The port a server is on: its configured `port`, or the one it moved to because that was taken (Vite tries
  5174 when 5173 is busy). Seen on Linux only, from the processes' environment (`marker/2`); elsewhere, and
  for a server started without the marker, the configured port.
  """
  def server_port(project, name) do
    port = project.servers[to_string(name)][:port]
    port && (moved(ours(listeners(), project, name), port) || port)
  end

  @doc """
  Waits (up to `ms`) for a server to listen: `:ok` on its configured port, `{:ok, port}` on the one it
  moved to, or `:timeout`. Something else already on the configured port (an old server outside the
  session) doesn't count while it can be seen not to be this server, so the wait goes on until the server
  takes the next port; one that can't be seen (another user's, a container's) counts, as before.
  """
  def wait_for_server(project, name, ms \\ 30_000) do
    port = project.servers[to_string(name)].port

    Enum.reduce_while(0..div(ms, 500), :timeout, fn tick, _ ->
      case server_state(project, name, port, tick) do
        :waiting ->
          Process.sleep(500)
          {:cont, :timeout}

        result ->
          {:halt, result}
      end
    end)
  end

  # tick counts the half-seconds waited. After 15 s, an open port counts whoever holds it: a server whose
  # processes drop the environment (env -i, a supervisor that starts it afresh) would otherwise never be seen.
  defp server_state(project, name, port, tick) do
    listeners = listeners()
    ours = ours(listeners, project, name)
    holders = for {pid, ^port} <- listeners, do: pid
    moved = moved(ours, port)

    cond do
      port in ours -> :ok
      moved -> {:ok, moved}
      port_open?(port) and (holders == [] or tick >= 30) -> :ok
      true -> :waiting
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
  Waits for the port to close, then ends whatever still holds it (a server started outside the session, or one
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
end
