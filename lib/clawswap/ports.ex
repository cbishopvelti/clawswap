defmodule Clawswap.Ports do
  @moduledoc "The servers' ports: waiting for them to open, and freeing them before a switch starts the servers again."

  alias Clawswap.Run

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
