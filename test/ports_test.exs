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
end
