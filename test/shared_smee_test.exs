defmodule Clawswap.SharedSmeeTest do
  use ExUnit.Case, async: true

  alias Clawswap.SharedSmee

  setup do
    dir = Path.join(System.tmp_dir!(), "clawswap-shared-smee-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    test = self()

    start = fn opts ->
      defaults = [
        name: nil,
        file: Path.join(dir, "smee.json"),
        new_channel: fn -> send(test, :new_channel) && {:ok, "https://smee.io/shared"} end,
        ensure_hook: fn repo, channel -> send(test, {:ensure_hook, repo, channel}) && {:ok, :created} end,
        # No smee.io: the test plays the listener's part, sending the hub what it would.
        listen: fn opts -> send(test, {:listening, opts[:url]}) && {:ok, spawn(fn -> Process.sleep(:infinity) end)} end
      ]

      start_supervised!({SharedSmee, Keyword.merge(defaults, opts)})
    end

    %{dir: dir, start: start, smee_file: Path.join(dir, "smee.json")}
  end

  # A process that subscribes for `repo` and passes on what it's sent as {:got, name, message}.
  defp subscriber(hub, name, repo) do
    test = self()

    pid =
      spawn_link(fn ->
        send(test, {:subscribed, name, SharedSmee.subscribe(hub, repo)})
        forward(test, name)
      end)

    assert_receive {:subscribed, ^name, status}, 1000
    {pid, status}
  end

  defp until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(20) && until(fun, tries - 1)
    end
  end

  defp forward(test, name) do
    receive do
      message -> send(test, {:got, name, message}) && forward(test, name)
    end
  end

  test "makes the channel once, adds each repo's webhook once, and sends each delivery to its repo's projects", %{start: start, smee_file: file} do
    hub = start.([])
    assert_receive :new_channel, 1000
    assert_receive {:listening, "https://smee.io/shared"}, 1000
    assert SharedSmee.channel(file) == "https://smee.io/shared"

    {_, status} = subscriber(hub, :app, "me/app")
    assert status == %{webhook: "connecting", error: nil}
    assert_receive {:ensure_hook, "me/app", "https://smee.io/shared"}, 1000
    assert_receive {:got, :app, {:shared_smee, {:log, "Added me/app's GitHub webhook" <> _}}}, 1000

    # GitHub's names aren't case-sensitive: the same repo isn't checked again.
    {_, _} = subscriber(hub, :app2, "Me/App")
    {_, _} = subscriber(hub, :other, "me/other")
    assert_receive {:ensure_hook, "me/other", _}, 1000
    refute_received {:ensure_hook, "Me/App", _}

    send(hub, {:smee, :open})
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "connected", error: nil}}}}, 1000
    assert_receive {:got, :app2, {:shared_smee, {:status, %{webhook: "connected"}}}}, 1000

    send(hub, {:smee, {:delivery, "push", "me/app"}})
    assert_receive {:got, :app, {:shared_smee, {:delivery, "push"}}}, 1000
    assert_receive {:got, :app2, {:shared_smee, {:delivery, "push"}}}, 1000
    refute_receive {:got, :other, {:shared_smee, {:delivery, _}}}, 100

    # A delivery that names no repo goes to everyone.
    send(hub, {:smee, {:delivery, "ping", nil}})
    assert_receive {:got, :other, {:shared_smee, {:delivery, "ping"}}}, 1000

    send(hub, {:smee, {:drop, "smee closed the stream"}})
    assert_receive {:got, :other, {:shared_smee, {:status, %{webhook: "connecting", error: "smee closed the stream"}}}}, 1000
  end

  test "keeps the channel it made before", %{start: start, smee_file: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, ~s({"channel": "https://smee.io/kept"}))
    start.([])
    assert_receive {:listening, "https://smee.io/kept"}, 1000
    refute_received :new_channel
  end

  test "says why a repo has no webhook, and tries again when it comes in again", %{start: start} do
    test = self()
    hub = start.(ensure_hook: fn repo, _ -> send(test, {:ensure_hook, repo}) && {:error, "GitHub answered 404"} end)

    {_, _} = subscriber(hub, :app, "me/app")
    assert_receive {:ensure_hook, "me/app"}, 1000
    assert_receive {:got, :app, {:shared_smee, {:log, "Couldn't add me/app's GitHub webhook (GitHub answered 404)" <> _}}}, 1000
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "off", error: "GitHub answered 404"}}}}, 1000

    {_, status} = subscriber(hub, :again, "me/app")
    assert status == %{webhook: "connecting", error: nil}
    assert_receive {:ensure_hook, "me/app"}, 1000
  end

  test "without a token it listens all the same, and a delivery shows a webhook added by hand works", %{start: start} do
    hub = start.(ensure_hook: fn _, _ -> {:error, :no_token} end)
    assert_receive {:listening, "https://smee.io/shared"}, 1000
    send(hub, {:smee, :open})

    {_, _} = subscriber(hub, :app, "me/app")

    assert_receive {:got, :app, {:shared_smee, {:log, "Listening for me/app's GitHub webhook on https://smee.io/shared; nothing has come" <> _}}},
                   1000

    assert_receive {:got, :app,
                    {:shared_smee, {:status, %{webhook: "unchecked", error: "no delivery yet on https://smee.io/shared (no GitHub token to check it with)"}}}},
                   1000

    send(hub, {:smee, {:delivery, "ping", "me/app"}})
    assert_receive {:got, :app, {:shared_smee, {:delivery, "ping"}}}, 1000
    assert_receive {:got, :app, {:shared_smee, {:log, "Got a delivery from me/app's GitHub webhook, so it's connected"}}}, 1000
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "connected", error: nil}}}}, 1000

    # It stays working: no more checks, and a second delivery says nothing new.
    {_, status} = subscriber(hub, :again, "me/app")
    assert status == %{webhook: "connected", error: nil}
    send(hub, {:smee, {:delivery, "push", "me/app"}})
    refute_receive {:got, :app, {:shared_smee, {:log, _}}}, 100
  end

  test "without a token, a webhook seen working before a restart starts connected", %{start: start, smee_file: file} do
    hub = start.(ensure_hook: fn _, _ -> {:error, :no_token} end)
    assert_receive {:listening, "https://smee.io/shared"}, 1000
    send(hub, {:smee, :open})
    {_, _} = subscriber(hub, :app, "me/app")
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "unchecked"}}}}, 1000
    send(hub, {:smee, {:delivery, "push", "Me/App"}})
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "connected"}}}}, 1000
    assert %DateTime{} = SharedSmee.last_delivery(file, "me/app")
    assert SharedSmee.channel(file) == "https://smee.io/shared"
    stop_supervised!(SharedSmee)

    hub = start.(ensure_hook: fn _, _ -> {:error, :no_token} end)
    send(hub, {:smee, :open})
    {_, _} = subscriber(hub, :app, "me/app")
    assert_receive {:got, :app, {:shared_smee, {:log, "me/app's GitHub webhook is connected (last delivery just now, on https://smee.io/shared)"}}}, 1000
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "connected", error: nil}}}}, 1000
    refute SharedSmee.last_delivery(file, "me/other")
  end

  test "ago says roughly how long ago" do
    now = ~U[2026-11-14 12:00:00Z]
    assert SharedSmee.ago(~U[2026-11-14 11:59:30Z], now) == "just now"
    assert SharedSmee.ago(~U[2026-11-14 11:55:00Z], now) == "5 min ago"
    assert SharedSmee.ago(~U[2026-11-14 09:00:00Z], now) == "3 h ago"
    assert SharedSmee.ago(~U[2026-11-12 12:00:00Z], now) == "2 days ago"
  end

  test "a delivery also clears a webhook that couldn't be added", %{start: start} do
    hub = start.(ensure_hook: fn _, _ -> {:error, "GitHub answered 404"} end)
    send(hub, {:smee, :open})
    {_, _} = subscriber(hub, :app, "me/app")
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "off"}}}}, 1000

    send(hub, {:smee, {:delivery, "push", "Me/App"}})
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "connected", error: nil}}}}, 1000
  end

  test "a checkout whose origin isn't on GitHub has no webhook", %{start: start} do
    hub = start.([])
    assert {_, %{webhook: "off", error: "origin isn't a GitHub repo"}} = subscriber(hub, :local, nil)
  end

  test "waits for the channel when smee.io can't make one", %{start: start} do
    test = self()
    hub = start.(new_channel: fn -> send(test, :new_channel) && {:error, "smee.io: timeout"} end)
    assert_receive :new_channel, 1000
    until(fn -> :sys.get_state(hub).channel_error != nil end)
    assert {_, %{webhook: "connecting", error: "smee.io: timeout"}} = subscriber(hub, :app, "me/app")
    refute_received {:ensure_hook, _, _}
  end

  test "routes a real smee-style stream's deliveries by the repo in their body", %{start: start, smee_file: file} do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, JSON.encode!(%{channel: "http://127.0.0.1:#{port}/chan"}))
    test = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\nevent: ready\ndata: {}\n\n")
        send(test, :ready)

        receive do
          {:deliver, repo} ->
            delivery = JSON.encode!(%{"x-github-event" => "create", "body" => %{"ref" => "claude/x", "repository" => %{"full_name" => repo}}})
            :gen_tcp.send(socket, "data: #{delivery}\n\n")
        end

        receive do: (:never -> :ok)
      end)

    hub = start.(listen: &Clawswap.Smee.start_link/1)
    {_, _} = subscriber(hub, :app, "me/app")
    {_, _} = subscriber(hub, :other, "me/other")
    assert_receive :ready, 3000
    assert_receive {:got, :app, {:shared_smee, {:status, %{webhook: "connected"}}}}, 3000

    send(server, {:deliver, "me/app"})
    assert_receive {:got, :app, {:shared_smee, {:delivery, "create"}}}, 3000
    refute_receive {:got, :other, {:shared_smee, {:delivery, _}}}, 200
  end

  test "ensure_channel keeps the one it makes", %{smee_file: file} do
    assert {:ok, "https://smee.io/a"} = SharedSmee.ensure_channel(file, fn -> {:ok, "https://smee.io/a"} end)
    assert {:ok, "https://smee.io/a"} = SharedSmee.ensure_channel(file, fn -> flunk("made another") end)
  end
end
