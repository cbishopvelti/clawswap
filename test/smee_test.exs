defmodule Clawswap.SmeeTest do
  use ExUnit.Case, async: true

  alias Clawswap.Smee

  test "parses server-sent events across chunks" do
    {events, rest} = Smee.parse_events(~s(event: ready\ndata: {}\n\ndata: {"x-github-event":))
    assert events == [%{event: "ready", data: "{}"}]
    {events, _} = Smee.parse_events(rest <> ~s("push"}\n\n: comment\n\n))
    assert events == [%{event: "message", data: ~s({"x-github-event":"push"})}, %{event: "message", data: ""}]
  end

  test "hears webhook deliveries from a smee-style stream" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    test = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, request} = :gen_tcp.recv(socket, 0)
        send(test, {:request, request})
        delivery = JSON.encode!(%{"x-github-event" => "create", "body" => %{"ref" => "claude/x"}})
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n")

        for part <- ["event: ready\ndata: {}\n\n", "data: #{delivery}\n\n"],
            do: :gen_tcp.send(socket, Integer.to_string(byte_size(part), 16) <> "\r\n" <> part <> "\r\n")

        # The stream stays open until the test is done.
        receive do
          :done -> :gen_tcp.close(socket)
        end
      end)

    {:ok, pid} = Smee.start_link(url: "http://127.0.0.1:#{port}/chan", owner: self(), log: &send(test, {:log, &1}))
    assert_receive {:smee, :open}, 3000
    assert_receive {:smee, {:delivery, "create"}}, 3000
    assert_received {:request, "GET /chan " <> _}
    GenServer.stop(pid)
    send(server, :done)
  end
end
