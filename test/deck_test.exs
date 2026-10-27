Code.require_file("../opendeck/dev.clawswap.sdPlugin/bin/deck.ex", __DIR__)
Code.require_file("../opendeck/dev.clawswap.sdPlugin/bin/websocket.ex", __DIR__)

defmodule Clawswap.DeckTest do
  use ExUnit.Case, async: true

  alias Clawswap.{Deck, WebSocket}

  @state %{
    "current" => %{"branch" => "claude-main", "sha" => "1"},
    "dirty" => false,
    "branches" => [
      %{"branch" => "claude-main", "short" => "claude-main", "sha" => "1"},
      %{"branch" => "claude/undo-sliders-abc123", "short" => "undo-sliders-abc123", "sha" => "2", "pr" => %{"number" => 41, "title" => "Undo for sliders"}},
      %{"branch" => "claude/streamdeck-branch-switcher", "short" => "streamdeck-branch-switcher", "sha" => "3"}
    ]
  }

  defp key(settings, row, column, pull \\ false), do: %{settings: settings, coordinates: %{"row" => row, "column" => column}, pull: pull}

  defp start(fetch, url \\ "http://dev") do
    me = self()
    deck = start_supervised!({Deck, send: &send(me, {:sent, &1}), fetch: fetch, url: url, schedule: fn _ -> nil end})
    deck
  end

  defp appear(deck, context, settings, row, column, action \\ "dev.clawswap.branch") do
    Deck.handle(deck, %{"event" => "willAppear", "action" => action, "context" => context, "payload" => %{"settings" => settings, "coordinates" => %{"row" => row, "column" => column}}})
  end

  # The last image sent for a key, decoded.
  defp image(context, last \\ nil) do
    receive do
      {:sent, %{event: "setImage", context: ^context, payload: %{image: image}}} -> image(context, URI.decode(image))
    after
      0 -> last
    end
  end

  test "keys on next branch take the list in deck order; named keys show their branch" do
    instances = %{"b" => key(%{}, 0, 1), "a" => key(%{}, 0, 0), "pinned" => key(%{"branch" => "claude/streamdeck-branch-switcher"}, 0, 2), "c" => key(%{}, 1, 0)}
    shown = Deck.assign(instances, @state["branches"])
    assert shown["a"]["branch"] == "claude-main"
    assert shown["b"]["branch"] == "claude/undo-sliders-abc123"
    assert shown["c"]["branch"] == "claude/streamdeck-branch-switcher"
    assert shown["pinned"]["branch"] == "claude/streamdeck-branch-switcher"
  end

  test "a key says what its branch is doing" do
    [main, undo, switcher] = @state["branches"]
    assert Deck.key_look(@state, main).status == "Current"
    assert Deck.key_look(@state, undo) == %{title: "Undo for sliders", number: 41}
    assert Deck.key_look(@state, switcher).title == "streamdeck-branch-switcher"
    assert Deck.key_look(@state, %{"branch" => "feature/x", "sha" => "9"}).title == "feature/x"
    switching = Map.put(@state, "switch", %{"target" => "claude/undo-sliders-abc123", "phase" => "running", "step" => "npm install"})
    assert Deck.key_look(switching, undo).status == "npm install"
    assert Deck.key_look(Map.put(@state, "current", %{"branch" => "claude-main", "sha" => "0"}), main).status == "New commits"
  end

  test "wraps titles into a few short lines" do
    assert Deck.wrap("Undo for sliders and macros too", 11, 3) == ["Undo for", "sliders and", "macros too"]
    assert Deck.wrap("streamdeck-branch-switcher", 11, 3) == ["streamdeck-", "branch-", "switcher"]
    assert "a b c d e f g h i j k l m n o p q r s t u v w x y z" |> Deck.wrap(5, 2) |> Enum.at(1) |> String.ends_with?("…")
  end

  test "draws keys from the watcher and posts presses to it" do
    me = self()
    deck = start(fn method, url, body -> send(me, {:request, method, url, body}) && {:ok, 200, @state} end)
    appear(deck, "a", %{}, 0, 0)
    Deck.poll(deck)
    assert image("a") =~ "claude-main"
    Deck.handle(deck, %{"event" => "keyDown", "context" => "a", "payload" => %{}})
    assert_received {:request, :post, "http://dev/switch", %{branch: "claude-main"}}
  end

  test "keys on different watchers get their own lists" do
    other = %{"current" => %{"branch" => "main", "sha" => "7"}, "branches" => [%{"branch" => "main", "short" => "main", "sha" => "7"}, %{"branch" => "fix", "short" => "fix", "sha" => "8"}]}
    me = self()
    deck = start(fn method, url, body -> send(me, {:request, method, url, body}) && {:ok, 200, if(String.starts_with?(url, "http://shop"), do: other, else: @state)} end)
    appear(deck, "a", %{}, 0, 0)
    appear(deck, "s1", %{"url" => "http://shop/"}, 0, 1)
    appear(deck, "s2", %{"url" => "http://shop"}, 0, 2)
    Deck.poll(deck)
    assert image("a") =~ "claude-main"
    assert image("s1") =~ ">main<"
    assert image("s2") =~ ">fix<"
    Deck.handle(deck, %{"event" => "keyDown", "context" => "s2", "payload" => %{}})
    assert_received {:request, :post, "http://shop/switch", %{branch: "fix"}}
  end

  test "says when the watcher isn't running" do
    deck = start(fn _, _, _ -> {:error, :econnrefused} end)
    appear(deck, "a", %{}, 0, 0)
    Deck.poll(deck)
    assert image("a") =~ "Not running"
  end

  test "a pull key shows the checkout's branch and what GitHub has for it, and posts /pull" do
    up = Map.put(@state, "upstream", %{"sha" => "1", "behind" => 0})
    assert Deck.pull_look(up) == %{title: "Pull claude-main", status: "Up to date"}
    assert Deck.pull_look(%{up | "current" => %{"branch" => "claude/undo-sliders-abc123"}}).title == "Pull undo-sliders-abc123"
    assert Deck.pull_look(Map.put(@state, "upstream", %{"sha" => "9", "behind" => 3})).status == "3 new commits"
    assert Deck.pull_look(Map.put(@state, "upstream", nil)).status == "Not on GitHub"

    pulling = Map.merge(@state, %{"upstream" => %{"sha" => "9", "behind" => 1}, "switch" => %{"target" => "claude-main", "pull" => true, "phase" => "running", "step" => "mix deps.get"}})
    assert Deck.pull_look(pulling).status == "mix deps.get"

    me = self()
    done = Map.put(up, "switch", %{"target" => "claude-main", "pull" => true, "phase" => "done", "notes" => ["Already up to date"]})
    deck = start(fn method, url, body -> send(me, {:request, method, url, body}) && {:ok, 200, done} end)
    # A pull key doesn't take a branch from the list, so the branch key next to it still shows the first one.
    appear(deck, "p", %{}, 0, 0, "dev.clawswap.pull")
    appear(deck, "b", %{}, 0, 1)
    Deck.poll(deck)
    assert image("b") =~ "claude-main"
    Deck.handle(deck, %{"event" => "keyDown", "context" => "p", "payload" => %{}})
    assert_received {:request, :post, "http://dev/pull", %{}}
    assert_received {:sent, %{event: "showOk", context: "p"}}
  end

  test "frames WebSocket messages both ways" do
    frame = WebSocket.frame(String.duplicate("x", 300))
    # Client frames are masked; decode unmasks them.
    assert {[{:text, text}], ""} = WebSocket.decode(frame)
    assert text == String.duplicate("x", 300)
    # A server's unmasked frame, split across reads.
    server = <<1::1, 0::3, 1::4, 0::1, 5::7>> <> "hello"
    assert {[], partial} = WebSocket.decode(binary_part(server, 0, 4))
    assert {[{:text, "hello"}], ""} = WebSocket.decode(partial <> binary_part(server, 4, 3))
    # Fragments are joined.
    parts = <<0::1, 0::3, 1::4, 0::1, 3::7>> <> "hel" <> <<1::1, 0::3, 0::4, 0::1, 2::7>> <> "lo"
    assert {[{:text, "hello"}], ""} = WebSocket.decode(parts)
  end

  test "upgrades a connection" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(socket, 0)
      [_, key] = Regex.run(~r/Sec-WebSocket-Key: (\S+)/, request)
      accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
      :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n" <> <<1::1, 0::3, 1::4, 0::1, 2::7>> <> "hi")
      {:ok, frame} = :gen_tcp.recv(socket, 0)
      send(Process.whereis(:deck_test_ws) || self(), {:server_got, WebSocket.decode(frame)})
      Process.sleep(500)
    end)

    Process.register(self(), :deck_test_ws)
    {:ok, socket, rest} = WebSocket.connect("127.0.0.1", port)
    assert {[{:text, "hi"}], ""} = WebSocket.decode(rest)
    :gen_tcp.send(socket, WebSocket.frame(~s({"event":"x"})))
    assert_receive {:server_got, {[{:text, ~s({"event":"x"})}], ""}}, 2000
  end
end
