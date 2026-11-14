defmodule Clawswap.PortsTest do
  use ExUnit.Case, async: true

  alias Clawswap.Ports

  test "sees a server on IPv4 loopback" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    assert Ports.port_open?(port)
    :gen_tcp.close(socket)
    refute Ports.port_open?(port)
  end

  # Vite binds localhost, which is ::1 alone where localhost resolves to it first (macOS, GitHub's runners).
  test "sees a server on IPv6 loopback only" do
    case :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}, ipv6_v6only: true]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        assert Ports.port_open?(port)
        :gen_tcp.close(socket)

      {:error, reason} ->
        IO.puts("No IPv6 loopback here (#{inspect(reason)}); skipped")
    end
  end

  # An old server outside the session holds the configured port (this test's own listener), so the server
  # takes the next one.
  test "finds a server on the port it moved to, from the marker in its environment" do
    python = System.find_executable("python3")

    if match?({:unix, :linux}, :os.type()) and python do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      project = %{id: "t#{System.unique_integer([:positive])}", servers: %{"web" => %{port: port}}}

      # Waiting while only the old server listens: it's seen not to be this one.
      assert Ports.wait_for_server(project, "web", 1000) == :timeout
      assert Ports.server_port(project, "web") == port

      code = "import socket, time; s = socket.socket(); s.bind(('127.0.0.1', #{port + 1})); s.listen(); time.sleep(30)"
      server = Port.open({:spawn_executable, System.find_executable("env")}, [:binary, args: [Ports.marker(project, "web"), python, "-c", code]])
      {:os_pid, pid} = Port.info(server, :os_pid)

      try do
        assert Ports.wait_for_server(project, "web", 5000) == {:ok, port + 1}
        assert Ports.server_port(project, "web") == port + 1
        # Another project's server of the same name isn't this one.
        assert Ports.server_port(%{project | id: project.id <> "x"}, "web") == port
      after
        System.cmd("kill", [to_string(pid)])
        :gen_tcp.close(socket)
      end
    else
      IO.puts("Needs Linux's /proc and python3; skipped")
    end
  end
end
